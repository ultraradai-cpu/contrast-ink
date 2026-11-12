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
    public const int Port = 47820, Version = 2;
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

    /// <summary>The REJECT texts (docs/pad-protocol.md lists them; the tablets show them as they are).</summary>
    public const string UpdateTablet = "Please update Contrast Ink on the tablet.",
        TooManyWrong = "Too many wrong codes: wait 30 seconds, then try again.",
        WrongCode = "Wrong code: type the code Contrast Ink shows on the PC (⚙ Settings).";

    public static byte[] StateMessage(Settings s, bool canUndo) =>
        Message(State, JsonSerializer.Serialize(new
        {
            tool = s.Tool.ToString().ToLowerInvariant(), color = s.Color, width = s.Width,
            opacity = Math.Round(s.Opacity, 2), fading = s.FadingInk, canUndo,
        }));

    /// <summary>
    /// A version-2 HELLO: the tablet's name and its fresh public key (65 bytes). Null for anything else, including a
    /// version-1 HELLO (it carries the code in the clear: such a tablet must be updated). Never throws.
    /// </summary>
    public static (string device, byte[] key)? ReadHelloV2(ReadOnlySpan<byte> payload)
    {
        if (payload.Length > HelloMax) return null;
        try
        {
            using var doc = JsonDocument.Parse(payload.ToArray());
            var r = doc.RootElement;
            if (r.ValueKind != JsonValueKind.Object) return null;
            if (!r.TryGetProperty("version", out var v) || v.ValueKind != JsonValueKind.Number || !v.TryGetInt32(out var ver) || ver < 2) return null;
            if (!r.TryGetProperty("key", out var k) || k.ValueKind != JsonValueKind.String) return null;
            var key = Convert.FromBase64String(k.GetString() ?? "");
            if (key.Length != 65) return null;
            var device = r.TryGetProperty("device", out var d) && d.ValueKind == JsonValueKind.String ? d.GetString() ?? "" : "";
            device = new string(device.Where(ch => !char.IsControl(ch)).Take(40).ToArray()).Trim();
            return (device.Length == 0 ? "a tablet" : device, key);
        }
        catch (Exception) { return null; }
    }

    public static byte[] ChallengeMessage(byte[] pcKey, byte[] salt, string name) =>
        Message(PadCrypto.Challenge, JsonSerializer.Serialize(new { key = Convert.ToBase64String(pcKey), salt = Convert.ToBase64String(salt), name }));

    /// <summary>The PC check shown beside the code: the first 4 bytes of SHA-256 of the PC's public key, "6FC6-6A90".</summary>
    public static string PcCheck(byte[] pcKey)
    {
        var h = System.Security.Cryptography.SHA256.HashData(pcKey);
        return $"{h[0]:X2}{h[1]:X2}-{h[2]:X2}{h[3]:X2}";
    }

    /// <summary>The longest HELLO accepted (a stranger's first message: small, so it can't be used to fill memory).</summary>
    public const int HelloMax = 1024;

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
    byte[] buffer = new byte[4096];
    int start, end;   // the bytes not yet taken are buffer[start..end]

    /// <summary>The longest message accepted now (lowered to <see cref="Pad.HelloMax"/> before a tablet is let in).</summary>
    public int MaxLength { get; set; } = Pad.MaxLength;

    /// <summary>Adds what arrived; returns every message now complete. Throws when a length is past the limit.</summary>
    public List<(byte type, byte[] payload)> Add(ReadOnlySpan<byte> data)
    {
        if (end + data.Length > buffer.Length)
        {
            // move what is left to the front, and grow only when that isn't enough
            int left = end - start;
            var into = left + data.Length > buffer.Length ? new byte[Math.Max(buffer.Length * 2, left + data.Length)] : buffer;
            Array.Copy(buffer, start, into, 0, left);
            buffer = into; start = 0; end = left;
        }
        data.CopyTo(buffer.AsSpan(end));
        end += data.Length;
        var done = new List<(byte, byte[])>();
        while (end - start >= 5)
        {
            uint len = BinaryPrimitives.ReadUInt32BigEndian(buffer.AsSpan(start + 1));
            if (len > (uint)MaxLength) throw new InvalidDataException("pad message too long: " + len);
            if (end - start < 5 + len) break;
            done.Add((buffer[start], buffer.AsSpan(start + 5, (int)len).ToArray()));
            start += 5 + (int)len;
        }
        if (start == end) start = end = 0;
        return done;
    }
}

/// <summary>
/// Wrong codes: a 6-digit code must not be guessable by a script on the same Wi-Fi. Five wrong in a row lock
/// everyone out for 30 s; twenty wrong in all make a new code (the presenter sees it change). At most about
/// 10 guesses a minute, against a code that changes every 20: guessing it is a 1 in 50,000 chance.
/// </summary>
public sealed class PadGuard
{
    public const int InARow = 5, BeforeNewCode = 20;
    public static readonly TimeSpan Lockout = TimeSpan.FromSeconds(30);
    int wrongInARow, wrongForThisCode;
    DateTime lockedUntil = DateTime.MinValue;

    /// <summary>Whether a HELLO may be tried at all right now.</summary>
    public bool Locked(DateTime now) => now < lockedUntil;

    /// <summary>A wrong code was given. True: time for a new code.</summary>
    public bool Wrong(DateTime now)
    {
        wrongForThisCode++;
        if (++wrongInARow >= InARow) { wrongInARow = 0; lockedUntil = now + Lockout; }
        if (wrongForThisCode < BeforeNewCode) return false;
        wrongForThisCode = 0;
        return true;
    }

    /// <summary>The right code: the count of guesses in a row starts again.</summary>
    public void Right() => wrongInARow = 0;
}
