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
    /// <summary>adb was found or is gone (for the ⚙ text). On the UI thread.</summary>
    public event Action? UsbToolsChanged;
    /// <summary>
    /// The question for the presenter: a tablet on the Android cable door wants to draw (the text), answered with
    /// <see cref="Answer"/>; null: no question any more (answered, or 30 s passed). On the UI thread.
    /// </summary>
    public event Action<string?>? CableAsk;

    const int MaxPending = 4;             // strangers not yet past the code, at once
    const int MaxQueued = 4000;           // messages from the tablet waiting for the UI: more is a flood
    // the hello within 3 s; the proof within 30 (the presenter may be comparing the PC check, or deciding)
    static readonly TimeSpan HelloWithin = TimeSpan.FromSeconds(3), ProofWithin = TimeSpan.FromSeconds(30), Silence = TimeSpan.FromSeconds(10);

    readonly Dispatcher ui;
    readonly Func<Native.RECT> screen;   // the screen being drawn on, in real pixels
    readonly Func<System.Windows.Media.Imaging.BitmapSource?> marks;   // the drawing layer's picture, on the UI thread
    readonly System.Security.Cryptography.ECDiffieHellman pcKey;       // this PC's own key (kept between runs)
    readonly byte[] pcPoint;
    /// <summary>What the tablet shows the first time, to compare with this PC: "6FC6-6A90-4861-71CA".</summary>
    public string PcCheck { get; }
    readonly PadGuard guard = new();
    readonly object gate = new();       // guards current, Code, guard
    TcpListener? listener, usbListener;
    Connection? current;
    // strangers not yet in, counted per door (one shared count let four stalled strangers on the Wi-Fi block even a
    // tablet on the cable) and per address on the Wi-Fi (one machine can't hold every place)
    int pendingWifi, pendingUsb;
    readonly Dictionary<IPAddress, int> pendingByAddress = new();
    const int MaxPendingPerAddress = 2, MaxPendingUsb = 2;
    readonly bool usbDoorAlways;   // the Windows check: the cable door open with no Android tablet attached
    // the Android cable door: any program on this PC, and any app on the tablet, can reach it, so the presenter allows
    // the first session there in each run (docs/pad-protocol.md, "USB"); one question at a time
    bool cableAllowed;
    TaskCompletionSource<bool>? asking;
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
        System.Security.Cryptography.ECDiffieHellman pcKey, string? code = null, bool usbDoorAlways = false)
    {
        this.usbDoorAlways = usbDoorAlways;
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
        if (usbDoorAlways) UsbDoor(true);
        Run("pad frames", FrameLoop);
        Run("pad ipad usb", () => UsbMux.Watch(() => running, OpenedOverUsb));
        Run("pad android usb", () => Adb.Watch(() => running, any => { if (!usbDoorAlways) UsbDoor(any); },
            () => ui.BeginInvoke(() => UsbToolsChanged?.Invoke())));
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

    /// <summary>
    /// The cable door for Android (where adb reverse arrives): reachable only from this PC, and open only while an
    /// Android tablet is plugged in and set up — not all the time, since any program on this PC can reach it.
    /// </summary>
    void UsbDoor(bool open)
    {
        lock (gate)
        {
            if (open == (usbListener != null) || (open && !running)) return;
            if (!open) { try { usbListener!.Stop(); } catch (Exception) { } usbListener = null; return; }
            try
            {
                var l = new TcpListener(IPAddress.Loopback, Pad.UsbPort);
                l.Start();
                usbListener = l;
                Run("pad usb accept", () => AcceptLoop(l, usb: true));
            }
            catch (SocketException e) { App.Log(e); }
        }
    }

    void AcceptLoop(TcpListener l, bool usb)
    {
        while (running)
        {
            TcpClient c;
            try { c = l.AcceptTcpClient(); }
            catch (Exception) { if (!running || !ReferenceEquals(l, usb ? usbListener : listener)) return; continue; }
            var from = (c.Client.RemoteEndPoint as IPEndPoint)?.Address ?? IPAddress.None;
            bool room;
            lock (gate)
            {
                if (usb) room = pendingUsb < MaxPendingUsb;
                else room = pendingWifi < MaxPending && pendingByAddress.GetValueOrDefault(from) < MaxPendingPerAddress;
                if (room)
                {
                    if (usb) pendingUsb++;
                    else { pendingWifi++; pendingByAddress[from] = pendingByAddress.GetValueOrDefault(from) + 1; }
                }
            }
            if (!room) { try { c.Close(); } catch (Exception) { } continue; }
            Run("pad tablet", () => Serve(c, usb, askFirst: usb, () =>
            {
                lock (gate)
                {
                    if (usb) { pendingUsb--; return; }
                    pendingWifi--;
                    if (--pendingByAddress[from] <= 0) pendingByAddress.Remove(from);
                }
            }));
        }
    }

    /// <summary>An iPad's USB connection, opened by this PC through Apple's USB service (one per iPad, so no count);
    /// ends when the session ends. Apple's service vouches for the device: no question for the presenter.</summary>
    void OpenedOverUsb(TcpClient c) => Serve(c, usb: true, askFirst: false, () => { });

    /// <summary>
    /// Asks the presenter (on the toolbar) whether the tablet on the Android cable door may draw: true at once when
    /// one was allowed earlier in this run. A second session meanwhile waits for the same answer. No answer in 30 s is no.
    /// </summary>
    Task<bool> AskPresenter(string device)
    {
        TaskCompletionSource<bool> tcs;
        lock (gate)
        {
            if (cableAllowed) return Task.FromResult(true);
            if (asking != null) return asking.Task;
            tcs = asking = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        }
        string text = $"An Android tablet on the USB cable wants to draw (\"{device}\"). Allow it?";
        ui.BeginInvoke(() => CableAsk?.Invoke(text));
        _ = Task.Delay(ProofWithin).ContinueWith(_ => Answer(false, tcs), TaskScheduler.Default);
        return tcs.Task;
    }

    /// <summary>The presenter's answer to <see cref="CableAsk"/> (Allow: true).</summary>
    public void Answer(bool allow)
    {
        TaskCompletionSource<bool>? tcs;
        lock (gate) tcs = asking;
        if (tcs != null) Answer(allow, tcs);
    }

    /// <summary>The connection that asked ended before an answer: no question left on the toolbar to allow later.</summary>
    void Withdraw(Task<bool> question)
    {
        TaskCompletionSource<bool>? tcs;
        lock (gate) tcs = asking != null && ReferenceEquals(asking.Task, question) ? asking : null;
        if (tcs != null) Answer(false, tcs);
    }

    void Answer(bool allow, TaskCompletionSource<bool> tcs)
    {
        lock (gate)
        {
            if (!ReferenceEquals(asking, tcs)) return;   // answered already (or timed out)
            asking = null;
            if (allow) cableAllowed = true;
        }
        tcs.TrySetResult(allow);
        ui.BeginInvoke(() => CableAsk?.Invoke(null));
    }

    /// <summary>A tablet is connected by the cable (not over Wi-Fi).</summary>
    public bool OverUsb => current?.Usb == true;

    /// <param name="askFirst">The Android cable door: the presenter allows the first session there in each run.</param>
    /// <param name="admitted">Called once when the connection stops being a stranger (let in, or ended).</param>
    void Serve(TcpClient tcp, bool usb, bool askFirst, Action admitted)
    {
        var conn = new Connection(tcp) { Usb = usb };
        string from = ((tcp.Client.RemoteEndPoint as IPEndPoint)?.Address ?? IPAddress.None).ToString();
        Task<bool>? allowed = null;
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
                        lock (gate) if (why == null && !usb && guard.Locked(from, DateTime.UtcNow)) why = Pad.TooManyWrong;
                        if (why != null) { Refuse(conn, why); return; }
                        device = hello!.Value.device;
                        salt = System.Security.Cryptography.RandomNumberGenerator.GetBytes(16);
                        conn.Stream.Write(Pad.ChallengeMessage(pcPoint, salt, Environment.MachineName));
                        step = 1;
                        deadline = DateTime.UtcNow + ProofWithin;
                        // asked now, so the presenter answers while the tablet's presenter compares the PC check
                        if (askFirst) allowed = AskPresenter(device);
                        continue;
                    }
                    if (step == 1)
                    {
                        if (!Prove(conn, type, payload, tabletKey!, salt!, device, from, allowed, deadline)) return;
                        step = 2;
                        reader.MaxLength = Pad.MaxLength;
                        admitted(); counted = false;
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
            if (counted) admitted();
            if (allowed is { IsCompleted: false }) Withdraw(allowed);   // gone before an answer: the question goes too
            conn.Close();
            bool wasCurrent;
            lock (gate) { wasCurrent = ReferenceEquals(current, conn); if (wasCurrent) current = null; }
            if (wasCurrent) ui.BeginInvoke(() => ConnectionChanged?.Invoke(null));
        }
    }

    /// <summary>The presenter's answer, waited for until <paramref name="deadline"/> (no answer by then is no).</summary>
    bool Wait(Task<bool> answer, DateTime deadline)
    {
        var left = deadline - DateTime.UtcNow;
        try { return left > TimeSpan.Zero && answer.Wait(left) && answer.Result && running; }
        catch (AggregateException) { return false; }
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
    bool Prove(Connection conn, byte type, byte[] payload, System.Security.Cryptography.ECDiffieHellmanPublicKey tabletKey, byte[] salt,
        string device, string from, Task<bool>? allowed, DateTime deadline)
    {
        string code;
        lock (gate) code = conn.Usb ? "" : Code;   // over the cable the code is empty (the Android door: the presenter allows it)
        var (toPc, toTablet) = PadCrypto.Keys(pcKey, tabletKey, salt, code);
        var open = new PadSeal(toPc);
        var proof = type == PadCrypto.Proof ? open.Open(payload) : null;
        var said = proof == null ? null : new PadReader().Add(proof);
        bool right = said is { Count: 1 } && said[0].type == Pad.Command && System.Text.Encoding.UTF8.GetString(said[0].payload) == PadCrypto.ProofText;
        // the Android cable door: in only once the presenter has said Allow (waiting here, within the PROOF's 30 s)
        bool let = allowed == null || (right && Wait(allowed, deadline));
        Connection? old = null;
        bool newCode = false;
        string? why = null;
        lock (gate)
        {
            if (!conn.Usb && guard.Locked(from, DateTime.UtcNow)) why = Pad.TooManyWrong;
            else if (!right)
            {
                why = Pad.WrongCode;
                if (!conn.Usb && guard.Wrong(from, DateTime.UtcNow)) { Code = Pad.NewCode(); newCode = true; }
            }
            else if (!let) why = Pad.NotAllowed;
            else
            {
                if (!conn.Usb) guard.Right(from);
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
        try
        {
            while (running)
            {
                var c = Volatile.Read(ref current);
                var now = DateTime.UtcNow;
                if (c != null && c.AckPending && now - c.SentAt > TimeSpan.FromSeconds(3)) c.AckPending = false;   // a lost acknowledgement
                if (c == null || c.Closed) StopCapture();   // no tablet: no capture (on Windows 10 it shows a border)
                if (c == null || c.Closed || c.AckPending || now - last < TimeSpan.FromMilliseconds(100)) { Thread.Sleep(15); continue; }
                try
                {
                    var jpeg = Capture(screen());
                    last = c.SentAt = DateTime.UtcNow;
                    c.AckPending = true;
                    c.Send(Pad.Message(Pad.Frame, jpeg));
                }
                catch (Exception e) { App.Log(e); Thread.Sleep(500); }   // a picture that can't be made: try again later
            }
        }
        finally { StopCapture(); }
    }

    /// <summary>The marks as the drawing layer shows them, asked of the UI thread (skipped when it's busy).</summary>
    System.Windows.Media.Imaging.BitmapSource? MarksNow()
    {
        try { return ui.Invoke(marks, DispatcherPriority.Render, CancellationToken.None, TimeSpan.FromMilliseconds(150)); }
        catch (Exception e) when (e is TimeoutException or TaskCanceledException or OperationCanceledException) { return null; }
    }

    // How the tablet's picture is made (only ever touched on the frame thread). Windows.Graphics.Capture first; the GDI
    // copy when this Windows can't, or when it failed once in this run (a capture that failed is not tried again).
    WgcCapture? wgc;
    bool wgcOff;
    string capturePath = "";
    // the Windows check's control: every picture white, so the check of the tablet's picture must fail
    static readonly bool blankForTest = Environment.GetEnvironmentVariable("CONTRASTINK_TEST") == "1"
                                     && Environment.GetEnvironmentVariable("CONTRASTINK_TEST_BLANKPAD") == "1";
    // test runs: which way the picture was made, for the Windows check to read (never written in normal use)
    static readonly string? captureReport = Environment.GetEnvironmentVariable("CONTRASTINK_STATUS") is { Length: > 0 } st ? st + ".capture.txt" : null;

    void StopCapture()
    {
        if (wgc == null || !OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041)) return;   // (only ever made on 19041+)
        try { wgc.Dispose(); } catch (Exception e) { App.Log(e); }
        wgc = null;
    }

    void Used(string how)
    {
        if (how == capturePath) return;
        capturePath = how;
        if (captureReport != null) try { File.WriteAllText(captureReport, how); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>
    /// The screen as the audience sees it, at most 1600 px wide, as a JPEG. The toolbar and the undo button are never in
    /// it (hidden from capture).
    /// </summary>
    byte[] Capture(Native.RECT r)
    {
        int w = Math.Max(1, r.Right - r.Left), h = Math.Max(1, r.Bottom - r.Top);
        double scale = Math.Min(1, 1600.0 / w);
        int ow = Math.Max(1, (int)(w * scale)), oh = Math.Max(1, (int)(h * scale));
        System.Windows.Media.Imaging.BitmapSource? picture = null;
        if (!wgcOff && OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        {
            try
            {
                if (wgc != null && !wgc.Covers(r)) StopCapture();   // the drawing moved to another screen
                if (wgc == null)
                {
                    if (!WgcCapture.Available()) { wgcOff = true; Used("gdi (Windows.Graphics.Capture not supported here)"); }
                    else wgc = WgcCapture.Start(r);
                }
                if (wgc != null) { picture = wgc.Picture(r, ow, oh); Used("wgc"); }
            }
            catch (Exception e)
            {
                // logged once: from now on the GDI copy, which works everywhere
                App.Log(new InvalidOperationException("Windows.Graphics.Capture failed; the tablet's picture is the GDI copy from now on", e));
                wgcOff = true;
                StopCapture();
                Used("gdi (Windows.Graphics.Capture failed: " + e.GetType().Name + ")");
                picture = null;
            }
        }
        else if (!wgcOff) { wgcOff = true; Used("gdi (Windows older than 10 2004)"); }
        if (picture == null)
        {
            // the GDI copy doesn't see the drawing layer (a layered window, without CAPTUREBLT): its marks go over it
            picture = GdiCopy(r, w, h, ow, oh);
            var marksPicture = MarksNow();
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
        }
        if (blankForTest)
        {
            var white = new byte[ow * oh * 4];
            Array.Fill(white, (byte)255);
            picture = System.Windows.Media.Imaging.BitmapSource.Create(ow, oh, 96, 96, System.Windows.Media.PixelFormats.Bgr32, null, white, ow * 4);
        }
        var jpeg = new System.Windows.Media.Imaging.JpegBitmapEncoder { QualityLevel = 70 };
        jpeg.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(picture));
        using var ms = new MemoryStream();
        jpeg.Save(ms);
        return ms.ToArray();
    }

    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr dc, ref BITMAPINFOHEADER info, uint usage, out IntPtr bits, IntPtr section, uint offset);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool StretchBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, int sw, int sh, uint rop);
    [DllImport("gdi32.dll")] static extern int SetStretchBltMode(IntPtr dc, int mode);
    [DllImport("gdi32.dll")] static extern bool SetBrushOrgEx(IntPtr dc, int x, int y, IntPtr old);
    [DllImport("gdi32.dll")] static extern bool GdiFlush();
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    const uint SRCCOPY = 0x00CC0020;
    const int HALFTONE = 4;
    [StructLayout(LayoutKind.Sequential)]
    struct BITMAPINFOHEADER
    {
        public int biSize, biWidth, biHeight;
        public short biPlanes, biBitCount;
        public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant;
    }

    /// <summary>
    /// The GDI copy: what is under the drawing layer, copied straight at the smaller size (no full-size copy of a 4K
    /// screen). Into a 32-bit top-down DIB whatever the screen's depth (a bitmap "compatible" with the screen is 16-bit
    /// in a 16-bit remote desktop or VM session, and read as 32-bit it came out scrambled), then read as opaque Bgr32:
    /// the copy's alpha byte is 0, and laid under the marks it vanished (the tablet's picture turned black). Without
    /// CAPTUREBLT: that flag makes the mouse pointer flicker on every copy, and OBS would record the flicker.
    /// </summary>
    static System.Windows.Media.Imaging.BitmapSource GdiCopy(Native.RECT r, int w, int h, int ow, int oh)
    {
        var info = new BITMAPINFOHEADER { biSize = Marshal.SizeOf<BITMAPINFOHEADER>(), biWidth = ow, biHeight = -oh, biPlanes = 1, biBitCount = 32 };
        IntPtr screenDc = GetDC(IntPtr.Zero), memDc = CreateCompatibleDC(screenDc);
        IntPtr bmp = CreateDIBSection(screenDc, ref info, 0 /* DIB_RGB_COLORS */, out var bits, IntPtr.Zero, 0);
        try
        {
            if (bmp == IntPtr.Zero || bits == IntPtr.Zero) throw new InvalidOperationException("no 32-bit bitmap for the screen's copy");
            var old = SelectObject(memDc, bmp);
            SetStretchBltMode(memDc, HALFTONE);
            SetBrushOrgEx(memDc, 0, 0, IntPtr.Zero);
            StretchBlt(memDc, 0, 0, ow, oh, screenDc, r.Left, r.Top, w, h, SRCCOPY);
            GdiFlush();
            SelectObject(memDc, old);
            int stride = ow * 4;
            var pixels = new byte[stride * oh];
            Marshal.Copy(bits, pixels, 0, pixels.Length);
            return System.Windows.Media.Imaging.BitmapSource.Create(ow, oh, 96, 96, System.Windows.Media.PixelFormats.Bgr32, null, pixels, stride);
        }
        finally
        {
            if (bmp != IntPtr.Zero) DeleteObject(bmp);
            DeleteDC(memDc);
            ReleaseDC(IntPtr.Zero, screenDc);
        }
    }

    public void Dispose()
    {
        running = false;
        Answer(false);   // a question still on the toolbar: no
        advert?.Dispose();
        try { listener?.Stop(); } catch (Exception) { }
        UsbDoor(false);
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
