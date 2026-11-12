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
    // the hello within 3 s; the proof within 30 (the presenter may be comparing the PC check, or deciding)
    static readonly TimeSpan HelloWithin = TimeSpan.FromSeconds(3), ProofWithin = TimeSpan.FromSeconds(30), Silence = TimeSpan.FromSeconds(10);

    readonly Dispatcher ui;
    readonly Func<Native.RECT> screen;   // the screen being drawn on, in real pixels
    readonly Func<System.Windows.Media.Imaging.BitmapSource?> marks;   // the drawing layer's picture, on the UI thread
    readonly System.Security.Cryptography.ECDiffieHellman pcKey;       // this PC's own key (kept between runs)
    readonly byte[] pcPoint;
    /// <summary>What the tablet shows the first time, to compare with this PC: "6FC6-6A90".</summary>
    public string PcCheck { get; }
    readonly PadGuard guard = new();
    readonly object gate = new();       // guards current, Code, guard
    TcpListener? listener, usbListener;
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
        public PadSeal? Out, In;   // once the code is proven: everything is sealed (version 2)
        public bool Usb;           // came by the cable: the code is empty
        readonly object sealing = new();
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

        /// <summary>Queues a message, sealed (in the order sent: the counters must be in order); a full queue means
        /// the tablet isn't keeping up: it is dropped.</summary>
        public void Send(byte[] m)
        {
            lock (sealing)
            {
                if (Closed) return;
                var wire = Out != null ? Pad.Message(PadCrypto.Sealed, Out.Seal(m)) : m;
                if (!outbox.TryAdd(wire)) Close();
            }
        }

        public void Close()
        {
            if (Closed) return;
            Closed = true;
            try { outbox.CompleteAdding(); } catch (Exception) { }
            try { Client.Close(); } catch (Exception) { }
        }
    }

    public PadServer(Dispatcher ui, Func<Native.RECT> screen, Func<System.Windows.Media.Imaging.BitmapSource?> marks,
        System.Security.Cryptography.ECDiffieHellman pcKey, string? code = null)
    {
        this.ui = ui;
        this.screen = screen;
        this.marks = marks;
        this.pcKey = pcKey;
        pcPoint = PadCrypto.PublicPoint(pcKey);
        PcCheck = Pad.PcCheck(pcPoint);
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
        Run("pad accept", () => AcceptLoop(listener, usb: false));
        // the USB door: reachable only from this PC (Android's USB link, adb reverse, arrives here)
        try { usbListener = new TcpListener(IPAddress.Loopback, Pad.UsbPort); usbListener.Start(); Run("pad usb accept", () => AcceptLoop(usbListener, usb: true)); }
        catch (SocketException e) { App.Log(e); usbListener = null; }
        Run("pad frames", FrameLoop);
        Run("pad ipad usb", () => UsbMux.Watch(() => running, OpenedOverUsb));
        Run("pad android usb", () => Adb.Watch(() => running));
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

    void AcceptLoop(TcpListener l, bool usb)
    {
        while (running)
        {
            TcpClient c;
            try { c = l.AcceptTcpClient(); }
            catch (Exception) when (!running) { return; }
            catch (SocketException) { continue; }
            if (Interlocked.Increment(ref pending) > MaxPending) { Interlocked.Decrement(ref pending); try { c.Close(); } catch (Exception) { } continue; }
            Run("pad tablet", () => Serve(c, usb));
        }
    }

    /// <summary>An iPad's USB connection, opened by this PC through Apple's USB service; ends when the session ends.</summary>
    void OpenedOverUsb(TcpClient c)
    {
        Interlocked.Increment(ref pending);
        Serve(c, usb: true);
    }

    /// <summary>A tablet is connected by the cable (not over Wi-Fi).</summary>
    public bool OverUsb => current?.Usb == true;

    void Serve(TcpClient tcp, bool usb)
    {
        var conn = new Connection(tcp) { Usb = usb };
        var reader = new PadReader { MaxLength = Pad.HelloMax };   // a stranger's first messages are small
        var buf = new byte[64 * 1024];
        int step = 0;   // 0: waiting for HELLO, 1: CHALLENGE sent, waiting for PROOF, 2: in
        bool counted = true;
        byte[]? salt = null;
        System.Security.Cryptography.ECDiffieHellmanPublicKey? tabletKey = null;
        string device = "";
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
                    if (step < 2 && DateTime.UtcNow > deadline) return;
                    if (step == 2 && DateTime.UtcNow - heard > Silence) return;
                    continue;
                }
                if (n <= 0) return;
                heard = DateTime.UtcNow;
                foreach (var (type, payload) in reader.Add(buf.AsSpan(0, n)))
                {
                    if (step == 0)
                    {
                        // HELLO: the tablet's fresh key. Answer with this PC's key and a salt, or refuse.
                        var hello = type == Pad.Hello ? Pad.ReadHelloV2(payload) : null;
                        tabletKey = hello == null ? null : PadCrypto.ReadPoint(hello.Value.key);
                        string? why = tabletKey == null ? Pad.UpdateTablet : null;
                        lock (gate) if (why == null && !usb && guard.Locked(DateTime.UtcNow)) why = Pad.TooManyWrong;
                        if (why != null) { Refuse(conn, why); return; }
                        device = hello!.Value.device;
                        salt = System.Security.Cryptography.RandomNumberGenerator.GetBytes(16);
                        conn.Stream.Write(Pad.ChallengeMessage(pcPoint, salt, Environment.MachineName));
                        step = 1;
                        deadline = DateTime.UtcNow + ProofWithin;
                        continue;
                    }
                    if (step == 1)
                    {
                        if (!Prove(conn, type, payload, tabletKey!, salt!, device)) return;
                        step = 2;
                        reader.MaxLength = Pad.MaxLength;
                        Interlocked.Decrement(ref pending); counted = false;
                        continue;
                    }
                    if (!ReferenceEquals(Volatile.Read(ref current), conn)) return;   // replaced or dropped
                    // in: only sealed messages, each opened in order (a replay, a change or another key: closed)
                    var inner = type == PadCrypto.Sealed ? conn.In!.Open(payload) : null;
                    if (inner == null) return;
                    foreach (var (t, p) in new PadReader().Add(inner))
                        switch (t)
                        {
                            case Pad.Ping: conn.Send(Pad.Message(Pad.Pong, ReadOnlySpan<byte>.Empty)); break;
                            case Pad.FrameAck: conn.AckPending = false; break;
                            default: Deliver(conn, t, p); break;
                        }
                }
                if (step < 2 && DateTime.UtcNow > deadline) return;
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

    static void Refuse(Connection conn, string why)
    {
        try { conn.Stream.Write(Pad.Message(Pad.Reject, why)); } catch (Exception) { }
    }

    /// <summary>
    /// The PROOF: sealed with keys made from this run's code. Opened, the tablet knows the code (it never crossed the
    /// network) and the session starts, replacing a connected tablet (the same one, back after a Wi-Fi drop before
    /// this PC noticed). Not opened: a wrong code, counted against guessing.
    /// </summary>
    bool Prove(Connection conn, byte type, byte[] payload, System.Security.Cryptography.ECDiffieHellmanPublicKey tabletKey, byte[] salt, string device)
    {
        string code;
        lock (gate) code = conn.Usb ? "" : Code;   // over the cable the code is empty: being plugged in is the proof
        var (toPc, toTablet) = PadCrypto.Keys(pcKey, tabletKey, salt, code);
        var open = new PadSeal(toPc);
        var proof = type == PadCrypto.Proof ? open.Open(payload) : null;
        var said = proof == null ? null : new PadReader().Add(proof);
        bool right = said is { Count: 1 } && said[0].type == Pad.Command && System.Text.Encoding.UTF8.GetString(said[0].payload) == PadCrypto.ProofText;
        Connection? old = null;
        bool newCode = false;
        string? why = null;
        lock (gate)
        {
            if (!conn.Usb && guard.Locked(DateTime.UtcNow)) why = Pad.TooManyWrong;
            else if (!right)
            {
                why = Pad.WrongCode;
                if (!conn.Usb && guard.Wrong(DateTime.UtcNow)) { Code = Pad.NewCode(); newCode = true; }
            }
            else
            {
                guard.Right();
                conn.Name = device;
                conn.In = open;
                conn.Out = new PadSeal(toTablet);
                old = current;
                current = conn;
            }
        }
        if (newCode) ui.BeginInvoke(() => CodeChanged?.Invoke());
        if (why != null) { open.Dispose(); Refuse(conn, why); return false; }
        old?.Close();
        conn.StartWriter();
        var r = screen();
        conn.Send(Pad.WelcomeMessage(Environment.MachineName, r.Right - r.Left, r.Bottom - r.Top));
        var name = conn.Name;
        ui.BeginInvoke(() => ConnectionChanged?.Invoke(name));
        return true;
    }

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
        try { usbListener?.Stop(); } catch (Exception) { }
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

/// <summary>
/// This PC's own key for the tablet link, kept between runs in the user's Windows key store, so a tablet can
/// recognise this PC next time (and notice a machine pretending to be it). If the store can't be used, a key for
/// this run only: tablets then see a new PC and show its check again.
/// </summary>
static class PadIdentity
{
    const string KeyName = "Contrast Ink tablet link";

    public static System.Security.Cryptography.ECDiffieHellman Load()
    {
        try
        {
            var k = System.Security.Cryptography.CngKey.Exists(KeyName)
                ? System.Security.Cryptography.CngKey.Open(KeyName)
                : System.Security.Cryptography.CngKey.Create(System.Security.Cryptography.CngAlgorithm.ECDiffieHellmanP256, KeyName);
            return new System.Security.Cryptography.ECDiffieHellmanCng(k);
        }
        catch (System.Security.Cryptography.CryptographicException e) { App.Log(e); return PadCrypto.NewKey(); }
    }
}
