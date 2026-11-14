using System;
using System.Runtime.InteropServices;
using ContrastInk.Core;

namespace ContrastInk;

/// <summary>
/// Sees every key and mouse movement on the computer, whichever app has focus, so the
/// keys work while PowerPoint is in front. Runs on the UI thread and must answer fast.
/// </summary>
sealed class InputHooks : IDisposable
{
    readonly Native.HookProc keyProc, mouseProc;   // kept in fields so they are never garbage-collected
    IntPtr keyHook, mouseHook;
    int lastX = int.MinValue, lastY;

    /// <summary>(virtual key, pressed?) → true to swallow the key (it then never reaches PowerPoint).</summary>
    public Func<int, bool, bool>? Key;
    /// <summary>The mouse moved or clicked: (kind of input, dx, dy).</summary>
    public Action<InputKind, int, int>? Pointer;
    /// <summary>Test runs only (CONTRASTINK_TEST): keys sent by software count too, so a test can press F9.</summary>
    public bool AcceptInjectedKeys;

    public InputHooks()
    {
        keyProc = OnKey;
        mouseProc = OnMouse;
        Install();
    }

    void Install()
    {
        var module = Native.GetModuleHandle(null);
        keyHook = Native.SetWindowsHookEx(Native.WH_KEYBOARD_LL, keyProc, module, 0);
        mouseHook = Native.SetWindowsHookEx(Native.WH_MOUSE_LL, mouseProc, module, 0);
    }

    /// <summary>
    /// Microsoft (LowLevelKeyboardProc, Remarks): a hook that times out is, "on Windows 7 and later, ... silently
    /// removed", and "There is no way for the application to know whether the hook is removed." So the hooks are
    /// installed again every two minutes, after a wake and after a screen change: a lost hook costs minutes, not a lecture.
    /// False when Windows refused them this time (the app then says so on the toolbar: only logging it left the
    /// presenter pressing keys that did nothing).
    /// </summary>
    public bool Reinstall()
    {
        Dispose();
        Install();
        if (!Working) App.Log(new InvalidOperationException("keyboard/mouse hooks could not be installed again"));
        return Working;
    }

    public bool Working => keyHook != IntPtr.Zero && mouseHook != IntPtr.Zero;

    IntPtr OnKey(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0 && Key is { } key)
        {
            var k = Marshal.PtrToStructure<Native.KBDLLHOOKSTRUCT>(lParam);
            int msg = wParam.ToInt32();
            bool down = msg is Native.WM_KEYDOWN or Native.WM_SYSKEYDOWN, up = msg is Native.WM_KEYUP or Native.WM_SYSKEYUP;
            // keys sent by other programs (e.g. a presenter app) pass untouched
            if ((down || up) && (AcceptInjectedKeys || (k.flags & Native.LLKHF_INJECTED) == 0))
            {
                try { if (key((int)k.vkCode, down)) return new IntPtr(1); }
                catch (Exception e) { App.Log(e); }   // never let a bug block the keyboard
            }
        }
        return Native.CallNextHookEx(keyHook, code, wParam, lParam);
    }

    IntPtr OnMouse(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0 && Pointer is { } pointer)
        {
            int msg = wParam.ToInt32();
            if (msg is Native.WM_MOUSEMOVE or Native.WM_LBUTTONDOWN)
            {
                var m = Marshal.PtrToStructure<Native.MSLLHOOKSTRUCT>(lParam);
                if ((m.flags & Native.LLMHF_INJECTED) == 0 || PenInput.Kind(m.dwExtraInfo.ToUInt64()) != InputKind.Mouse)
                {
                    int dx = lastX == int.MinValue ? 0 : m.x - lastX, dy = lastX == int.MinValue ? 0 : m.y - lastY;
                    lastX = m.x; lastY = m.y;
                    try { pointer(PenInput.Kind(m.dwExtraInfo.ToUInt64()), dx, dy); }
                    catch (Exception e) { App.Log(e); }
                }
            }
        }
        return Native.CallNextHookEx(mouseHook, code, wParam, lParam);
    }

    public void Dispose()
    {
        if (keyHook != IntPtr.Zero) { Native.UnhookWindowsHookEx(keyHook); keyHook = IntPtr.Zero; }
        if (mouseHook != IntPtr.Zero) { Native.UnhookWindowsHookEx(mouseHook); mouseHook = IntPtr.Zero; }
    }
}
