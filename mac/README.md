# Contrast Ink for the Mac

Draw on your Mac's screen while you lecture: over PowerPoint (also in a full-screen slide show), a DICOM viewer
(Horos, OsiriX), a browser, anything. OBS records your drawings. An Android tablet or an iPad can be the pad you
draw on, over Wi-Fi or by its USB cable, exactly as with the Windows app.

macOS 13 (Ventura) or newer, Apple silicon or Intel.

## Get It

1. Open **Releases → Mac (latest)** on this page and download **ContrastInk-Mac.zip**.
2. Double-click it to unzip, and drag **ContrastInk.app** into **Applications**.
3. The first time, **right-click ContrastInk.app → Open**, then **Open** again. The app isn't signed by Apple, so
   a plain double-click says it "can't be opened" the first time. (On macOS 15, if there is no Open button: try
   to open it once, then **System Settings → Privacy & Security → Open Anyway**.)

There is no Dock icon and no menu: a small dark Contrast Ink toolbar appears at the top right of the screen.
Drag it by the blue Contrast mark at its left end. Quit with **✕** on the toolbar.

## Permissions macOS May Ask For

All in **System Settings → Privacy & Security**. Contrast Ink asks only when a feature needs one; ⚙ on the
toolbar shows which are given, with buttons to the right page.

| Permission | What for | When it is asked |
|---|---|---|
| **Screen Recording** | The tablet's live picture of the screen. Without it macOS gives only the desktop picture. | When you switch on the tablet link. After allowing it, quit Contrast Ink (✕) and open it again. |
| **Accessibility** | Sending → and ← to the app in front: the tablet's ‹ › buttons, and slide keys pressed while drawing is on. | The first time the tablet sends ‹ or ›, or you press a slide key while drawing. |
| **Local Network** (macOS 15) | Letting a tablet on the Wi-Fi find this Mac and connect. | When you switch on the tablet link. |

**After updating Contrast Ink** (a new ContrastInk.app in place of the old one): in **System Settings → Privacy &
Security**, open **Screen Recording** and **Accessibility**, select Contrast Ink, remove it with **−**, then add it
again with **+** (or switch it on when it asks), and quit and reopen Contrast Ink. The app isn't signed by Apple, so
macOS ties each permission to the exact build you allowed: the switch can still show as on while the new build is
refused (the tablet then sees only the desktop picture, and ‹ › don't change slides).

Drawing, the toolbar, F9 and recording with OBS need none of these. Holding Control to draw needs none either
(Contrast Ink only reads whether Control is down, not what you type). macOS's firewall, if switched on, may ask
whether Contrast Ink may accept incoming connections: allow it for the tablet link.

## Draw

| How | What it does |
|---|---|
| **F9** or the **✏ button** | Drawing on / off. On a laptop keyboard F9 may need **fn**, unless "Use F1, F2, etc. keys as standard function keys" is on (System Settings → Keyboard). |
| **Hold Control** | Draw while Control is held; let go and clicks go to PowerPoint again (⚙ Settings to switch off) |
| **Esc** | Stop drawing |
| **Right-click** | Undo the last mark (while drawing) |
| **Pen tablet** (Wacom, XP-Pen, Huion...) | Its pen draws with pressure; turned over, its eraser end removes marks |

While drawing (switched on with F9 or ✏), the drawing layer has the keyboard, so the letter keys below choose tools.
Slide keys (→, ←, Space, Page Down, a presenter clicker) are passed on to PowerPoint, so the slide still turns
(this needs the Accessibility permission; without it, press F9 first). Drawing with Control held leaves the
keyboard with PowerPoint.

## Keys While Drawing

| Key | Tool |
|---|---|
| P | Pen |
| H | Highlighter |
| A | Arrow: drag from the tail to the tip |
| O | Circle a finding; hold Shift for a perfect circle |
| E | Eraser: touch a mark to remove it |
| L | Laser pointer: a red dot follows the pointer; dragging draws a glowing line that fades in a second |
| 1 2 3 4 5 6 | Red, yellow, green, cyan, white, black |
| [ and ] | Thinner / thicker |
| F | Fading ink on/off: marks disappear after 3 seconds (hold Shift while drawing to keep one) |
| C | Clear all marks |
| ⌘Z or Z | Undo (also brings back a Clear) |

The 🖥 button moves the drawing layer to your other screen (a projector). Plugged in or out mid-lecture, the layer
follows by itself. The opacity slider sets how solid new pen, arrow and circle marks are.

## Record From the Toolbar

Contrast Ink starts and stops OBS for you; OBS still does the recording, with your OBS settings.

**Once, in OBS (28 or newer):** **Tools → WebSocket Server Settings**, tick **Enable WebSocket Server**, **OK**.
Contrast Ink reads the port and password from OBS's own settings, so there's nothing to type.

| Button | What it does |
|---|---|
| ⏺ | Start recording (grey until OBS is open and connected; press it to connect) |
| ⏹ | Stop recording |
| ⏸ / ▶ | Pause / resume |

While recording, the toolbar shows the time, and a message under the buttons if OBS stops by itself, OBS closes,
less than 2 GB is left on the recording disk, or the OBS scene has no screen capture (then your marks wouldn't be
in the video). Click a message to dismiss it.

### OBS settings on the Mac

- Use **macOS Screen Capture** (the whole display), not a window capture of PowerPoint, or your drawings won't be
  recorded. OBS needs its own Screen Recording permission for that.
- **The toolbar may show in the recording.** Contrast Ink asks macOS to leave its toolbar out of screen captures,
  but on recent macOS versions OBS's capture (ScreenCaptureKit) ignores that request. Make the toolbar small (‹)
  and leave it in a corner, or crop that corner in OBS. The tablet's picture always leaves it out.
- Turn off **Show Cursor** in the capture's settings if you don't want the pointer in the video.

## A Tablet as a Pad (Android or iPad)

The Mac is the PC for the tablet, exactly as Windows is: the tablet shows a live picture of the Mac's screen, and
what you draw on it is drawn on the Mac, so OBS records it.

1. On the Mac: **⚙ → Let a Tablet Draw Here**. It shows a 6-digit **code** (new each time Contrast Ink starts), a
   **PC check** (always the same for this Mac) and the Mac's address. macOS asks for Screen Recording (and on
   macOS 15, Local Network): allow both, then quit and reopen Contrast Ink once.
2. On the tablet (same Wi-Fi): Contrast Ink → **Use as a pad for a PC** → pick the Mac → type the code.
3. The first time, the tablet shows a PC check: tap **It matches** only if it is the same as on the Mac.
4. Draw. The tablet's toolbar has the tools, colours, widths, undo, clear, the laser, and ‹ › to change slides
   (the first ‹ or › asks for Accessibility on the Mac: it sends → and ← to the app in front).

**By USB cable**, used by itself when plugged in (no code needed):
- **iPad** in pad mode: just plug it in. The Mac itself opens the connection to the iPad through Apple's own USB
  service, which only reaches devices on the cable, so nothing more is asked.
- **Android**: switch on USB debugging (Developer options) and install Google's platform-tools on the Mac
  (`brew install android-platform-tools`, or Android Studio). Contrast Ink finds `adb` on the PATH, in
  `~/Library/Android/sdk/platform-tools` or in `/opt/homebrew/bin`, and runs `adb reverse tcp:47830 tcp:47830`.
  The tablet then reaches the Mac at 127.0.0.1:47830, a port on the Mac that any program running on this Mac
  could also reach, so the cable alone doesn't prove who is connecting. Contrast Ink therefore opens that port only
  while `adb` has set up a tablet, and the first time a tablet connects there after Contrast Ink starts, the
  toolbar asks **"An Android tablet on the USB cable wants to draw: Allow / Deny"**. Choose **Allow** only if you
  have just plugged in your tablet (it waits up to 30 seconds). Later connections in the same run are let in by
  themselves.

Everything between the tablet and the Mac is encrypted, and the code never crosses the network. Wrong codes are
limited (five in a row lock pairing for 30 s; twenty make a new code), and a few strangers on the Wi-Fi can't keep
your tablet out (at most four waiting at once, two from any one address; the cable has its own places). The Mac's
own key (behind the PC check) is kept in `~/Library/Application Support/Contrast Ink/pad-key`, readable only by
you. Earlier versions kept it in the login Keychain; it is moved to that file by itself. If the file is there but
can't be read, the toolbar says so and the tablet link stays off (rather than making a new key, which would make
your tablets warn that this is "not the PC you paired with"). With patient images on screen, a private network or
the Mac's own hotspot is safer still. The link itself is described in [docs/pad-protocol.md](../docs/pad-protocol.md).

## Limits (Compared With Windows)

- **Slides:** no per-slide marks and no chapters yet (Windows reads PowerPoint's slide show; the Mac doesn't yet).
  Marks stay until you clear them.
- No undo button beside the last mark (undo with Z, ⌘Z, right-click, ↶ or the tablet).
- A pen tablet beside the keyboard always works like the mouse (macOS does this itself); there is no "Pen Tablet
  Beside the Keyboard" setting.
- The toolbar can show in OBS recordings (above).
- While drawing with F9, the keyboard belongs to the drawing layer, so typing goes nowhere until you press F9 or Esc.

## If Something Goes Wrong

- Nothing happens on F9: another app may own F9 (the toolbar then says so); use ✏ or hold Control.
- The tablet sees only the desktop picture: Screen Recording isn't allowed yet (⚙ shows it). Allow it, then quit
  and reopen Contrast Ink. Just after an update, remove Contrast Ink from the list and add it again (above).
- The tablet doesn't find the Mac: type the address shown in ⚙ into the tablet instead (some networks hide names),
  and check macOS 15's Local Network permission and the firewall.

Errors are written to `~/Library/Logs/Contrast Ink.log`. Send that file along with what you were doing.
Settings are kept in the app's preferences (`defaults delete com.contrast.ink.mac` starts fresh).

## For Developers

- `mac/PCCore`: the Mac's rules with no AppKit (the tablet link's server and handshake, the marks and undo, keys,
  OBS, USB helpers), built on `ios/Core`. `swift test --package-path mac/PCCore`: the pure rules run anywhere; on a
  Mac the handshake is checked against the spec's test vectors and the real server is paired with on loopback ports.
- `mac/App`: the AppKit app. `brew install xcodegen && cd mac && xcodegen`, then open `ContrastInk.xcodeproj`.
- `ContrastInk.app/Contents/MacOS/ContrastInk --smoke-test` starts the app, checks it came up (drawing layer,
  toolbar, a tablet stroke drawn and seen, undo), prints `SMOKE OK` and quits. GitHub's Macs can't give Screen
  Recording permission, so pictures of the screen aren't taken there.
- Every push that touches `mac/` or `ios/Core` builds the app on GitHub (`.github/workflows/mac.yml`); on `main`
  it replaces the **Mac (latest)** release.
