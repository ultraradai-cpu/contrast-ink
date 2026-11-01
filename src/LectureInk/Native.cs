using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;

namespace LectureInk;

/// <summary>The few Windows functions WPF doesn't offer: click-through, hide-from-capture, topmost, monitors, input hooks.</summary>
static class Native
{
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80, WS_EX_LAYERED = 0x80000, WS_EX_NOACTIVATE = 0x08000000;

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);

    public static void SetExStyle(IntPtr hwnd, int add, int remove)
    {
        long style = GetWindowLongPtr(hwnd, GWL_EXSTYLE).ToInt64();
        SetWindowLongPtr(hwnd, GWL_EXSTYLE, new IntPtr((style | (uint)add) & ~(long)(uint)remove));
    }

    /// <summary>Windows 10 2004+: the window is shown on screen but left out of every screen capture (OBS included).</summary>
    public const uint WDA_EXCLUDEFROMCAPTURE = 0x11;
    [DllImport("user32.dll")] public static extern bool SetWindowDisplayAffinity(IntPtr hwnd, uint affinity);

    public static readonly IntPtr HWND_TOPMOST = new(-1);
    public const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOACTIVATE = 0x10, SWP_SHOWWINDOW = 0x40;
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

    public const int WM_MOUSEACTIVATE = 0x21, MA_NOACTIVATE = 3;

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

    public sealed record Monitor(RECT Bounds, bool Primary);

    /// <summary>Monitors, the main one first, then left to right.</summary>
    public static List<Monitor> Monitors()
    {
        var list = new List<Monitor>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr m, IntPtr dc, ref RECT r, IntPtr d) =>
        {
            var mi = new MONITORINFOEX { cbSize = Marshal.SizeOf<MONITORINFOEX>(), szDevice = "" };
            if (GetMonitorInfo(m, ref mi)) list.Add(new Monitor(mi.rcMonitor, (mi.dwFlags & 1) != 0));
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
}
