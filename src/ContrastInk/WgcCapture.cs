using System;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Threading;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;

namespace ContrastInk;

/// <summary>
/// The tablet's picture by Windows.Graphics.Capture: one monitor as Windows composes it. Unlike the GDI copy it sees
/// GPU-drawn windows (DirectX, flip-model: a DICOM viewer, a browser, PowerPoint's slide show), which GDI can copy
/// black or frozen, and it leaves out the windows hidden from capture (the toolbar, the undo button) while showing the
/// drawing layer, so the marks need no separate pass. No mouse pointer, no border where Windows allows it (11).
/// When to use it at all is <see cref="ContrastInk.Core.PadCaptureChoice"/>'s decision; any failure: the GDI copy.
/// </summary>
[SupportedOSPlatform("windows10.0.19041.0")]
sealed unsafe class WgcCapture : IDisposable
{
    /// <summary>This Windows can capture this way (Windows 10 2004 or later, and the capture service is there).</summary>
    public static bool Available()
    {
        try { return GraphicsCaptureSession.IsSupported(); }
        catch (Exception) { return false; }
    }

    /// <summary>The capture can't go on as it is (its monitor went, the GPU was reset, the screen's size changed):
    /// started afresh, at once.</summary>
    public sealed class LostException : Exception { public LostException(string why, Exception? inner = null) : base(why, inner) { } }
    /// <summary>The screen is in HDR: this 8-bit capture would be washed out; the GDI copy gets an SDR picture.</summary>
    public sealed class HdrException : Exception { public HdrException() : base("the screen is in HDR") { } }

    /// <summary>A screen that hasn't sent a frame for this long: the session is started again (a stalled capture
    /// would otherwise show the same picture for ever; a still screen just gets one fresh frame).</summary>
    static readonly TimeSpan Stale = TimeSpan.FromSeconds(4);

    readonly Native.RECT started;      // the screen this capture was made for
    readonly int generation;           // the display layout it was made in (PadServer counts display changes)
    readonly Native.RECT monitor;      // that monitor's whole area, in real pixels (the capture's 0,0)
    IntPtr device, context, staging, mipped, mippedView;
    int stagingW, stagingH, mippedW, mippedH, mippedLevels;
    readonly IDirect3DDevice d3d;
    readonly GraphicsCaptureItem item;
    volatile Direct3D11CaptureFramePool? pool;
    GraphicsCaptureSession? session;
    readonly object gate = new();
    Direct3D11CaptureFrame? latest;     // the newest frame not yet turned into a picture
    Windows.Graphics.SizeInt32 poolSize;
    volatile Exception? failed;
    volatile bool closed;
    DateTime sessionStarted, lastFrame;
    System.Windows.Media.Imaging.BitmapSource? last;   // the last picture: the screen sends no frame while nothing changes
    bool disposed;

    /// <summary>The last picture made was nearly all black.</summary>
    public bool LastWasBlack { get; private set; }

    WgcCapture(Native.RECT r, int generation)
    {
        started = r;
        this.generation = generation;
        IntPtr hmon = MonitorFromRect(ref r, 2 /* MONITOR_DEFAULTTONEAREST */);
        var mi = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
        if (hmon == IntPtr.Zero || !GetMonitorInfo(hmon, ref mi)) throw new InvalidOperationException("no monitor for the screen");
        monitor = mi.rcMonitor;
        if (IsHdr(hmon)) throw new HdrException();
        try
        {
            // the GPU; WARP (software) where there is none usable
            int hr = D3D11CreateDevice(IntPtr.Zero, 1 /* HARDWARE */, IntPtr.Zero, 0x20 /* BGRA_SUPPORT */, IntPtr.Zero, 0, 7, out device, out _, out context);
            if (hr < 0) hr = D3D11CreateDevice(IntPtr.Zero, 5 /* WARP */, IntPtr.Zero, 0x20, IntPtr.Zero, 0, 7, out device, out _, out context);
            Marshal.ThrowExceptionForHR(hr);
            var iidDxgi = IidDxgiDevice;
            Marshal.ThrowExceptionForHR(Marshal.QueryInterface(device, ref iidDxgi, out var dxgi));
            try
            {
                Marshal.ThrowExceptionForHR(CreateDirect3D11DeviceFromDXGIDevice(dxgi, out var inspectable));
                try { d3d = WinRT.MarshalInterface<IDirect3DDevice>.FromAbi(inspectable); }
                finally { Marshal.Release(inspectable); }
            }
            finally { Marshal.Release(dxgi); }

            item = ItemForMonitor(hmon);
            item.Closed += (_, _) => closed = true;   // the monitor went away
            StartSession();
        }
        catch
        {
            Dispose();
            throw;
        }
    }

    /// <summary>Starts capturing the monitor that shows <paramref name="r"/>, in display layout <paramref name="generation"/>.</summary>
    public static WgcCapture Start(Native.RECT r, int generation) => new(r, generation);

    /// <summary>Made for this screen in this display layout (else it is started afresh: a screen plugged in or out,
    /// the resolution or the scale changed, the drawing moved to another screen).</summary>
    public bool Covers(Native.RECT r, int generation) => generation == this.generation
        && r.Left == started.Left && r.Top == started.Top && r.Right == started.Right && r.Bottom == started.Bottom;

    /// <summary>A new frame pool and session on the same device and monitor (the first, and after a stall).</summary>
    void StartSession()
    {
        StopSession();
        poolSize = item.Size;
        var p = Direct3D11CaptureFramePool.CreateFreeThreaded(d3d, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, poolSize);
        p.FrameArrived += OnFrame;
        pool = p;
        var s = p.CreateCaptureSession(item);
        session = s;
        s.IsCursorCaptureEnabled = false;
        if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 20348)) NoBorder(s);
        if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 26100)) AtMostTenASecond(s);
        sessionStarted = lastFrame = DateTime.UtcNow;
        s.StartCapture();
    }

    void StopSession()
    {
        var p = pool;
        pool = null;   // a frame still arriving on the old pool is dropped (OnFrame checks)
        Direct3D11CaptureFrame? f;
        lock (gate) { f = latest; latest = null; }
        try { f?.Dispose(); } catch (Exception) { }
        if (p != null) try { p.FrameArrived -= OnFrame; } catch (Exception) { }
        try { session?.Dispose(); } catch (Exception) { }
        session = null;
        try { p?.Dispose(); } catch (Exception) { }
    }

    /// <summary>Windows 11: no yellow border (asked for; where Windows says no, the border stays and the picture is the same).</summary>
    [SupportedOSPlatform("windows10.0.20348.0")]
    static void NoBorder(GraphicsCaptureSession s)
    {
        try
        {
            if (!Windows.Foundation.Metadata.ApiInformation.IsPropertyPresent("Windows.Graphics.Capture.GraphicsCaptureSession", "IsBorderRequired")) return;
            try { GraphicsCaptureAccess.RequestAccessAsync(GraphicsCaptureAccessKind.Borderless).AsTask().Wait(TimeSpan.FromSeconds(2)); }
            catch (Exception) { }
            s.IsBorderRequired = false;
        }
        catch (Exception) { }
    }

    /// <summary>Windows 11 24H2: frames at most every 100 ms (the tablet gets about ten a second; a 60 Hz video under
    /// the slides would otherwise keep the GPU copying sixty).</summary>
    [SupportedOSPlatform("windows10.0.26100.0")]
    static void AtMostTenASecond(GraphicsCaptureSession s)
    {
        try
        {
            if (Windows.Foundation.Metadata.ApiInformation.IsPropertyPresent("Windows.Graphics.Capture.GraphicsCaptureSession", "MinUpdateInterval"))
                s.MinUpdateInterval = TimeSpan.FromMilliseconds(100);
        }
        catch (Exception) { }
    }

    void OnFrame(Direct3D11CaptureFramePool sender, object args)
    {
        try
        {
            // keep only the newest: the older one goes back to the pool at once, so a new frame always has room
            Direct3D11CaptureFrame? f;
            while ((f = sender.TryGetNextFrame()) != null)
            {
                Direct3D11CaptureFrame? old;
                lock (gate)
                {
                    if (disposed || !ReferenceEquals(sender, pool)) { f.Dispose(); return; }   // an old pool's frame
                    old = latest; latest = f;
                }
                old?.Dispose();
            }
        }
        catch (Exception e) { if (ReferenceEquals(sender, pool)) failed ??= e; }
    }

    /// <summary>
    /// The screen <paramref name="r"/> at <paramref name="ow"/> x <paramref name="oh"/>, opaque Bgr32 (the drawing layer
    /// included). The last picture again when the screen hasn't changed. Throws <see cref="LostException"/> when the
    /// capture must be started afresh, anything else when it failed.
    /// </summary>
    public System.Windows.Media.Imaging.BitmapSource Picture(Native.RECT r, int ow, int oh)
    {
        Direct3D11CaptureFrame? f;
        var waited = DateTime.UtcNow;
        while (true)
        {
            if (closed) throw new LostException("the captured monitor went away");
            if (failed != null) throw new InvalidOperationException("the capture stopped", failed);
            lock (gate) { f = latest; latest = null; }
            if (f != null) break;
            var now = DateTime.UtcNow;
            if (last != null && last.PixelWidth == ow && last.PixelHeight == oh)
            {
                // a still screen sends nothing; one that has sent nothing for a while gets a new session, which always
                // sends a first frame: a stalled capture can't keep the tablet's picture frozen
                if (now - lastFrame > Stale) StartSession();
                return last;
            }
            // the first frame comes within a screen refresh or two; none in 2 s: this capture doesn't work here
            if (now - sessionStarted > TimeSpan.FromSeconds(2) && now - waited > TimeSpan.FromMilliseconds(500))
                throw new TimeoutException("no frame from Windows.Graphics.Capture");
            Thread.Sleep(10);
        }
        lastFrame = DateTime.UtcNow;
        using (f)
        {
            var size = f.ContentSize;
            // the screen's size changed: a capture made afresh (Recreate here would race the frame callback)
            if (size.Width != poolSize.Width || size.Height != poolSize.Height) throw new LostException("the screen's size changed");
            using var surface = f.Surface;
            IntPtr tex = Texture(surface);
            try
            {
                D3D11_TEXTURE2D_DESC desc;
                ((delegate* unmanaged[Stdcall]<IntPtr, D3D11_TEXTURE2D_DESC*, void>)VTable(tex, 10))(tex, &desc);
                int tw = Math.Min((int)desc.Width, size.Width), th = Math.Min((int)desc.Height, size.Height);
                // the screen's part of the monitor (the whole of it, normally), within what the frame holds
                int x0 = Math.Clamp(r.Left - monitor.Left, 0, tw - 1), y0 = Math.Clamp(r.Top - monitor.Top, 0, th - 1);
                int w = Math.Clamp(r.Right - r.Left, 1, tw - x0), h = Math.Clamp(r.Bottom - r.Top, 1, th - y0);
                var box = new D3D11_BOX { left = (uint)x0, top = (uint)y0, front = 0, right = (uint)(x0 + w), bottom = (uint)(y0 + h), back = 1 };
                // on the GPU: halved (mip levels) until the next halving would be smaller than the tablet's picture, so
                // the CPU reads and averages at most four pixels for each of the picture's (a 4K screen: 1/6 of it)
                int levels = 1;
                while ((w >> levels) >= ow && (h >> levels) >= oh && levels < 12) levels++;
                int level = levels - 1, mw = Math.Max(1, w >> level), mh = Math.Max(1, h >> level);
                EnsureStaging(mw, mh);
                if (level == 0)
                    CopyRegion(staging, 0, tex, 0, &box);
                else
                {
                    EnsureMipped(w, h, levels);
                    CopyRegion(mipped, 0, tex, 0, &box);
                    ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, void>)VTable(context, 54))(context, mippedView);   // GenerateMips
                    CopyRegion(staging, 0, mipped, (uint)level, null);
                }
                D3D11_MAPPED_SUBRESOURCE mapped;
                int hr = ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, uint, int, uint, D3D11_MAPPED_SUBRESOURCE*, int>)VTable(context, 14))(
                    context, staging, 0, 1 /* READ */, 0, &mapped);
                if (hr == DeviceRemoved || hr == DeviceReset) throw new LostException("the graphics device was reset", Marshal.GetExceptionForHR(hr));
                Marshal.ThrowExceptionForHR(hr);
                byte[] pixels;
                try { pixels = Shrink((byte*)mapped.pData, (int)mapped.RowPitch, mw, mh, ow, oh); }
                finally { ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, uint, void>)VTable(context, 15))(context, staging, 0); }   // Unmap
                LastWasBlack = ContrastInk.Core.PadCaptureChoice.MostlyBlack(pixels, ow, oh);
                var pic = System.Windows.Media.Imaging.BitmapSource.Create(ow, oh, 96, 96, System.Windows.Media.PixelFormats.Bgr32, null, pixels, ow * 4);
                pic.Freeze();
                last = pic;
                return pic;
            }
            finally { Marshal.Release(tex); }
        }
    }

    void CopyRegion(IntPtr dst, uint dstSub, IntPtr src, uint srcSub, D3D11_BOX* box) =>
        ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, uint, uint, uint, uint, IntPtr, uint, D3D11_BOX*, void>)VTable(context, 46))(
            context, dst, dstSub, 0, 0, 0, src, srcSub, box);   // CopySubresourceRegion

    /// <summary>A w x h BGRA picture averaged down to ow x oh (each output pixel the mean of its box: small slide text
    /// stays readable), alpha set opaque.</summary>
    static byte[] Shrink(byte* src, int pitch, int w, int h, int ow, int oh)
    {
        var dst = new byte[ow * oh * 4];
        var xs = new int[ow + 1];
        for (int i = 0; i <= ow; i++) xs[i] = (int)((long)i * w / ow);
        fixed (byte* d0 = dst)
        {
            for (int oy = 0; oy < oh; oy++)
            {
                int sy0 = (int)((long)oy * h / oh), sy1 = Math.Min(h, Math.Max(sy0 + 1, (int)((long)(oy + 1) * h / oh)));
                byte* d = d0 + (long)oy * ow * 4;
                for (int ox = 0; ox < ow; ox++, d += 4)
                {
                    int a = Math.Min(xs[ox], w - 1), b = Math.Min(w, Math.Max(a + 1, xs[ox + 1]));
                    int sb = 0, sg = 0, sr = 0;
                    for (int sy = sy0; sy < sy1; sy++)
                    {
                        byte* p = src + (long)sy * pitch + a * 4;
                        for (int sx = a; sx < b; sx++, p += 4) { sb += p[0]; sg += p[1]; sr += p[2]; }
                    }
                    int n = (sy1 - sy0) * (b - a);
                    d[0] = (byte)(sb / n); d[1] = (byte)(sg / n); d[2] = (byte)(sr / n); d[3] = 255;
                }
            }
        }
        return dst;
    }

    void EnsureStaging(int w, int h)
    {
        if (staging != IntPtr.Zero && stagingW == w && stagingH == h) return;
        Release(ref staging);
        staging = CreateTexture(w, h, 1, 3 /* STAGING */, 0, 0x20000 /* CPU READ */, 0);
        stagingW = w; stagingH = h;
    }

    /// <summary>A GPU texture of the screen's size with its mip levels, for halving on the GPU.</summary>
    void EnsureMipped(int w, int h, int levels)
    {
        if (mipped != IntPtr.Zero && mippedW == w && mippedH == h && mippedLevels == levels) return;
        Release(ref mippedView); Release(ref mipped);
        mipped = CreateTexture(w, h, levels, 0 /* DEFAULT */, 0x8 | 0x20 /* SHADER_RESOURCE | RENDER_TARGET */, 0, 0x1 /* GENERATE_MIPS */);
        IntPtr view;
        int hr = ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, IntPtr, IntPtr*, int>)VTable(device, 7))(device, mipped, IntPtr.Zero, &view);   // CreateShaderResourceView
        Marshal.ThrowExceptionForHR(hr);
        mippedView = view;
        mippedW = w; mippedH = h; mippedLevels = levels;
    }

    IntPtr CreateTexture(int w, int h, int levels, uint usage, uint bind, uint cpu, uint misc)
    {
        var desc = new D3D11_TEXTURE2D_DESC
        {
            Width = (uint)w, Height = (uint)h, MipLevels = (uint)levels, ArraySize = 1, Format = 87 /* B8G8R8A8_UNORM */,
            SampleCount = 1, SampleQuality = 0, Usage = usage, BindFlags = bind, CPUAccessFlags = cpu, MiscFlags = misc,
        };
        IntPtr t;
        int hr = ((delegate* unmanaged[Stdcall]<IntPtr, D3D11_TEXTURE2D_DESC*, IntPtr, IntPtr*, int>)VTable(device, 5))(device, &desc, IntPtr.Zero, &t);   // CreateTexture2D
        if (hr == DeviceRemoved || hr == DeviceReset) throw new LostException("the graphics device was reset", Marshal.GetExceptionForHR(hr));
        Marshal.ThrowExceptionForHR(hr);
        return t;
    }

    static void Release(ref IntPtr p) { if (p != IntPtr.Zero) { Marshal.Release(p); p = IntPtr.Zero; } }

    /// <summary>The frame's ID3D11Texture2D (a reference the caller releases).</summary>
    static IntPtr Texture(IDirect3DSurface surface)
    {
        IntPtr unknown = ((WinRT.IWinRTObject)surface).NativeObject.ThisPtr;
        var iidAccess = IidDxgiInterfaceAccess;
        Marshal.ThrowExceptionForHR(Marshal.QueryInterface(unknown, ref iidAccess, out var access));
        try
        {
            var iidTex = IidTexture2D;
            IntPtr tex;
            int hr = ((delegate* unmanaged[Stdcall]<IntPtr, Guid*, IntPtr*, int>)VTable(access, 3))(access, &iidTex, &tex);   // GetInterface
            Marshal.ThrowExceptionForHR(hr);
            return tex;
        }
        finally { Marshal.Release(access); }
    }

    /// <summary>A capture item for a whole monitor, through IGraphicsCaptureItemInterop::CreateForMonitor.</summary>
    static GraphicsCaptureItem ItemForMonitor(IntPtr hmon)
    {
        const string cls = "Windows.Graphics.Capture.GraphicsCaptureItem";
        Marshal.ThrowExceptionForHR(WindowsCreateString(cls, cls.Length, out var name));
        try
        {
            var iidInterop = IidCaptureItemInterop;
            Marshal.ThrowExceptionForHR(RoGetActivationFactory(name, ref iidInterop, out var interop));
            try
            {
                var iidItem = IidGraphicsCaptureItem;
                IntPtr p;
                int hr = ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, Guid*, IntPtr*, int>)VTable(interop, 4))(interop, hmon, &iidItem, &p);   // CreateForMonitor
                Marshal.ThrowExceptionForHR(hr);
                try { return GraphicsCaptureItem.FromAbi(p); }
                finally { Marshal.Release(p); }
            }
            finally { Marshal.Release(interop); }
        }
        finally { WindowsDeleteString(name); }
    }

    /// <summary>
    /// Whether the monitor is in HDR (advanced colour): its DXGI output's colour space is HDR10 (ST.2084, BT.2020).
    /// Every adapter's outputs are looked at (on a laptop with two GPUs the screen may hang off either). Unknown: no.
    /// </summary>
    public static bool IsHdr(IntPtr hmon)
    {
        var d = stackalloc byte[256];   // a DXGI_OUTPUT_DESC1
        var iidFactory = IidDxgiFactory1;
        if (CreateDXGIFactory1(ref iidFactory, out var factory) < 0 || factory == IntPtr.Zero) return false;
        try
        {
            for (uint a = 0; a < 16; a++)
            {
                IntPtr adapter;
                if (((delegate* unmanaged[Stdcall]<IntPtr, uint, IntPtr*, int>)VTable(factory, 7))(factory, a, &adapter) < 0) break;   // EnumAdapters
                try
                {
                    for (uint o = 0; o < 16; o++)
                    {
                        IntPtr output;
                        if (((delegate* unmanaged[Stdcall]<IntPtr, uint, IntPtr*, int>)VTable(adapter, 7))(adapter, o, &output) < 0) break;   // EnumOutputs
                        try
                        {
                            var iid6 = IidDxgiOutput6;
                            if (Marshal.QueryInterface(output, ref iid6, out var output6) < 0) continue;   // before Windows 10 1803: no HDR to see
                            try
                            {
                                if (((delegate* unmanaged[Stdcall]<IntPtr, byte*, int>)VTable(output6, 27))(output6, d) < 0) continue;   // GetDesc1
                                // DXGI_OUTPUT_DESC1: DeviceName[32] WCHAR, RECT, BOOL, rotation, HMONITOR at 88; BitsPerColor 96, ColorSpace 100
                                if (*(IntPtr*)(d + 88) == hmon) return *(int*)(d + 100) == 12 /* DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020 */;
                            }
                            finally { Marshal.Release(output6); }
                        }
                        finally { Marshal.Release(output); }
                    }
                }
                finally { Marshal.Release(adapter); }
            }
        }
        catch (Exception) { }
        finally { Marshal.Release(factory); }
        return false;
    }

    static IntPtr VTable(IntPtr com, int slot) => (*(IntPtr**)com)[slot];

    public void Dispose()
    {
        lock (gate) disposed = true;
        StopSession();
        try { d3d?.Dispose(); } catch (Exception) { }
        Release(ref mippedView); Release(ref mipped); Release(ref staging);
        Release(ref context); Release(ref device);
    }

    const int DeviceRemoved = unchecked((int)0x887A0005), DeviceReset = unchecked((int)0x887A0007);
    static readonly Guid IidDxgiDevice = new("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
    static readonly Guid IidDxgiFactory1 = new("770aae78-f26f-4dba-a829-253c83d1b387");
    static readonly Guid IidDxgiOutput6 = new("068346e8-aaec-4b84-add7-137f513f77a1");
    static readonly Guid IidDxgiInterfaceAccess = new("A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1");
    static readonly Guid IidTexture2D = new("6f15aaf2-d208-4e89-9ab4-489535d34f9c");
    static readonly Guid IidCaptureItemInterop = new("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356");
    static readonly Guid IidGraphicsCaptureItem = new("79C3F95B-31F7-4EC2-A464-632EF5D30760");

    [StructLayout(LayoutKind.Sequential)]
    struct D3D11_TEXTURE2D_DESC
    {
        public uint Width, Height, MipLevels, ArraySize, Format, SampleCount, SampleQuality, Usage, BindFlags, CPUAccessFlags, MiscFlags;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct D3D11_BOX { public uint left, top, front, right, bottom, back; }
    [StructLayout(LayoutKind.Sequential)]
    struct D3D11_MAPPED_SUBRESOURCE { public IntPtr pData; public uint RowPitch, DepthPitch; }
    [StructLayout(LayoutKind.Sequential)]
    struct MONITORINFO { public int cbSize; public Native.RECT rcMonitor, rcWork; public uint dwFlags; }

    [DllImport("d3d11.dll")]
    static extern int D3D11CreateDevice(IntPtr adapter, int driverType, IntPtr software, uint flags, IntPtr featureLevels, uint levels,
        uint sdkVersion, out IntPtr device, out int featureLevel, out IntPtr context);
    [DllImport("d3d11.dll")] static extern int CreateDirect3D11DeviceFromDXGIDevice(IntPtr dxgiDevice, out IntPtr graphicsDevice);
    [DllImport("dxgi.dll")] static extern int CreateDXGIFactory1(ref Guid iid, out IntPtr factory);
    [DllImport("combase.dll", CharSet = CharSet.Unicode)] static extern int WindowsCreateString(string s, int length, out IntPtr hstring);
    [DllImport("combase.dll")] static extern int WindowsDeleteString(IntPtr hstring);
    [DllImport("combase.dll")] static extern int RoGetActivationFactory(IntPtr classId, ref Guid iid, out IntPtr factory);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromRect(ref Native.RECT r, uint flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
}
