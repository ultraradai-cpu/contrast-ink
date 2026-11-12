using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Threading;
using ContrastInk.Core;

namespace ContrastInk;

/// <summary>
/// A tablet used as a pad (docs/pad-protocol.md): listens on the network, lets in one tablet that knows this run's
/// 6-digit code, sends it pictures of the screen being drawn on (about 10 a second, each after the last was shown),
/// and hands what it draws to the app on the UI thread. Advertised with DNS-SD so the tablet finds it by name.
/// </summary>
sealed class PadServer : IDisposable
{
    public string Code { get; }
    public int Port { get; private set; }
    /// <summary>The connected tablet's name, or null.</summary>
    public string? Connected { get; private set; }
    /// <summary>A tablet connected (its name) or went (null). On the UI thread.</summary>
    public event Action<string?>? ConnectionChanged;
    /// <summary>A message from the tablet (strokes, hover, commands). On the UI thread.</summary>
    public event Action<byte, byte[]>? Received;

    readonly Dispatcher ui;
    readonly Func<Native.RECT> screen;   // the screen being drawn on, in real pixels
    TcpListener? listener;
    TcpClient? client;
    readonly object sendLock = new();
    volatile bool running, ackPending;
    DateTime lastHeard;
    DnsSd? advert;

    public PadServer(Dispatcher ui, Func<Native.RECT> screen, string? code = null)
    {
        this.ui = ui;
        this.screen = screen;
        Code = code ?? Pad.NewCode();
    }

    public void Start()
    {
        running = true;
        for (int p = Pad.Port; p < Pad.Port + 10 && listener == null; p++)
        {
            try { var l = new TcpListener(IPAddress.Any, p); l.Start(); listener = l; Port = p; }
            catch (SocketException) { }
        }
        if (listener == null) throw new InvalidOperationException("no free port for the tablet link");
        new Thread(AcceptLoop) { IsBackground = true, Name = "pad accept" }.Start();
        new Thread(FrameLoop) { IsBackground = true, Name = "pad frames" }.Start();
        try { advert = DnsSd.Register(Environment.MachineName, Port); } catch (Exception e) { App.Log(e); }
    }

    /// <summary>This PC's addresses on its networks, for typing into a tablet when the network hides names.</summary>
    public static List<string> Addresses() =>
        NetworkInterface.GetAllNetworkInterfaces()
            .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
            .SelectMany(n => n.GetIPProperties().UnicastAddresses)
            .Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a.Address)
                        && !a.Address.ToString().StartsWith("169.254.", StringComparison.Ordinal))
            .Select(a => a.Address.ToString()).Distinct().ToList();

    void AcceptLoop()
    {
        while (running)
        {
            TcpClient c;
            try { c = listener!.AcceptTcpClient(); }
            catch (Exception) when (!running) { return; }
            catch (SocketException) { continue; }
            catch (ObjectDisposedException) { return; }
            new Thread(() => Serve(c)) { IsBackground = true, Name = "pad tablet" }.Start();
        }
    }

    void Serve(TcpClient c)
    {
        var reader = new PadReader();
        var buf = new byte[64 * 1024];
        bool mine = false;
        try
        {
            c.NoDelay = true;
            var s = c.GetStream();
            s.ReadTimeout = 10000;   // nothing at all for 10 s (the tablet pings every 2 s): it's gone
            while (running)
            {
                int n = s.Read(buf, 0, buf.Length);
                if (n <= 0) break;
                foreach (var (type, payload) in reader.Add(buf.AsSpan(0, n)))
                {
                    lastHeard = DateTime.UtcNow;
                    if (!mine)
                    {
                        // the first message must be HELLO with this run's code; one tablet at a time
                        var hello = type == Pad.Hello ? Pad.ReadHello(payload) : null;
                        string? why = hello == null ? "Please update Contrast Ink on the tablet."
                            : hello.Value.code != Code ? "Wrong code: type the code Contrast Ink shows on the PC (⚙ Settings)."
                            : client != null ? "Another tablet is connected to this PC."
                            : null;
                        if (why != null) { Write(s, Pad.Message(Pad.Reject, why)); return; }
                        var r = screen();
                        Write(s, Pad.WelcomeMessage(Environment.MachineName, r.Right - r.Left, r.Bottom - r.Top));
                        lock (sendLock) { client = c; ackPending = false; }
                        mine = true;
                        Connected = hello!.Value.device;
                        ui.BeginInvoke(() => ConnectionChanged?.Invoke(Connected));
                        continue;
                    }
                    switch (type)
                    {
                        case Pad.Ping: Send(Pad.Message(Pad.Pong, ReadOnlySpan<byte>.Empty)); break;
                        case Pad.FrameAck: ackPending = false; break;
                        default: ui.BeginInvoke(() => Received?.Invoke(type, payload)); break;
                    }
                }
            }
        }
        catch (Exception e) when (e is IOException or SocketException or ObjectDisposedException or InvalidDataException) { }
        finally
        {
            if (mine)
            {
                lock (sendLock) { if (client == c) client = null; }
                Connected = null;
                ui.BeginInvoke(() => ConnectionChanged?.Invoke(null));
            }
            try { c.Close(); } catch (Exception) { }
        }
    }

    static void Write(NetworkStream s, byte[] m) => s.Write(m, 0, m.Length);

    /// <summary>To the connected tablet, if any (from any thread). A failed send ends the connection.</summary>
    public void Send(byte[] message)
    {
        lock (sendLock)
        {
            if (client == null) return;
            try { Write(client.GetStream(), message); }
            catch (Exception e) when (e is IOException or SocketException or ObjectDisposedException or InvalidOperationException)
            { try { client.Close(); } catch (Exception) { } client = null; }
        }
    }

    public void SendState(Settings s, bool canUndo) => Send(Pad.StateMessage(s, canUndo));

    /// <summary>Pictures of the screen, one at a time: the next only after the tablet says it showed the last.</summary>
    void FrameLoop()
    {
        var last = DateTime.MinValue;
        var sentAt = DateTime.MinValue;
        while (running)
        {
            bool connected;
            lock (sendLock) connected = client != null;
            var now = DateTime.UtcNow;
            // a lost acknowledgement must not stop the pictures for good
            if (ackPending && now - sentAt > TimeSpan.FromSeconds(3)) ackPending = false;
            if (!connected || ackPending || now - last < TimeSpan.FromMilliseconds(100)) { Thread.Sleep(15); continue; }
            try
            {
                var jpeg = Capture(screen());
                last = sentAt = DateTime.UtcNow;
                ackPending = true;
                Send(Pad.Message(Pad.Frame, jpeg));
            }
            catch (Exception e) when (e is ExternalException or ArgumentException or InvalidOperationException or NotSupportedException) { Thread.Sleep(200); }
        }
    }

    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleBitmap(IntPtr dc, int w, int h);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, uint rop);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    const uint SRCCOPY = 0x00CC0020, CAPTUREBLT = 0x40000000;

    /// <summary>
    /// The screen, as the audience sees it: the slide and the marks (the drawing layer is a layered window, so
    /// CAPTUREBLT), not the toolbar (hidden from capture). At most 1600 px wide, as a JPEG.
    /// </summary>
    static byte[] Capture(Native.RECT r)
    {
        int w = Math.Max(1, r.Right - r.Left), h = Math.Max(1, r.Bottom - r.Top);
        IntPtr screenDc = GetDC(IntPtr.Zero), memDc = CreateCompatibleDC(screenDc), bmp = CreateCompatibleBitmap(screenDc, w, h);
        try
        {
            var old = SelectObject(memDc, bmp);
            BitBlt(memDc, 0, 0, w, h, screenDc, r.Left, r.Top, SRCCOPY | CAPTUREBLT);
            SelectObject(memDc, old);
            System.Windows.Media.Imaging.BitmapSource picture = System.Windows.Interop.Imaging.CreateBitmapSourceFromHBitmap(
                bmp, IntPtr.Zero, System.Windows.Int32Rect.Empty, System.Windows.Media.Imaging.BitmapSizeOptions.FromEmptyOptions());
            double scale = Math.Min(1, 1600.0 / w);
            if (scale < 1) picture = new System.Windows.Media.Imaging.TransformedBitmap(picture, new System.Windows.Media.ScaleTransform(scale, scale));
            var jpeg = new System.Windows.Media.Imaging.JpegBitmapEncoder { QualityLevel = 70 };
            jpeg.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(picture));
            using var ms = new MemoryStream();
            jpeg.Save(ms);
            return ms.ToArray();
        }
        finally
        {
            DeleteObject(bmp);
            DeleteDC(memDc);
            ReleaseDC(IntPtr.Zero, screenDc);
        }
    }

    public void Dispose()
    {
        running = false;
        advert?.Dispose();
        try { listener?.Stop(); } catch (SocketException) { }
        lock (sendLock) { try { client?.Close(); } catch (Exception) { } client = null; }
    }
}

/// <summary>
/// Advertises the tablet link on the network with DNS-SD (Bonjour/mDNS), Windows 10 1809 and later:
/// "LAPTOP._contrastink._tcp.local". Without it a tablet can still be given this PC's address by hand.
/// </summary>
sealed class DnsSd : IDisposable
{
    [StructLayout(LayoutKind.Sequential)]
    struct DNS_SERVICE_REGISTER_REQUEST
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr pServiceInstance;
        public IntPtr pRegisterCompletionCallback;
        public IntPtr pQueryContext;
        public IntPtr hCredentials;
        public int unicastEnabled;
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    delegate void RegisterComplete(uint status, IntPtr context, IntPtr instance);

    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr DnsServiceConstructInstance(string serviceName, string hostName, IntPtr ip4, IntPtr ip6, ushort port,
        ushort priority, ushort weight, uint propertiesCount,
        [MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.LPWStr)] string[] keys,
        [MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.LPWStr)] string[] values);
    [DllImport("dnsapi.dll")] static extern uint DnsServiceRegister(IntPtr request, IntPtr cancel);
    [DllImport("dnsapi.dll")] static extern uint DnsServiceDeRegister(IntPtr request, IntPtr cancel);
    [DllImport("dnsapi.dll")] static extern void DnsServiceFreeInstance(IntPtr instance);

    const uint DNS_REQUEST_PENDING = 9506;
    static readonly RegisterComplete Done = (_, _, instance) => { if (instance != IntPtr.Zero) DnsServiceFreeInstance(instance); };

    IntPtr request, instance;

    public static DnsSd? Register(string name, int port)
    {
        var d = new DnsSd();
        d.instance = DnsServiceConstructInstance($"{name}.{Pad.ServiceType}.local", $"{name}.local", IntPtr.Zero, IntPtr.Zero,
            (ushort)port, 0, 0, 1, new[] { "v" }, new[] { Pad.Version.ToString() });
        if (d.instance == IntPtr.Zero) return null;
        var req = new DNS_SERVICE_REGISTER_REQUEST
        {
            Version = 1, pServiceInstance = d.instance,
            pRegisterCompletionCallback = Marshal.GetFunctionPointerForDelegate(Done),
        };
        d.request = Marshal.AllocHGlobal(Marshal.SizeOf<DNS_SERVICE_REGISTER_REQUEST>());
        Marshal.StructureToPtr(req, d.request, false);
        if (DnsServiceRegister(d.request, IntPtr.Zero) != DNS_REQUEST_PENDING) { d.Dispose(); return null; }
        return d;
    }

    public void Dispose()
    {
        if (request == IntPtr.Zero) return;
        try { DnsServiceDeRegister(request, IntPtr.Zero); } catch (Exception) { }
        // the request stays allocated: Windows may still call back with it after deregistering (a few bytes, once)
        request = IntPtr.Zero;
    }
}
