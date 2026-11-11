import PDFKit
import UIKit

/// What is being presented: PDF slides (PowerPoint → Export → PDF), pictures (CT/MR screenshots), or a whiteboard.
/// Every page is laid out 1024 points wide; marks are kept in those points, so they stay in place on any screen.
final class Deck {
    enum Source {
        case pdf(PDFDocument)
        case images([UIImage])
        case whiteboard
    }

    static let pageWidth: CGFloat = 1024

    let title: String
    let source: Source
    private(set) var pageCount: Int
    private let cache = NSCache<NSString, UIImage>()

    init(title: String, source: Source) {
        self.title = title
        self.source = source
        switch source {
        case .pdf(let d): pageCount = max(d.pageCount, 1)
        case .images(let i): pageCount = max(i.count, 1)
        case .whiteboard: pageCount = 1
        }
    }

    static func open(pdf url: URL) -> Deck? {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return nil }
        return Deck(title: url.deletingPathExtension().lastPathComponent, source: .pdf(doc))
    }

    var isWhiteboard: Bool { if case .whiteboard = source { return true } else { return false } }

    /// A whiteboard grows: going past its last page adds a clean one.
    func addWhiteboardPage() { if isWhiteboard { pageCount += 1 } }

    /// The page's size in layout points (1024 wide).
    func pageSize(_ page: Int) -> CGSize {
        let natural: CGSize
        switch source {
        case .pdf(let d):
            guard let p = d.page(at: page) else { natural = CGSize(width: 4, height: 3); break }
            let box = p.bounds(for: .cropBox)
            // a page turned in the PDF (rotation 90/270) is shown the way it reads
            natural = p.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        case .images(let i):
            natural = i.indices.contains(page) ? i[page].size : CGSize(width: 4, height: 3)
        case .whiteboard:
            natural = CGSize(width: 4, height: 3)
        }
        guard natural.width > 0, natural.height > 0 else { return CGSize(width: Deck.pageWidth, height: Deck.pageWidth * 3 / 4) }
        return CGSize(width: Deck.pageWidth, height: Deck.pageWidth * natural.height / natural.width)
    }

    /// The page as a picture `pixelWidth` pixels wide (drawn once per size, then kept).
    func image(_ page: Int, pixelWidth: CGFloat) -> UIImage {
        let w = max(64, (pixelWidth / 64).rounded(.up) * 64)   // a few sizes only, so the cache is reused
        let key = "\(page)@\(Int(w))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let size = pageSize(page), px = CGSize(width: w, height: (w * size.height / size.width).rounded())
        let img: UIImage
        switch source {
        case .pdf(let d):
            img = d.page(at: page)?.thumbnail(of: px, for: .cropBox) ?? Deck.blank(px)
        case .images(let i):
            img = i.indices.contains(page) ? i[page] : Deck.blank(px)
        case .whiteboard:
            img = Deck.blank(px)
        }
        cache.setObject(img, forKey: key)
        return img
    }

    static func blank(_ size: CGSize) -> UIImage {
        let f = UIGraphicsImageRendererFormat.default(); f.scale = 1
        return UIGraphicsImageRenderer(size: size, format: f).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}

/// Decks kept in the app's Documents/Decks folder (visible in the Files app), newest first.
enum Library {
    static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let f = docs.appendingPathComponent("Decks", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    static func decks() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "pdf" }.sorted {
            let a = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return a > b
        }
    }

    /// Copies a PDF picked in Files into the library (replacing one of the same name), so it opens again next time.
    static func add(_ picked: URL) throws -> URL {
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let dest = folder.appendingPathComponent(picked.lastPathComponent)
        if dest.standardizedFileURL == picked.standardizedFileURL { return dest }
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.copyItem(at: picked, to: dest)
        return dest
    }

    /// Marks it as just used, so it is listed first.
    static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    static func loadImages(_ urls: [URL]) -> [UIImage] {
        urls.compactMap { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return (try? Data(contentsOf: url)).flatMap(UIImage.init(data:))
        }
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
        return Deck(title: "Sample", source: .pdf(PDFDocument(data: data)!))
    }
}
