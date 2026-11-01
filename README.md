# Contrast Ink

Draw on your screen while you lecture: over PowerPoint, a DICOM viewer, a browser, anything.
OBS records your drawings; the toolbar stays out of the recording.

## Get It

1. Open **Releases → Latest** on this page and download **ContrastInk.exe**.
2. Double-click it. No install, no admin rights.
3. The first time, Windows may say "Windows protected your PC" (the app isn't signed):
   click **More info → Run anyway**.

A small dark Contrast Ink toolbar appears at the top of the screen. Drag it by the blue Contrast mark at its left end.

## Draw

| How | What it does |
|---|---|
| **Hold Ctrl** | Draw while Ctrl is held; let go and clicks go to PowerPoint again |
| **F9** or the **✏ button** | Drawing on / off |
| **Pen or stylus** | Draws by itself when it comes near the screen; moving the mouse goes back to clicking |
| **Finger (touch)** | Always clicks, never draws |
| **Esc** | Stop drawing |

While drawing, slide keys (→, Page Down, Space, a presenter clicker) still go to PowerPoint.

Good to know:
- While Contrast Ink is running, holding Ctrl anywhere switches drawing on, so a Ctrl+click in another
  program (e.g. picking several files) lands on the drawing layer. Quit it (✕) when you're not lecturing.
- The pen switches drawing on when it hovers near the screen, and off 3 seconds after it leaves (or when the mouse moves). A stylus that can't hover (some cheap
  touch-screen styluses) sends its first tap to PowerPoint, which may change the slide: use F9 with those.

## Keys While Drawing

| Key | Tool |
|---|---|
| P | Pen |
| H | Highlighter |
| A | Arrow: drag from the tail to the tip |
| O | Circle a finding; hold Shift for a perfect circle |
| E | Eraser: touch a mark to remove it |
| 1 2 3 4 5 6 | Red, yellow, green, cyan, white, black (bright colours for dark images, black for white slides, red for both) |
| [ and ] | Thinner / thicker |
| F | Fading ink on/off: marks disappear after 3 seconds (hold Shift while drawing to keep one) |
| C | Clear all marks |
| Ctrl+Z or Z | Undo (also brings back a Clear) |

The 🖥 button moves the drawing layer to your other screen.

## Undo

Any of these removes the last mark. Each one can be switched off under **⚙ Settings** on the toolbar.

- **Z** on its own, or **Ctrl+Z**, while drawing.
- **Right-click**, or the **side button on your pen**, while drawing.
- The small blue **↶ button** that appears beside your last mark. Like the toolbar, OBS doesn't record it. On a
  Windows too old to hide it, it never appears.
- Turn the pen over: its **eraser end** removes any mark it touches, whatever tool is chosen.

## Slides

In a PowerPoint slide show, each slide keeps its own marks. The next slide starts clean, and going back to a slide
shows its marks again. Animations on a slide (clicks that don't change the slide) keep the marks. When the slide show
ends, the marks drawn on its slides go away with it. Switch this off under ⚙ Settings to keep marks until you clear them.

This needs the desktop PowerPoint app (Microsoft 365, 2016, 2019, 2021). In other apps (PowerPoint on the web, a PDF
viewer, a DICOM viewer) marks stay until you clear them.

## OBS Settings

- Use **Display Capture** (the whole screen), not Window Capture of PowerPoint, or your drawings won't be recorded.
- The toolbar, and its hover help, are hidden from recordings on Windows 10 (version 2004 or newer) and Windows 11.
  On older Windows 10 it can't be hidden (Microsoft: there the setting records the window as an empty box), so the
  dot beside the Contrast mark turns **red** and a warning line stays under the buttons: make the toolbar small (‹) or move it to a corner.
- Hover help appears as a line inside the toolbar (never as a pop-up, which OBS could record).
- Turn off **Capture Cursor** in the Display Capture settings if you don't want the mouse arrow in the video.

## If Something Goes Wrong

- If F9 or the letter keys stop working, wait up to two minutes: Windows can silently drop the app's keyboard
  watcher, and Contrast Ink installs it again every two minutes, after sleep, and when a screen is plugged in or out.
- A projector plugged in or out mid-lecture: the drawing layer moves to cover the right screen by itself.

Errors are written to `%AppData%\ContrastInk\error.log`. Send that file along with what you were doing.
Settings are in `%AppData%\ContrastInk\settings.json` (delete it to start fresh).

## For Developers

- `src/ContrastInk.Core`: the rules (when to draw, shapes, fading, settings), plain .NET, tested on any OS.
- `src/ContrastInk`: the Windows app (WPF): transparent drawing layer, toolbar, keyboard and pen detection.
- `tests/ContrastInk.Core.Tests`: `dotnet test tests/ContrastInk.Core.Tests`
- Every push to `main` builds `ContrastInk.exe` on GitHub and replaces the **Latest** release.
