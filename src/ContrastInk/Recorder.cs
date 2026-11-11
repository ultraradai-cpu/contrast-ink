using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using System.Windows.Threading;
using ContrastInk.Core;

namespace ContrastInk;

/// <summary>
/// Recording from the toolbar: ⏺ / ⏹, ⏸ / ▶, a timer, chapters at every slide change, and a warning on the toolbar
/// when OBS stops by itself, the line to OBS drops, the disk is filling up, or the scene has no Display Capture.
/// OBS does the recording; nothing here touches the video.
/// </summary>
sealed class Recorder
{
    readonly ObsLink obs = new();
    readonly ToolbarWindow toolbar;
    readonly Func<string> currentSlide;
    readonly Dispatcher ui;
    readonly DispatcherTimer clock;

    public enum State { Idle, Starting, Recording, Paused, Stopping }
    State state = State.Idle;
    bool stopAsked;   // a stop we asked for (anything else is OBS stopping by itself)
    TimeSpan elapsed;
    int ticks;
    bool ticking;           // one status check at a time, even if OBS is slow to answer
    bool diskWarned;        // the low-disk message once per recording: dismissed, it should stay dismissed
    bool connectNotice;     // the message on show is about reaching OBS: cleared once OBS is reached
    string lastChapterSlide = "";
    string? recordFolder;   // OBS's recording folder, learned at the start: OBS may be gone when the chapters are saved

    /// <summary>OBS is recording (or paused) as far as Contrast Ink knows.</summary>
    public bool Active => state is State.Recording or State.Paused or State.Stopping;
    readonly List<(TimeSpan at, string name)> chapters = new();

    public Recorder(ToolbarWindow toolbar, Func<string> currentSlide, Dispatcher ui)
    {
        this.toolbar = toolbar;
        this.currentSlide = currentSlide;
        this.ui = ui;
        obs.RecordState += (s, path) => ui.BeginInvoke(() => OnRecordState(s, path));
        obs.Lost += () => ui.BeginInvoke(OnLost);
        clock = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        clock.Tick += async (_, _) => await Tick();
        clock.Start();
        Show();
    }

    void Show() => toolbar.ShowRecording(state, obs.Connected, elapsed);

    /// <summary>⏺ / ⏹ pressed.</summary>
    public async void RecordClicked()
    {
        try
        {
            if (state is State.Recording or State.Paused) { await Stop(); return; }
            if (state != State.Idle) return;
            state = State.Starting; Show();
            var problem = await obs.Connect();
            if (problem != null) { state = State.Idle; toolbar.Notice(problem); connectNotice = true; Show(); return; }
            toolbar.Notice(null); connectNotice = false;
            var scene = await SceneProblem();
            var status = await obs.Request("GetRecordStatus");
            if (status?["outputActive"]?.GetValue<bool>() == true)
            {
                // already recording (started in OBS itself): take it over rather than start a second one
                state = status["outputPaused"]?.GetValue<bool>() == true ? State.Paused : State.Recording;
            }
            else if (await obs.Request("StartRecord") == null)
            {
                state = State.Idle; toolbar.Notice("OBS didn't start recording. Look at OBS for the reason (often the recording folder or the disk)."); Show(); return;
            }
            else state = State.Recording;
            Began();
            if (scene != null) toolbar.Notice(scene);
            Show();
            await CheckDisk();
        }
        catch (Exception e) { App.Log(e); state = State.Idle; Show(); }
    }

    /// <summary>A recording began (here, or in OBS itself): start its chapter list on the slide showing now.</summary>
    void Began()
    {
        stopAsked = false;
        diskWarned = false;
        elapsed = TimeSpan.Zero;
        chapters.Clear();
        lastChapterSlide = "";
        var slide = currentSlide();
        if (Obs.SlideNumber(slide) is int n) { chapters.Add((TimeSpan.Zero, "Slide " + n)); lastChapterSlide = slide; }
        LearnRecordFolder();
    }

    async void LearnRecordFolder()
    {
        try { recordFolder = (await obs.Request("GetRecordDirectory"))?["recordDirectory"]?.GetValue<string>(); }
        catch (Exception e) { App.Log(e); }
    }

    /// <summary>⏸ / ▶ pressed.</summary>
    public async void PauseClicked()
    {
        try
        {
            if (state == State.Recording && await obs.Request("PauseRecord") != null) state = State.Paused;
            else if (state == State.Paused && await obs.Request("ResumeRecord") != null)
            {
                state = State.Recording;
                // slides changed while paused: the video goes on from the slide showing now, so it gets its chapter
                if (currentSlide() != lastChapterSlide) SlideChanged(currentSlide());
            }
            Show();
        }
        catch (Exception e) { App.Log(e); }
    }

    async Task Stop()
    {
        state = State.Stopping; stopAsked = true; Show();
        var r = await obs.Request("StopRecord");
        if (r == null) { state = State.Recording; toolbar.Notice("OBS didn't stop. Stop it in OBS itself."); Show(); return; }
        Finished(r["outputPath"]?.GetValue<string>());
    }

    void Finished(string? path)
    {
        if (state == State.Idle) return;   // already handled (the reply and OBS's event both say so)
        state = State.Idle;
        WriteChapters(path);
        Show();
    }

    /// <summary>A slide change: a chapter in the video (Hybrid MP4 in OBS 30.2+) and in the chapters file beside it.</summary>
    public async void SlideChanged(string key)
    {
        try
        {
            if (state != State.Recording || Obs.SlideNumber(key) is not int n || key == lastChapterSlide) return;
            lastChapterSlide = key;
            var status = await obs.Request("GetRecordStatus");
            var at = status?["outputDuration"] is JsonNode ms ? TimeSpan.FromMilliseconds(ms.GetValue<double>()) : elapsed;
            chapters.Add((at, "Slide " + n));
            await obs.Request("CreateRecordChapter", new JsonObject { ["chapterName"] = "Slide " + n });   // older OBS / other formats: says no, fine
        }
        catch (Exception e) { App.Log(e); }
    }

    void OnRecordState(string s, string? path)
    {
        switch (s)
        {
            case "OBS_WEBSOCKET_OUTPUT_STARTED":
                // started from OBS itself (its button or its hotkey): follow it, so ⏹, the timer and chapters work too
                if (state == State.Idle) { state = State.Recording; Began(); Show(); }
                break;
            case "OBS_WEBSOCKET_OUTPUT_STOPPED":
                if (state == State.Idle) return;
                if (!stopAsked) toolbar.Notice("OBS stopped recording by itself. What was recorded is saved" + (path != null ? ": " + path : "") + ". Press ⏺ to record again.");
                Finished(path);
                break;
            case "OBS_WEBSOCKET_OUTPUT_PAUSED": if (state == State.Recording) { state = State.Paused; Show(); } break;
            case "OBS_WEBSOCKET_OUTPUT_RESUMED": if (state == State.Paused) { state = State.Recording; Show(); } break;
        }
    }

    void OnLost()
    {
        if (state is State.Recording or State.Paused or State.Stopping)
        {
            // the video's name is only known when OBS reports it stopped, which it now can't: keep the chapters anyway
            string? saved = SaveOrphanChapters();
            toolbar.Notice("Lost contact with OBS while recording. Check OBS: if it closed, what was recorded so far is in its recording folder."
                + (saved != null ? " The chapters are in " + saved + "." : ""));
        }
        state = State.Idle;
        Show();
    }

    /// <summary>The chapters, saved in OBS's recording folder (else Documents) with the time in the name. Null if none.</summary>
    string? SaveOrphanChapters()
    {
        if (chapters.Count < 2) return null;
        try
        {
            string folder = recordFolder is { Length: > 0 } f && Directory.Exists(f) ? f : Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
            string path = Path.Combine(folder, $"Contrast Ink chapters {DateTime.Now:yyyy-MM-dd HHmm}.txt");
            File.WriteAllText(path, Obs.Chapters(chapters));
            return path;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { App.Log(e); return null; }
    }

    async Task Tick()
    {
        if (ticking) return;
        ticking = true;
        try
        {
            if (state is State.Recording or State.Paused)
            {
                var status = await obs.Request("GetRecordStatus");
                if (status?["outputDuration"] is JsonNode ms) elapsed = TimeSpan.FromMilliseconds(ms.GetValue<double>());
                if (++ticks % 15 == 0) await CheckDisk();
            }
            else if (!obs.Connected && ++ticks % 5 == 0 && Obs.ReadConfig(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData)) is { Enabled: true }
                     && await obs.Connect() == null)   // quietly, so ⏺ shows whether OBS is ready
            {
                if (connectNotice) { toolbar.Notice(null); connectNotice = false; }   // "can't reach OBS" is no longer true
                // OBS may already be recording (started before Contrast Ink, or before the line dropped): follow it
                var status = await obs.Request("GetRecordStatus");
                if (state == State.Idle && status?["outputActive"]?.GetValue<bool>() == true)
                {
                    state = status["outputPaused"]?.GetValue<bool>() == true ? State.Paused : State.Recording;
                    Began();
                }
            }
            Show();
        }
        catch (Exception e) { App.Log(e); }
        finally { ticking = false; }
    }

    async Task CheckDisk()
    {
        var stats = await obs.Request("GetStats");
        if (!diskWarned && stats?["availableDiskSpace"] is JsonNode mb && mb.GetValue<double>() < Obs.LowDiskMB)   // MB (obs-websocket: bytes / 1024²)
        {
            diskWarned = true;
            toolbar.Notice($"Only {mb.GetValue<double>() / 1024:0.0} GB left on the recording disk. Free some space, or stop soon.");
        }
    }

    /// <summary>A warning if the scene being recorded has no Display Capture (then the marks aren't in the video).</summary>
    async Task<string?> SceneProblem()
    {
        var scene = await obs.Request("GetCurrentProgramScene");
        string? name = scene?["sceneName"]?.GetValue<string>() ?? scene?["currentProgramSceneName"]?.GetValue<string>();
        if (name == null) return null;   // couldn't ask: say nothing rather than something wrong
        if (await HasScreen("GetSceneItemList", name, 0)) return null;
        return $"OBS's scene \"{name}\" has no Display Capture, so your marks won't be in the video. In OBS: Sources, +, Display Capture.";
    }

    async Task<bool> HasScreen(string request, string name, int depth)
    {
        var items = (await obs.Request(request, new JsonObject { ["sceneName"] = name }))?["sceneItems"] as JsonArray;
        if (items == null) return true;   // couldn't tell
        foreach (var item in items.OfType<JsonObject>())
        {
            if (item["sceneItemEnabled"]?.GetValue<bool>() == false) continue;
            string? kind = item["inputKind"]?.GetValue<string>();
            if (kind is "monitor_capture" or "display_capture" or "screen_capture" or "xshm_input" or "pipewire-desktop-capture-source") return true;
            string? source = item["sourceName"]?.GetValue<string>();
            if (source == null || depth > 3) continue;
            if (item["isGroup"]?.GetValue<bool>() == true && await HasScreen("GetGroupSceneItemList", source, depth + 1)) return true;
            if (item["sourceType"]?.GetValue<string>() == "OBS_SOURCE_TYPE_SCENE" && await HasScreen("GetSceneItemList", source, depth + 1)) return true;
        }
        return false;
    }

    void WriteChapters(string? video)
    {
        if (video == null || chapters.Count < 2) return;
        try { File.WriteAllText(Path.ChangeExtension(video, null) + " chapters.txt", Obs.Chapters(chapters)); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { App.Log(e); }
    }
}
