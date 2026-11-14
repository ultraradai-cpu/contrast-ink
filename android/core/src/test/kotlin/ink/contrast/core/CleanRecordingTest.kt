package ink.contrast.core

import ink.contrast.core.CleanRecording.AfterShown
import ink.contrast.core.CleanRecording.Box
import ink.contrast.core.CleanRecording.Detector
import ink.contrast.core.CleanRecording.Mode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CleanRecordingTest {
    private fun assertBox(expected: Box, actual: Box) {
        assertEquals(expected.left, actual.left, 0.01f); assertEquals(expected.top, actual.top, 0.01f)
        assertEquals(expected.width, actual.width, 0.01f); assertEquals(expected.height, actual.height, 0.01f)
    }

    @Test fun sameShapeFillsTheFrame() = assertBox(Box(0f, 0f, 720f, 1600f), CleanRecording.fit(1080, 2400, 720, 1600))

    @Test fun widerContentGetsBarsAboveAndBelow() = assertBox(Box(0f, 300f, 1000f, 500f), CleanRecording.fit(2000, 1000, 1000, 1100))

    @Test fun tallerContentGetsBarsAtTheSides() = assertBox(Box(250f, 0f, 500f, 1000f), CleanRecording.fit(500, 1000, 1000, 1000))

    @Test fun fullScreenAppMarksLineUpOneToOne() {
        val (ink, clip) = CleanRecording.inkPlacement(1080, 2400, 1080, 2400, 720, 1600)
        assertBox(Box(0f, 0f, 720f, 1600f), ink)
        assertBox(ink, clip)
    }

    @Test fun unknownAppSizeIsTakenAsTheScreen() {
        val (ink, _) = CleanRecording.inkPlacement(1080, 2400, 0, 0, 1080, 2400)
        assertBox(Box(0f, 0f, 1080f, 2400f), ink)
    }

    @Test fun upperHalfOfASplitScreenIsCentredAndClipped() {
        // the app is the top half of a 1000 x 2000 screen, recorded into a 1000 x 2000 frame: it keeps its size (the
        // frame's width is the limit) and is centred; the screen-sized ink layer goes with it, clipped to the app
        val (ink, clip) = CleanRecording.inkPlacement(1000, 2000, 1000, 1000, 1000, 2000)
        assertBox(Box(0f, 500f, 1000f, 1000f), clip)
        assertBox(Box(0f, 500f, 1000f, 2000f), ink)
    }

    @Test fun smallerAppIsScaledUpAndTheInkWithIt() {
        val (ink, clip) = CleanRecording.inkPlacement(1000, 2000, 500, 1000, 1000, 2000)
        assertBox(Box(0f, 0f, 1000f, 2000f), clip)
        assertBox(Box(0f, 0f, 2000f, 4000f), ink)   // twice the size, as the app is shown twice its size
    }

    private val bar = 0xFF141A22.toInt()

    @Test fun toolbarColourWithinTolerance() {
        assertTrue(CleanRecording.near(0xFF1A2028.toInt(), bar))
        assertFalse(CleanRecording.near(0xFF000000.toInt(), bar))
        assertFalse(CleanRecording.near(0xFFFFFFFF.toInt(), bar))
    }

    // ---------- the beacon ----------

    private val magenta = 0xFFFF00FF.toInt()
    private val cyan = 0xFF00FFFF.toInt()
    private val yellow = 0xFFFFFF00.toInt()

    /** A [w] x [h] strip whose three thirds are [a], [b], [c]. */
    private fun strip(w: Int, h: Int, a: Int, b: Int, c: Int) = IntArray(w * h) { i ->
        val x = i % w
        when { x < w / 3 -> a; x < 2 * w / 3 -> b; else -> c }
    }

    /** As a video encoder leaves it: each channel moved by up to [by], here and there. */
    private fun compressed(p: IntArray, by: Int) = IntArray(p.size) { i ->
        val d = ((i * 7919) % (2 * by + 1)) - by
        fun ch(v: Int) = (v + d).coerceIn(0, 255)
        (0xFF shl 24) or (ch((p[i] shr 16) and 0xFF) shl 16) or (ch((p[i] shr 8) and 0xFF) shl 8) or ch(p[i] and 0xFF)
    }

    @Test fun theBeaconIsSeen() {
        assertTrue(CleanRecording.beaconSeen(strip(90, 12, magenta, cyan, yellow), 90))
        assertTrue("after video compression", CleanRecording.beaconSeen(compressed(strip(90, 12, magenta, cyan, yellow), 40), 90))
        // blurred edges between the colours and along the top and bottom don't matter
        val blurred = strip(90, 12, magenta, cyan, yellow).also { p ->
            for (x in 0 until 90) { p[x] = 0xFF808080.toInt(); p[11 * 90 + x] = 0xFF808080.toInt() }
            for (y in 0 until 12) for (x in intArrayOf(29, 30, 59, 60)) p[y * 90 + x] = 0xFF808080.toInt()
        }
        assertTrue(CleanRecording.beaconSeen(blurred, 90))
    }

    /** The old check (the toolbar's own dark colour) took these for the toolbar: a one-app video got no marks. */
    @Test fun aDarkSlideIsNotTheBeacon() {
        val dark = 0xFF1E1E1E.toInt()
        assertTrue("the slide is within the old tolerance of the toolbar's colour", CleanRecording.near(dark, bar))
        assertFalse(CleanRecording.beaconSeen(IntArray(90 * 12) { dark }, 90))
        assertFalse("not even exactly the toolbar's colour", CleanRecording.beaconSeen(IntArray(90 * 12) { bar }, 90))
        assertFalse(CleanRecording.beaconSeen(IntArray(90 * 12) { 0xFF000000.toInt() }, 90))
        assertFalse(CleanRecording.beaconSeen(IntArray(90 * 12) { 0xFFFFFFFF.toInt() }, 90))
    }

    @Test fun onlyTheThreeColoursInTheirOrderAreTheBeacon() {
        assertFalse("one colour", CleanRecording.beaconSeen(IntArray(90 * 12) { magenta }, 90))
        assertFalse("another order", CleanRecording.beaconSeen(strip(90, 12, cyan, magenta, yellow), 90))
        assertFalse("red, green, blue", CleanRecording.beaconSeen(strip(90, 12, 0xFFFF0000.toInt(), 0xFF00FF00.toInt(), 0xFF0000FF.toInt()), 90))
        assertFalse("pale versions (a pastel slide)", CleanRecording.beaconSeen(strip(90, 12, 0xFFFFB0FF.toInt(), 0xFFB0FFFF.toInt(), 0xFFFFFFB0.toInt()), 90))
        assertFalse("nothing to look at", CleanRecording.beaconSeen(IntArray(0), 0))
    }

    // ---------- working out what Android records ----------

    @Test fun startsUnknown() = assertEquals(Mode.UNKNOWN, Detector().mode)

    @Test fun contentSmallerThanTheScreenIsOneApp() {
        val d = Detector()
        assertEquals(Mode.SINGLE_APP, d.contentSize(1080, 1200, 1080, 2400))
        assertTrue("said by size (split screen or a window)", d.bySize)
        assertEquals("no frame changes a decision by size", Mode.SINGLE_APP, d.frame(true, 10))
        assertTrue(d.settled(0))
    }

    @Test fun contentTheScreenSizeDecidesNothing() {
        val d = Detector()
        assertEquals(Mode.UNKNOWN, d.contentSize(1080, 2400, 1080, 2400))
        assertEquals(Mode.UNKNOWN, d.contentSize(2400, 1080, 1080, 2400))   // turned
    }

    @Test fun beaconInTheFrameIsTheEntireScreen() = assertEquals(Mode.ENTIRE_SCREEN, Detector().frame(true, 50))

    @Test fun noBeaconInTheFirstFrameIsOneApp() = assertEquals(Mode.SINGLE_APP, Detector().frame(false, 50))

    @Test fun beaconSoonAfterwardsCorrectsToTheEntireScreen() {
        val d = Detector(settleMs = 1500)
        d.frame(false, 50)
        assertEquals(Mode.ENTIRE_SCREEN, d.frame(true, 400))
        assertEquals("entire screen stays", Mode.ENTIRE_SCREEN, d.frame(false, 600))
    }

    @Test fun afterSettlingNothingChangesIt() {
        val d = Detector(settleMs = 1500)
        d.frame(false, 50)
        assertFalse(d.settled(1000)); assertTrue(d.settled(1600))
        assertEquals(1551L, d.settlesAt())
        assertEquals(Mode.SINGLE_APP, d.frame(true, 3000))
    }

    /**
     * The first frame came 5 s after the start (the mic and the encoder took their time). Before, the time to look
     * ran from the start: by then it was over, so the compositor never looked (it asked [Detector.settled] first) and
     * the whole video had no marks. Now it runs from the first frame looked at: the compositor's own sequence.
     */
    @Test fun firstFrameLateStillDecides() {
        val d = Detector(settleMs = 1500)
        assertFalse("not settled before any frame was looked at, however late", d.settled(5000))
        assertEquals(Mode.SINGLE_APP, d.frame(false, 5000))
        assertFalse("and it can still be corrected for a moment", d.settled(6000))
        assertEquals(Mode.ENTIRE_SCREEN, d.frame(true, 6000))
        assertTrue(d.settled(6600))
    }

    @Test fun noFrameAtAllDrawsTheMarksToBeSafe() {
        val d = Detector(giveUpMs = 4000)
        assertEquals("not yet", Mode.UNKNOWN, d.noLook(3000))
        assertEquals("then the marks go into the video", Mode.SINGLE_APP, d.noLook(4000))
        assertTrue(d.guessed)
        assertEquals(CleanRecording.modeNotice(Mode.SINGLE_APP, bySize = false, guessed = true)!!.startsWith("Couldn't see yet"), true)
        // a frame that comes later still decides
        assertEquals(Mode.ENTIRE_SCREEN, d.frame(true, 9000))
        assertFalse(d.guessed)
    }

    @Test fun splitScreenIsSaidToMisplaceTheMarks() {
        assertTrue(CleanRecording.modeNotice(Mode.SINGLE_APP, bySize = true, guessed = false)!!.contains("split screen"))
        assertFalse(CleanRecording.modeNotice(Mode.SINGLE_APP, bySize = false, guessed = false)!!.contains("split screen"))
        assertEquals(null, CleanRecording.modeNotice(Mode.UNKNOWN, bySize = false, guessed = false))
    }

    @Test fun noMarksWhileTheRecordedAppIsOutOfSight() {
        assertTrue(CleanRecording.drawInk(Mode.SINGLE_APP, contentVisible = true))
        assertFalse("its frozen last picture gets no new marks", CleanRecording.drawInk(Mode.SINGLE_APP, contentVisible = false))
        assertFalse(CleanRecording.drawInk(Mode.ENTIRE_SCREEN, contentVisible = true))
        assertFalse(CleanRecording.drawInk(Mode.UNKNOWN, contentVisible = true))
    }

    /** Back in sight with a black picture held (Android 14, a still slide): ask again, then no marks over black. */
    @Test fun noMarksOverAHeldBlackPictureWhenTheAppComesBack() {
        assertEquals(AfterShown.DRAW_MARKS, CleanRecording.afterShown(haveFrame = true, Mode.SINGLE_APP, heldBlack = false, asks = 0))
        assertEquals(AfterShown.ASK_AGAIN, CleanRecording.afterShown(haveFrame = true, Mode.SINGLE_APP, heldBlack = true, asks = 0))
        assertEquals(AfterShown.ASK_AGAIN, CleanRecording.afterShown(true, Mode.SINGLE_APP, true, CleanRecording.PICTURE_ASKS - 1))
        assertEquals("never marks over black, however long", AfterShown.NO_MARKS,
            CleanRecording.afterShown(true, Mode.SINGLE_APP, true, CleanRecording.PICTURE_ASKS))
        assertEquals(AfterShown.NO_MARKS, CleanRecording.afterShown(true, Mode.SINGLE_APP, true, 100))
        assertEquals("a black slide before it went out of sight: its marks come back", AfterShown.DRAW_MARKS,
            CleanRecording.afterShown(true, Mode.SINGLE_APP, heldBlack = true, asks = 0, blackBefore = true))
        assertEquals("the entire screen has its marks in the picture", AfterShown.DRAW_MARKS,
            CleanRecording.afterShown(true, Mode.ENTIRE_SCREEN, true, 0))
        assertTrue(CleanRecording.isBlack(intArrayOf(0xFF000000.toInt(), 0xFF080808.toInt())))
        assertFalse("a dark slide (#141A22) isn't black", CleanRecording.isBlack(intArrayOf(0xFF000000.toInt(), 0xFF141A22.toInt())))
        assertFalse(CleanRecording.isBlack(IntArray(0)))
    }

    @Test fun theLaserAloneIsCopiedLessOften() {
        assertEquals(33L, CleanRecording.snapshotDelay(1000, 1000, onlyLaser = false))
        assertEquals(66L, CleanRecording.snapshotDelay(1000, 1000, onlyLaser = true))
        assertEquals(0L, CleanRecording.snapshotDelay(1000, 2000, onlyLaser = true))
    }
}
