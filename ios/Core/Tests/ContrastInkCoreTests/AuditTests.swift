import XCTest
import Foundation
@testable import ContrastInkCore

/// The rules behind the fixes of the iPad audit: a stroke stays on its slide, marks kept on disk, room for a
/// recording, the recorder's stop while starting, the library's names and pictures, the sideload expiry, the iPhone's
/// finger, the 16-digit PC check. All plain Swift: these run on Linux too.
final class StrokeSlideTests: XCTestCase {
    /// Strokes are numbers here; a canvas hands back whatever it holds.
    private func finish(_ marks: inout PageMarks<[Int]>, canvas: [Int], pen: inout PenPage, current: Int,
                        ignore: Set<Int> = []) {
        let page = pen.finish(current: current)
        let m = InkMerge.merge(slide: marks.drawing(on: page), canvas: canvas, erasing: false, ignore: ignore, id: { $0 })
        if page == marks.current { marks.commit(m.strokes) } else { marks.commit(m.strokes, on: page) }
    }

    /// The pen goes down on slide 1, the clicker moves to slide 2 before it lifts: the stroke is slide 1's.
    func testAStrokeBegunBeforeASlideChangeStaysOnItsSlide() {
        var marks = PageMarks(empty: [Int]())
        var pen = PenPage()
        marks.commit([1])                           // slide 1 already has a mark
        pen.begin(on: 0)                             // the pen goes down on slide 1
        marks.show(page: 1)                          // the clicker: slide 2 (the canvas still holds slide 1's marks)
        finish(&marks, canvas: [1, 2], pen: &pen, current: 1, ignore: [1])   // the pen lifts: stroke 2
        XCTAssertEqual(marks.drawing(on: 0), [1, 2], "the stroke stays on the slide it was begun on")
        XCTAssertEqual(marks.drawing, [], "the new slide stays clean")
        XCTAssertNil(pen.began, "forgotten once used")
        XCTAssertFalse(marks.canUndo, "nothing to undo on slide 2")
        marks.show(page: 0)
        XCTAssertTrue(marks.undo(), "the stroke is an undo step on its own slide")
        XCTAssertEqual(marks.drawing, [1])
    }

    /// The same for an arrow or a circle: its drag began on slide 1.
    func testAShapeBegunBeforeASlideChangeStaysOnItsSlide() {
        var marks = PageMarks(empty: [Int]())
        var pen = PenPage()
        pen.begin(on: 0)
        marks.show(page: 1)
        let page = pen.finish(current: marks.current)
        XCTAssertEqual(page, 0)
        marks.commit(marks.drawing(on: page) + [42], on: page)
        XCTAssertEqual(marks.drawing(on: 0), [42])
        XCTAssertEqual(marks.drawing(on: 1), [])
        XCTAssertEqual(marks.current, 1, "the slide showing doesn't change")
    }

    func testNoSlideChangeIsTheUsualCase() {
        var marks = PageMarks(empty: [Int]())
        var pen = PenPage()
        pen.begin(on: 0)
        finish(&marks, canvas: [5], pen: &pen, current: 0)
        XCTAssertEqual(marks.drawing, [5])
        XCTAssertEqual(pen.finish(current: 3), 3, "no beginning seen: the slide showing")
    }

    func testMergeTakesOnlyNewStrokesAndOnlyTheEraserRemoves() {
        let m = InkMerge.merge(slide: [1, 2], canvas: [2, 3, 9], erasing: false, ignore: [9], id: { $0 })
        XCTAssertEqual(m.strokes, [1, 2, 3], "a canvas that is behind doesn't remove marks; ignored ones don't come back")
        XCTAssertEqual(m.added, [3])
        let e = InkMerge.merge(slide: [1, 2], canvas: [2], erasing: true, ignore: Set<Int>(), id: { $0 })
        XCTAssertEqual(e.strokes, [2])
        XCTAssertEqual(e.added, [])
    }
}

final class SavedMarksTests: XCTestCase {
    func testMarksFileRoundTrip() {
        let pages: [Int: Data] = [0: Data([1, 2, 3]), 7: Data([9])]
        XCTAssertEqual(MarksFile.decode(MarksFile.encode(pages)), pages)
        XCTAssertEqual(MarksFile.decode(MarksFile.encode([0: Data()])), [:], "empty slides aren't kept")
    }

    func testDamagedMarksFileOpensClean() {
        XCTAssertEqual(MarksFile.decode(nil), [:])
        XCTAssertEqual(MarksFile.decode(Data("not json".utf8)), [:])
        XCTAssertEqual(MarksFile.decode(Data(#"{"pages":{"-1":"AQ==","x":"AQ==","2":"%%%","3":"AQ=="}}"#.utf8)), [3: Data([1])])
    }

    func testMarksFileName() {
        XCTAssertEqual(MarksFile.fileName(forDeck: "Chest CT.pdf"), "Chest CT.pdf.marks")
        XCTAssertEqual(MarksFile.fileName(forDeck: "a/b:c"), "a-b-c.marks")
        XCTAssertEqual(MarksFile.fileName(forDeck: "  "), "Deck.marks")
    }

    /// Saved, then a new PageMarks (the app opened again): every slide's marks come back, with nothing to undo.
    func testSavedPagesComeBack() {
        var m = PageMarks(empty: [Int]())
        m.commit([1]); m.show(page: 4); m.commit([2, 3]); m.show(page: 5)
        XCTAssertTrue(m.hasMarks)
        XCTAssertEqual(m.savedPages, [0: [1], 4: [2, 3]], "only slides with marks")
        var again = PageMarks(empty: [Int]())
        XCTAssertFalse(again.hasMarks)
        again.restore(m.savedPages)
        XCTAssertEqual(again.drawing, [1])
        XCTAssertEqual(again.drawing(on: 4), [2, 3])
        XCTAssertFalse(again.canUndo, "restored marks are not an undo step")
    }
}

final class RecordingRulesTests: XCTestCase {
    let gb: Int64 = 1_000_000_000, mb: Int64 = 1_000_000

    func testRefusesToStartUnderOneGigabyte() {
        let why = RecordingSpace.beforeStart(free: 900 * mb)
        XCTAssertNotNil(why)
        XCTAssertTrue(why?.contains("900 MB") == true, why ?? "")
        XCTAssertNil(RecordingSpace.beforeStart(free: 5 * gb))
        XCTAssertNil(RecordingSpace.beforeStart(free: nil), "unknown space doesn't block")
    }

    func testWarnsThenStopsWhileRecording() {
        XCTAssertEqual(RecordingSpace.whileRecording(free: 5 * gb, written: gb, alsoPhotos: false), .fine)
        guard case .warn = RecordingSpace.whileRecording(free: 800 * mb, written: gb, alsoPhotos: false) else {
            return XCTFail("under 1 GB: warn")
        }
        guard case .stop = RecordingSpace.whileRecording(free: 299 * mb, written: gb, alsoPhotos: false) else {
            return XCTFail("under 300 MB: stop and keep the file")
        }
    }

    func testThePhotosCopyIsCounted() {
        XCTAssertEqual(RecordingSpace.whileRecording(free: 3 * gb, written: 2500 * mb, alsoPhotos: false), .fine)
        guard case .warn = RecordingSpace.whileRecording(free: 3 * gb, written: 2500 * mb, alsoPhotos: true) else {
            return XCTFail("the copy to Photos needs the video's size again")
        }
        XCTAssertTrue(RecordingSpace.photosCopyFits(free: 3 * gb, fileSize: gb))
        XCTAssertFalse(RecordingSpace.photosCopyFits(free: gb, fileSize: 900 * mb))
    }

    /// ✕ (or ⏹) while iOS is still asking to record: once capture starts it is stopped at once.
    func testStopWhileStartingStopsOnceStarted() {
        var r = RecorderPhase()
        XCTAssertTrue(r.startTapped())
        XCTAssertFalse(r.active, "starting isn't writing yet")
        XCTAssertEqual(r.stopRequested(), .whenStarted)
        XCTAssertFalse(r.started(), "capture started: stop it now")
        XCTAssertEqual(r.state, .stopping)
        r.finished()
        XCTAssertEqual(r.state, .idle)
        XCTAssertTrue(r.startTapped(), "and it can record again")
        XCTAssertTrue(r.started())
        XCTAssertEqual(r.state, .recording)
    }

    func testRecorderStates() {
        var r = RecorderPhase()
        XCTAssertEqual(r.stopRequested(), .nothing)
        XCTAssertTrue(r.startTapped())
        XCTAssertFalse(r.startTapped(), "one start at a time")
        r.failedToStart()
        XCTAssertEqual(r.state, .idle)
        _ = r.startTapped(); _ = r.started()
        r.pause(); XCTAssertEqual(r.state, .paused); XCTAssertTrue(r.active)
        r.resume(); XCTAssertEqual(r.state, .recording)
        XCTAssertEqual(r.stopRequested(), .now)
        XCTAssertEqual(r.stopRequested(), .nothing, "one stop at a time")
    }

    func testTheEndOfARecordingSaysWhereItIs() {
        let done = RecordingReport.text(file: "Chest 2026.mov", complete: true, photos: .off)
        XCTAssertTrue(done.contains("Recordings (Chest 2026.mov)"))
        XCTAssertFalse(done.contains("Photos"), "Photos is off by default: not mentioned")
        let cut = RecordingReport.text(file: "Chest 2026.mov", complete: false, photos: .off)
        XCTAssertTrue(cut.contains("may be incomplete"))
        XCTAssertTrue(cut.contains("Chest 2026.mov"), "and where it is")
        let failed = RecordingReport.text(file: "x.mov", complete: true, photos: .failed("disk full"))
        let denied = RecordingReport.text(file: "x.mov", complete: true, photos: .notAllowed)
        XCTAssertNotEqual(failed, denied, "a failure that isn't the permission says so")
        XCTAssertTrue(failed.contains("disk full"))
        XCTAssertTrue(denied.contains("allow Photos access"))
    }
}

final class LibraryRulesTests: XCTestCase {
    func testDuplicatesGetTheirOwnName() {
        var taken: Set<String> = ["Lecture.pdf"]
        let second = FileNames.unique("Lecture.pdf", exists: taken.contains)
        XCTAssertEqual(second, "Lecture (2).pdf")
        taken.insert(second)
        XCTAssertEqual(FileNames.unique("Lecture.pdf", exists: taken.contains), "Lecture (3).pdf")
        XCTAssertEqual(FileNames.unique("New.pdf", exists: taken.contains), "New.pdf")
        XCTAssertEqual(FileNames.unique("Folder", exists: { $0 == "Folder" }), "Folder (2)")
        XCTAssertEqual(FileNames.unique(".hidden", exists: { $0 == ".hidden" }), ".hidden (2)")
    }

    func testPicturesKeepTheirOrder() {
        XCTAssertEqual(FileNames.numbered(0, "b.jpg"), "001 b.jpg")
        XCTAssertEqual(FileNames.numbered(11, "a/b.jpg"), "012 a-b.jpg")
        XCTAssertLessThan(FileNames.numbered(1, "z.jpg"), FileNames.numbered(9, "a.jpg"))
    }

    func testPicturesAreDecodedAtTheSizeShown() {
        XCTAssertEqual(SlideImages.decodeSide(natural: Size(4000, 3000), pixelWidth: 2048), 2048)
        XCTAssertEqual(SlideImages.decodeSide(natural: Size(3000, 4000), pixelWidth: 1500), 2000, "upright: its height")
        XCTAssertEqual(SlideImages.decodeSide(natural: Size(8000, 6000), pixelWidth: 5000), 2560, "never over 2560")
        XCTAssertEqual(SlideImages.decodeSide(natural: Size(800, 600), pixelWidth: 2048), 800, "never over its own size")
    }

    func testTheCacheHasALimit() {
        XCTAssertEqual(SlideImages.cost(width: 2048, height: 1536), 2048 * 1536 * 4)
        XCTAssertEqual(SlideImages.costLimit(memory: 8 << 30), 256 << 20)
        XCTAssertEqual(SlideImages.costLimit(memory: 2 << 30), 128 << 20)
        XCTAssertEqual(SlideImages.costLimit(memory: 512 << 20), 64 << 20)
    }

    func testUnreadablePicturesAreCounted() {
        XCTAssertNil(SlideImages.unreadable(0, of: 5))
        XCTAssertEqual(SlideImages.unreadable(2, of: 5), "2 of 5 pictures couldn't be read and were left out.")
        XCTAssertEqual(SlideImages.unreadable(3, of: 3), "None of those 3 files could be read as pictures.")
    }
}

final class ProvisionTests: XCTestCase {
    /// A profile as it is on disk: signature bytes, the property list, more signature bytes.
    private func profile(expires: String) -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>AppIDName</key><string>Contrast Ink</string>
        <key>ExpirationDate</key><date>\(expires)</date>
        </dict></plist>
        """
        return Data([0x30, 0x82, 0x10, 0x00, 0x06, 0x09]) + Data(xml.utf8) + Data([0xA0, 0x82, 0x00, 0xFF])
    }

    func testReadsTheExpiryDate() throws {
        let d = try XCTUnwrap(Provision.expiration(profile(expires: "2026-11-20T10:00:00Z")))
        XCTAssertEqual(d, ISO8601DateFormatter().date(from: "2026-11-20T10:00:00Z"))
        XCTAssertNil(Provision.expiration(Data("no plist here".utf8)))
    }

    func testWarnsFortyEightHoursAhead() {
        let expires = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertNil(Provision.warning(expires: expires, now: expires.addingTimeInterval(-49 * 3600)))
        let w = Provision.warning(expires: expires, now: expires.addingTimeInterval(-47 * 3600))
        XCTAssertTrue(w?.contains("in 47 hours") == true, w ?? "")
        XCTAssertTrue(Provision.warning(expires: expires, now: expires.addingTimeInterval(60))?.contains("expired") == true)
        XCTAssertNil(Provision.warning(expires: nil), "no profile (App Store, Xcode): nothing")
    }
}

final class DeviceDefaultsTests: XCTestCase {
    func testAFingerDrawsOnAnIPhone() {
        XCTAssertTrue(Settings.decode(nil, isPhone: true).fingerDraws, "an iPhone has no Pencil")
        XCTAssertFalse(Settings.decode(nil, isPhone: false).fingerDraws, "an iPad: the Pencil draws, a finger swipes")
        XCTAssertTrue(Settings.decode(Data(#"{"color": 2}"#.utf8), isPhone: true).fingerDraws, "an older saved copy too")
        XCTAssertFalse(Settings.decode(Data(#"{"fingerDraws": false}"#.utf8), isPhone: true).fingerDraws,
                       "switched off on purpose: stays off")
    }

    func testPhotosIsOffUnlessSwitchedOn() throws {
        XCTAssertFalse(Settings().alsoSaveToPhotos, "iCloud Photos would upload patient images")
        var s = Settings(); s.alsoSaveToPhotos = true
        XCTAssertTrue(Settings.decode(try JSONEncoder().encode(s)).alsoSaveToPhotos)
    }

    func testTheLaserKeyAndReturnAreInTheTable() {
        XCTAssertEqual(Keys.action(for: "l"), .laser)
        XCTAssertEqual(Keys.action(for: "return"), .next)
    }
}

final class PadCheckFormatTests: XCTestCase {
    /// SHA-256 of the spec's PC public key; the check is its first 8 bytes.
    func testTheCheckHasSixteenHexDigits() {
        let hash = Data([0x6F, 0xC6, 0x6A, 0x90, 0x48, 0x61, 0x71, 0xCA, 0x69, 0xB5, 0x12, 0xBE, 0x18, 0x5D, 0x66, 0xA7,
                         0x63, 0xA6, 0x8F, 0xF2, 0xD3, 0x4C, 0xDA, 0x63, 0x9E, 0x78, 0xCF, 0xF9, 0xE9, 0x8C, 0xAE, 0xAB])
        XCTAssertEqual(PadCheckFormat.format(hash: hash), "6FC6-6A90-4861-71CA")
        XCTAssertEqual(PadCheckFormat.format(hash: Data(repeating: 0x0A, count: 32)), "0A0A-0A0A-0A0A-0A0A", "leading zeros kept")
    }
}

final class SplitViewCropTests: XCTestCase {
    /// The app in the right part of Split View: its window starts 400 points in on a 1000 x 800 display, and the frame
    /// is the whole display at 2 pixels a point. The slide must be cut from the window's place, not the display's left.
    func testTheCropFollowsAWindowThatIsSmallerAndMoved() {
        let stage = Rect(0, 100, 600, 450)                       // in the window (600 x 800)
        let onScreen = Crop.onScreen(stageInWindow: stage, windowOrigin: Pt(400, 0))
        XCTAssertEqual(onScreen, Rect(400, 100, 600, 450))
        let px = Crop.pixelRect(stage: onScreen, screen: Size(1000, 800), image: Size(2000, 1600))
        XCTAssertEqual(px, Rect(800, 1600 - 200 - 900, 1200, 900), "800 pixels in, not 0")
        // what the old geometry gave (the window's own size as the display): the left of the display, squeezed
        let old = Crop.pixelRect(stage: stage, screen: Size(600, 800), image: Size(2000, 1600))
        XCTAssertNotEqual(old.x, px.x)
    }
}
