// swift-tools-version:5.9
// The PC's side of Contrast Ink on the Mac, with no AppKit in it: the tablet link's server (its rules, its handshake,
// and the server itself on Network.framework), the marks and their undo, the laser, keys, OBS's password answer and
// settings, the USB helpers. `swift test` in this folder; the parts that need Apple's CryptoKit or Network.framework
// are left out on Linux and run on the Mac (GitHub's macOS run).
import PackageDescription

let package = Package(
    name: "ContrastInkPC",
    platforms: [.macOS(.v13)],
    products: [.library(name: "ContrastInkPC", targets: ["ContrastInkPC"])],
    dependencies: [.package(path: "../../ios/Core")],
    targets: [
        .target(name: "ContrastInkPC", dependencies: [.product(name: "ContrastInkCore", package: "Core")]),
        .testTarget(name: "ContrastInkPCTests", dependencies: ["ContrastInkPC"]),
    ]
)
