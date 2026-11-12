import AppKit

// Contrast Ink for the Mac: an app with no Dock icon and no menu bar of its own (LSUIElement), so PowerPoint or the
// DICOM viewer in front keeps the menu bar and the keyboard. Quit it with ✕ on its toolbar.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
