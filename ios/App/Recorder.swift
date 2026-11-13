import AVFoundation
import ContrastInkCore
import CoreImage
import Photos
import ReplayKit
import UIKit

/// Recording from the toolbar: ⏺ / ⏹, ⏸ / ▶, a timer, and a chapter at every slide change.
/// Apple's in-app screen capture (ReplayKit) gives the app's frames and the microphone; only the slide (with its
/// ink) is cut out of each frame and written to the video, so the toolbar is never in it. The video goes to
/// Contrast Ink's folder in the Files app, with "<video> chapters.txt" beside it, and to Photos when switched on.
///
/// The video is a fragmented QuickTime movie: every 10 s what was recorded is complete on disk, so a crash, the
/// battery or iOS ending the app late in a lecture leaves a video that plays up to the last few seconds. A recording
/// is never deleted: one that couldn't be finished is kept and the presenter is told it may be incomplete.
@MainActor
final class LectureRecorder: ObservableObject {
    typealias State = RecorderPhase.State
    @Published private(set) var state = State.idle
    @Published private(set) var elapsed: Double = 0
    @Published var notice: String?

    private var phase = RecorderPhase() { didSet { state = phase.state } }
    private let sink = CaptureSink()
    private var chapters: [(at: Double, name: String)] = []
    private var lastChapterPage = -1
    private var clock: Timer?
    private var lastSpaceCheck = Date.distantPast
    private var warnedSpace = false
    /// Why it stopped by itself (left the screen, interrupted, the iPad full): said before where the video is.
    private var stopReason: String?

    var active: Bool { phase.active }
    /// ✕ asks first while recording or starting.
    var busy: Bool { state != .idle }

    init() {
        Lecture.shared.slideChanged = { [weak self] page in self?.slideChanged(page) }
        // iOS stops in-app capture when the app leaves the screen: finish the file so nothing is lost. With a
        // projector connected only the iPad's own scene leaves, so its notice counts too.
        MainScreen.onLeave { [weak self] in self?.leftScreen() }
    }

    private func leftScreen() {
        guard state != .idle, state != .stopping else { return }
        stopReason = "Recording stopped because Contrast Ink left the screen."
        Task {
            // iOS gives an app in the background only moments: ask for time to finish the file and save it
            let app = UIApplication.shared
            var task = UIBackgroundTaskIdentifier.invalid
            task = app.beginBackgroundTask(withName: "Saving the recording") { app.endBackgroundTask(task); task = .invalid }
            await self.stop()
            if task != .invalid { app.endBackgroundTask(task) }
        }
    }

    /// The stage tells where the slide is on screen.
    func stageMoved(_ rect: CGRect, in window: UIWindow) {
        sink.setGeometry(stage: rect, screen: window.bounds.size)
    }

    func recordTapped() {
        Task {
            if state == .recording || state == .paused { await stop(); return }
            guard state == .idle else { return }
            await start()
        }
    }

    func pauseTapped() {
        let now = CaptureSink.hostNow()
        if state == .recording { sink.pause(at: now); phase.pause() }
        else if state == .paused {
            sink.resume(at: now); phase.resume()
            // slides changed while paused: the video goes on from the slide showing now, so it gets its chapter
            if Lecture.shared.page != lastChapterPage { slideChanged(Lecture.shared.page) }
        }
    }

    /// Free space on the iPad for the app's files (nil when iOS doesn't say).
    static func freeSpace() -> Int64? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let v = try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else { return nil }
        return v.volumeAvailableCapacityForImportantUsage
    }

    private func start() async {
        let screen = RPScreenRecorder.shared()
        guard screen.isAvailable else {
            notice = "Screen recording isn't available right now (it may be off in Settings → Screen Time → Content & Privacy)."
            return
        }
        if let why = RecordingSpace.beforeStart(free: Self.freeSpace()) { notice = why; return }
        guard phase.startTapped() else { return }
        notice = nil
        stopReason = nil
        warnedSpace = false
        let url = LectureRecorder.newFileURL(title: Lecture.shared.deck?.title ?? "Lecture")
        sink.prepare(url: url)
        screen.isMicrophoneEnabled = true
        do {
            try await screen.startCapture { [sink] buffer, type, error in
                if let error { sink.interrupted(error); return }
                sink.receive(buffer, type: type)
            }
        } catch {
            phase.failedToStart()
            notice = "Recording didn't start: \(error.localizedDescription)"
            return
        }
        guard phase.started() else {
            // ✕ or the app leaving the screen while iOS was still asking: stop now rather than record unseen
            try? await screen.stopCapture()
            _ = await sink.finish()
            phase.finished()
            notice = stopReason ?? "Recording stopped before it began."
            stopReason = nil
            return
        }
        if !screen.isMicrophoneEnabled { notice = "Recording without sound: microphone access is off (Settings → Contrast Ink)." }
        chapters = []
        lastChapterPage = Lecture.shared.page
        chapters.append((0, "Slide \(Lecture.shared.page + 1)"))
        lastSpaceCheck = Date()
        clock = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        elapsed = sink.elapsed(at: CaptureSink.hostNow())
        if let problem = sink.takeProblem() { notice = problem }
        // capture broke (a phone call, the system took the screen) or the file can't be written: stop and save what
        // there is, rather than a timer running over nothing
        if sink.broken, state == .recording || state == .paused { Task { await stop() }; return }
        // every minute: is there still room?
        if Date().timeIntervalSince(lastSpaceCheck) >= 60 {
            lastSpaceCheck = Date()
            checkSpace()
        }
    }

    private func checkSpace() {
        let written = sink.writtenBytes()
        switch RecordingSpace.whileRecording(free: Self.freeSpace(), written: written,
                                             alsoPhotos: Lecture.shared.settings.alsoSaveToPhotos) {
        case .fine: break
        case .warn(let why):
            if !warnedSpace { warnedSpace = true; notice = why }
        case .stop(let why):
            stopReason = why
            Task { await stop() }
        }
    }

    /// ⏹, ✕, leaving the screen. While still starting, the recording stops as soon as capture begins.
    func stop() async {
        guard phase.stopRequested() == .now else { return }
        clock?.invalidate(); clock = nil
        try? await RPScreenRecorder.shared().stopCapture()
        let result = await sink.finish()
        phase.finished()
        elapsed = 0
        let reason = stopReason.map { $0 + " " } ?? ""
        stopReason = nil
        guard let result else {
            notice = reason + (notice ?? "Nothing was recorded (no picture arrived from the screen).")
            return
        }
        let url = result.url
        if chapters.count > 1 {
            let file = url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + " chapters.txt")
            try? Chapters.text(chapters).write(to: file, atomically: true, encoding: .utf8)
        }
        var photos = RecordingReport.Photos.off
        if Lecture.shared.settings.alsoSaveToPhotos {
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            if RecordingSpace.photosCopyFits(free: Self.freeSpace(), fileSize: size) {
                photos = await LectureRecorder.saveToPhotos(url)
            } else {
                photos = .noRoom
            }
        }
        notice = reason + RecordingReport.text(file: url.lastPathComponent, complete: result.complete, photos: photos)
    }

    private func slideChanged(_ page: Int) {
        guard state == .recording, page != lastChapterPage else { return }
        lastChapterPage = page
        chapters.append((sink.elapsed(at: CaptureSink.hostNow()), "Slide \(page + 1)"))
    }

    static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func newFileURL(title: String) -> URL {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"
        let name = FileNames.unique("\(FileNames.safe(title)) \(f.string(from: Date())).mov") {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        return folder.appendingPathComponent(name)
    }

    private static func saveToPhotos(_ url: URL) async -> RecordingReport.Photos {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .notAllowed }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// Writes the video. ReplayKit hands frames over on its own thread; everything here happens on one queue.
final class CaptureSink: @unchecked Sendable {
    /// How often what was recorded is made complete on disk.
    let fragmentInterval: Double
    private let queue = DispatchQueue(label: "Contrast Ink recording")
    private let lock = NSLock()
    private let ci = CIContext(options: [.cacheIntermediates: false])

    // read and written under `lock` (the main thread and the capture queue both use them)
    private var stage = CGRect.zero, screen = CGSize.zero
    private var timeline = Timeline()
    private var problem: String?
    private var isBroken = false
    private var fileURL: URL?

    // the capture queue only
    private var url: URL?
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outSize = CGSize.zero
    private var failed = false
    private var videoForward = Forward(), audioForward = Forward()   // times only go forward in each track

    /// Whether the video gets a sound track: only when the microphone is allowed. A track that never gets a sample
    /// would hold every fragment back (the writer waits to interleave it), and nothing would reach the disk until the end.
    let withSound: () -> Bool

    init(fragmentInterval: Double = 10,
         withSound: @escaping () -> Bool = { AVAudioSession.sharedInstance().recordPermission == .granted }) {
        self.fragmentInterval = fragmentInterval
        self.withSound = withSound
    }

    static func hostNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    func setGeometry(stage: CGRect, screen: CGSize) {
        lock.lock(); self.stage = stage; self.screen = screen; lock.unlock()
    }

    func pause(at t: Double) { lock.lock(); timeline.pause(at: t); lock.unlock() }
    func resume(at t: Double) { lock.lock(); timeline.resume(at: t); lock.unlock() }
    func elapsed(at t: Double) -> Double { lock.lock(); defer { lock.unlock() }; return timeline.elapsed(at: t) }
    func takeProblem() -> String? { lock.lock(); defer { problem = nil; lock.unlock() }; return problem }
    /// Capture or writing stopped working: the recording should be stopped (what was written is kept).
    var broken: Bool { lock.lock(); defer { lock.unlock() }; return isBroken }

    /// The video's size on disk so far.
    func writtenBytes() -> Int64 {
        lock.lock(); let u = fileURL; lock.unlock()
        guard let u, let size = try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return 0 }
        return Int64(size)
    }

    /// ReplayKit reported an error instead of a frame.
    func interrupted(_ error: Error) {
        lock.lock()
        if !isBroken { problem = "Recording was interrupted (\(error.localizedDescription)). What was recorded is saved." }
        isBroken = true
        lock.unlock()
    }

    func prepare(url: URL) {
        queue.sync {
            self.url = url
            writer = nil; video = nil; audio = nil; adaptor = nil; failed = false
            videoForward = Forward(); audioForward = Forward()
            lock.lock(); timeline = Timeline(); problem = nil; isBroken = false; fileURL = url; lock.unlock()
        }
    }

    func receive(_ buffer: CMSampleBuffer, type: RPSampleBufferType) {
        queue.async { [self] in
            guard !failed, CMSampleBufferDataIsReady(buffer) else { return }
            switch type {
            case .video: writeVideo(buffer)
            case .audioMic: writeAudio(buffer)
            default: break   // the app's own sounds are not wanted
            }
        }
    }

    private func report(_ text: String) { lock.lock(); problem = text; lock.unlock() }

    private func writeVideo(_ buffer: CMSampleBuffer) {
        guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        var image = CIImage(cvPixelBuffer: pixels)
        // frames may arrive turned; turn them the way the screen is
        if let raw = CMGetAttachment(buffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
           let o = CGImagePropertyOrientation(rawValue: raw.uint32Value) {
            image = image.oriented(o)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        lock.lock(); let stage = self.stage, screen = self.screen; lock.unlock()
        let crop = Crop.pixelRect(stage: Rect(stage.minX, stage.minY, stage.width, stage.height),
                                  screen: Size(screen.width, screen.height),
                                  image: Size(image.extent.width, image.extent.height))
        guard crop.width >= 2, crop.height >= 2 else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        lock.lock(); timeline.begin(at: pts.seconds); let t = timeline.videoTime(pts.seconds); lock.unlock()
        guard let t else { return }   // paused, or before the start
        if writer == nil {
            let out = Crop.outputSize(Size(crop.width, crop.height))
            guard start(size: CGSize(width: out.width, height: out.height)) else { return }
        }
        guard let video, let adaptor, video.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        guard videoForward.admit(t) else { return }

        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return }
        // the slide's shape can change mid-recording (a slide of another shape, the iPad turned, the toolbar on two
        // rows): each frame's slide is fitted whole into the video, centred, on black
        let cut = image.cropped(to: CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height))
        let fit = Fit.aspect(Size(crop.width, crop.height), in: Size(outSize.width, outSize.height))
        let s = CGFloat(fit.width) / CGFloat(crop.width)
        let placed = cut
            .transformed(by: CGAffineTransform(translationX: -CGFloat(crop.x), y: -CGFloat(crop.y)))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
            .transformed(by: CGAffineTransform(translationX: CGFloat(fit.x), y: CGFloat(fit.y)))
        let frame = CGRect(origin: .zero, size: outSize)
        let picture = placed.composited(over: CIImage(color: .black).cropped(to: frame))
        ci.render(picture, to: out, bounds: frame, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        if !adaptor.append(out, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600)) { fail() }
    }

    private func writeAudio(_ buffer: CMSampleBuffer) {
        guard let audio, audio.isReadyForMoreMediaData else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        lock.lock(); let t = timeline.videoTime(pts.seconds); lock.unlock()
        guard let t, audioForward.admit(t) else { return }   // before the first picture, paused, or out of order
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(buffer),
                                        presentationTimeStamp: CMTime(seconds: t, preferredTimescale: 48000),
                                        decodeTimeStamp: .invalid)
        var moved: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &moved)
        if let moved, !audio.append(moved) { fail() }
    }

    private func start(size: CGSize) -> Bool {
        guard let url else { return false }
        do {
            // QuickTime with movie fragments: the file plays up to the last fragment even if it is never finished
            let w = try AVAssetWriter(outputURL: url, fileType: .mov)
            w.movieFragmentInterval = CMTime(seconds: fragmentInterval, preferredTimescale: 600)
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000, AVVideoExpectedSourceFrameRateKey: 30],
            ])
            v.expectsMediaDataInRealTime = true
            guard w.canAdd(v) else { throw CocoaError(.fileWriteUnknown) }
            w.add(v)
            var a: AVAssetWriterInput?
            if withSound() {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1, AVSampleRateKey: 44100, AVEncoderBitRateKey: 96_000,
                ])
                input.expectsMediaDataInRealTime = true
                if w.canAdd(input) { w.add(input); a = input }
            }
            let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: v, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
            ])
            guard w.startWriting() else { throw w.error ?? CocoaError(.fileWriteUnknown) }
            w.startSession(atSourceTime: .zero)
            writer = w; video = v; audio = a; adaptor = ad; outSize = size
            return true
        } catch {
            failed = true
            lock.lock(); isBroken = true; lock.unlock()
            report("Recording couldn't write the video file: \(error.localizedDescription)")
            return false
        }
    }

    private func fail() {
        guard !failed else { return }
        failed = true
        lock.lock(); isBroken = true; lock.unlock()
        report("Recording stopped writing: \(writer?.error?.localizedDescription ?? "unknown error"). What was recorded until then is kept.")
    }

    /// Finishes the file. Its address and whether it was finished properly (false: it may be incomplete, but it is
    /// kept: its fragments play); nil when no picture ever arrived (no file was made).
    func finish() async -> (url: URL, complete: Bool)? {
        await withCheckedContinuation { (done: CheckedContinuation<(url: URL, complete: Bool)?, Never>) in
            queue.async { [self] in
                guard let writer, let url else { done.resume(returning: nil); return }
                self.writer = nil
                guard writer.status == .writing else {
                    // writing failed: what reached the disk is kept, never deleted
                    let there = FileManager.default.fileExists(atPath: url.path)
                    done.resume(returning: there ? (url, false) : nil)
                    return
                }
                video?.markAsFinished(); audio?.markAsFinished()
                writer.finishWriting {
                    let there = FileManager.default.fileExists(atPath: url.path)
                    done.resume(returning: there ? (url, writer.status == .completed) : nil)
                }
            }
        }
    }
}
