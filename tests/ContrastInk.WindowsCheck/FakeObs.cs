// A stand-in OBS for the Windows check: a WebSocket server on 127.0.0.1:4455 that speaks obs-websocket 5 the way OBS
// does (Hello with a password challenge, Identify, requests, RecordStateChanged events) and writes down every request.
// The password answer is worked out here independently of Contrast Ink's code, so a wrong recipe in the app fails.
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

sealed class FakeObs : IDisposable
{
    public const string Password = "lecture-check-pw";
    readonly TcpListener listener = new(IPAddress.Loopback, 4455);
    readonly string salt = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));
    readonly string challenge = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));
    WebSocket? client;
    readonly SemaphoreSlim sending = new(1, 1);

    public readonly ConcurrentQueue<string> Requests = new();
    public readonly ConcurrentQueue<string> ChapterNames = new();
    public volatile bool Identified, WrongPassword;
    public int Identifications;
    public volatile bool Recording, Paused;
    public double DiskMB = 50_000;
    public bool SceneHasScreen = true;
    public string OutputPath = "";
    /// <summary>StopRecord is answered after 6 s (OBS busy finishing the file): Contrast Ink gives up waiting at 5 s.</summary>
    public volatile bool StopLate;
    DateTime started; TimeSpan pausedFor; DateTime pausedAt;

    public FakeObs() { listener.Start(); _ = Task.Run(Accept); }

    /// <summary>Where Contrast Ink finds OBS's remote-control settings (as OBS 30+ saves them).</summary>
    public static string ConfigPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "obs-studio", "plugin_config", "obs-websocket", "config.json");
    public static void WriteConfig()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(ConfigPath)!);
        File.WriteAllText(ConfigPath, "{\"alerts_enabled\":false,\"auth_required\":true,\"first_load\":false,\"server_enabled\":true,\"server_password\":\"" + Password + "\",\"server_port\":4455}");
    }

    public int Count(string request) { int n = 0; foreach (var r in Requests) if (r == request) n++; return n; }
    TimeSpan Duration => !Recording ? TimeSpan.Zero : (Paused ? pausedAt : DateTime.UtcNow) - started - pausedFor;

    async Task Accept()
    {
        while (true)
        {
            TcpClient tcp;
            try { tcp = await listener.AcceptTcpClientAsync(); } catch (Exception) { return; }
            _ = Task.Run(() => Serve(tcp));
        }
    }

    async Task Serve(TcpClient tcp)
    {
        try
        {
            var stream = tcp.GetStream();
            // the HTTP upgrade, by hand (RFC 6455 section 4.2.2)
            var head = new StringBuilder();
            var one = new byte[1];
            while (!head.ToString().EndsWith("\r\n\r\n") && await stream.ReadAsync(one) == 1) head.Append((char)one[0]);
            string key = "";
            foreach (var line in head.ToString().Split("\r\n"))
                if (line.StartsWith("Sec-WebSocket-Key:", StringComparison.OrdinalIgnoreCase)) key = line[18..].Trim();
            string accept = Convert.ToBase64String(SHA1.HashData(Encoding.ASCII.GetBytes(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
            await stream.WriteAsync(Encoding.ASCII.GetBytes("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\nSec-WebSocket-Protocol: obswebsocket.json\r\n\r\n"));
            var ws = WebSocket.CreateFromStream(stream, new WebSocketCreationOptions { IsServer = true, SubProtocol = "obswebsocket.json" });

            await Send(ws, new JsonObject { ["op"] = 0, ["d"] = new JsonObject { ["obsStudioVersion"] = "31.0.0", ["obsWebSocketVersion"] = "5.5.0", ["rpcVersion"] = 1,
                ["authentication"] = new JsonObject { ["challenge"] = challenge, ["salt"] = salt } } });
            var identify = await Receive(ws);
            string secret = Convert.ToBase64String(SHA256.HashData(Encoding.UTF8.GetBytes(Password + salt)));
            string want = Convert.ToBase64String(SHA256.HashData(Encoding.UTF8.GetBytes(secret + challenge)));
            if (identify?["op"]?.GetValue<int>() != 1 || identify["d"]?["authentication"]?.GetValue<string>() != want)
            {
                WrongPassword = true;
                await ws.CloseAsync((WebSocketCloseStatus)4009, "Authentication failed.", CancellationToken.None);
                return;
            }
            await Send(ws, new JsonObject { ["op"] = 2, ["d"] = new JsonObject { ["negotiatedRpcVersion"] = 1 } });
            client = ws;
            Identified = true;
            Interlocked.Increment(ref Identifications);
            while (ws.State == WebSocketState.Open)
            {
                var m = await Receive(ws);
                if (m == null) break;
                if (m["op"]?.GetValue<int>() != 6) continue;
                var d = m["d"]!;
                string type = d["requestType"]!.GetValue<string>(), id = d["requestId"]!.GetValue<string>();
                Requests.Enqueue(type);
                if (type == "StopRecord" && StopLate) await Task.Delay(6000);   // past Contrast Ink's 5 s: it hears the event first
                var (ok, data) = Answer(type, d["requestData"] as JsonObject);
                var reply = new JsonObject { ["requestType"] = type, ["requestId"] = id, ["requestStatus"] = new JsonObject { ["result"] = ok, ["code"] = ok ? 100 : 501 } };
                if (data != null) reply["responseData"] = data;
                await Send(ws, new JsonObject { ["op"] = 7, ["d"] = reply });
            }
        }
        catch (Exception e) when (e is IOException or WebSocketException or ObjectDisposedException) { }
        finally { Identified = false; }
    }

    (bool, JsonObject?) Answer(string type, JsonObject? data)
    {
        switch (type)
        {
            case "GetRecordStatus":
                return (true, new JsonObject { ["outputActive"] = Recording, ["outputPaused"] = Paused, ["outputDuration"] = Duration.TotalMilliseconds, ["outputTimecode"] = Duration.ToString(@"hh\:mm\:ss\.fff"), ["outputBytes"] = 0 });
            case "StartRecord":
                if (Recording) return (false, null);
                Recording = true; Paused = false; started = DateTime.UtcNow; pausedFor = TimeSpan.Zero;
                _ = Event("OBS_WEBSOCKET_OUTPUT_STARTED", null);
                return (true, null);
            case "StopRecord":
                if (!Recording) return (false, null);
                Recording = false;
                _ = Event("OBS_WEBSOCKET_OUTPUT_STOPPED", OutputPath);
                return (true, new JsonObject { ["outputPath"] = OutputPath });
            case "PauseRecord":
                if (!Recording || Paused) return (false, null);
                Paused = true; pausedAt = DateTime.UtcNow; return (true, null);
            case "ResumeRecord":
                if (!Recording || !Paused) return (false, null);
                Paused = false; pausedFor += DateTime.UtcNow - pausedAt; return (true, null);
            case "CreateRecordChapter":
                if (!Recording) return (false, null);
                ChapterNames.Enqueue(data?["chapterName"]?.GetValue<string>() ?? ""); return (true, null);
            case "GetRecordDirectory":
                return (true, new JsonObject { ["recordDirectory"] = Path.GetDirectoryName(OutputPath) ?? "" });
            case "GetStats":
                return (true, new JsonObject { ["availableDiskSpace"] = DiskMB, ["cpuUsage"] = 1.0 });
            case "GetCurrentProgramScene":
                return (true, new JsonObject { ["sceneName"] = "Lecture", ["currentProgramSceneName"] = "Lecture" });
            case "GetSceneItemList":
                var items = new JsonArray();
                items.Add(new JsonObject { ["sourceName"] = "Mic", ["inputKind"] = "wasapi_input_capture", ["sceneItemEnabled"] = true, ["isGroup"] = null, ["sourceType"] = "OBS_SOURCE_TYPE_INPUT" });
                if (SceneHasScreen) items.Add(new JsonObject { ["sourceName"] = "Screen", ["inputKind"] = "monitor_capture", ["sceneItemEnabled"] = true, ["isGroup"] = null, ["sourceType"] = "OBS_SOURCE_TYPE_INPUT" });
                return (true, new JsonObject { ["sceneItems"] = items });
            default:
                return (false, null);
        }
    }

    /// <summary>Recording started from OBS's own button or hotkey.</summary>
    public async Task StartByItself()
    {
        Recording = true; Paused = false; started = DateTime.UtcNow; pausedFor = TimeSpan.Zero;
        await Event("OBS_WEBSOCKET_OUTPUT_STARTED", null);
    }

    /// <summary>OBS stopping by itself (a full disk, an encoder error): the event, without anyone asking.</summary>
    public async Task StopByItself()
    {
        Recording = false;
        await Event("OBS_WEBSOCKET_OUTPUT_STOPPED", OutputPath);
    }

    async Task Event(string state, string? path)
    {
        await Task.Delay(50);
        if (client is { } ws)
            await Send(ws, new JsonObject { ["op"] = 5, ["d"] = new JsonObject { ["eventType"] = "RecordStateChanged", ["eventIntent"] = 1 << 6,
                ["eventData"] = new JsonObject { ["outputActive"] = state.EndsWith("STARTED"), ["outputState"] = state, ["outputPath"] = path } } });
    }

    async Task Send(WebSocket ws, JsonObject m)
    {
        await sending.WaitAsync();
        try { await ws.SendAsync(Encoding.UTF8.GetBytes(m.ToJsonString()), WebSocketMessageType.Text, true, CancellationToken.None); }
        catch (Exception e) when (e is IOException or WebSocketException or ObjectDisposedException) { }
        finally { sending.Release(); }
    }

    static async Task<JsonObject?> Receive(WebSocket ws)
    {
        var buffer = new byte[64 * 1024];
        using var all = new MemoryStream();
        while (true)
        {
            var r = await ws.ReceiveAsync(buffer, CancellationToken.None);
            if (r.MessageType == WebSocketMessageType.Close) return null;
            all.Write(buffer, 0, r.Count);
            if (r.EndOfMessage) break;
        }
        return JsonNode.Parse(all.ToArray()) as JsonObject;
    }

    /// <summary>The line to Contrast Ink drops (a network hiccup, OBS's server restarted) while OBS goes on recording;
    /// Contrast Ink may connect again.</summary>
    public void DropLine()
    {
        try { client?.Abort(); } catch (Exception) { }
        client = null;
    }

    public void Dispose()
    {
        listener.Stop();
        try { client?.Abort(); } catch (Exception) { }
    }
}
