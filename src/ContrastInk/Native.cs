using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;

namespace ContrastInk;

/// <summary>The few Windows functions WPF doesn't offer: click-through, hide-from-capture, topmost, monitors, input hooks.</summary>
static class Native
{
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80, WS_EX_LAYERED = 0x80000, WS_EX_NOACTIVATE = 0x08000000;

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);

    /// <summary>Changes a window's extended style and reads it back: true only if Windows now has what was asked.</summary>
    public static bool SetExStyle(IntPtr hwnd, int add, int remove)
    {
        long style = GetWindowLongPtr(hwnd, GWL_EXSTYLE).ToInt64();
        long want = (style | (uint)add) & ~(long)(uint)remove;
        SetWindowLongPtr(hwnd, GWL_EXSTYLE, new IntPtr(want));
        return GetWindowLongPtr(hwnd, GWL_EXSTYLE).ToInt64() == want;
    }

    /// <summary>Windows 10 2004+: the window is shown on screen but left out of every screen capture (OBS included).</summary>
    public const uint WDA_EXCLUDEFROMCAPTURE = 0x11;
    [DllImport("user32.dll")] static extern bool SetWindowDisplayAffinity(IntPtr hwnd, uint affinity);

    /// <summary>
    /// Hides the window from screen capture. True only when it really is hidden.
    /// Microsoft (SetWindowDisplayAffinity, Remarks): on Windows before 10 version 2004 this value "will behave as
    /// if WDA_MONITOR is applied", which records the window as an empty box, and the call can still report success.
    /// So older Windows is answered "not hidden" without asking, and the toolbar says so.
    /// </summary>
    public static bool HideFromCapture(IntPtr hwnd) =>
        Environment.OSVersion.Version.Build >= 19041 && SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);

    public static readonly IntPtr HWND_TOPMOST = new(-1);
    public const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOACTIVATE = 0x10, SWP_SHOWWINDOW = 0x40;
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

    public const int WM_MOUSEACTIVATE = 0x21, MA_NOACTIVATE = 3;

    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr hwnd);
    public static RECT WindowRect(System.Windows.Window w) { GetWindowRect(new System.Windows.Interop.WindowInteropHelper(w).Handle, out var r); return r; }
    public const uint SWP_NOZORDER = 0x4;
    /// <summary>Moves a window's top-left corner to (x, y) in real screen pixels, keeping its size and stacking.</summary>
    public static void MoveTo(System.Windows.Window w, int x, int y) =>
        SetWindowPos(new System.Windows.Interop.WindowInteropHelper(w).Handle, IntPtr.Zero, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);

    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    /// <summary>Whether a key is physically down right now (not what our watcher last saw).</summary>
    public static bool IsDown(int vk) => (GetAsyncKeyState(vk) & 0x8000) != 0;

    public static uint Dpi(System.Windows.Window w) => GetDpiForWindow(new System.Windows.Interop.WindowInteropHelper(w).Handle);

    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    /// <summary>Windows 11 rounds the corners of a solid window when asked; Windows 10 ignores it.</summary>
    public static void RoundCorners(IntPtr hwnd)
    {
        int round = 2;   // DWMWCP_ROUND
        DwmSetWindowAttribute(hwnd, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, ref round, sizeof(int));
    }

    // ---------- monitors ----------
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct MONITORINFOEX
    {
        public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
    }
    delegate bool MonitorEnumProc(IntPtr monitor, IntPtr hdc, ref RECT rect, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFOEX info);

    /// <summary>A screen: where it is, its work area, whether it is the main one, and Windows' name for it ("\\.\DISPLAY2").</summary>
    public sealed record Monitor(RECT Bounds, RECT Work, bool Primary, string Device)
    {
        public ContrastInk.Core.Box Box => new(Bounds.Left, Bounds.Top, Bounds.Right, Bounds.Bottom);
        public ContrastInk.Core.Display Display => new(Device, Box);
    }

    /// <summary>Monitors, the main one first, then left to right.</summary>
    public static List<Monitor> Monitors()
    {
        var list = new List<Monitor>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr m, IntPtr dc, ref RECT r, IntPtr d) =>
        {
            var mi = new MONITORINFOEX { cbSize = Marshal.SizeOf<MONITORINFOEX>(), szDevice = "" };
            if (GetMonitorInfo(m, ref mi)) list.Add(new Monitor(mi.rcMonitor, mi.rcWork, (mi.dwFlags & 1) != 0, mi.szDevice ?? ""));
            return true;
        }, IntPtr.Zero);
        return list.OrderByDescending(m => m.Primary).ThenBy(m => m.Bounds.Left).ThenBy(m => m.Bounds.Top).ToList();
    }

    // ---------- low-level keyboard and mouse hooks ----------
    public const int WH_KEYBOARD_LL = 13, WH_MOUSE_LL = 14;
    public const int WM_KEYDOWN = 0x100, WM_KEYUP = 0x101, WM_SYSKEYDOWN = 0x104, WM_SYSKEYUP = 0x105;
    public const int WM_MOUSEMOVE = 0x200, WM_LBUTTONDOWN = 0x201;
    public const uint LLKHF_INJECTED = 0x10, LLMHF_INJECTED = 0x1;

    public delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr module, uint thread);
    [DllImport("user32.dll")] public static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] public static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetModuleHandle(string? name);

    [StructLayout(LayoutKind.Sequential)] public struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public UIntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct MSLLHOOKSTRUCT { public int x, y; public uint mouseData, flags, time; public UIntPtr dwExtraInfo; }

    // ---------- pens Windows knows about (Windows 8 and later) ----------
    const int POINTER_DEVICE_TYPE_INTEGRATED_PEN = 1, POINTER_DEVICE_TYPE_EXTERNAL_PEN = 2;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct POINTER_DEVICE_INFO
    {
        public uint displayOrientation;
        public IntPtr device;
        public int pointerDeviceType;
        public IntPtr monitor;
        public uint startingCursorId;
        public ushort maxActiveContacts;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 520)] public string productString;
    }

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool GetPointerDevices(ref uint count, [Out] POINTER_DEVICE_INFO[]? devices);

    /// <summary>
    /// The pens Windows reports: tablets beside the keyboard ("external") and pen screens ("integrated", tied to a
    /// display), with their names. Empty when Windows can't say (then nothing is assumed).
    /// </summary>
    public static (List<string> tablets, List<string> penScreens) PenDevices()
    {
        var tablets = new List<string>();
        var screens = new List<string>();
        try
        {
            uint n = 0;
            if (!GetPointerDevices(ref n, null) || n == 0) return (tablets, screens);
            var all = new POINTER_DEVICE_INFO[n];
            if (!GetPointerDevices(ref n, all)) return (tablets, screens);
            foreach (var d in all.Take((int)n))
            {
                var name = string.IsNullOrWhiteSpace(d.productString) ? "a pen" : d.productString.Trim();
                if (d.pointerDeviceType == POINTER_DEVICE_TYPE_EXTERNAL_PEN) tablets.Add(name);
                else if (d.pointerDeviceType == POINTER_DEVICE_TYPE_INTEGRATED_PEN) screens.Add(name);
            }
        }
        catch (Exception e) when (e is EntryPointNotFoundException or DllNotFoundException) { }
        return (tablets, screens);
    }

    // ---------- a key press for the app in front (the tablet's next / previous slide) ----------
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit, Size = 40)]
    struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KEYBDINPUT ki; }
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    public const ushort VK_LEFT = 0x25, VK_RIGHT = 0x27;

    /// <summary>
    /// Presses and releases a key, as if typed: PowerPoint, a PDF viewer or a DICOM viewer turns the page. False when
    /// Windows refused it. (Microsoft, SendInput: a key blocked because the app in front runs as administrator is NOT
    /// reported here; <see cref="ForegroundElevated"/> tells that case.)
    /// </summary>
    public static bool PressKey(ushort vk)
    {
        const uint KEYUP = 0x2, EXTENDED = 0x1;   // the arrow keys are "extended" keys
        var down = new INPUT { type = 1, ki = new KEYBDINPUT { wVk = vk, dwFlags = EXTENDED } };
        var up = new INPUT { type = 1, ki = new KEYBDINPUT { wVk = vk, dwFlags = EXTENDED | KEYUP } };
        return SendInput(2, new[] { down, up }, Marshal.SizeOf<INPUT>()) == 2;
    }

    // ---------- an app in front that runs as administrator ----------
    // Windows keeps keys sent by a normal app from reaching it, and keeps its keys from a normal app's keyboard watcher.
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetTokenInformation(IntPtr token, int cls, out int value, int size, out int returned);
    const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000, TOKEN_QUERY = 0x8;
    const int TokenElevation = 20;

    /// <summary>Whether a process runs as administrator; null when Windows won't say (a token a normal app may not read).</summary>
    static bool? Elevated(IntPtr process)
    {
        if (!OpenProcessToken(process, TOKEN_QUERY, out var token)) return null;
        try { return GetTokenInformation(token, TokenElevation, out int e, sizeof(int), out _) ? e != 0 : null; }
        finally { CloseHandle(token); }
    }

    /// <summary>Contrast Ink itself runs as administrator (then nothing is kept from it).</summary>
    public static readonly bool SelfElevated = Elevated(GetCurrentProcess()) == true;

    static uint lastPid;
    static bool lastElevated;

    /// <summary>
    /// The app in front runs as administrator (and Contrast Ink doesn't): Contrast Ink's keys and the tablet's ‹ ›
    /// can't reach it, and the keyboard watcher doesn't see keys typed into it. A process whose token can't even be
    /// read by a normal app counts as such. Asked every 1.5 s: remembered for the last process asked about.
    /// </summary>
    public static bool ForegroundElevated()
    {
        if (SelfElevated) return false;
        var hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero || GetWindowThreadProcessId(hwnd, out uint pid) == 0 || pid == 0) return false;
        if (pid == (uint)Environment.ProcessId) return false;
        if (pid == lastPid) return lastElevated;
        var p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        bool elevated;
        if (p == IntPtr.Zero) elevated = true;
        else
        {
            try { elevated = Elevated(p) ?? true; }
            finally { CloseHandle(p); }
        }
        lastPid = pid; lastElevated = elevated;
        return elevated;
    }
}
