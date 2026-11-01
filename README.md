# Lecture Ink

Draw on your screen while you lecture: over PowerPoint, a DICOM viewer, a browser, anything.
OBS records your drawings; the toolbar stays out of the recording.

## Get It

1. Open **Releases → Latest** on this page and download **LectureInk.exe**.
2. Double-click it. No install, no admin rights.
3. The first time, Windows may say "Windows protected your PC" (the app isn't signed):
   click **More info → Run anyway**.

A small maroon toolbar appears at the top of the screen. Drag it by the ⋮⋮ handle.

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
- While Lecture Ink is running, holding Ctrl anywhere switches drawing on, so a Ctrl+click in another
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
| Ctrl+Z | Undo (also brings back a Clear) |

Marks stay until you clear them. The 🖥 button moves the drawing layer to your other screen.

## OBS Settings

- Use **Display Capture** (the whole screen), not Window Capture of PowerPoint, or your drawings won't be recorded.
- The toolbar, and its hover help, are hidden from recordings on Windows 10 (version 2004 or newer) and Windows 11.
  On older Windows 10 it can't be hidden (Microsoft: there the setting records the window as an empty box), so the
  ⋮⋮ handle turns **red** and a warning line stays under the buttons: make the toolbar small (‹) or move it to a corner.
- Hover help appears as a line inside the toolbar (never as a pop-up, which OBS could record).
- Turn off **Capture Cursor** in the Display Capture settings if you don't want the mouse arrow in the video.

## If Something Goes Wrong

- If F9 or the letter keys stop working, wait up to two minutes: Windows can silently drop the app's keyboard
  watcher, and Lecture Ink installs it again every two minutes, after sleep, and when a screen is plugged in or out.
- A projector plugged in or out mid-lecture: the drawing layer moves to cover the right screen by itself.

Errors are written to `%AppData%\LectureInk\error.log`. Send that file along with what you were doing.
Settings are in `%AppData%\LectureInk\settings.json` (delete it to start fresh).

## For Developers

- `src/LectureInk.Core`: the rules (when to draw, shapes, fading, settings), plain .NET, tested on any OS.
- `src/LectureInk`: the Windows app (WPF): transparent drawing layer, toolbar, keyboard and pen detection.
- `tests/LectureInk.Core.Tests`: `dotnet test tests/LectureInk.Core.Tests`
- Every push to `main` builds `LectureInk.exe` on GitHub and replaces the **Latest** release.
