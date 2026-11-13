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
/// drawing layer, so the marks need no separate pass. No mouse pointer. On Windows 11 without the capture border; on
/// Windows 10 Windows draws a yellow border around the screen while it runs (README), so it runs only while a tablet is
/// connected. Any failure: the caller goes back to the GDI copy.
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

    readonly Native.RECT started;      // the screen this capture was made for
    readonly Native.RECT monitor;      // that monitor's whole area, in real pixels (the capture's 0,0)
    IntPtr device, context, staging;
    int stagingW, stagingH;
    readonly IDirect3DDevice d3d;
    readonly GraphicsCaptureItem item;
    readonly Direct3D11CaptureFramePool pool;
    readonly GraphicsCaptureSession session;
    readonly object gate = new();
    Direct3D11CaptureFrame? latest;     // the newest frame not yet turned into a picture
    Windows.Graphics.SizeInt32 poolSize;
    Exception? failed;
    readonly DateTime startedAt = DateTime.UtcNow;
    System.Windows.Media.Imaging.BitmapSource? last;   // the last picture: the screen sends no frame while nothing changes
    bool disposed;

    WgcCapture(Native.RECT r)
    {
        started = r;
        IntPtr hmon = MonitorFromRect(ref r, 2 /* MONITOR_DEFAULTTONEAREST */);
        var mi = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
        if (hmon == IntPtr.Zero || !GetMonitorInfo(hmon, ref mi)) throw new InvalidOperationException("no monitor for the screen");
        monitor = mi.rcMonitor;
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
            poolSize = item.Size;
            pool = Direct3D11CaptureFramePool.CreateFreeThreaded(d3d, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, poolSize);
            pool.FrameArrived += OnFrame;
            session = pool.CreateCaptureSession(item);
            session.IsCursorCaptureEnabled = false;
            if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 20348)) NoBorder(session);
            session.StartCapture();
        }
        catch
        {
            Dispose();
            throw;
        }
    }

    /// <summary>Starts capturing the monitor that shows <paramref name="r"/>.</summary>
    public static WgcCapture Start(Native.RECT r) => new(r);

    /// <summary>Made for this screen (a capture of another screen is started afresh).</summary>
    public bool Covers(Native.RECT r) => r.Left == started.Left && r.Top == started.Top && r.Right == started.Right && r.Bottom == started.Bottom;

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
                    if (disposed) { f.Dispose(); return; }
                    old = latest; latest = f;
                }
                old?.Dispose();
            }
        }
        catch (Exception e) { failed ??= e; }
    }

    /// <summary>
    /// The screen <paramref name="r"/> at <paramref name="ow"/> x <paramref name="oh"/>, opaque Bgr32 (the drawing layer
    /// included). The last picture again when the screen hasn't changed. Throws when the capture failed or never sent a frame.
    /// </summary>
    public System.Windows.Media.Imaging.BitmapSource Picture(Native.RECT r, int ow, int oh)
    {
        if (failed != null) throw new InvalidOperationException("the capture stopped", failed);
        Direct3D11CaptureFrame? f;
        var waited = DateTime.UtcNow;
        while (true)
        {
            lock (gate) { f = latest; latest = null; }
            if (f != null) break;
            if (last != null && last.PixelWidth == ow && last.PixelHeight == oh) return last;
            // the first frame comes within a screen refresh or two; none in 2 s: this capture doesn't work here
            if (DateTime.UtcNow - startedAt > TimeSpan.FromSeconds(2) && DateTime.UtcNow - waited > TimeSpan.FromMilliseconds(500))
                throw new TimeoutException("no frame from Windows.Graphics.Capture");
            if (failed != null) throw new InvalidOperationException("the capture stopped", failed);
            Thread.Sleep(10);
        }
        using (f)
        {
            var size = f.ContentSize;
            if (size.Width != poolSize.Width || size.Height != poolSize.Height)
            {
                // the monitor's resolution changed: frames of the new size from now on
                poolSize = size;
                pool.Recreate(d3d, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, size);
            }
            IntPtr tex = Texture(f.Surface);
            try
            {
                D3D11_TEXTURE2D_DESC desc;
                ((delegate* unmanaged[Stdcall]<IntPtr, D3D11_TEXTURE2D_DESC*, void>)VTable(tex, 10))(tex, &desc);
                int tw = (int)desc.Width, th = (int)desc.Height;
                EnsureStaging(tw, th);
                ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, IntPtr, void>)VTable(context, 47))(context, staging, tex);   // CopyResource
                D3D11_MAPPED_SUBRESOURCE mapped;
                int hr = ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, uint, int, uint, D3D11_MAPPED_SUBRESOURCE*, int>)VTable(context, 14))(
                    context, staging, 0, 1 /* READ */, 0, &mapped);
                Marshal.ThrowExceptionForHR(hr);
                try
                {
                    // the screen's part of the monitor (the whole of it, normally), within what the frame holds
                    int x0 = Math.Clamp(r.Left - monitor.Left, 0, tw - 1), y0 = Math.Clamp(r.Top - monitor.Top, 0, th - 1);
                    int w = Math.Clamp(r.Right - r.Left, 1, Math.Min(tw, size.Width) - x0), h = Math.Clamp(r.Bottom - r.Top, 1, Math.Min(th, size.Height) - y0);
                    var pixels = Shrink((byte*)mapped.pData, (int)mapped.RowPitch, x0, y0, w, h, ow, oh);
                    var pic = System.Windows.Media.Imaging.BitmapSource.Create(ow, oh, 96, 96, System.Windows.Media.PixelFormats.Bgr32, null, pixels, ow * 4);
                    pic.Freeze();
                    last = pic;
                    return pic;
                }
                finally { ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, uint, void>)VTable(context, 15))(context, staging, 0); }   // Unmap
            }
            finally { Marshal.Release(tex); }
        }
    }

    /// <summary>The area x0,y0 w x h of a BGRA picture, averaged down to ow x oh (each output pixel the mean of its
    /// box: small slide text stays readable), alpha set opaque.</summary>
    static byte[] Shrink(byte* src, int pitch, int x0, int y0, int w, int h, int ow, int oh)
    {
        var dst = new byte[ow * oh * 4];
        var xs = new int[ow + 1];
        for (int i = 0; i <= ow; i++) xs[i] = x0 + (int)((long)i * w / ow);
        var sum = new int[ow * 3];
        for (int oy = 0; oy < oh; oy++)
        {
            int sy0 = y0 + (int)((long)oy * h / oh), sy1 = Math.Max(sy0 + 1, y0 + (int)((long)(oy + 1) * h / oh));
            Array.Clear(sum);
            for (int sy = sy0; sy < sy1; sy++)
            {
                byte* row = src + (long)sy * pitch;
                for (int ox = 0; ox < ow; ox++)
                {
                    int a = xs[ox], b = Math.Max(a + 1, xs[ox + 1]);
                    int sb = 0, sg = 0, sr = 0;
                    for (int sx = a; sx < b; sx++) { byte* p = row + sx * 4; sb += p[0]; sg += p[1]; sr += p[2]; }
                    sum[ox * 3] += sb; sum[ox * 3 + 1] += sg; sum[ox * 3 + 2] += sr;
                }
            }
            for (int ox = 0; ox < ow; ox++)
            {
                int n = (sy1 - sy0) * Math.Max(1, xs[ox + 1] - xs[ox]);
                int d = (oy * ow + ox) * 4;
                dst[d] = (byte)(sum[ox * 3] / n); dst[d + 1] = (byte)(sum[ox * 3 + 1] / n); dst[d + 2] = (byte)(sum[ox * 3 + 2] / n); dst[d + 3] = 255;
            }
        }
        return dst;
    }

    void EnsureStaging(int w, int h)
    {
        if (staging != IntPtr.Zero && stagingW == w && stagingH == h) return;
        if (staging != IntPtr.Zero) { Marshal.Release(staging); staging = IntPtr.Zero; }
        var desc = new D3D11_TEXTURE2D_DESC
        {
            Width = (uint)w, Height = (uint)h, MipLevels = 1, ArraySize = 1, Format = 87 /* B8G8R8A8_UNORM */,
            SampleCount = 1, SampleQuality = 0, Usage = 3 /* STAGING */, BindFlags = 0, CPUAccessFlags = 0x20000 /* READ */, MiscFlags = 0,
        };
        IntPtr t;
        int hr = ((delegate* unmanaged[Stdcall]<IntPtr, D3D11_TEXTURE2D_DESC*, IntPtr, IntPtr*, int>)VTable(device, 5))(device, &desc, IntPtr.Zero, &t);   // CreateTexture2D
        Marshal.ThrowExceptionForHR(hr);
        staging = t; stagingW = w; stagingH = h;
    }

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

    static IntPtr VTable(IntPtr com, int slot) => (*(IntPtr**)com)[slot];

    public void Dispose()
    {
        Direct3D11CaptureFrame? f;
        lock (gate) { disposed = true; f = latest; latest = null; }
        try { if (pool != null) pool.FrameArrived -= OnFrame; } catch (Exception) { }
        try { session?.Dispose(); } catch (Exception) { }
        try { f?.Dispose(); } catch (Exception) { }
        try { pool?.Dispose(); } catch (Exception) { }
        try { d3d?.Dispose(); } catch (Exception) { }
        if (staging != IntPtr.Zero) { Marshal.Release(staging); staging = IntPtr.Zero; }
        if (context != IntPtr.Zero) { Marshal.Release(context); context = IntPtr.Zero; }
        if (device != IntPtr.Zero) { Marshal.Release(device); device = IntPtr.Zero; }
    }

    static readonly Guid IidDxgiDevice = new("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
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
    struct D3D11_MAPPED_SUBRESOURCE { public IntPtr pData; public uint RowPitch, DepthPitch; }
    [StructLayout(LayoutKind.Sequential)]
    struct MONITORINFO { public int cbSize; public Native.RECT rcMonitor, rcWork; public uint dwFlags; }

    [DllImport("d3d11.dll")]
    static extern int D3D11CreateDevice(IntPtr adapter, int driverType, IntPtr software, uint flags, IntPtr featureLevels, uint levels,
        uint sdkVersion, out IntPtr device, out int featureLevel, out IntPtr context);
    [DllImport("d3d11.dll")] static extern int CreateDirect3D11DeviceFromDXGIDevice(IntPtr dxgiDevice, out IntPtr graphicsDevice);
    [DllImport("combase.dll", CharSet = CharSet.Unicode)] static extern int WindowsCreateString(string s, int length, out IntPtr hstring);
    [DllImport("combase.dll")] static extern int WindowsDeleteString(IntPtr hstring);
    [DllImport("combase.dll")] static extern int RoGetActivationFactory(IntPtr classId, ref Guid iid, out IntPtr factory);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromRect(ref Native.RECT r, uint flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
}
