import Combine
import ContrastInkCore
import PencilKit
import SwiftUI
import UIKit

/// The slide with the ink on top. Apple Pencil draws; a finger swipes to the next or previous slide (unless "finger
/// draws" is on). A two-finger tap, or a double-tap on the Pencil, undoes.
struct StageView: UIViewRepresentable {
    @ObservedObject var lecture: Lecture
    var recorder: LectureRecorder

    func makeUIView(context: Context) -> Stage {
        let s = Stage(lecture: lecture)
        s.slideRectChanged = { [weak recorder] rect, window in recorder?.stageMoved(rect, in: window) }
        return s
    }

    func updateUIView(_ stage: Stage, context: Context) { stage.refresh() }
}

final class Stage: UIView, PKCanvasViewDelegate, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
    let lecture: Lecture
    let canvas = PKCanvasView()
    private let slide = UIImageView()
    private let preview = CAShapeLayer()       // the arrow or oval being dragged
    private let shapePan = UIPanGestureRecognizer()
    private var swipes: [UISwipeGestureRecognizer] = []
    private let twoFingerTap = UITapGestureRecognizer()
    private var shownPage = -1
    private var shownDrawing = PKDrawing()
    private var applying = false               // a drawing set by the app, not drawn by the presenter
    private var pageSize = CGSize(width: 1024, height: 768)
    private var shapeStart = CGPoint.zero
    private var bag: Set<AnyCancellable> = []
    /// The slide's rectangle in its window moved or resized (the recorder crops the video to it).
    var slideRectChanged: ((CGRect, UIWindow) -> Void)?

    init(lecture: Lecture) {
        self.lecture = lecture
        super.init(frame: .zero)
        backgroundColor = .black
        accessibilityIdentifier = "stage"

        canvas.delegate = self
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.accessibilityIdentifier = "canvas"
        // PencilKit swaps black and white ink in dark mode: marks must look the same as in the recording and on the projector
        canvas.overrideUserInterfaceStyle = .light
        slide.contentMode = .scaleToFill
        canvas.insertSubview(slide, at: 0)
        addSubview(canvas)

        preview.fillColor = nil
        preview.lineCap = .round
        preview.lineJoin = .round
        canvas.layer.addSublayer(preview)

        shapePan.addTarget(self, action: #selector(shapeDrag(_:)))
        shapePan.maximumNumberOfTouches = 1
        canvas.addGestureRecognizer(shapePan)

        for dir in [UISwipeGestureRecognizer.Direction.left, .right] {
            let s = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            s.direction = dir
            s.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            s.delegate = self
            addGestureRecognizer(s)
            swipes.append(s)
        }
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        twoFingerTap.addTarget(self, action: #selector(twoFingerTapped))
        addGestureRecognizer(twoFingerTap)

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)

        lecture.applyTool = { [weak self] in self?.applyTool() }
        lecture.$drawing.sink { [weak self] d in self?.show(d) }.store(in: &bag)
        applyTool()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: showing the slide and its marks

    func refresh() {
        guard let deck = lecture.deck else { return }
        if lecture.page != shownPage {
            shownPage = lecture.page
            pageSize = deck.pageSize(shownPage)
            setNeedsLayout()
        }
        show(lecture.drawing)
        applyTool()
    }

    private func show(_ d: PKDrawing) {
        guard d != shownDrawing || d != canvas.drawing else { return }
        shownDrawing = d
        applying = true
        canvas.drawing = d
        applying = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let deck = lecture.deck, bounds.width > 0 else { return }
        let fit = Fit.aspect(Size(pageSize.width, pageSize.height), in: Size(bounds.width, bounds.height))
        let frame = CGRect(x: fit.x, y: fit.y, width: fit.width, height: fit.height).integral
        let zoom = frame.width / pageSize.width
        canvas.frame = frame
        // the ink is kept in slide points (1024 wide) and shown zoomed to fit: sharp at any size, same place on any screen
        canvas.minimumZoomScale = zoom
        canvas.maximumZoomScale = zoom
        canvas.zoomScale = zoom
        canvas.contentSize = frame.size
        canvas.contentOffset = .zero
        slide.frame = CGRect(origin: .zero, size: frame.size)
        slide.image = deck.image(shownPage, pixelWidth: frame.width * (window?.screen.scale ?? 2))
        canvas.sendSubviewToBack(slide)
        if let window { slideRectChanged?(canvas.convert(canvas.bounds, to: window), window) }
    }

    // MARK: tools

    private func applyTool() {
        let s = lecture.settings
        canvas.tool = lecture.pkTool
        canvas.drawingPolicy = s.fingerDraws ? .anyInput : .pencilOnly
        let shapes = s.tool == .arrow || s.tool == .oval
        canvas.drawingGestureRecognizer.isEnabled = !shapes
        shapePan.isEnabled = shapes
        shapePan.allowedTouchTypes = s.fingerDraws
            ? [NSNumber(value: UITouch.TouchType.pencil.rawValue), NSNumber(value: UITouch.TouchType.direct.rawValue)]
            : [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        swipes.forEach { $0.isEnabled = !s.fingerDraws }
        twoFingerTap.isEnabled = s.twoFingerTapUndoes
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !applying, canvasView.drawing != shownDrawing else { return }
        shownDrawing = canvasView.drawing
        lecture.canvasChanged(canvasView.drawing)
    }

    // MARK: arrow and oval

    private func slidePoint(_ g: UIGestureRecognizer) -> CGPoint {
        let p = g.location(in: canvas)
        return CGPoint(x: p.x / canvas.zoomScale, y: p.y / canvas.zoomScale)
    }

    private func shapePoints(to end: CGPoint, circle: Bool) -> [Pt] {
        let a = Pt(shapeStart.x, shapeStart.y), b = Pt(end.x, end.y)
        if lecture.settings.tool == .arrow { return Shapes.arrow(from: a, to: b, width: Settings.widths[lecture.settings.width]) }
        return Shapes.oval(a, circle ? Shapes.square(start: a, end: b) : b)
    }

    @objc private func shapeDrag(_ g: UIPanGestureRecognizer) {
        let z = canvas.zoomScale
        switch g.state {
        case .began:
            // the drag began a few points before it was recognised: start where the pen first touched
            let t = g.translation(in: canvas), p = slidePoint(g)
            shapeStart = CGPoint(x: p.x - t.x / z, y: p.y - t.y / z)
            preview.strokeColor = lecture.inkColor.cgColor
            preview.lineWidth = CGFloat(Settings.widths[lecture.settings.width]) * z
            fallthrough
        case .changed:
            let pts = shapePoints(to: slidePoint(g), circle: g.modifierFlags.contains(.shift) || Lecture.shiftHeld)
            let path = UIBezierPath()
            for (i, p) in pts.enumerated() {
                let q = CGPoint(x: p.x * z, y: p.y * z)
                if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
            }
            preview.path = path.cgPath
        case .ended:
            preview.path = nil
            let end = slidePoint(g)
            guard !Shapes.tooSmall(Pt(shapeStart.x, shapeStart.y), Pt(end.x, end.y)) else { return }
            lecture.add(shape: shapePoints(to: end, circle: g.modifierFlags.contains(.shift) || Lecture.shiftHeld))
        default:
            preview.path = nil
        }
    }

    // MARK: undo gestures and slide swipes

    @objc private func swiped(_ g: UISwipeGestureRecognizer) {
        if g.direction == .left { lecture.next() } else { lecture.previous() }
    }

    @objc private func twoFingerTapped() { lecture.undo() }

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        if lecture.settings.pencilTapUndoes { lecture.undo() }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
