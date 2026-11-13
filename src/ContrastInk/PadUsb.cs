using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Xml;
using System.Xml.Linq;
using ContrastInk.Core;

namespace ContrastInk;

/// <summary>
/// iPads over the cable, through Apple's USB service (usbmuxd: the Apple Mobile Device Service that iTunes or the
/// Apple Devices app installs, at 127.0.0.1:27015). Every few seconds: which iPhones and iPads are plugged in;
/// for each without a session, a connection to its port 47830 through the cable. The iPad listens there only
/// while it is in pad mode, on its own loopback address (so never over Wi-Fi). docs/pad-protocol.md, "USB".
/// </summary>
static class UsbMux
{
    const int Service = 27015;

    /// <summary>Until <paramref name="running"/> says stop: connect to each plugged-in iPad, hand the connection on.</summary>
    public static void Watch(Func<bool> running, Action<TcpClient> opened)
    {
        var busy = new HashSet<int>();
        while (running())
        {
            try
            {
                foreach (var id in Devices())
                {
                    lock (busy) if (busy.Contains(id)) continue;
                    var c = Connect(id, Pad.UsbPort);
                    if (c == null) continue;   // not in pad mode: try again next time
                    lock (busy) busy.Add(id);
                    new Thread(() =>
                    {
                        try { opened(c); }
                        catch (Exception e) { App.Log(e); }
                        finally { lock (busy) busy.Remove(id); }
                    }) { IsBackground = true, Name = "pad ipad" }.Start();
                }
            }
            catch (Exception e) when (e is IOException or SocketException or XmlException or InvalidDataException) { }
            for (int i = 0; i < 6 && running(); i++) Thread.Sleep(500);
        }
    }

    /// <summary>The iPhones and iPads plugged in by cable (not ones paired over the network). Empty without the service.</summary>
    public static List<int> Devices()
    {
        using var c = Open();
        if (c == null) return new List<int>();
        var answer = Ask(c.GetStream(), Plist(("MessageType", "ListDevices"), ("ClientVersionString", "Contrast Ink"), ("ProgName", "Contrast Ink")));
        return answer.Descendants("dict")
            .Where(d => Value(d, "ConnectionType") == "USB")
            .Select(d => int.TryParse(Value(d, "DeviceID"), out var id) ? id : -1)
            .Where(id => id >= 0).Distinct().ToList();
    }

    /// <summary>A connection to <paramref name="port"/> on the device, through the cable; null if nothing listens there.</summary>
    public static TcpClient? Connect(int device, int port)
    {
        var c = Open();
        if (c == null) return null;
        try
        {
            int swapped = ((port & 0xFF) << 8) | ((port >> 8) & 0xFF);   // usbmuxd wants the port's two bytes swapped
            var answer = Ask(c.GetStream(), Plist(("MessageType", "Connect"), ("ClientVersionString", "Contrast Ink"),
                ("ProgName", "Contrast Ink"), ("DeviceID", device), ("PortNumber", swapped)));
            if (Value(answer.Descendants("dict").First(), "Number") == "0") return c;   // from now on: the device's port
        }
        catch (Exception e) when (e is IOException or SocketException or XmlException or InvalidDataException or InvalidOperationException) { }
        c.Dispose();
        return null;
    }

    static TcpClient? Open()
    {
        try
        {
            var c = new TcpClient();
            if (!c.ConnectAsync("127.0.0.1", Service).Wait(500)) { c.Dispose(); return null; }
            c.ReceiveTimeout = 3000;
            c.SendTimeout = 3000;
            return c;
        }
        catch (Exception e) when (e is SocketException or AggregateException) { return null; }
    }

    static byte[] Plist(params (string key, object value)[] items)
    {
        var sb = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict>");
        foreach (var (k, v) in items)
            sb.Append("<key>").Append(k).Append("</key>").Append(v is int n ? $"<integer>{n}</integer>" : $"<string>{System.Security.SecurityElement.Escape((string)v)}</string>");
        sb.Append("</dict></plist>");
        return Encoding.UTF8.GetBytes(sb.ToString());
    }

    /// <summary>One request and its answer: a 16-byte header (length, version 1, type 8 = plist, tag), little-endian.</summary>
    static XDocument Ask(NetworkStream s, byte[] plist)
    {
        var head = new byte[16];
        BitConverter.GetBytes(16 + plist.Length).CopyTo(head, 0);
        BitConverter.GetBytes(1).CopyTo(head, 4);
        BitConverter.GetBytes(8).CopyTo(head, 8);
        BitConverter.GetBytes(1).CopyTo(head, 12);
        s.Write(head);
        s.Write(plist);
        var h = ReadExactly(s, 16);
        int len = BitConverter.ToInt32(h, 0) - 16;
        if (len < 0 || len > 1 << 20) throw new InvalidDataException("usbmuxd answer of " + len + " bytes");
        var body = ReadExactly(s, len);
        using var xml = XmlReader.Create(new MemoryStream(body), new XmlReaderSettings { DtdProcessing = DtdProcessing.Ignore, XmlResolver = null });
        return XDocument.Load(xml);
    }

    static byte[] ReadExactly(NetworkStream s, int n)
    {
        var b = new byte[n];
        for (int got = 0; got < n;)
        {
            int k = s.Read(b, got, n - got);
            if (k <= 0) throw new IOException("usbmuxd closed");
            got += k;
        }
        return b;
    }

    /// <summary>The value after &lt;key&gt;name&lt;/key&gt; in this dict (not in a dict inside it).</summary>
    static string? Value(XElement dict, string name)
    {
        var key = dict.Elements("key").FirstOrDefault(k => k.Value == name);
        return (key?.NextNode as XElement)?.Value;
    }
}

/// <summary>
/// Android tablets over the cable, through Android's USB debugging (adb): every few seconds, for each tablet newly
/// plugged in, "adb reverse tcp:47830 tcp:47830", so the tablet's 127.0.0.1:47830 reaches this PC's USB door.
/// Only when adb is found (Google's free platform-tools). docs/pad-protocol.md, "USB".
/// </summary>
static class Adb
{
    /// <summary>
    /// adb.exe, or null: on the PATH, or in the user's own Android SDK folder (%LOCALAPPDATA%\Android\Sdk\platform-tools,
    /// where Android Studio puts it and where the README says to unzip platform-tools). Never C:\platform-tools: any
    /// user of this PC may create that folder, and whatever adb.exe is there would run as the presenter.
    /// Looks at the disk (the PATH may name slow network folders): never on the UI thread, which reads <see cref="Found"/>.
    /// </summary>
    public static string? Find()
    {
        var places = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator)
            .Append(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Android", "Sdk", "platform-tools"));
        foreach (var dir in places.Select(d => d.Trim().Trim('"')).Where(d => d.Length > 0 && Path.IsPathFullyQualified(d)))
        {
            try { var f = Path.Combine(dir, "adb.exe"); if (File.Exists(f)) return f; }
            catch (ArgumentException) { }
        }
        return null;
    }

    static volatile string? found;
    /// <summary>The adb.exe last found (looked for every 30 s by <see cref="Watch"/>), or null.</summary>
    public static string? Found => found;
    public static readonly TimeSpan LookEvery = TimeSpan.FromSeconds(30);

    /// <param name="any">Told every few seconds whether at least one tablet is set up (the PC's cable door opens only then).</param>
    /// <param name="foundChanged">adb was found, or is gone (for the ⚙ text).</param>
    public static void Watch(Func<bool> running, Action<bool> any, Action foundChanged)
    {
        var done = new HashSet<string>();
        var looked = DateTime.MinValue;
        while (running())
        {
            if (DateTime.UtcNow - looked >= LookEvery)
            {
                looked = DateTime.UtcNow;
                var now = Find();
                if (now != found) { found = now; foundChanged(); }
            }
            var adb = found;
            if (adb == null) done.Clear();
            else
            {
                var now = Run(adb, "devices")?.Split('\n').Select(l => l.Trim().Split('\t'))
                    .Where(p => p.Length == 2 && p[1] == "device").Select(p => p[0]).ToHashSet() ?? new HashSet<string>();
                foreach (var serial in now.Where(x => !done.Contains(x)))
                    if (Run(adb, $"-s {serial} reverse tcp:{Pad.UsbPort} tcp:{Pad.UsbPort}") != null) done.Add(serial);
                done.IntersectWith(now);   // unplugged: set up again when it comes back
            }
            any(done.Count > 0);
            for (int i = 0; i < 10 && running(); i++) Thread.Sleep(500);
        }
    }

    /// <summary>Runs adb (hidden, at most 5 s); its output, or null when it failed.</summary>
    static string? Run(string adb, string args)
    {
        try
        {
            using var p = Process.Start(new ProcessStartInfo(adb, args)
            {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
            });
            if (p == null) return null;
            var output = p.StandardOutput.ReadToEndAsync();
            if (!p.WaitForExit(5000)) { try { p.Kill(); } catch (Exception) { } return null; }
            return p.ExitCode == 0 ? output.Result : null;
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException or IOException) { return null; }
    }
}
