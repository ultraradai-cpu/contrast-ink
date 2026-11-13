package ink.contrast.core

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
        assertFalse(CleanRecording.near(0xFF000000.toInt(), bar))   // black (a CT or MR image) is not the toolbar
        assertFalse(CleanRecording.near(0xFFFFFFFF.toInt(), bar))
    }

    @Test fun toolbarSeenWhenMostOfItsBoxIsItsColour() {
        val white = 0xFFFFFFFF.toInt()
        assertTrue(CleanRecording.toolbarSeen(IntArray(100) { if (it < 70) bar else white }, bar))
        assertFalse(CleanRecording.toolbarSeen(IntArray(100) { if (it < 20) bar else white }, bar))
        assertFalse(CleanRecording.toolbarSeen(IntArray(0), bar))
    }

    @Test fun startsUnknown() = assertEquals(Mode.UNKNOWN, Detector().mode)

    @Test fun contentSmallerThanTheScreenIsOneApp() {
        val d = Detector()
        assertEquals(Mode.SINGLE_APP, d.contentSize(1080, 1200, 1080, 2400))
        assertEquals("no frame changes a decision by size", Mode.SINGLE_APP, d.frame(true, 10))
        assertTrue(d.settled(0))
    }

    @Test fun contentTheScreenSizeDecidesNothing() {
        val d = Detector()
        assertEquals(Mode.UNKNOWN, d.contentSize(1080, 2400, 1080, 2400))
        assertEquals(Mode.UNKNOWN, d.contentSize(2400, 1080, 1080, 2400))   // turned
    }

    @Test fun toolbarInTheFrameIsTheEntireScreen() = assertEquals(Mode.ENTIRE_SCREEN, Detector().frame(true, 50))

    @Test fun noToolbarInTheFirstFrameIsOneApp() = assertEquals(Mode.SINGLE_APP, Detector().frame(false, 50))

    @Test fun toolbarSoonAfterwardsCorrectsToTheEntireScreen() {
        val d = Detector(settleMs = 1500)
        d.frame(false, 50)
        assertEquals(Mode.ENTIRE_SCREEN, d.frame(true, 400))
        assertEquals("entire screen stays", Mode.ENTIRE_SCREEN, d.frame(false, 600))
    }

    @Test fun afterSettlingADarkSlideDoesNotChangeIt() {
        val d = Detector(settleMs = 1500)
        d.frame(false, 50)
        assertFalse(d.settled(1000)); assertTrue(d.settled(1600))
        assertEquals(Mode.SINGLE_APP, d.frame(true, 3000))
    }

    @Test fun firstFrameLateStillDecides() = assertEquals(Mode.SINGLE_APP, Detector(settleMs = 1500).frame(false, 5000))
}
