import AVFoundation
import ContrastInkCore
import CoreImage
import Photos
import ReplayKit
import UIKit

/// Recording from the toolbar: ⏺ / ⏹, ⏸ / ▶, a timer, and a chapter at every slide change.
/// Apple's in-app screen capture (ReplayKit) gives the app's frames and the microphone; only the slide (with its
/// ink) is cut out of each frame and written to the video, so the toolbar is never in it. The video goes to
/// Photos and to Contrast Ink's folder in the Files app, with "<video> chapters.txt" beside it.
@MainActor
final class LectureRecorder: ObservableObject {
    enum State { case idle, starting, recording, paused, stopping }
    @Published private(set) var state = State.idle
    @Published private(set) var elapsed: Double = 0
    @Published var notice: String?

    private let sink = CaptureSink()
    private var chapters: [(at: Double, name: String)] = []
    private var lastChapterPage = -1
    private var clock: Timer?

    var active: Bool { state == .recording || state == .paused || state == .stopping }

    init() {
        Lecture.shared.slideChanged = { [weak self] page in self?.slideChanged(page) }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                // iOS stops in-app capture when the app leaves the screen: finish the file so nothing is lost
                guard let self, self.active else { return }
                self.notice = "Recording stopped because Contrast Ink left the screen. What was recorded is saved."
                await self.stop()
            }
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
        if state == .recording { sink.pause(at: now); state = .paused }
        else if state == .paused {
            sink.resume(at: now); state = .recording
            // slides changed while paused: the video goes on from the slide showing now, so it gets its chapter
            if Lecture.shared.page != lastChapterPage { slideChanged(Lecture.shared.page) }
        }
    }

    private func start() async {
        let screen = RPScreenRecorder.shared()
        guard screen.isAvailable else {
            notice = "Screen recording isn't available right now (it may be off in Settings → Screen Time → Content & Privacy)."
            return
        }
        state = .starting
        notice = nil
        let url = LectureRecorder.newFileURL(title: Lecture.shared.deck?.title ?? "Lecture")
        sink.prepare(url: url)
        screen.isMicrophoneEnabled = true
        do {
            try await screen.startCapture { [sink] buffer, type, error in
                guard error == nil else { return }
                sink.receive(buffer, type: type)
            }
        } catch {
            state = .idle
            notice = "Recording didn't start: \(error.localizedDescription)"
            return
        }
        if !screen.isMicrophoneEnabled { notice = "Recording without sound: microphone access is off (Settings → Contrast Ink)." }
        chapters = []
        lastChapterPage = Lecture.shared.page
        chapters.append((0, "Slide \(Lecture.shared.page + 1)"))
        state = .recording
        clock = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        elapsed = sink.elapsed(at: CaptureSink.hostNow())
        if let problem = sink.takeProblem() { notice = problem }
    }

    func stop() async {
        guard active, state != .stopping else { return }
        state = .stopping
        clock?.invalidate(); clock = nil
        try? await RPScreenRecorder.shared().stopCapture()
        let url = await sink.finish()
        state = .idle
        elapsed = 0
        guard let url else {
            notice = notice ?? "Nothing was recorded (no picture arrived from the screen)."
            return
        }
        let text = Chapters.text(chapters)
        if chapters.count > 1 {
            let file = url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + " chapters.txt")
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
        let saved = await LectureRecorder.saveToPhotos(url)
        let name = url.lastPathComponent
        notice = saved
            ? "Saved to Photos, and to Files → On My iPad → Contrast Ink → Recordings (\(name))."
            : "Saved to Files → On My iPad → Contrast Ink → Recordings (\(name)). Allow Photos access to also save it there."
    }

    private func slideChanged(_ page: Int) {
        guard state == .recording, page != lastChapterPage else { return }
        lastChapterPage = page
        chapters.append((sink.elapsed(at: CaptureSink.hostNow()), "Slide \(page + 1)"))
    }

    private static func newFileURL(title: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var url = folder.appendingPathComponent("\(safe) \(f.string(from: Date())).mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(safe) \(f.string(from: Date())) (\(n)).mp4"); n += 1
        }
        return url
    }

    private static func saveToPhotos(_ url: URL) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            return true
        } catch { return false }
    }
}

/// Writes the video. ReplayKit hands frames over on its own thread; everything here happens on one queue.
final class CaptureSink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Contrast Ink recording")
    private let lock = NSLock()
    private let ci = CIContext(options: [.cacheIntermediates: false])

    // read and written under `lock` (the main thread and the capture queue both use them)
    private var stage = CGRect.zero, screen = CGSize.zero
    private var timeline = Timeline()
    private var problem: String?

    // the capture queue only
    private var url: URL?
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outSize = CGSize.zero
    private var failed = false

    static func hostNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    func setGeometry(stage: CGRect, screen: CGSize) {
        lock.lock(); self.stage = stage; self.screen = screen; lock.unlock()
    }

    func pause(at t: Double) { lock.lock(); timeline.pause(at: t); lock.unlock() }
    func resume(at t: Double) { lock.lock(); timeline.resume(at: t); lock.unlock() }
    func elapsed(at t: Double) -> Double { lock.lock(); defer { lock.unlock() }; return timeline.elapsed(at: t) }
    func takeProblem() -> String? { lock.lock(); defer { problem = nil; lock.unlock() }; return problem }

    func prepare(url: URL) {
        queue.sync {
            self.url = url
            writer = nil; video = nil; audio = nil; adaptor = nil; failed = false
            lock.lock(); timeline = Timeline(); problem = nil; lock.unlock()
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
        if writer == nil {
            let out = Crop.outputSize(Size(crop.width, crop.height))
            guard start(size: CGSize(width: out.width, height: out.height)) else { return }
            lock.lock(); timeline.begin(at: pts.seconds); lock.unlock()
        }
        lock.lock(); let t = timeline.videoTime(pts.seconds); lock.unlock()
        guard let t, let video, let adaptor, video.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }

        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return }
        let cut = image.cropped(to: CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height))
        let s = outSize.width / CGFloat(crop.width)
        let placed = cut.transformed(by: CGAffineTransform(translationX: -CGFloat(crop.x), y: -CGFloat(crop.y)).concatenating(CGAffineTransform(scaleX: s, y: s)))
        ci.render(placed, to: out, bounds: CGRect(origin: .zero, size: outSize), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        if !adaptor.append(out, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600)) { fail() }
    }

    private func writeAudio(_ buffer: CMSampleBuffer) {
        guard let audio, audio.isReadyForMoreMediaData else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        lock.lock(); let t = timeline.videoTime(pts.seconds); lock.unlock()
        guard let t else { return }   // before the first picture, or paused
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
            let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000, AVVideoExpectedSourceFrameRateKey: 30],
            ])
            v.expectsMediaDataInRealTime = true
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1, AVSampleRateKey: 44100, AVEncoderBitRateKey: 96_000,
            ])
            a.expectsMediaDataInRealTime = true
            guard w.canAdd(v), w.canAdd(a) else { throw CocoaError(.fileWriteUnknown) }
            w.add(v); w.add(a)
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
            report("Recording couldn't write the video file: \(error.localizedDescription)")
            return false
        }
    }

    private func fail() {
        guard !failed else { return }
        failed = true
        report("Recording stopped writing: \(writer?.error?.localizedDescription ?? "unknown error"). Press ⏹ and record again.")
    }

    /// Finishes the file. The file's address, or nil when no picture ever arrived.
    func finish() async -> URL? {
        await withCheckedContinuation { (done: CheckedContinuation<URL?, Never>) in
            queue.async { [self] in
                guard let writer, writer.status == .writing else {
                    if let url { try? FileManager.default.removeItem(at: url) }
                    done.resume(returning: nil); return
                }
                video?.markAsFinished(); audio?.markAsFinished()
                let url = self.url
                writer.finishWriting { done.resume(returning: writer.status == .completed ? url : nil) }
                self.writer = nil
            }
        }
    }
}
