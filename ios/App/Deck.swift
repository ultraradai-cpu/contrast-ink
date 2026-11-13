import ContrastInkCore
import CryptoKit
import PDFKit
import PencilKit
import ImageIO
import UIKit

/// What is being presented: PDF slides (PowerPoint → Export → PDF), pictures (CT/MR screenshots), or a whiteboard.
/// Every page is laid out 1024 points wide; marks are kept in those points, so they stay in place on any screen.
///
/// Pictures are kept as files (copied into the deck's folder) and decoded when shown, at the size shown, away from
/// the main thread; decoded slides are kept in a cache with a memory limit, emptied when iOS runs short of memory.
final class Deck: @unchecked Sendable {
    enum Source {
        case pdf(PDFDocument)
        /// The pictures' files, and each one's size the way it is seen (read from its header, not decoded).
        case images([URL], sizes: [CGSize])
        case whiteboard
    }

    static let pageWidth: CGFloat = 1024

    let title: String
    let source: Source
    /// What its marks are saved under (its file or folder name), nil when they aren't kept.
    let key: String?
    private(set) var pageCount: Int
    private let cache = NSCache<NSString, UIImage>()
    private let rendering = NSLock()                       // one PDF page drawn at a time (PDFKit isn't for two threads)
    /// Which slide the slides ahead are for: a decode queued for a slide left behind is skipped.
    private let aheadLock = NSLock()
    private var aheadFor = -1
    private static let ahead = DispatchQueue(label: "Contrast Ink slides ahead", qos: .utility)
    private static let now = DispatchQueue(label: "Contrast Ink slide", qos: .userInitiated)
    private var memoryWarning: NSObjectProtocol?

    init(title: String, source: Source, key: String? = nil) {
        self.title = title
        self.source = source
        self.key = key
        switch source {
        case .pdf(let d): pageCount = max(d.pageCount, 1)
        case .images(let i, _): pageCount = max(i.count, 1)
        case .whiteboard: pageCount = 1
        }
        cache.totalCostLimit = SlideImages.costLimit(memory: ProcessInfo.processInfo.physicalMemory)
        memoryWarning = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                               object: nil, queue: nil) { [weak self] _ in
            self?.cache.removeAllObjects()
        }
    }

    deinit { if let memoryWarning { NotificationCenter.default.removeObserver(memoryWarning) } }

    /// Opens a PDF. A locked one opens (nil `password` asks) only once unlocked.
    static func open(pdf url: URL) -> PDFDocument? {
        guard let doc = PDFDocument(url: url) else { return nil }
        guard doc.isLocked || doc.pageCount > 0 else { return nil }
        return doc
    }

    /// An image deck from its folder in the library: every picture in it, in name order (they are numbered).
    static func open(images folder: URL) -> Deck? {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var urls: [URL] = [], sizes: [CGSize] = []
        for f in files {
            guard let size = Library.pictureSize(f) else { continue }
            urls.append(f); sizes.append(size)
        }
        guard !urls.isEmpty else { return nil }
        return Deck(title: folder.lastPathComponent, source: .images(urls, sizes: sizes), key: folder.lastPathComponent)
    }

    var isWhiteboard: Bool { if case .whiteboard = source { return true } else { return false } }

    /// A whiteboard grows: going past its last page adds a clean one.
    func addWhiteboardPage() { if isWhiteboard { pageCount += 1 } }

    /// A whiteboard reopened with marks saved on later pages: it has those pages again.
    func growWhiteboard(to count: Int) { if isWhiteboard { pageCount = max(pageCount, count) } }

    /// The page's size in layout points (1024 wide).
    func pageSize(_ page: Int) -> CGSize {
        let natural: CGSize
        switch source {
        case .pdf(let d):
            guard let p = d.page(at: page) else { natural = CGSize(width: 4, height: 3); break }
            let box = p.bounds(for: .cropBox)
            // a page turned in the PDF (rotation 90/270) is shown the way it reads
            natural = p.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        case .images(_, let sizes):
            natural = sizes.indices.contains(page) ? sizes[page] : CGSize(width: 4, height: 3)
        case .whiteboard:
            natural = CGSize(width: 4, height: 3)
        }
        guard natural.width > 0, natural.height > 0 else { return CGSize(width: Deck.pageWidth, height: Deck.pageWidth * 3 / 4) }
        return CGSize(width: Deck.pageWidth, height: Deck.pageWidth * natural.height / natural.width)
    }

    private static func roundedWidth(_ pixelWidth: CGFloat) -> CGFloat { max(64, (pixelWidth / 64).rounded(.up) * 64) }
    private static func key(_ page: Int, _ w: CGFloat) -> NSString { "\(page)@\(Int(w))" as NSString }

    /// The page, if it was drawn at this size already.
    func cachedImage(_ page: Int, pixelWidth: CGFloat) -> UIImage? {
        cache.object(forKey: Deck.key(page, Deck.roundedWidth(pixelWidth)))
    }

    /// Draws the page away from the main thread; `done` gets it on the main thread.
    func loadImage(_ page: Int, pixelWidth: CGFloat, done: @escaping (UIImage) -> Void) {
        Deck.now.async { [weak self] in
            guard let self else { return }
            let img = self.image(page, pixelWidth: pixelWidth)
            DispatchQueue.main.async { done(img) }
        }
    }

    /// The page as a picture `pixelWidth` pixels wide (drawn once per size, then kept while memory allows).
    /// Decodes or renders when it isn't cached: call it away from the main thread (loadImage).
    func image(_ page: Int, pixelWidth: CGFloat) -> UIImage {
        let w = Deck.roundedWidth(pixelWidth)   // a few sizes only, so the cache is reused
        let key = Deck.key(page, w)
        if let hit = cache.object(forKey: key) { return hit }
        // PDFKit draws one page at a time; pictures decode side by side
        let isPDF: Bool = { if case .pdf = source { return true } else { return false } }()
        if isPDF { rendering.lock() }
        defer { if isPDF { rendering.unlock() } }
        if let hit = cache.object(forKey: key) { return hit }   // drawn ahead while this waited
        let size = pageSize(page), px = CGSize(width: w, height: (w * size.height / size.width).rounded())
        let img: UIImage
        switch source {
        case .pdf(let d):
            img = d.page(at: page)?.thumbnail(of: px, for: .cropBox) ?? Deck.blank(px)
        case .images(let urls, let sizes):
            if urls.indices.contains(page) {
                let n = sizes[page]
                let side = SlideImages.decodeSide(natural: Size(Double(n.width), Double(n.height)), pixelWidth: Double(w))
                img = Library.decode(urls[page], maxSide: side) ?? Deck.blank(px)
            } else { img = Deck.blank(px) }
        case .whiteboard:
            img = Deck.blank(px)
        }
        let pixels = img.cgImage.map { ($0.width, $0.height) } ?? (Int(px.width), Int(px.height))
        cache.setObject(img, forKey: key, cost: SlideImages.cost(width: pixels.0, height: pixels.1))
        return img
    }

    /// Draws the slides either side of `page` in the background, so turning to them doesn't hold up the Pencil.
    func drawAhead(around page: Int, pixelWidth: CGFloat) {
        aheadLock.lock(); aheadFor = page; aheadLock.unlock()
        for p in [page + 1, page - 1] where p >= 0 && p < pageCount {
            Deck.ahead.async { [weak self] in
                guard let self else { return }
                // the presenter has moved on (clicking through a big deck): this one isn't next to the slide any more
                self.aheadLock.lock(); let current = self.aheadFor; self.aheadLock.unlock()
                guard abs(current - p) <= 1 else { return }
                _ = self.image(p, pixelWidth: pixelWidth)
            }
        }
    }

    static func blank(_ size: CGSize) -> UIImage {
        let f = UIGraphicsImageRendererFormat.default(); f.scale = 1
        return UIGraphicsImageRenderer(size: size, format: f).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}

/// Decks kept in the app's Documents/Decks folder (visible in the Files app), newest first: PDFs, and folders of
/// pictures (an image deck).
enum Library {
    static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let f = docs.appendingPathComponent("Decks", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    static func isImageDeck(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

    static func decks() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "pdf" || isImageDeck($0) }.sorted {
            let a = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return a > b
        }
    }

    struct Problem: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    /// Copies a PDF picked in Files into the library, so it opens again next time. It is opened first: a file that
    /// isn't a PDF never gets in. The same PDF picked again (the same bytes) is the deck already there, with its
    /// marks; another one with the same name as a deck there gets its own name ("Lecture (2).pdf").
    static func add(_ picked: URL) throws -> URL {
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        guard Deck.open(pdf: picked) != nil else {
            throw Problem(text: "\(picked.lastPathComponent) couldn't be opened as a PDF (it may be damaged, or not a PDF). Nothing was added.")
        }
        if picked.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { return picked }
        if let same = sameContent(as: picked) { return same }
        let name = FileNames.unique(picked.lastPathComponent) { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        let dest = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: picked, to: dest)
        return dest
    }

    /// A PDF already in the library with exactly these bytes (sizes compared first, so few files are hashed).
    static func sameContent(as url: URL) -> URL? {
        let size = CaptureSink.size(of: url)
        guard size > 0, let hash = sha256(url) else { return nil }
        for d in decks() where d.pathExtension.lowercased() == "pdf" && CaptureSink.size(of: d) == size {
            if sha256(d) == hash { return d }
        }
        return nil
    }

    /// The SHA-256 of a file, read 1 MB at a time (a deck can be hundreds of MB), as hex. Away from the main thread.
    static func sha256(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The key a PDF's marks are kept under: its content (a revised PDF of the same name gets none of the old
    /// marks). Marks an earlier version kept under the file's name move to it once. Away from the main thread.
    static func marksKey(pdf url: URL) -> String? {
        guard let hash = sha256(url) else { return nil }
        let key = MarksPlan.key(sha256: hash)
        SavedMarks.migrate(from: url.lastPathComponent, to: key)
        SavedMarks.remember(key, for: url.lastPathComponent)
        return key
    }

    /// The marks key of a deck listed in the library, as far as known without reading it (nil: never opened).
    static func listedMarksKey(_ url: URL) -> String? {
        isImageDeck(url) ? url.lastPathComponent : SavedMarks.key(for: url.lastPathComponent)
    }

    /// Copies picked pictures into a new folder in the library (an image deck), in the order picked. Pictures that
    /// can't be read are left out and counted. Nil folder when none could be read. Run it away from the main thread.
    static func addImages(_ urls: [URL]) -> (folder: URL?, failed: Int) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"
        let name = FileNames.unique("Images \(f.string(from: Date()))") { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        let deck = folder.appendingPathComponent(name, isDirectory: true)
        do { try FileManager.default.createDirectory(at: deck, withIntermediateDirectories: true) } catch { return (nil, urls.count) }
        var failed = 0, kept = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard pictureSize(url) != nil else { failed += 1; continue }
            do {
                try FileManager.default.copyItem(at: url, to: deck.appendingPathComponent(FileNames.numbered(kept, url.lastPathComponent)))
                kept += 1
            } catch { failed += 1 }
        }
        if kept == 0 { try? FileManager.default.removeItem(at: deck); return (nil, failed) }
        return (deck, failed)
    }

    /// A picture's size the way it is seen (turned by its orientation), from its header: nothing is decoded.
    static func pictureSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0
        else { return nil }
        let o = p[kCGImagePropertyOrientation] as? Int ?? 1
        return o >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// A picture decoded at most `maxSide` pixels on its long side, the way it was taken.
    static func decode(_ url: URL, maxSide: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // the way the picture was taken
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return flattened(cg)
    }

    /// A picture on opaque white: a PNG with a see-through background (black lines on nothing) would otherwise show
    /// black on the black stage.
    static func flattened(_ cg: CGImage) -> UIImage {
        let size = CGSize(width: cg.width, height: cg.height)
        let f = UIGraphicsImageRendererFormat.default()
        f.scale = 1
        f.opaque = true
        return UIGraphicsImageRenderer(size: size, format: f).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Removes a deck and its saved marks.
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        SavedMarks.remove(key: SavedMarks.key(for: url.lastPathComponent))
        SavedMarks.remove(key: url.lastPathComponent)
    }

    /// Marks it as just used, so it is listed first.
    static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// A two-page deck for the app's own UI test (no Files picker in a test).
    static func sampleDeck() -> Deck {
        let size = CGSize(width: 1024, height: 768)
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { ctx in
            for (n, color) in [(1, UIColor(white: 0.12, alpha: 1)), (2, UIColor(white: 0.95, alpha: 1))] {
                ctx.beginPage()
                color.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
                let text = "Sample slide \(n)" as NSString
                text.draw(at: CGPoint(x: 80, y: 80), withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 56),
                    .foregroundColor: n == 1 ? UIColor.white : UIColor.black,
                ])
            }
        }
        return Deck(title: "Sample", source: .pdf(PDFDocument(data: data)!), key: "Sample (UI test)")
    }
}

/// Each deck's marks on disk: Application Support/Marks/<key>.marks (not in Files: they aren't documents). A PDF's
/// key is its content's SHA-256 (MarksPlan.key), an image deck's its folder's name.
///
/// Everything happens on one queue. It keeps what each deck's file holds, so a save encodes only the slides that
/// changed, and slides beyond the deck's pages (a deck that got shorter) are written back, never dropped.
enum SavedMarks {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let f = base.appendingPathComponent("Marks", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    static func url(key: String) -> URL { folder.appendingPathComponent(MarksFile.fileName(forDeck: key)) }

    private static let queue = DispatchQueue(label: "Contrast Ink saving marks", qos: .utility)
    /// What is on disk for each key (the queue only).
    private static var onDisk: [String: [Int: Data]] = [:]

    /// The saved marks of a deck (all its slides, those beyond its pages too).
    static func load(key: String) -> [Int: Data] {
        queue.sync {
            if let known = onDisk[key] { return known }
            let saved = MarksFile.decode(try? Data(contentsOf: url(key: key)))
            onDisk[key] = saved
            return saved
        }
    }

    static func exists(key: String) -> Bool { FileManager.default.fileExists(atPath: url(key: key).path) }

    /// The slides that changed (an empty drawing: none left), encoded and written in the background.
    static func save(_ changes: [Int: PKDrawing], key: String, pageCount: Int) {
        let u = url(key: key)
        queue.async {
            var now = onDisk[key] ?? MarksFile.decode(try? Data(contentsOf: u))
            let kept = now.filter { $0.key >= pageCount }
            for (p, d) in changes { now[p] = d.strokes.isEmpty ? nil : d.dataRepresentation() }
            now = MarksPlan.toSave(now.filter { $0.key < pageCount }, kept: kept, pageCount: pageCount)
            onDisk[key] = now
            if now.isEmpty { try? FileManager.default.removeItem(at: u); return }
            try? MarksFile.encode(now).write(to: u, options: .atomic)
        }
    }

    /// Waits for the saves already asked for (before the app may be suspended).
    static func flush() { queue.sync {} }

    static func remove(key: String?) {
        guard let key else { return }
        let u = url(key: key)
        queue.sync { onDisk[key] = nil; try? FileManager.default.removeItem(at: u) }
    }

    static func removeAll() {
        queue.sync { onDisk = [:] }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Marks kept under a PDF's file name by an earlier version move to its content key, once.
    static func migrate(from old: String, to new: String) {
        let o = url(key: old), n = url(key: new)
        queue.sync {
            let fm = FileManager.default
            guard MarksPlan.migrate(oldExists: fm.fileExists(atPath: o.path), newExists: fm.fileExists(atPath: n.path)) else { return }
            try? fm.moveItem(at: o, to: n)
            onDisk[old] = nil; onDisk[new] = nil
        }
    }

    // which content key a library file's marks are under (for the home screen's "Clear saved marks")
    private static let indexKey = "marksKeys"
    static func remember(_ key: String, for fileName: String) {
        var all = UserDefaults.standard.dictionary(forKey: indexKey) as? [String: String] ?? [:]
        all[fileName] = key
        UserDefaults.standard.set(all, forKey: indexKey)
    }

    static func key(for fileName: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: indexKey) as? [String: String])?[fileName]
    }
}
