# Contrast Ink for Android

Draw on your screen while you lecture, over any app: PowerPoint, a PDF, a DICOM viewer, the browser. Record the
screen with your voice. Works like the Windows app: a floating toolbar and a drawing layer on top of everything.

For personal use: it isn't on the Play Store.

## Install

1. On your phone or tablet, open **Releases → android-latest** on this repository's GitHub page and download
   **ContrastInk.apk** (sign in to GitHub first: the repository is private).
2. Open the downloaded file. Android asks to allow installing apps from your browser (or Files): allow it, then
   **Install**. If a new version says "App not installed", uninstall the old Contrast Ink first (see Signing below).
3. Open **Contrast Ink** and press **Allow drawing over other apps** (switch it on for Contrast Ink), then
   **Allow the microphone**. Press **Start Contrast Ink**.

## Draw

| On the toolbar | What it does |
|---|---|
| **✎ Off / On** | Drawing on or off. Off, every tap goes to the app below |
| ✎ ▬ ↗ ◯ ⌫ | Pen, highlighter, arrow, circle, eraser (touch a mark to remove it). Picking one switches drawing on |
| Colour dots | Red, yellow, green, cyan, white, black (bright ones for dark MR/CT images, black for white slides) |
| • • • | Thin, medium, thick |
| ⏱ | Fading ink: marks disappear after 3 seconds |
| ↶ | Undo (Clear can be undone too) |
| 🗑 | Clear all marks |
| ‹ | Make the toolbar small (it keeps ✎, ↶ and the recording buttons) |
| ✕ | Quit (or **Quit** in the notification) |

Drag the toolbar by the blue Contrast mark.

**Stylus** (Samsung S Pen and others): the side button held as the pen touches undoes; the eraser end, on
styluses that have one, erases. Under **Settings** on the Contrast Ink screen you can make only the stylus draw:
a finger touching the drawing layer then switches drawing off, so your next tap reaches the app.
**Drawing pads** (Wacom One, XP-Pen, Huion... on USB or Bluetooth, where Android supports them) work like a stylus:
the pen draws while drawing is on and taps through to the app below while it's off; its button undoes.

A stylus hovering over the toolbar (S Pen) shows button names like "Pen"; switch **Show button names** off there
to stop it.

While drawing is off, marks look slightly lighter: Android lets taps through a layer from another app only when
it is at most 80% opaque.

## Record

Press **⏺**, then answer Android's "start recording?" question.

**Recording without the toolbar (Android 14 and later):** when Android asks, choose **A single app**, then pick
your slides app (PowerPoint, the PDF viewer...). The video has that app and your marks (pen, shapes, laser), with
your voice, and **no toolbar**. The toolbar says "Recording one app" once it has started. Keep the slides app in
front while recording: if you switch to another app, the video doesn't show it.

- **Entire screen** works too, but then the toolbar is in the video (the toolbar says so): make it small with ‹ and
  drag it to a corner.
- **Android 8 to 13** can only record the entire screen: **the toolbar is in the video** (Android can't leave one
  window out of it). Make it small with ‹ and drag it to a corner.
- With **A single app**, the marks are placed assuming the app fills the screen (how slides are shown). In split
  screen, marks line up for the top or left app only.
- **⏸ / ▶** pauses and resumes; **⏹** stops.
- Videos go to **Movies/Contrast Ink** (Gallery, Files). A long lecture takes a little while to save: the toolbar
  says when it's there. Quitting while recording (✕, or Quit on the notification) stops and saves it first.
  On Android 8–9 allow storage on the setup screen (the microphone button asks for both), or videos stay in the
  app's own folder, which is deleted with the app.
- Hold the phone or tablet the way you'll present **before** pressing ⏺: the video keeps that shape, and turning the
  screen mid-recording shows the new view smaller, with black bars.

## Pad mode: draw on a PC from the tablet

On the setup screen, **Use as a pad for a PC**. The PC runs Contrast Ink (⚙ Settings → Let a Tablet Draw Here) and
shows a 6-digit code; both must be on the same Wi-Fi. Pick the PC from the list (or type the address it shows under
the code, like `192.168.1.20`), type the code, **Connect**. The tablet shows the PC's screen; what you draw on it, the
PC draws on its own drawing layer (so OBS records it). The toolbar picks the PC's tool and colour, undoes, clears and
turns slides. A second finger cancels a line; a stylus hovering shows the laser's dot. Back asks before
disconnecting. If the Wi-Fi drops, the pad tries again by itself twice, then says **Lost the PC** with **Reconnect**.

The link is encrypted (version 2 of `docs/pad-protocol.md`): the code never crosses the Wi-Fi, and the tablet
remembers each PC's key by its name. The first time, it shows the PC's **PC check** (like `6FC6-6A90`): compare it
with the one next to the code on the PC. If a PC by that name later shows another key, the tablet stops and warns
(after reinstalling Contrast Ink on the PC, **Connect anyway**). The code is never saved; the pad screen is kept out of
screenshots and the recent-apps view. For patient images a private network or the PC's own hotspot is still best.

**By USB cable** (steadier than Wi-Fi, and nothing goes over the air): once, turn on **Developer options** on the
tablet (Settings → About tablet → tap **Build number** seven times) and switch on **USB debugging** in them; the PC
needs Google's **platform-tools** (`adb`: on the PATH, in `%LOCALAPPDATA%\Android\Sdk\platform-tools`, or in
`C:\platform-tools`). Then plug the tablet into the PC (allow USB debugging for that PC when the tablet asks): in pad
mode the pad switches to the cable by itself within a few seconds, with no code to type, and the title says
**By the USB cable**. Unplug it and the pad goes back to Wi-Fi by itself if you connected over Wi-Fi earlier, or
shows the connect screen. The PC check isn't asked over the cable, but a PC with another key is still stopped.

## Not on Android (yet)

- Keyboard keys (Android doesn't let an app watch the keyboard while another app is in front).
- Marks kept per PowerPoint slide, and chapters (Android's PowerPoint doesn't say which slide is showing).

## For Developers

- `core`: the rules (shapes, eraser hit test, fading, undo, settings), plain Kotlin: `./gradlew :core:test`.
- `app`: the Android app (service with overlay windows, drawing view, toolbar, screen recording, pad mode).
- Clean recording (Android 14+): `ScreenRecorder` sends what Android records through `VideoCompositor` (OpenGL ES 2:
  VirtualDisplay → SurfaceTexture → the encoder's surface). When the presenter chose one app, the drawing layer is
  copied into a bitmap (at most ~30 times a second, whenever it redraws) and blended over each frame. Android doesn't
  say which choice was made: if the recorded content isn't the screen's size it is one app; otherwise the first
  frames are looked at where the toolbar is (the entire screen has it there, one app never does). These rules and
  where the marks go in the frame are in `core/.../CleanRecording.kt`, with tests.
- `core/.../PadProtocol.kt`, `PadCrypto.kt`, `PadClient.kt`: the pad link's messages, its encryption (the platform's
  own P-256, HKDF and AES-GCM) and the tablet's handshake, checked byte for byte against the spec's test vectors.
- `app/src/androidTest`: runs the app on an emulator over a stand-in app (Android's Settings hides other apps' overlays): a tap goes through with drawing
  off, every tool draws, undo / clear / eraser, with a screenshot of every step. Two recording tests: the entire
  screen (the red line and the toolbar are both in the saved video's last frame) and, on Android 14+, "A single app"
  with the stand-in picked in Android's app picker (the red line is in the frame, the toolbar's rectangle has none of
  the toolbar's colour). The frames are saved next to the screenshots. `PadTest` runs pad mode against a
  stand-in PC inside the test that speaks version 2 (picture, strokes, commands, a reconnect, a lost connection, a
  wrong code, a PC whose key changed).
- Every push that changes `android/` runs all of this on GitHub (`.github/workflows/android.yml`); on main the APK
  goes to the **android-latest** release.
- Signing: Android installs an update over the old app only when both carry the same key. Builds are signed with
  the key in the repository secrets `ANDROID_KEYSTORE_B64` (the keystore file, base64) and
  `ANDROID_KEYSTORE_PASSWORD`. The key is never kept in the repository. Without those secrets the APK gets a
  throwaway key: it works, but uninstall the old Contrast Ink before installing a new one.
