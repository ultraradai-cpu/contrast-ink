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
    /// <summary>The USB door: the PC's loopback port Android's USB link reaches, and the iPad's own loopback port.</summary>
    public const int UsbPort = 47830;
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
        WrongCode = "Wrong code: type the code Contrast Ink shows on the PC (⚙ Settings).",
        NotAllowed = "Not allowed on the PC: press Allow on Contrast Ink's toolbar when it asks, then try again.";

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

    /// <summary>
    /// The PC check shown beside the code: the first 8 bytes of SHA-256 of the PC's public key, "6FC6-6A90-4861-71CA".
    /// (4 bytes were too few: a fake key matching them could be searched for offline in about 2^32 tries.)
    /// </summary>
    /// <summary>The address Windows gives itself on its own Mobile hotspot (192.168.137.x).</summary>
    public static bool IsHotspot(string address) => address.StartsWith("192.168.137.", StringComparison.Ordinal);

    /// <summary>
    /// Every IPv4 address a tablet could type to reach this PC, from all its adapters that are up: the Wi-Fi or
    /// Ethernet ones and the Mobile hotspot's (a PC sharing its own hotspot has no other address the tablet can
    /// reach). Not loopback, not self-assigned (169.254.x, no network behind it); each once; the hotspot's last.
    /// </summary>
    public static List<string> UsableAddresses(IEnumerable<PadAdapter> adapters)
    {
        var list = new List<string>();
        foreach (var a in adapters)
        {
            if (!a.Up || a.Loopback) continue;
            foreach (var text in a.IPv4)
            {
                if (!System.Net.IPAddress.TryParse(text, out var ip) || ip.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork) continue;
                var b = ip.GetAddressBytes();
                if (b[0] == 127 || b[0] == 0 || (b[0] == 169 && b[1] == 254)) continue;
                var s = ip.ToString();
                if (!list.Contains(s)) list.Add(s);
            }
        }
        return list.Where(x => !IsHotspot(x)).Concat(list.Where(IsHotspot)).ToList();
    }

    /// <summary>The addresses for the ⚙ panel: "192.168.1.20, 192.168.137.1 (hotspot)", each with the port when it isn't the usual one.</summary>
    public static string AddressText(IReadOnlyList<string> addresses, int port) =>
        string.Join(", ", addresses.Select(a => a + (port != Port ? $":{port}" : "") + (IsHotspot(a) ? " (hotspot)" : "")));

    public static string PcCheck(byte[] pcKey)
    {
        var h = System.Security.Cryptography.SHA256.HashData(pcKey);
        return string.Join("-", Enumerable.Range(0, 4).Select(i => $"{h[2 * i]:X2}{h[2 * i + 1]:X2}"));
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
/// Wrong codes: a 6-digit code must not be guessable by a script on the same Wi-Fi. Counted per address, so one
/// tablet's typos (or one stranger's guesses) don't lock out everyone: five wrong in a row from one address lock
/// that address out for 30 s. A backstop against guessing from many addresses: fifteen wrong in a row from all of
/// them lock everyone out for 30 s. Twenty wrong in all make a new code (the presenter sees it change).
/// docs/pad-protocol.md, "Limits the PC enforces".
/// </summary>
public sealed class PadGuard
{
    public const int InARow = 5, AllInARow = 15, BeforeNewCode = 20;
    public static readonly TimeSpan Lockout = TimeSpan.FromSeconds(30);
    const int MaxAddresses = 1024;   // addresses remembered at most: a flood of new ones can't fill memory
    readonly Dictionary<string, (int row, DateTime until)> byAddress = new();
    int allInARow, wrongForThisCode;
    DateTime allUntil = DateTime.MinValue;

    /// <summary>Whether a HELLO from this address may be tried at all right now.</summary>
    public bool Locked(string from, DateTime now) =>
        now < allUntil || (byAddress.TryGetValue(from, out var a) && now < a.until);

    /// <summary>A wrong code was given from this address. True: time for a new code.</summary>
    public bool Wrong(string from, DateTime now)
    {
        if (!byAddress.ContainsKey(from) && byAddress.Count >= MaxAddresses)
            foreach (var old in byAddress.Where(kv => now >= kv.Value.until).Select(kv => kv.Key).ToList()) byAddress.Remove(old);
        var (row, until) = byAddress.GetValueOrDefault(from);
        if (++row >= InARow) { row = 0; until = now + Lockout; }
        if (byAddress.ContainsKey(from) || byAddress.Count < MaxAddresses) byAddress[from] = (row, until);
        else allUntil = now + Lockout;   // a thousand addresses locked out at once: guessing from everywhere
        if (++allInARow >= AllInARow) { allInARow = 0; allUntil = now + Lockout; }
        if (++wrongForThisCode < BeforeNewCode) return false;
        wrongForThisCode = 0;
        return true;
    }

    /// <summary>The right code from this address: its run of guesses, and the run from all addresses, start again.</summary>
    public void Right(string from)
    {
        byAddress.Remove(from);
        allInARow = 0;
    }
}

/// <summary>A network adapter as <see cref="Pad.UsableAddresses"/> needs it: up or not, loopback or not, its IPv4 addresses.</summary>
public sealed record PadAdapter(string Name, bool Up, bool Loopback, IReadOnlyList<string> IPv4);
