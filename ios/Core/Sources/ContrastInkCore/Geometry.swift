/// Plain geometry, so the rules don't need CoreGraphics (and are tested on any machine).
public struct Pt: Equatable, Sendable {
    public var x: Double, y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

public struct Size: Equatable, Sendable {
    public var width: Double, height: Double
    public init(_ width: Double, _ height: Double) { self.width = width; self.height = height }
}

public struct Rect: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public enum Fit {
    /// The largest rectangle with `content`'s shape that fits inside `box`, centred (a slide on any screen).
    public static func aspect(_ content: Size, in box: Size) -> Rect {
        guard content.width > 0, content.height > 0, box.width > 0, box.height > 0 else { return Rect(0, 0, 0, 0) }
        let scale = min(box.width / content.width, box.height / content.height)
        let w = content.width * scale, h = content.height * scale
        return Rect((box.width - w) / 2, (box.height - h) / 2, w, h)
    }
}

/// Which part of a screen recording frame is the slide (the toolbar is left out of the video).
public enum Crop {
    /// - Parameters:
    ///   - stage: the slide's rectangle on screen, in points, top-left origin (UIKit).
    ///   - screen: the whole screen in points, the same way up as `stage`.
    ///   - image: the recorded frame in pixels, already turned the same way up as the screen.
    /// - Returns: the slide's rectangle in the frame's pixels with a BOTTOM-left origin (Core Image), whole pixels,
    ///   even width and height (video encoders need them), and never outside the frame.
    public static func pixelRect(stage: Rect, screen: Size, image: Size) -> Rect {
        guard screen.width > 0, screen.height > 0 else { return Rect(0, 0, 0, 0) }
        let sx = image.width / screen.width, sy = image.height / screen.height
        var x = (stage.x * sx).rounded(), w = (stage.width * sx).rounded()
        var yTop = (stage.y * sy).rounded(), h = (stage.height * sy).rounded()
        x = max(0, min(x, image.width)); yTop = max(0, min(yTop, image.height))
        w = max(0, min(w, image.width - x)); h = max(0, min(h, image.height - yTop))
        w -= w.truncatingRemainder(dividingBy: 2); h -= h.truncatingRemainder(dividingBy: 2)
        return Rect(x, image.height - yTop - h, w, h)
    }

    /// The size to write the video at: the crop itself, scaled down to fit `maxWidth` wide, even numbers.
    public static func outputSize(_ crop: Size, maxWidth: Double = 1920) -> Size {
        guard crop.width > 0, crop.height > 0 else { return Size(0, 0) }
        let s = min(1, maxWidth / crop.width)
        func even(_ v: Double) -> Double { let r = (v * s).rounded(.down); return max(2, r - r.truncatingRemainder(dividingBy: 2)) }
        return Size(even(crop.width), even(crop.height))
    }
}
