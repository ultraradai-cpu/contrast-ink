using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;
using ContrastInk.Core;

namespace ContrastInk;

/// <summary>
/// A tablet used as a pad (docs/pad-protocol.md): listens on the network, lets in one tablet that knows this run's
/// 6-digit code, sends it pictures of the screen being drawn on (about 10 a second, each after the last was shown),
/// and hands what it draws to the app on the UI thread. Advertised with DNS-SD so the tablet finds it by name.
/// Everything a stranger on the Wi-Fi can send is bounded (see the audit notes in each part), and nothing that
/// happens on its threads can end the app or block the UI.
/// </summary>
sealed class PadServer : IDisposable
{
    /// <summary>The code a tablet must give. Changes after too many wrong ones (<see cref="CodeChanged"/>).</summary>
    public string Code { get; private set; }
    public int Port { get; private set; }
    /// <summary>The connected tablet's name, or null.</summary>
    public string? Connected => current?.Name;
    /// <summary>A tablet connected (its name) or went (null). On the UI thread.</summary>
    public event Action<string?>? ConnectionChanged;
    /// <summary>A new code, after too many wrong ones. On the UI thread.</summary>
    public event Action? CodeChanged;
    /// <summary>Messages from the tablet (strokes, hover, commands), in order. On the UI thread.</summary>
    public event Action<byte, byte[]>? Received;

    const int MaxPending = 4;             // strangers not yet past the code, at once
    const int MaxQueued = 4000;           // messages from the tablet waiting for the UI: more is a flood
    static readonly TimeSpan HelloWithin = TimeSpan.FromSeconds(3), Silence = TimeSpan.FromSeconds(10);

    readonly Dispatcher ui;
    readonly Func<Native.RECT> screen;   // the screen being drawn on, in real pixels
    readonly Func<System.Windows.Media.Imaging.BitmapSource?> marks;   // the drawing layer's picture, on the UI thread
    readonly PadGuard guard = new();
    readonly object gate = new();       // guards current, Code, guard
    TcpListener? listener;
    Connection? current;
    int pending;
    volatile bool running;
    DnsSd? advert;

    /// <summary>One tablet's connection. Writes go through its own queue and thread: a tablet that stops reading
    /// (locked, out of range) can then never block the UI or the pictures, it is dropped.</summary>
    sealed class Connection
    {
        public readonly TcpClient Client;
        public readonly NetworkStream Stream;
        public string Name = "";
        public volatile bool AckPending, Closed;
        public DateTime SentAt;
        readonly System.Collections.Concurrent.BlockingCollection<byte[]> outbox = new(64);

        public Connection(TcpClient c)
        {
            Client = c;
            Stream = c.GetStream();
            Stream.WriteTimeout = 3000;   // a write that can't get through in 3 s: the tablet is gone
        }

        public void StartWriter() => new Thread(() =>
        {
            try { foreach (var m in outbox.GetConsumingEnumerable()) Stream.Write(m, 0, m.Length); }
            catch (Exception) { }
            finally { Close(); }
        }) { IsBackground = true, Name = "pad writer" }.Start();

        /// <summary>Queues a message; a full queue means the tablet isn't keeping up: it is dropped.</summary>
        public void Send(byte[] m) { if (Closed || !outbox.TryAdd(m)) Close(); }

        public void Close()
        {
            if (Closed) return;
            Closed = true;
            try { outbox.CompleteAdding(); } catch (Exception) { }
            try { Client.Close(); } catch (Exception) { }
        }
    }

    public PadServer(Dispatcher ui, Func<Native.RECT> screen, Func<System.Windows.Media.Imaging.BitmapSource?> marks, string? code = null)
    {
        this.ui = ui;
        this.screen = screen;
        this.marks = marks;
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
        if (listener == null) throw new InvalidOperationException("no free network port (47820 to 47829 are all in use)");
        Run("pad accept", AcceptLoop);
        Run("pad frames", FrameLoop);
        try { advert = DnsSd.Register(Environment.MachineName, Port); } catch (Exception e) { App.Log(e); }
    }

    /// <summary>A thread whose failure is logged, never fatal (an exception escaping a thread ends the app).</summary>
    static void Run(string name, Action body) => new Thread(() =>
    {
        try { body(); } catch (Exception e) { App.Log(e); }
    }) { IsBackground = true, Name = name }.Start();

    /// <summary>This PC's addresses on its networks, for typing into a tablet when the network hides names.</summary>
    public static List<string> Addresses()
    {
        try
        {
            return NetworkInterface.GetAllNetworkInterfaces()
                .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
                .SelectMany(n => n.GetIPProperties().UnicastAddresses)
                .Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a.Address)
                            && !a.Address.ToString().StartsWith("169.254.", StringComparison.Ordinal))
                .Select(a => a.Address.ToString()).Distinct().ToList();
        }
        catch (NetworkInformationException) { return new List<string>(); }
    }

    /// <summary>Ends the tablet's connection (the presenter switched the link off, or wants another tablet).</summary>
    public void Drop() { Connection? c; lock (gate) c = current; c?.Close(); }

    void AcceptLoop()
    {
        while (running)
        {
            TcpClient c;
            try { c = listener!.AcceptTcpClient(); }
            catch (Exception) when (!running) { return; }
            catch (SocketException) { continue; }
            if (Interlocked.Increment(ref pending) > MaxPending) { Interlocked.Decrement(ref pending); try { c.Close(); } catch (Exception) { } continue; }
            Run("pad tablet", () => Serve(c));
        }
    }

    void Serve(TcpClient tcp)
    {
        var conn = new Connection(tcp);
        var reader = new PadReader { MaxLength = Pad.HelloMax };   // a stranger's first message is small
        var buf = new byte[64 * 1024];
        bool admitted = false, counted = true;
        var deadline = DateTime.UtcNow + HelloWithin;
        try
        {
            tcp.NoDelay = true;
            conn.Stream.ReadTimeout = 1000;
            var heard = DateTime.UtcNow;
            while (running && !conn.Closed)
            {
                int n;
                try { n = conn.Stream.Read(buf, 0, buf.Length); }
                catch (IOException e) when (e.InnerException is SocketException { SocketErrorCode: SocketError.TimedOut })
                {
                    // a byte now and then must not keep a stranger's connection open, nor a silent tablet's
                    if (!admitted && DateTime.UtcNow > deadline) return;
                    if (admitted && DateTime.UtcNow - heard > Silence) return;
                    continue;
                }
                if (n <= 0) return;
                heard = DateTime.UtcNow;
                foreach (var (type, payload) in reader.Add(buf.AsSpan(0, n)))
                {
                    if (!admitted)
                    {
                        if (!Admit(conn, type, payload)) return;
                        admitted = true;
                        reader.MaxLength = Pad.MaxLength;
                        Interlocked.Decrement(ref pending); counted = false;
                        continue;
                    }
                    if (!ReferenceEquals(Volatile.Read(ref current), conn)) return;   // replaced or dropped
                    switch (type)
                    {
                        case Pad.Ping: conn.Send(Pad.Message(Pad.Pong, ReadOnlySpan<byte>.Empty)); break;
                        case Pad.FrameAck: conn.AckPending = false; break;
                        default: Deliver(conn, type, payload); break;
                    }
                }
                if (!admitted && DateTime.UtcNow > deadline) return;
            }
        }
        catch (Exception e) when (e is IOException or SocketException or ObjectDisposedException or InvalidDataException) { }
        finally
        {
            if (counted) Interlocked.Decrement(ref pending);
            conn.Close();
            bool wasCurrent;
            lock (gate) { wasCurrent = ReferenceEquals(current, conn); if (wasCurrent) current = null; }
            if (wasCurrent) ui.BeginInvoke(() => ConnectionChanged?.Invoke(null));
        }
    }

    /// <summary>
    /// The first message: HELLO with this run's code, for a free slot. Refusals say why in words a presenter can
    /// act on, but a busy slot is checked first, so the refusal never tells a guesser whether the code was right.
    /// </summary>
    bool Admit(Connection conn, byte type, byte[] payload)
    {
        var hello = type == Pad.Hello ? Pad.ReadHello(payload) : null;
        string? why;
        bool newCode = false;
        var now = DateTime.UtcNow;
        lock (gate)
        {
            if (hello == null) why = "Please update Contrast Ink on the tablet.";
            else if (current != null) why = "Another tablet is connected to this PC. Disconnect it first.";
            else if (guard.Locked(now)) why = "Too many wrong codes: wait 30 seconds, then try again.";
            else if (!CodesEqual(hello.Value.code, Code))
            {
                why = "Wrong code: type the code Contrast Ink shows on the PC (⚙ Settings).";
                if (guard.Wrong(now)) { Code = Pad.NewCode(); newCode = true; }
            }
            else
            {
                why = null;
                guard.Right();
                conn.Name = hello.Value.device;
                current = conn;
            }
        }
        if (newCode) ui.BeginInvoke(() => CodeChanged?.Invoke());
        if (why != null)
        {
            try { conn.Stream.Write(Pad.Message(Pad.Reject, why)); } catch (Exception) { }
            return false;
        }
        conn.StartWriter();
        var r = screen();
        conn.Send(Pad.WelcomeMessage(Environment.MachineName, r.Right - r.Left, r.Bottom - r.Top));
        var name = conn.Name;
        ui.BeginInvoke(() => ConnectionChanged?.Invoke(name));
        return true;
    }

    static bool CodesEqual(string a, string b) =>
        System.Security.Cryptography.CryptographicOperations.FixedTimeEquals(System.Text.Encoding.UTF8.GetBytes(a), System.Text.Encoding.UTF8.GetBytes(b));

    // messages for the UI: queued here and handed over in one go, at input priority, so a flood can't starve the
    // presenter's own mouse and keys, and can't grow without end
    readonly System.Collections.Concurrent.ConcurrentQueue<(byte, byte[])> inbox = new();
    int inboxCount, draining;

    void Deliver(Connection conn, byte type, byte[] payload)
    {
        if (Interlocked.Increment(ref inboxCount) > MaxQueued) { conn.Close(); return; }
        inbox.Enqueue((type, payload));
        if (Interlocked.Exchange(ref draining, 1) == 0) ui.BeginInvoke(DispatcherPriority.Input, Drain);
    }

    void Drain()
    {
        Volatile.Write(ref draining, 0);
        int n = 0;
        while (n++ < 500 && inbox.TryDequeue(out var m))
        {
            Interlocked.Decrement(ref inboxCount);
            try { Received?.Invoke(m.Item1, m.Item2); } catch (Exception e) { App.Log(e); }
        }
        if (!inbox.IsEmpty && Interlocked.Exchange(ref draining, 1) == 0) ui.BeginInvoke(DispatcherPriority.Input, Drain);
    }

    /// <summary>To the connected tablet, if any, from any thread. Never blocks (it is queued).</summary>
    public void Send(byte[] message) { Volatile.Read(ref current)?.Send(message); }

    public void SendState(Settings s, bool canUndo) => Send(Pad.StateMessage(s, canUndo));

    /// <summary>Pictures of the screen, one at a time: the next only after the tablet says it showed the last.</summary>
    void FrameLoop()
    {
        var last = DateTime.MinValue;
        while (running)
        {
            var c = Volatile.Read(ref current);
            var now = DateTime.UtcNow;
            if (c != null && c.AckPending && now - c.SentAt > TimeSpan.FromSeconds(3)) c.AckPending = false;   // a lost acknowledgement
            if (c == null || c.Closed || c.AckPending || now - last < TimeSpan.FromMilliseconds(100)) { Thread.Sleep(15); continue; }
            try
            {
                var jpeg = Capture(screen(), MarksNow());
                last = c.SentAt = DateTime.UtcNow;
                c.AckPending = true;
                c.Send(Pad.Message(Pad.Frame, jpeg));
            }
            catch (Exception e) { App.Log(e); Thread.Sleep(500); }   // a picture that can't be made: try again later
        }
    }

    /// <summary>The marks as the drawing layer shows them, asked of the UI thread (skipped when it's busy).</summary>
    System.Windows.Media.Imaging.BitmapSource? MarksNow()
    {
        try { return ui.Invoke(marks, DispatcherPriority.Render, CancellationToken.None, TimeSpan.FromMilliseconds(150)); }
        catch (Exception e) when (e is TimeoutException or TaskCanceledException or OperationCanceledException) { return null; }
    }

    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleBitmap(IntPtr dc, int w, int h);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool StretchBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, int sw, int sh, uint rop);
    [DllImport("gdi32.dll")] static extern int SetStretchBltMode(IntPtr dc, int mode);
    [DllImport("gdi32.dll")] static extern bool SetBrushOrgEx(IntPtr dc, int x, int y, IntPtr old);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    const uint SRCCOPY = 0x00CC0020;
    const int HALFTONE = 4;

    /// <summary>
    /// The screen as the audience sees it, at most 1600 px wide, as a JPEG: what is under the drawing layer, copied
    /// straight at the smaller size (no full-size copy of a 4K screen), with the marks laid over it. Without
    /// CAPTUREBLT: that flag makes the mouse pointer flicker on every copy, and OBS would record the flicker. The
    /// toolbar is never in it (hidden from capture).
    /// </summary>
    static byte[] Capture(Native.RECT r, System.Windows.Media.Imaging.BitmapSource? marksPicture)
    {
        int w = Math.Max(1, r.Right - r.Left), h = Math.Max(1, r.Bottom - r.Top);
        double scale = Math.Min(1, 1600.0 / w);
        int ow = Math.Max(1, (int)(w * scale)), oh = Math.Max(1, (int)(h * scale));
        IntPtr screenDc = GetDC(IntPtr.Zero), memDc = CreateCompatibleDC(screenDc), bmp = CreateCompatibleBitmap(screenDc, ow, oh);
        System.Windows.Media.Imaging.BitmapSource picture;
        try
        {
            var old = SelectObject(memDc, bmp);
            SetStretchBltMode(memDc, HALFTONE);
            SetBrushOrgEx(memDc, 0, 0, IntPtr.Zero);
            StretchBlt(memDc, 0, 0, ow, oh, screenDc, r.Left, r.Top, w, h, SRCCOPY);
            SelectObject(memDc, old);
            picture = System.Windows.Interop.Imaging.CreateBitmapSourceFromHBitmap(
                bmp, IntPtr.Zero, System.Windows.Int32Rect.Empty, System.Windows.Media.Imaging.BitmapSizeOptions.FromEmptyOptions());
        }
        finally
        {
            DeleteObject(bmp);
            DeleteDC(memDc);
            ReleaseDC(IntPtr.Zero, screenDc);
        }
        if (marksPicture != null)
        {
            var v = new System.Windows.Media.DrawingVisual();
            using (var dc = v.RenderOpen())
            {
                var area = new System.Windows.Rect(0, 0, ow, oh);
                dc.DrawImage(picture, area);
                dc.DrawImage(marksPicture, area);
            }
            var both = new System.Windows.Media.Imaging.RenderTargetBitmap(ow, oh, 96, 96, System.Windows.Media.PixelFormats.Pbgra32);
            both.Render(v);
            picture = both;
        }
        var jpeg = new System.Windows.Media.Imaging.JpegBitmapEncoder { QualityLevel = 70 };
        jpeg.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(picture));
        using var ms = new MemoryStream();
        jpeg.Save(ms);
        return ms.ToArray();
    }

    public void Dispose()
    {
        running = false;
        advert?.Dispose();
        try { listener?.Stop(); } catch (Exception) { }
        Drop();
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
        if (DnsServiceRegister(d.request, IntPtr.Zero) != DNS_REQUEST_PENDING)
        {
            DnsServiceFreeInstance(d.instance);   // never registered: nothing to deregister
            return null;
        }
        return d;
    }

    public void Dispose()
    {
        if (request == IntPtr.Zero) return;
        try { DnsServiceDeRegister(request, IntPtr.Zero); } catch (Exception) { }
        // the request and the instance it points to stay allocated: Windows may still use them after deregistering
        // (a few hundred bytes, once per switch-off)
        request = IntPtr.Zero;
    }
}
