import AppKit
import ContrastInkCore
import ContrastInkPC
import CryptoKit
import ImageIO
import ScreenCaptureKit
import Security
import UniformTypeIdentifiers

/// This Mac's own key for the tablet link, kept between runs in the login Keychain, so a tablet recognises this Mac
/// next time (and notices a machine pretending to be it). If the Keychain can't be used: a key for this run only
/// (tablets then see a new PC and show its check again).
enum PadIdentity {
    private static let service = "Contrast Ink tablet link"
    private static let account = "P-256 key"

    static func load() -> P256.KeyAgreement.PrivateKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
           let k = try? P256.KeyAgreement.PrivateKey(rawRepresentation: d) {
            return k
        }
        let k = P256.KeyAgreement.PrivateKey()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: account, kSecValueData as String: k.rawRepresentation,
                                  kSecAttrLabel as String: "Contrast Ink tablet link (this Mac's key)"]
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { Log.write("tablet link: the Keychain kept no key (\(status)): tablets will see a new PC next time") }
        return k
    }
}

/// Pictures of the screen for the tablet, at most 1600 px wide, as JPEG: ScreenCaptureKit on macOS 14 and later
/// (leaving out the toolbar), CGDisplayCreateImage on macOS 13. Needs the Screen Recording permission: without it
/// macOS gives only the desktop picture.
final class ScreenGrabber {
    private let queue = DispatchQueue(label: "screen grabber")
    private var content: AnyObject?   // SCShareableContent, refreshed every few seconds
    private var contentAt = Date.distantPast

    struct Target { var display: CGDirectDisplayID; var pixelWidth: Int; var pixelHeight: Int; var exclude: [Int] }

    func jpeg(_ target: Target, _ done: @escaping (Data?) -> Void) {
        if #available(macOS 14.0, *) {
            withContent { content in
                guard let content = content as? SCShareableContent,
                      let display = content.displays.first(where: { $0.displayID == target.display }) else { done(nil); return }
                let leaveOut = content.windows.filter { target.exclude.contains(Int($0.windowID)) }
                let filter = SCContentFilter(display: display, excludingWindows: leaveOut)
                let config = SCStreamConfiguration()
                let size = Self.scaled(target.pixelWidth, target.pixelHeight)
                config.width = size.0
                config.height = size.1
                config.showsCursor = false
                config.scalesToFit = true
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                    if let error { self.queue.async { self.content = nil }; Log.write("tablet picture: \(error.localizedDescription)") }
                    done(image.flatMap { Self.encode($0) })
                }
            }
        } else {
            queue.async {
                guard let image = Self.legacyImage(target.display) else { done(nil); return }
                let size = Self.scaled(image.width, image.height)
                done(Self.encode(Self.resize(image, size.0, size.1) ?? image))
            }
        }
    }

    @available(macOS 14.0, *)
    private func withContent(_ use: @escaping (AnyObject?) -> Void) {
        queue.async {
            if let c = self.content, Date().timeIntervalSince(self.contentAt) < 3 { use(c); return }
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { c, error in
                self.queue.async {
                    if let c { self.content = c; self.contentAt = Date() }
                    else if let error { Log.write("tablet picture: \(error.localizedDescription)") }
                    use(c)
                }
            }
        }
    }

    /// At most 1600 px wide, the same shape.
    static func scaled(_ w: Int, _ h: Int) -> (Int, Int) {
        let s = min(1, Double(PadPC.frameMaxWidth) / Double(max(w, 1)))
        return (max(1, Int(Double(w) * s)), max(1, Int(Double(h) * s)))
    }

    static func encode(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: PadPC.jpegQuality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    static func resize(_ image: CGImage, _ w: Int, _ h: Int) -> CGImage? {
        if image.width == w && image.height == h { return image }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// macOS 13: CGDisplayCreateImage, looked up at run time (newer SDKs mark it unavailable, as ScreenCaptureKit replaces it).
    private static func legacyImage(_ display: CGDirectDisplayID) -> CGImage? {
        typealias Grab = @convention(c) (CGDirectDisplayID) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGDisplayCreateImage") else { return nil }   // RTLD_DEFAULT
        return unsafeBitCast(sym, to: Grab.self)(display)?.takeRetainedValue()
    }
}

/// The tablet link on the Mac: the server (ContrastInkPC's PadServer), pictures of the drawing layer's screen, and the
/// USB cable (iPads through usbmuxd, Android tablets through `adb reverse`), watched every few seconds.
final class PadHost {
    let server: PadServer
    private let grabber = ScreenGrabber()
    private let lock = NSLock()
    private var target = ScreenGrabber.Target(display: CGMainDisplayID(), pixelWidth: 1920, pixelHeight: 1080, exclude: [])
    private var running = true
    private var usbBusy = Set<Int>()
    private var adbDone = Set<String>()
    private(set) var adbFound = false

    static var macName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }

    init(code: String? = nil) {
        server = PadServer(key: PadIdentity.load(), config: PadServer.Config(name: Self.macName), code: code)
        server.screenSize = { [weak self] in
            guard let self else { return (1920, 1080) }
            self.lock.lock(); defer { self.lock.unlock() }
            return (self.target.pixelWidth, self.target.pixelHeight)
        }
        server.frameSource = { [weak self] done in
            guard let self else { done(nil); return }
            self.lock.lock(); let t = self.target; self.lock.unlock()
            self.grabber.jpeg(t, done)
        }
    }

    /// The screen the drawing layer covers (its display, its size in pixels) and the windows to leave out.
    func setTarget(_ t: ScreenGrabber.Target) { lock.lock(); target = t; lock.unlock() }

    func start() {
        server.start()
        let t = Thread { [weak self] in self?.watchUsb() }
        t.name = "pad usb watch"
        t.start()
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
        server.stop()
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// Every 3 seconds: an iPad in pad mode plugged in gets a connection through the cable; a new Android tablet
    /// with USB debugging gets `adb reverse`.
    private func watchUsb() {
        while isRunning {
            for id in UsbMuxClient.devices() {
                lock.lock(); let busy = usbBusy.contains(id); lock.unlock()
                if busy { continue }
                guard let fd = UsbMuxClient.connect(device: id, port: PadPC.usbPort) else { continue }   // not in pad mode yet
                lock.lock(); usbBusy.insert(id); lock.unlock()
                server.attachUsb(fd: fd) { [weak self] in
                    guard let self else { return }
                    self.lock.lock(); self.usbBusy.remove(id); self.lock.unlock()
                }
            }
            adb()
            for _ in 0..<6 where isRunning { Thread.sleep(forTimeInterval: 0.5) }
        }
    }

    private func adb() {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        guard let path = Adb.candidates(path: env["PATH"], home: fm.homeDirectoryForCurrentUser.path).first(where: { fm.isExecutableFile(atPath: $0) })
        else { adbFound = false; return }
        adbFound = true
        let now = Set(Adb.devices(run(path, ["devices"]) ?? ""))
        for serial in now.subtracting(adbDone) where run(path, Adb.reverseArguments(serial: serial)) != nil { adbDone.insert(serial) }
        adbDone.formIntersection(now)   // unplugged: set up again when it comes back
    }

    /// Runs adb (at most 5 s); its output, or nil when it failed.
    private func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    /// This Mac's IPv4 addresses on its networks, for typing into a tablet when the network hides names.
    static func addresses() -> [String] {
        var list: [(String, String)] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let a = p.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET),
                  p.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                list.append((String(cString: p.pointee.ifa_name), String(cString: host)))
            }
        }
        return PadPC.usableAddresses(list.map { (interface: $0.0, address: $0.1) })
    }
}
