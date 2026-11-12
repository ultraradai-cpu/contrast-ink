# Contrast Ink for iPad and iPhone

Present your slides on an iPad and draw on them with Apple Pencil. Record the lecture with your voice, and show a
clean picture on a projector or TV.

Apple doesn't let any app draw on top of other apps (PowerPoint, Keynote, a DICOM viewer), so on iPad the slides
open inside Contrast Ink: **in PowerPoint, File → Export → PDF**, then open the PDF here.

## Open

| Button | What it opens |
|---|---|
| **Open slides (PDF)** | A PDF from Files, iCloud Drive, OneDrive, AirDrop... It's kept under **Recent slides** for next time. |
| **Open images** | One or more pictures (CT/MR screenshots), one per page |
| **Whiteboard** | Clean white pages: going past the last one adds a new page |

## Draw

- **Apple Pencil draws.** A finger swipes left or right to change slides (switch on **⚙ → Finger draws too** to draw with a finger).
- Tools on the toolbar: pen, highlighter, arrow, circle (hold Shift on a keyboard for a perfect circle), eraser (touch a mark to remove it).
- Six colours (bright ones for dark MR/CT images, black for white slides, red for both) and three widths.
- **Fading ink** (⏱): marks disappear after 3 seconds. Hold Shift on a keyboard while drawing to keep one.
- Each slide keeps its own marks. The next slide starts clean, and going back shows its marks again. Closing the slides (✕) ends the lecture and its marks go with it.

## Undo

- The **↶** button. **Clear** (🗑) can be undone too.
- **Double-tap** on Apple Pencil (2nd generation, Pro).
- **Two-finger tap** on the slide.
- **Z** or **⌘Z** on a keyboard.

Each one can be switched off under ⚙.

Hovering Apple Pencil (or a mouse / trackpad) over a toolbar button shows its name, like "Pen (P)". To stop it:
**⚙ → Toolbar → Show button names**, off.

## Keyboard and presenter clicker

| Key | What it does |
|---|---|
| → ↓ Space Page Down Return | Next slide (a presenter clicker works) |
| ← ↑ Page Up | Previous slide |
| P H A O E | Pen, highlighter, arrow, circle, eraser |
| 1 2 3 4 5 6 | Red, yellow, green, cyan, white, black |
| [ and ] | Thinner / thicker |
| F | Fading ink on/off |
| C | Clear all marks |
| Z or ⌘Z | Undo |

## Record

Press **⏺** on the toolbar. The first time, iPad asks to allow screen recording and the microphone.

- The video has **only the slide and your marks**, with your voice. The toolbar is never in it.
- **⏸ / ▶** pauses and resumes; **⏹** stops.
- The video is saved to **Photos**, and to **Files → On My iPad → Contrast Ink → Recordings**.
- Every slide change becomes a chapter: `<video> chapters.txt` is saved beside the video, ready to paste into a
  YouTube description.
- If Contrast Ink leaves the screen (Home, another app) or the recording is interrupted (a call), it stops;
  what was recorded is saved.
- Slides of different shapes, turning the iPad, a toolbar on two rows: the video keeps its first shape and shows
  each slide whole, centred, with black bars where the shapes differ.

## Projector or TV

Connect a projector or TV with an HDMI adapter or AirPlay. It shows **the slide and your marks only**, filling the
screen, while the toolbar stays on your iPad. A mark appears on the projector when the Pencil lifts.

## Pad for a PC

**Use this iPad as a pad for a PC** (on the home screen) turns the iPad into a wireless drawing pad for Contrast Ink
on a Windows PC on the same Wi-Fi. The iPad shows the PC's screen; what you draw on the iPad is drawn by the PC, so
OBS on the PC records it.

1. Pick the PC under **PCs on this Wi-Fi** (or type the address the PC shows, like `192.168.1.20` or
   `192.168.1.20:47820`, if it isn't listed).
2. Type the 6-digit code the PC shows and press **Connect**. The first time, iPad asks to allow the local network.
3. Draw with Apple Pencil or a finger. A second finger cancels the stroke. Pencil hover (M2 iPads and later) moves
   the laser's dot. The toolbar's tools, colours, undo, clear and slide buttons work the PC's Contrast Ink.

If the Wi-Fi drops or the PC stops answering for 6 seconds, the iPad says **Lost the PC**, with **Reconnect**.
The link is written down in `docs/pad-protocol.md`.

## Install

It isn't on the App Store. Install it yourself (sideload) from a Windows PC, no Mac needed:

1. Download **ContrastInk.ipa** from **Releases → iPad (latest)**:
   https://github.com/ultraradai-cpu/contrast-ink/releases/download/ios-latest/ContrastInk.ipa
2. On the PC, install **iTunes** (from apple.com, not the Microsoft Store version) and
   **Sideloadly** (sideloadly.io).
3. Plug the iPad into the PC with a cable and tap **Trust** on the iPad.
4. Open Sideloadly, drag `ContrastInk.ipa` into it, type your Apple ID, press **Start**.
   (Use a spare Apple ID if you prefer: it only signs the app.)
5. On the iPad: **Settings → General → VPN & Device Management**, tap your Apple ID, **Trust**.
6. iPadOS 16 and later: **Settings → Privacy & Security → Developer Mode → On**, and restart when asked.

With a free Apple ID the app opens for **7 days**; then plug in and press Start in Sideloadly again (your decks and
recordings stay). A free Apple ID can have 3 such apps at a time. AltStore (altstore.io) works too, and can renew
the 7 days over Wi-Fi by itself while the PC is on.

With a Mac instead: `brew install xcodegen`, `xcodegen` in this folder, open `ContrastInk.xcodeproj`, choose your
team under Signing & Capabilities, plug in the iPad, press Run. An Apple Developer account ($99 a year) removes the
7 days and allows TestFlight.

## For Developers

- `Core`: the rules (shapes, fading, chapters, each slide's marks and undo, keys, video crop), plain Swift with no
  Apple-only code: `swift test --package-path Core` on any Mac or Linux machine.
- `App`: the iOS app (SwiftUI, PencilKit, PDFKit, ReplayKit).
- `UITests`: runs the app on a simulated iPad with a sample deck, draws, changes slides, undoes, draws shapes, and
  keeps a screenshot of every step.
- Every push that changes `ios/` runs all of this on GitHub (`.github/workflows/ios.yml`); the screenshots are
  the run's **ios-screenshots** download.
