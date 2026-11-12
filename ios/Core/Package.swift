// swift-tools-version:5.9
// The rules of Contrast Ink for iPad and iPhone (shapes, fading, chapters, undo, keys), with no Apple-only code,
// so they are tested on any machine: `swift test` in this folder.
import PackageDescription

let package = Package(
    name: "ContrastInkCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "ContrastInkCore", targets: ["ContrastInkCore"])],
    targets: [
        .target(name: "ContrastInkCore"),
        .testTarget(name: "ContrastInkCoreTests", dependencies: ["ContrastInkCore"]),
    ]
)
