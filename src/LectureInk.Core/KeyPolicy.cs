namespace LectureInk.Core;

public enum KeyAction { Pass, ToggleDrawing, Undo, StopDrawing, Pen, Highlighter, Arrow, Oval, Eraser, Clear, Fade, Thinner, Thicker, Color }

/// <summary>
/// Which keys Lecture Ink takes and which reach PowerPoint. The most important rule in the app:
/// a key taken by mistake is a slide that won't change; a key let through by mistake types into the slide.
/// Lifted out of the Windows code so it can be tested.
/// </summary>
public static class KeyPolicy
{
    public const int VK_ESC = 0x1B, VK_F9 = 0x78, VK_Z = 0x5A;

    /// <param name="vk">Windows virtual-key code of a key being pressed (not released).</param>
    /// <param name="drawing">Whether the drawing layer is on right now.</param>
    /// <param name="ctrl">Ctrl held. <param name="altOrWin">Alt or the Windows key held.</param></param>
    /// <returns>What to do, and for <see cref="KeyAction.Color"/> which colour (0-based).</returns>
    public static (KeyAction action, int color) Decide(int vk, bool drawing, bool ctrl, bool altOrWin)
    {
        if (altOrWin) return (KeyAction.Pass, 0);                   // Alt+Tab, Win+D... are Windows'
        if (vk == VK_F9) return (KeyAction.ToggleDrawing, 0);
        if (ctrl) return (vk == VK_Z && drawing ? KeyAction.Undo : KeyAction.Pass, 0);   // Ctrl+C etc. are PowerPoint's
        if (!drawing) return (KeyAction.Pass, 0);                  // not drawing: every key is PowerPoint's
        switch (vk)
        {
            case VK_ESC: return (KeyAction.StopDrawing, 0);
            case 0x50: return (KeyAction.Pen, 0);           // P
            case 0x48: return (KeyAction.Highlighter, 0);   // H
            case 0x41: return (KeyAction.Arrow, 0);         // A
            case 0x4F: return (KeyAction.Oval, 0);          // O
            case 0x45: return (KeyAction.Eraser, 0);        // E
            case 0x43: return (KeyAction.Clear, 0);         // C
            case 0x46: return (KeyAction.Fade, 0);          // F
            case 0xDB: return (KeyAction.Thinner, 0);       // [
            case 0xDD: return (KeyAction.Thicker, 0);       // ]
        }
        // 1-6 on the top row (0x31...) and on the number pad (0x61...); 7, 8, 9 pass
        int n = vk is >= 0x31 and <= 0x39 ? vk - 0x31 : vk is >= 0x61 and <= 0x69 ? vk - 0x61 : -1;
        if (n >= 0 && n < Settings.Colors.Length) return (KeyAction.Color, n);
        return (KeyAction.Pass, 0);   // arrows, Page Down, Space, B/W (black/white screen)... change slides while drawing
    }
}
