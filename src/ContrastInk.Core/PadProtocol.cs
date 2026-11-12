using System.Buffers.Binary;
using System.Text;
using System.Text.Json;

namespace ContrastInk.Core;

/// <summary>
/// The link between the PC and a tablet used as a pad (docs/pad-protocol.md): every message is
/// [type: 1 byte][length: 4 bytes, big-endian][payload]. Kept free of sockets so it is tested anywhere.
/// </summary>
public static class Pad
{
    public const int Port = 47820, Version = 1;
    public const string ServiceType = "_contrastink._tcp";
    public const int MaxLength = 16 * 1024 * 1024;

    // tablet → PC
    public const byte Hello = 0x01, Ping = 0x02, FrameAck = 0x03,
        StrokeBegin = 0x10, StrokePoints = 0x11, StrokeEnd = 0x12, StrokeCancel = 0x13, Hover = 0x14, HoverEnd = 0x15,
        Command = 0x20;
    // PC → tablet
    public const byte Welcome = 0x81, Reject = 0x82, Frame = 0x83, State = 0x84, Pong = 0x85;

    public static byte[] Message(byte type, ReadOnlySpan<byte> payload)
    {
        var m = new byte[5 + payload.Length];
        m[0] = type;
        BinaryPrimitives.WriteUInt32BigEndian(m.AsSpan(1), (uint)payload.Length);
        payload.CopyTo(m.AsSpan(5));
        return m;
    }

    public static byte[] Message(byte type, string utf8) => Message(type, Encoding.UTF8.GetBytes(utf8));

    public static byte[] WelcomeMessage(string name, int screenW, int screenH) =>
        Message(Welcome, JsonSerializer.Serialize(new { name, screenW, screenH, version = Version }));

    public static byte[] StateMessage(Settings s, bool canUndo) =>
        Message(State, JsonSerializer.Serialize(new
        {
            tool = s.Tool.ToString().ToLowerInvariant(), color = s.Color, width = s.Width,
            opacity = Math.Round(s.Opacity, 2), fading = s.FadingInk, canUndo,
        }));

    /// <summary>What a tablet's HELLO says; null when it isn't one we understand.</summary>
    public static (string code, string device)? ReadHello(ReadOnlySpan<byte> payload)
    {
        try
        {
            using var doc = JsonDocument.Parse(payload.ToArray());
            var r = doc.RootElement;
            var code = r.TryGetProperty("code", out var c) && c.ValueKind == JsonValueKind.String ? c.GetString()! : "";
            var device = r.TryGetProperty("device", out var d) && d.ValueKind == JsonValueKind.String ? d.GetString()! : "a tablet";
            return (code, device);
        }
        catch (JsonException) { return null; }
    }

    /// <summary>STROKE_BEGIN: where (fractions of the screen) and whether the pen's eraser end touched.</summary>
    public static (float x, float y, bool eraserEnd)? ReadBegin(ReadOnlySpan<byte> p) =>
        p.Length < 9 ? null : (F(p, 0), F(p, 4), p[8] == 1);

    /// <summary>STROKE_POINTS: the points (fractions of the screen), clamped to the screen.</summary>
    public static List<(float x, float y)> ReadPoints(ReadOnlySpan<byte> p)
    {
        var pts = new List<(float, float)>();
        if (p.Length < 2) return pts;
        int n = BinaryPrimitives.ReadUInt16BigEndian(p);
        for (int i = 0; i < n && 2 + i * 8 + 8 <= p.Length; i++) pts.Add((F(p, 2 + i * 8), F(p, 6 + i * 8)));
        return pts;
    }

    /// <summary>HOVER: where the pen is above the glass.</summary>
    public static (float x, float y)? ReadHover(ReadOnlySpan<byte> p) => p.Length < 8 ? null : (F(p, 0), F(p, 4));

    static float F(ReadOnlySpan<byte> p, int at)
    {
        float v = BinaryPrimitives.ReadSingleBigEndian(p[at..]);
        return float.IsFinite(v) ? Math.Clamp(v, 0f, 1f) : 0f;
    }

    /// <summary>A COMMAND, as what the app should do. Null for one it doesn't know (a newer tablet).</summary>
    public static PadCommand? ReadCommand(ReadOnlySpan<byte> p)
    {
        var s = Encoding.UTF8.GetString(p).Trim();
        switch (s)
        {
            case "undo": return new PadCommand(PadAction.Undo);
            case "clear": return new PadCommand(PadAction.Clear);
            case "next": return new PadCommand(PadAction.Next);
            case "previous": return new PadCommand(PadAction.Previous);
            case "fade:on": return new PadCommand(PadAction.Fade, 1);
            case "fade:off": return new PadCommand(PadAction.Fade, 0);
        }
        int colon = s.IndexOf(':');
        if (colon < 0) return null;
        string key = s[..colon], value = s[(colon + 1)..];
        switch (key)
        {
            case "tool" when Enum.TryParse<Tool>(value, ignoreCase: true, out var t) && Enum.IsDefined(t):
                return new PadCommand(PadAction.Tool, (int)t);
            case "color" when int.TryParse(value, out var c) && c >= 0 && c < Settings.Colors.Length:
                return new PadCommand(PadAction.Color, c);
            case "width" when int.TryParse(value, out var w) && w >= 0 && w < Settings.Widths.Length:
                return new PadCommand(PadAction.Width, w);
            case "opacity" when double.TryParse(value, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var o) && double.IsFinite(o):
                return new PadCommand(PadAction.Opacity, 0, Math.Clamp(o, Settings.MinOpacity, 1));
        }
        return null;
    }

    /// <summary>A new 6-digit code for this run of the app (what a tablet must type to draw on this PC).</summary>
    public static string NewCode() => System.Security.Cryptography.RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6");
}

public enum PadAction { Undo, Clear, Next, Previous, Fade, Tool, Color, Width, Opacity }

public readonly record struct PadCommand(PadAction Action, int Value = 0, double Amount = 0);

/// <summary>Splits a byte stream into messages, however it arrives (a message across reads, several in one).</summary>
public sealed class PadReader
{
    readonly List<byte> buffer = new();

    /// <summary>Adds what arrived; returns every message now complete. Throws when a length is past the limit.</summary>
    public List<(byte type, byte[] payload)> Add(ReadOnlySpan<byte> data)
    {
        buffer.AddRange(data.ToArray());
        var done = new List<(byte, byte[])>();
        while (buffer.Count >= 5)
        {
            var head = buffer.GetRange(0, 5).ToArray();
            uint len = BinaryPrimitives.ReadUInt32BigEndian(head.AsSpan(1));
            if (len > Pad.MaxLength) throw new InvalidDataException("pad message too long: " + len);
            if (buffer.Count < 5 + len) break;
            done.Add((head[0], buffer.GetRange(5, (int)len).ToArray()));
            buffer.RemoveRange(0, 5 + (int)len);
        }
        return done;
    }
}
