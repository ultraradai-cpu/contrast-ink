import ContrastInkCore
import PDFKit
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
    private let rendering = NSLock()                       // one page drawn at a time (PDFKit isn't for two threads)
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
        rendering.lock(); defer { rendering.unlock() }
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
        for p in [page + 1, page - 1] where p >= 0 && p < pageCount {
            Deck.ahead.async { [weak self] in _ = self?.image(p, pixelWidth: pixelWidth) }
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
    /// isn't a PDF never gets in. One with the same name as a deck already there gets its own name ("Lecture (2).pdf").
    static func add(_ picked: URL) throws -> URL {
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        guard Deck.open(pdf: picked) != nil else {
            throw Problem(text: "\(picked.lastPathComponent) couldn't be opened as a PDF (it may be damaged, or not a PDF). Nothing was added.")
        }
        if picked.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { return picked }
        let name = FileNames.unique(picked.lastPathComponent) { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        let dest = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: picked, to: dest)
        return dest
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
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }

    /// Removes a deck and its saved marks.
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
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

/// Each deck's marks on disk: Application Support/Marks/<deck>.marks (not in Files: they aren't documents).
enum SavedMarks {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let f = base.appendingPathComponent("Marks", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    static func url(key: String) -> URL { folder.appendingPathComponent(MarksFile.fileName(forDeck: key)) }

    static func load(key: String) -> [Int: Data] { MarksFile.decode(try? Data(contentsOf: url(key: key))) }

    static func exists(key: String) -> Bool { FileManager.default.fileExists(atPath: url(key: key).path) }

    private static let writing = DispatchQueue(label: "Contrast Ink saving marks", qos: .utility)

    /// Saved in the background; with no marks the file goes.
    static func save(_ pages: [Int: Data], key: String) {
        let u = url(key: key)
        writing.async {
            if pages.isEmpty { try? FileManager.default.removeItem(at: u); return }
            try? MarksFile.encode(pages).write(to: u, options: .atomic)
        }
    }

    /// Waits for the saves already asked for (before the app may be suspended).
    static func flush() { writing.sync {} }

    static func remove(key: String) {
        let u = url(key: key)
        writing.sync { try? FileManager.default.removeItem(at: u) }
    }

    static func removeAll() { try? FileManager.default.removeItem(at: folder) }
}
