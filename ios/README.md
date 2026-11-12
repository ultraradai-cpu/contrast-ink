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

## Install

It isn't on the App Store yet. To put it on an iPad you need a Mac with Xcode:

1. `brew install xcodegen`, then in this `ios` folder: `xcodegen`
2. Open `ContrastInk.xcodeproj`, choose your team under Signing & Capabilities, plug in the iPad, and press Run.

With a free Apple ID the app works for 7 days before it must be installed again; with an Apple Developer account
($99 a year) it can go to TestFlight and the App Store.

## For Developers

- `Core`: the rules (shapes, fading, chapters, each slide's marks and undo, keys, video crop), plain Swift with no
  Apple-only code: `swift test --package-path Core` on any Mac or Linux machine.
- `App`: the iOS app (SwiftUI, PencilKit, PDFKit, ReplayKit).
- `UITests`: runs the app on a simulated iPad with a sample deck, draws, changes slides, undoes, draws shapes, and
  keeps a screenshot of every step.
- Every push that changes `ios/` runs all of this on GitHub (`.github/workflows/ios.yml`); the screenshots are
  the run's **ios-screenshots** download.
