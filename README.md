# Contrast Ink

Draw on your screen while you lecture: over PowerPoint, a DICOM viewer, a browser, anything.
OBS records your drawings; the toolbar stays out of the recording.

Also for iPad and Android, for personal use:

- **iPad** (Apple Pencil, slides as PDF, built-in recording, projector): see [ios/README.md](ios/README.md).
- **Android** phone or tablet (draws over any app, records the screen): see [android/README.md](android/README.md).
  The APK is on **Releases → Android (latest)**.
- **Mac** (draws over PowerPoint or anything, OBS, tablets as pads): see [mac/README.md](mac/README.md).

This page is about the Windows app.

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
| **Finger (touch)** | Never switches drawing on: with drawing off, a finger always clicks |
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

**Pen tablets** you write on beside the keyboard (Wacom Intuos and One, XP-Pen Deco, Huion Inspiroy, Gaomon,
Veikk...) are found by themselves: their pen then works like the mouse (switch drawing on with ✏, F9 or Ctrl), so
clicks and marks land where the cursor is. **Pen screens** you write on directly (Wacom Cintiq, XP-Pen Artist,
Huion Kamvas, a Surface) stay pens, with pressure. To choose yourself: **⚙ Settings → Pen Tablet Beside the
Keyboard**, then close Contrast Ink (✕) and open it again. (Untick **Windows Ink** in the tablet's own settings and
it is a mouse to every app, which works too.)

Resting the mouse or pen on a button shows its name ("Pen (P)", "Highlighter (H)") under the buttons. To stop
that: **⚙ Settings → Toolbar → Show Button Names**, off. Warnings still show.

- **Z** on its own, or **Ctrl+Z**, while drawing.
- **Right-click**, or the **side button on your pen**, while drawing.
- The small blue **↶ button** that appears beside your last mark. Like the toolbar, OBS doesn't record it. On a
  Windows too old to hide it, it never appears.
- Turn the pen over: its **eraser end** removes any mark it touches, whatever tool is chosen.

## Slides

In a PowerPoint slide show, each slide keeps its own marks. The next slide starts clean, and going back to a slide
shows its marks again. Animations on a slide (clicks that don't change the slide) keep the marks. When the slide show
ends, the marks drawn on its slides go away with it, and starting the show again starts clean. Switch this off under ⚙ Settings to keep marks until you clear them.

This needs the desktop PowerPoint app (Microsoft 365, 2016, 2019, 2021). In other apps (PowerPoint on the web, a PDF
viewer, a DICOM viewer) marks stay until you clear them.

## Record From the Toolbar

Contrast Ink can start and stop OBS for you, so you never have to switch to OBS mid-lecture. OBS still does the
recording, with your OBS settings.

**Once, in OBS:** open **Tools → WebSocket Server Settings**, tick **Enable WebSocket Server**, and press **OK**.
Contrast Ink reads the port and password from OBS's own settings, so there's nothing to type. (OBS 28 or newer.)

| Button | What it does |
|---|---|
| ⏺ | Start recording (grey until OBS is open and connected; press it to connect) |
| ⏹ | Stop recording |
| ⏸ / ▶ | Pause / resume |

While recording, the toolbar shows the time, and a message under the buttons if:
- OBS stops recording by itself (what was recorded is saved),
- OBS closes (the chapters are still saved, in OBS's recording folder),
- less than 2 GB is left on the recording disk, or
- the OBS scene has no Display Capture, so your marks wouldn't be in the video.

Click a message to dismiss it.

**Chapters:** in a PowerPoint slide show, every slide change becomes a chapter, named by PowerPoint's own slide number. When you stop, a file named
`<your video> chapters.txt` is saved next to the video, ready to paste into a YouTube description. YouTube ignores
the whole list if one chapter is shorter than 10 seconds, so a slide shown less than 10 seconds (clicked past) gives
its place to the next one. A recording already running when Contrast Ink connects (started in OBS, or after Contrast
Ink was restarted) gets its first chapter at the time it has reached. With OBS 30.2 or newer
and the **Hybrid MP4** recording format (Settings → Output → Recording Format), the chapters are also inside the video.

## A Tablet as a Pad (Android or iPad)

Draw on a tablet in your hand while the PC shows the slides and OBS records: the tablet shows a live picture of
the PC's screen, and what you draw on it is drawn on the PC.

1. On the PC: **⚙ Settings → Let a Tablet Draw Here (Over Wi-Fi)**. It shows a 6-digit **code** (new each time
   Contrast Ink starts), a **PC check** (always the same for this PC) and the PC's address. The first time,
   Windows may ask to let Contrast Ink use the network: allow it (tick "public" too if the lecture-hall Wi-Fi is
   a public network).
2. On the tablet (same Wi-Fi): Contrast Ink → **Use as a pad for a PC** → pick the PC → type the code.
3. The first time with this PC, the tablet shows a PC check: tap **It matches** only if it is the same as on the
   PC. Next time it goes straight in, and warns you if another machine ever pretends to be this PC.
4. Draw. The tablet's toolbar has the tools, colours, widths, undo, clear, the laser, and ‹ › to change slides
   (the app in front on the PC turns the page).

**No shared Wi-Fi** (a lecture hall whose Wi-Fi keeps devices apart, or none at all): turn on Windows' **Mobile
hotspot** (Settings → Network & internet → Mobile hotspot) and join it from the tablet. The ⚙ panel lists every
address of the PC, the hotspot's marked "(hotspot)" (usually 192.168.137.1), and the tablet finds the PC there by
name too; or use the USB cable.

**By USB cable** (it switches to the cable by itself when plugged in, and back to Wi-Fi when unplugged):
- iPad: install iTunes (or Apple Devices) on the PC, plug in, tap Trust on the iPad. No code needed by cable.
- Android: once, on the tablet, Settings → About → tap Build number 7 times, then Developer options → USB
  debugging on; on the PC, unzip Google's free platform-tools into `%LOCALAPPDATA%\Android\Sdk\platform-tools`
  (so that `adb.exe` is in that folder; Android Studio puts it there already), or add the folder you unzipped it to
  to your PATH. (`C:\platform-tools` is no longer used: any user of the PC can create that folder.) Plug in and allow
  the PC on the tablet. No code needed by cable, but the first time in each run of Contrast Ink the toolbar asks
  "An Android tablet on the USB cable wants to draw": press **Allow** (Deny, or no answer in 30 s, turns it away).
  Any program on the PC can reach the cable's door, so only allow it when you just plugged your tablet in.
- The first time with this PC, the tablet shows the PC check by cable too: compare it as over Wi-Fi.

**The tablet's picture** is made with Windows' own screen capture (Windows.Graphics.Capture), which also sees
videos, DICOM viewers and other programs drawn by the graphics card, and leaves out the toolbar and the mouse
pointer. On **Windows 10**, Windows draws a thin **yellow border** around the screen while a tablet is connected
(it shows to the audience and in OBS, and goes when the tablet disconnects); Windows 11 needs no border. Where that
capture isn't available (Windows 10 before version 2004) or fails, Contrast Ink falls back to an older copy of the
screen, which can show some video or 3D windows black or still.

Everything between the tablet and the PC is encrypted, and the code itself never crosses the network. The PC check
is 16 characters (`XXXX-XXXX-XXXX-XXXX`): compare all of them. Wrong codes are limited per device: five in a row
from one device lock that device out for 30 s (fifteen in a row from all devices lock everyone out for 30 s), and
twenty in all make a new code. With patient images on screen, a private network or the PC's own hotspot is safer still.

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
- A projector plugged in or out mid-lecture: the drawing layer moves to the laptop's screen while the projector is
  gone, and back to the projector when it returns (the screen you chose with 🖥 is remembered by name).
- An app started **as administrator** (some DICOM viewers, or any app you ran with "Run as administrator"): while it
  is in front, Windows keeps Contrast Ink's keys and the tablet's ‹ › from reaching it, and keeps its keys from
  Contrast Ink (F9, Ctrl, the letter keys do nothing). The toolbar says so. Open that app normally, or start
  Contrast Ink as administrator too.
- If the toolbar's line says Windows didn't allow Contrast Ink to watch the keyboard and pen, use the toolbar's
  buttons; it tries again every two minutes and the line goes when it works.

Errors are written to `%AppData%\ContrastInk\error.log`. Send that file along with what you were doing.
Settings are in `%AppData%\ContrastInk\settings.json` (delete it to start fresh).

## For Developers

- `src/ContrastInk.Core`: the rules (when to draw, shapes, fading, settings), plain .NET, tested on any OS.
- `src/ContrastInk`: the Windows app (WPF): transparent drawing layer, toolbar, keyboard and pen detection.
- `tests/ContrastInk.Core.Tests`: `dotnet test tests/ContrastInk.Core.Tests`
- Every push to `main` builds `ContrastInk.exe` on GitHub and replaces the **Latest** release.
