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

While drawing is off, marks look slightly lighter: Android lets taps through a layer from another app only when
it is at most 80% opaque.

## Record

Press **⏺**. When Android asks, choose **Entire screen** (recording a single app would leave out your marks).

- The video has the whole screen with your voice. **The toolbar is in it** (Android can't hide it the way
  Windows does): make it small with ‹ and drag it to a corner.
- **⏸ / ▶** pauses and resumes; **⏹** stops.
- Videos go to **Movies/Contrast Ink** (Gallery, Files).

## Not on Android (yet)

- Keyboard keys (Android doesn't let an app watch the keyboard while another app is in front).
- Marks kept per PowerPoint slide, and chapters (Android's PowerPoint doesn't say which slide is showing).

## For Developers

- `core`: the rules (shapes, eraser hit test, fading, undo, settings), plain Kotlin: `./gradlew :core:test`.
- `app`: the Android app (service with overlay windows, drawing view, toolbar, screen recording).
- `app/src/androidTest`: runs the app on an emulator over Android's Settings: a tap goes through with drawing
  off, every tool draws, undo / clear / eraser, with a screenshot of every step.
- Every push that changes `android/` runs all of this on GitHub (`.github/workflows/android.yml`); on main the APK
  goes to the **android-latest** release.
- Signing: Android installs an update over the old app only when both carry the same key. Builds are signed with
  the key in the repository secrets `ANDROID_KEYSTORE_B64` (the keystore file, base64) and
  `ANDROID_KEYSTORE_PASSWORD`. The key is never kept in the repository. Without those secrets the APK gets a
  throwaway key: it works, but uninstall the old Contrast Ink before installing a new one.
