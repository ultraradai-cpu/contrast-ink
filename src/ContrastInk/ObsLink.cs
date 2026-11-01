using System;
using System.Collections.Concurrent;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using ContrastInk.Core;

namespace ContrastInk;

/// <summary>
/// The line to OBS's built-in remote control (obs-websocket 5, in OBS 28 and later). OBS keeps doing the recording;
/// this only asks it to start, pause and stop, and listens for what it reports.
/// Every call is made from the UI thread; replies and events arrive on a background reader.
/// </summary>
sealed class ObsLink
{
    ClientWebSocket? ws;
    readonly ConcurrentDictionary<string, TaskCompletionSource<JsonObject>> pending = new();
    readonly SemaphoreSlim sending = new(1, 1);

    /// <summary>OBS reported a change in recording: (state, file path when it stopped). Raised on the reader thread.</summary>
    public event Action<string, string?>? RecordState;
    /// <summary>The line to OBS dropped (OBS closed or crashed). Raised on the reader thread.</summary>
    public event Action? Lost;

    public bool Connected => ws?.State == WebSocketState.Open;

    /// <summary>
    /// Connects if not connected. Null on success, otherwise what the presenter should do about it.
    /// </summary>
    public async Task<string?> Connect()
    {
        if (Connected) return null;
        var cfg = Obs.ReadConfig(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData));
        if (cfg == null) return "OBS isn't set up on this computer yet. Install OBS Studio 28 or newer and open it once.";
        if (!cfg.Enabled) return "In OBS, open Tools → WebSocket Server Settings and tick Enable WebSocket Server. Then press ⏺ again.";
        var socket = new ClientWebSocket();
        socket.Options.AddSubProtocol("obswebsocket.json");
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(4));
            await socket.ConnectAsync(new Uri($"ws://127.0.0.1:{cfg.Port}"), timeout.Token);
            var hello = await Receive(socket, timeout.Token);
            if (hello?["op"]?.GetValue<int>() != 0) throw new WebSocketException("OBS did not say hello");
            var identify = new JsonObject { ["rpcVersion"] = 1, ["eventSubscriptions"] = 1 << 6 };   // EventSubscription::Outputs
            if (hello["d"]?["authentication"] is JsonObject auth)
                identify["authentication"] = Obs.Auth(cfg.Password ?? "", (string)auth["salt"]!, (string)auth["challenge"]!);
            await Send(socket, new JsonObject { ["op"] = 1, ["d"] = identify }, timeout.Token);
            var identified = await Receive(socket, timeout.Token);
            if (identified?["op"]?.GetValue<int>() != 2)
            {
                string why = Refused(socket) ?? "OBS didn't accept Contrast Ink's connection. Restart OBS and press ⏺ again.";
                socket.Dispose();
                return why;
            }
        }
        catch (Exception e) when (e is WebSocketException or OperationCanceledException or System.Net.Http.HttpRequestException or JsonException)
        {
            string why = Refused(socket) ?? "Can't reach OBS. Open OBS (and in Tools → WebSocket Server Settings, Enable WebSocket Server on port " + cfg.Port + "), then press ⏺ again.";
            socket.Dispose();
            return why;
        }
        ws = socket;
        _ = Task.Run(() => ReadLoop(socket));
        return null;
    }

    // protocol.md, WebSocketCloseCode::AuthenticationFailed (4009): OBS closes the line instead of answering
    static string? Refused(ClientWebSocket s) => s.CloseStatus == (WebSocketCloseStatus)4009
        ? "OBS refused the password it saved. In OBS, open Tools → WebSocket Server Settings, press Apply, and press ⏺ again."
        : null;

    /// <summary>Asks OBS for something. Null when OBS said no or didn't answer in 5 seconds.</summary>
    public async Task<JsonObject?> Request(string type, JsonObject? data = null)
    {
        var socket = ws;
        if (socket == null || socket.State != WebSocketState.Open) return null;
        string id = Guid.NewGuid().ToString("N");
        var reply = new TaskCompletionSource<JsonObject>(TaskCreationOptions.RunContinuationsAsynchronously);
        pending[id] = reply;
        try
        {
            var d = new JsonObject { ["requestType"] = type, ["requestId"] = id };
            if (data != null) d["requestData"] = data;
            await Send(socket, new JsonObject { ["op"] = 6, ["d"] = d }, CancellationToken.None);
            var done = await Task.WhenAny(reply.Task, Task.Delay(5000));
            if (done != reply.Task) return null;
            var r = reply.Task.Result;
            if (r["requestStatus"]?["result"]?.GetValue<bool>() != true) return null;
            return r["responseData"] as JsonObject ?? new JsonObject();
        }
        catch (Exception e) when (e is WebSocketException or ObjectDisposedException or InvalidOperationException) { return null; }
        finally { pending.TryRemove(id, out _); }
    }

    async Task ReadLoop(ClientWebSocket socket)
    {
        try
        {
            while (socket.State == WebSocketState.Open)
            {
                var m = await Receive(socket, CancellationToken.None);
                if (m == null) break;
                var d = m["d"] as JsonObject;
                int op = m["op"]?.GetValue<int>() ?? -1;
                if (op == 7 && d?["requestId"]?.GetValue<string>() is { } id && pending.TryGetValue(id, out var tcs)) tcs.TrySetResult(d);
                else if (op == 5 && d?["eventType"]?.GetValue<string>() == "RecordStateChanged")
                {
                    var ev = d["eventData"];
                    RecordState?.Invoke(ev?["outputState"]?.GetValue<string>() ?? "", ev?["outputPath"]?.GetValue<string>());
                }
            }
        }
        catch (Exception e) when (e is WebSocketException or JsonException or InvalidOperationException or ObjectDisposedException) { }
        catch (Exception e) { App.Log(e); }
        if (ws == socket) ws = null;
        socket.Dispose();
        Lost?.Invoke();
    }

    async Task Send(ClientWebSocket socket, JsonObject message, CancellationToken token)
    {
        var bytes = Encoding.UTF8.GetBytes(message.ToJsonString());
        await sending.WaitAsync(token);
        try { await socket.SendAsync(bytes, WebSocketMessageType.Text, true, token); }
        finally { sending.Release(); }
    }

    static async Task<JsonObject?> Receive(ClientWebSocket socket, CancellationToken token)
    {
        var buffer = new byte[16 * 1024];
        using var all = new System.IO.MemoryStream();
        while (true)
        {
            var r = await socket.ReceiveAsync(buffer, token);
            if (r.MessageType == WebSocketMessageType.Close) return null;
            all.Write(buffer, 0, r.Count);
            if (r.EndOfMessage) break;
        }
        return JsonNode.Parse(all.ToArray()) as JsonObject;
    }
}
