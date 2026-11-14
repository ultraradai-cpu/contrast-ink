using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace ContrastInk.Core;

/// <summary>
/// The parts of talking to OBS (its built-in obs-websocket remote control, protocol version 5) that can be tested
/// without OBS: the password answer, where OBS keeps its remote-control settings, and the chapter list.
/// Source: github.com/obsproject/obs-websocket, docs/generated/protocol.md and src/Config.cpp (read 2026-11).
/// </summary>
public static class Obs
{
    /// <summary>
    /// protocol.md, "Creating an authentication string": base64(sha256(password + salt)) is the secret;
    /// the answer is base64(sha256(secret + challenge)).
    /// </summary>
    public static string Auth(string password, string salt, string challenge)
    {
        string secret = Convert.ToBase64String(SHA256.HashData(Encoding.UTF8.GetBytes(password + salt)));
        return Convert.ToBase64String(SHA256.HashData(Encoding.UTF8.GetBytes(secret + challenge)));
    }

    /// <summary>OBS's remote-control settings. Password is null when OBS asks for none.</summary>
    public sealed record Connection(bool Enabled, int Port, string? Password);

    /// <summary>
    /// Reads OBS's own remote-control settings, so nothing has to be typed into Contrast Ink.
    /// OBS 30 and later: %AppData%\obs-studio\plugin_config\obs-websocket\config.json. OBS 28 and 29 kept them in
    /// global.ini, section [OBSWebSocket] (src/Config.cpp moves them across). Defaults are OBS's own: off, port 4455,
    /// password required. Null when OBS has never saved them (OBS not installed, or never opened).
    /// </summary>
    public static Connection? ReadConfig(string appData)
    {
        string dir = Path.Combine(appData, "obs-studio");
        try
        {
            string json = Path.Combine(dir, "plugin_config", "obs-websocket", "config.json");
            if (File.Exists(json))
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(json));
                var r = doc.RootElement;
                bool enabled = r.TryGetProperty("server_enabled", out var e) && e.ValueKind == JsonValueKind.True;
                int port = r.TryGetProperty("server_port", out var p) && p.TryGetInt32(out var n) ? n : 4455;
                bool auth = !r.TryGetProperty("auth_required", out var a) || a.ValueKind != JsonValueKind.False;
                string? pass = r.TryGetProperty("server_password", out var pw) && pw.ValueKind == JsonValueKind.String ? pw.GetString() : null;
                return new Connection(enabled, port, auth ? pass ?? "" : null);
            }
            foreach (var ini in new[] { "user.ini", "global.ini" })
            {
                var path = Path.Combine(dir, ini);
                if (!File.Exists(path)) continue;
                var v = IniSection(File.ReadAllLines(path), "OBSWebSocket");
                if (v.Count == 0) continue;
                bool enabled = v.TryGetValue("ServerEnabled", out var e) && e.Equals("true", StringComparison.OrdinalIgnoreCase);
                int port = v.TryGetValue("ServerPort", out var p) && int.TryParse(p, out var n) ? n : 4455;
                bool auth = !(v.TryGetValue("AuthRequired", out var a) && a.Equals("false", StringComparison.OrdinalIgnoreCase));
                return new Connection(enabled, port, auth ? v.GetValueOrDefault("ServerPassword", "") : null);
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { }
        return null;
    }

    static Dictionary<string, string> IniSection(string[] lines, string section)
    {
        var d = new Dictionary<string, string>();
        bool inside = false;
        foreach (var raw in lines)
        {
            var line = raw.Trim();
            if (line.StartsWith('[')) { inside = line == "[" + section + "]"; continue; }
            int eq = line.IndexOf('=');
            if (inside && eq > 0) d[line[..eq]] = line[(eq + 1)..];
        }
        return d;
    }

    /// <summary>YouTube's shortest chapter: one shorter makes it ignore the whole list.</summary>
    public const double MinChapterSeconds = 10;

    /// <summary>
    /// A chapter list in the form YouTube reads from a video description: "0:00 Slide 1", one per line, the first at
    /// 0:00 and in time order, none shorter than 10 s (YouTube drops the whole list for one shorter chapter). A slide
    /// shown less than 10 s (clicked past) gives its place to the slide after it; a first slide within 10 s of the
    /// start starts at 0:00 (later than that, a "Start" chapter comes first); and when <paramref name="end"/> (the
    /// video's length) is known, a last slide shown less than 10 s before the end is left to the one before it.
    /// </summary>
    public static string Chapters(IReadOnlyList<(TimeSpan at, string name)> chapters, TimeSpan? end = null)
    {
        var kept = new List<(TimeSpan at, string name)>();
        foreach (var c in chapters.OrderBy(c => c.at))
        {
            var at = c.at < TimeSpan.Zero ? TimeSpan.Zero : c.at;
            if (kept.Count == 0)
            {
                if (at.TotalSeconds >= MinChapterSeconds) kept.Add((TimeSpan.Zero, "Start"));
                kept.Add((kept.Count == 0 ? TimeSpan.Zero : at, c.name));
            }
            else if ((at - kept[^1].at).TotalSeconds < MinChapterSeconds) kept[^1] = (kept[^1].at, c.name);
            else kept.Add((at, c.name));
        }
        if (kept.Count == 0) return "";
        if (end is { } e && kept.Count > 1 && (e - kept[^1].at).TotalSeconds < MinChapterSeconds) kept.RemoveAt(kept.Count - 1);
        bool hours = kept[^1].at.TotalHours >= 1;
        return string.Join("\n", kept.Select(c => Time(c.at, hours) + " " + c.name)) + "\n";
    }

    /// <summary>"4:05", or "1:04:05" when the video passes an hour (then every line has hours, as YouTube expects).</summary>
    public static string Time(TimeSpan t, bool hours) =>
        hours ? $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}" : $"{(int)t.TotalMinutes}:{t.Seconds:00}";

    /// <summary>The slide number in a slide-watcher key ("C:\x.pptx#5#12" is 12: position 5 in the show, slide 12); null outside a slide show.</summary>
    public static int? SlideNumber(string key)
    {
        int hash = key.LastIndexOf('#');
        return hash >= 0 && int.TryParse(key[(hash + 1)..], out var n) && n > 0 ? n : null;
    }

    /// <summary>Below this much free space on the recording disk, the toolbar warns (OBS reports it in MB).</summary>
    public const double LowDiskMB = 2048;
}

/// <summary>
/// The chapters of the recording in progress, in the recording's own time (OBS's outputDuration). A recording taken
/// over while it runs (OBS started first, or the line to OBS dropped, or Contrast Ink was restarted) gets its first
/// chapter at the time it has reached, not at 0:00; taken over again after a dropped line, it is the same recording
/// (its time has gone on from where it was) and its chapters so far are kept.
/// </summary>
public sealed class ChapterLog
{
    readonly List<(TimeSpan at, string name)> items = new();
    TimeSpan? seen;   // the recording's time last seen; null: no recording followed since the last one ended

    public IReadOnlyList<(TimeSpan at, string name)> Items => items;
    /// <summary>The slide-watcher key of the last chapter ("" before the first).</summary>
    public string LastKey { get; private set; } = "";

    /// <summary>
    /// A recording is followed from <paramref name="at"/> into it (zero for one that just started), on the slide
    /// showing now. True when it is the recording followed before (its chapters were kept).
    /// </summary>
    public bool Begin(TimeSpan at, string slideKey)
    {
        bool same = at > TimeSpan.Zero && seen is { } s && at >= s;
        if (!same) { items.Clear(); LastKey = ""; }
        Seen(at);
        Add(at, slideKey);
        return same;
    }

    /// <summary>A slide change at <paramref name="at"/>: a chapter, unless it is no slide or the same slide. True when added.</summary>
    public bool Add(TimeSpan at, string slideKey)
    {
        Seen(at);
        if (Obs.SlideNumber(slideKey) is not int n || slideKey == LastKey) return false;
        LastKey = slideKey;
        items.Add((at, "Slide " + n));
        return true;
    }

    /// <summary>The recording's time as OBS reported it (on every status check).</summary>
    public void Seen(TimeSpan at) { if (seen is not { } s || at > s) seen = at; }

    /// <summary>The recording ended: the next one is a new recording.</summary>
    public void Ended() => seen = null;
}
