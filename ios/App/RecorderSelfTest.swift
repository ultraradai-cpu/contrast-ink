#if DEBUG
import AVFoundation
import ReplayKit
import SwiftUI

/// The UI test's check of the video writer (`-recorderTest`; Debug builds only), for a simulator where ReplayKit
/// may not record: made-up frames go through the same CaptureSink as a recording, with a pause, and then
/// - a copy of the file taken while it is still being written (as a crash or the battery would leave it) must play,
/// - the finished file must play, with the paused stretch cut out.
enum RecorderSelfTest {
    static func run() async -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-test", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("test.mov"), cut = dir.appendingPathComponent("interrupted.mov")
        let sink = CaptureSink(fragmentInterval: 1)
        sink.prepare(url: url)
        sink.setGeometry(stage: CGRect(x: 0, y: 0, width: 320, height: 240), screen: CGSize(width: 320, height: 240))

        let t0 = CaptureSink.hostNow()
        await feed(sink, seconds: 2.5, shade: 0.2)
        let p0 = CaptureSink.hostNow()
        sink.pause(at: p0)
        await feed(sink, seconds: 1, shade: 0.9)              // paused: none of these are in the video
        let p1 = CaptureSink.hostNow()
        sink.resume(at: p1)
        await feed(sink, seconds: 1, shade: 0.5)
        let expected = CaptureSink.hostNow() - t0 - (p1 - p0)
        try? await Task.sleep(nanoseconds: 1_500_000_000)     // the fragments reach the disk

        // what a crash would leave: the file as it is, never finished
        do { try FileManager.default.copyItem(at: url, to: cut) } catch { return "fail: no file while recording (\(error.localizedDescription))" }
        let early = await frames(cut)
        guard early.count > 0 else { return "fail: the unfinished file doesn't play (\(early.note))" }

        guard let result = await sink.finish() else { return "fail: nothing was written" }
        guard result.complete else { return "fail: the file wasn't finished" }
        let full = await frames(result.url)
        guard full.count >= early.count, abs(full.duration - expected) < 0.7 else {
            return "fail: the finished file has \(full.count) frames over \(String(format: "%.1f", full.duration)) s, expected \(String(format: "%.1f", expected)) s without the pause (\(full.note))"
        }
        return "ok: finished \(String(format: "%.1f", full.duration)) s, \(full.count) frames; the unfinished copy plays \(early.count) frames"
    }

    /// Frames at 30 a second, stamped with the host clock as ReplayKit's are.
    private static func feed(_ sink: CaptureSink, seconds: Double, shade: CGFloat) async {
        let n = Int(seconds * 30)
        for i in 0..<n {
            if let b = sample(shade: shade + CGFloat(i % 30) / 100) { sink.receive(b, type: .video) }
            try? await Task.sleep(nanoseconds: 33_000_000)
        }
    }

    private static func sample(shade: CGFloat) -> CMSampleBuffer? {
        var px: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &px)
        guard let px else { return nil }
        CVPixelBufferLockBaseAddress(px, [])
        if let base = CVPixelBufferGetBaseAddress(px) {
            memset(base, Int32(min(255, shade * 255)), CVPixelBufferGetBytesPerRow(px) * 240)
        }
        CVPixelBufferUnlockBaseAddress(px, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: px, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: px, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &out)
        return out
    }

    /// How many video frames can be read back, and the video's length.
    private static func frames(_ url: URL) async -> (count: Int, duration: Double, note: String) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return (0, 0, "no video track") }
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        guard let reader = try? AVAssetReader(asset: asset) else { return (0, duration, "can't be read") }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(out)
        guard reader.startReading() else { return (0, duration, reader.error?.localizedDescription ?? "can't be read") }
        var n = 0
        while let s = out.copyNextSampleBuffer() { if CMSampleBufferGetNumSamples(s) > 0 { n += 1 } }
        return (n, duration, reader.status == .failed ? (reader.error?.localizedDescription ?? "read failed") : "")
    }
}

/// Shows the self-test's result for the UI test to read.
struct RecorderSelfTestView: View {
    @State private var result = "running"
    var body: some View {
        Text(result)
            .padding()
            .accessibilityIdentifier("recorderTestResult")
            .task { result = await RecorderSelfTest.run() }
    }
}
#endif
