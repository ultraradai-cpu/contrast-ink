# Contrast Ink for iPad and iPhone

Present your slides on an iPad and draw on them with Apple Pencil. Record the lecture with your voice, and show a
clean picture on a projector or TV.

Apple doesn't let any app draw on top of other apps (PowerPoint, Keynote, a DICOM viewer), so on iPad the slides
open inside Contrast Ink: **in PowerPoint, File → Export → PDF**, then open the PDF here.

## Open

| Button | What it opens |
|---|---|
| **Open slides (PDF)** | A PDF from Files, iCloud Drive, OneDrive, AirDrop... It's kept under **Recent slides** for next time (a second PDF of the same name gets its own name, "Lecture (2)"). A PDF with a password asks for it. |
| **Open images** | One or more pictures (CT/MR screenshots), one per page. They are copied into a folder under **Recent slides**; any that can't be read are left out, and it says how many. |
| **Whiteboard** | Clean white pages: going past the last one adds a new page |

## Draw

- **Apple Pencil draws.** A finger swipes left or right to change slides (switch on **⚙ → Finger draws too** to draw with a finger). On an iPhone (no Pencil) a finger draws from the start.
- Tools on the toolbar: pen, highlighter, arrow, circle (hold Shift on a keyboard for a perfect circle), eraser (touch a mark to remove it).
- Six colours (bright ones for dark MR/CT images, black for white slides, red for both) and three widths.
- **Fading ink** (⏱): marks disappear after 3 seconds. Hold Shift on a keyboard while drawing to keep one.
- Each slide keeps its own marks. The next slide starts clean, and going back shows its marks again.
- **Marks are kept**: on every slide change and whenever Contrast Ink leaves the screen they are saved with the deck,
  and they come back the next time it is opened (a crash or a flat battery doesn't lose them). To start clean:
  **Clear saved marks** on the note that says they are back, or touch and hold the deck under **Recent slides**.
- A stroke belongs to the slide it was begun on, even if the slide changes (a clicker) before the Pencil lifts.
- **✕** closes the slides; with marks or a recording it asks first (a recording is stopped and saved).

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
| L | Laser pointer |
| 1 2 3 4 5 6 | Red, yellow, green, cyan, white, black |
| [ and ] | Thinner / thicker |
| F | Fading ink on/off |
| C | Clear all marks |
| Z or ⌘Z | Undo |

## Record

Press **⏺** on the toolbar. The first time, iPad asks to allow screen recording and the microphone.

- The video has **only the slide and your marks**, with your voice. The toolbar is never in it.
- **⏸ / ▶** pauses and resumes; **⏹** stops.
- The video (`.mov`) is saved to **Files → On My iPad → Contrast Ink → Recordings**. To also put it in **Photos**,
  switch on **⚙ → Also save recordings to Photos** (off at first: with iCloud Photos on, a copy in Photos is uploaded
  to iCloud, patient images included).
- The video is written so that what was recorded is complete on disk every 10 seconds: if the iPad crashes, the
  battery dies or iOS closes Contrast Ink late in a lecture, the video plays up to the last few seconds. A recording
  that couldn't be finished is kept, and it says it may be incomplete.
- It needs room: under 1 GB free it doesn't start (it says what to delete); while recording it checks every minute,
  warns under 1 GB, and under 300 MB stops by itself and keeps the video. A lecture is about 3 GB an hour, and the
  copy to Photos needs as much again.
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
   `192.168.1.20:47820`, if it isn't listed). If the list says to allow Local Network: **Settings → Privacy &
   Security → Local Network → Contrast Ink**, on.
2. Type the 6-digit code the PC shows and press **Connect**. The code itself never crosses the network, and the
   PC's pictures come encrypted.
3. **The first time** with a PC, the iPad shows its **PC check** (16 digits, like `6FC6-6A90-4861-71CA`) and waits: compare it with the
   one the PC shows (⚙ Settings, beside the code) and press **It matches** (within about 25 seconds), or **It
   doesn't** to stop without sending anything. The iPad remembers that PC; if a machine later answers under its name
   with another check, the iPad stops and warns (**Connect anyway** only if you reinstalled Contrast Ink on that PC;
   it shows the new check to compare too).
4. Draw with Apple Pencil or a finger. Once the Pencil has touched the glass, only the Pencil draws (a resting palm
   doesn't). A second finger cancels the stroke. Pencil hover (M2 iPads and later) moves the laser's dot. The
   toolbar's tools, colours, widths, fading ink, undo, clear and slide buttons work the PC's Contrast Ink.

For patient images, a private network or the PC's own hotspot is still the safest choice.

**Can't find the PC?** Hospital Wi-Fi often blocks devices from seeing each other. When no PC shows up for about 8
seconds, or a typed address can't be reached, the connect screen says so: join the PC's hotspot (Windows: **Settings →
Network → Mobile hotspot**; the PC is then usually `192.168.137.1`) or your phone's hotspot on both, or use the USB
cable.

**By the USB cable**: plug the iPad into the PC with its cable (the PC needs **iTunes** or **Apple Devices**
installed, and the iPad must have tapped **Trust** for it). In pad mode the iPad switches to the cable by itself, even
from the connect screen with nothing typed: no code is needed over the cable, and the pad says **By the USB cable**.
The first time with a PC on the cable it shows the PC check too, as on Wi-Fi (any app on the iPad could reach the
cable's door, so the cable alone doesn't prove it's your PC); after that it goes on at once.
Unplug it and the iPad goes back to the Wi-Fi PC by itself if you typed its code earlier, otherwise to the connect
screen.

If the Wi-Fi drops or the PC stops answering for 6 seconds, the iPad keeps the last picture and reconnects by
itself; after two tries it says **Lost the PC**, with **Reconnect**. The address and the PC are remembered for next
time, the code isn't (the PC makes a new one each time it starts). The link is written down in `docs/pad-protocol.md`.

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
recordings stay). Contrast Ink's home screen warns 48 hours before the 7 days run out. A free Apple ID can have 3 such apps at a time. AltStore (altstore.io) works too, and can renew
the 7 days over Wi-Fi by itself while the PC is on.

With a Mac instead: `brew install xcodegen`, `xcodegen` in this folder, open `ContrastInk.xcodeproj`, choose your
team under Signing & Capabilities, plug in the iPad, press Run. An Apple Developer account ($99 a year) removes the
7 days and allows TestFlight.

## For Developers

- `Core`: the rules (shapes, fading, chapters, each slide's marks and undo, keys, video crop), plain Swift with no
  Apple-only code: `swift test --package-path Core` on any Mac or Linux machine (the pad link's encryption uses
  CryptoKit, so its tests run only on a Mac).
- `App`: the iOS app (SwiftUI, PencilKit, PDFKit, ReplayKit).
- `UITests`: runs the app on a simulated iPad with a sample deck, draws, changes slides, undoes, draws shapes, the
  keyboard keys, saved marks, closing, the video writer (and a real recording where the simulator allows it),
  importing PDFs and pictures, pad mode against a pretend PC (Wi-Fi and cable), and keeps a screenshot of every step.
- Every push that changes `ios/` runs all of this on GitHub (`.github/workflows/ios.yml`); the screenshots are
  the run's **ios-screenshots** download.
