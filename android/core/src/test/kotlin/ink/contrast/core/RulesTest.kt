package ink.contrast.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ShapesTest {
    @Test fun arrowEndsAtTipWithTwoHeadSides() {
        val a = Shapes.arrow(Pt(0f, 0f), Pt(100f, 0f), 6f)
        assertEquals(5, a.size)
        assertEquals(Pt(100f, 0f), a[1]); assertEquals(Pt(100f, 0f), a[3])
        assertTrue(a[2].x < 100f && a[4].x < 100f)
        assertEquals(a[2].y, -a[4].y, 1e-4f)
    }

    @Test fun arrowHeadNeverPastHalfTheArrow() {
        val a = Shapes.arrow(Pt(0f, 0f), Pt(10f, 0f), 10f)
        assertTrue(10f - a[2].x <= 5f + 1e-4f)
    }

    @Test fun tinyArrowIsTwoPoints() = assertEquals(2, Shapes.arrow(Pt(5f, 5f), Pt(5.5f, 5f), 3f).size)

    @Test fun ovalIsClosedAndInsideItsBox() {
        val o = Shapes.oval(Pt(100f, 50f), Pt(0f, 0f))
        assertEquals(o.first(), o.last())
        assertTrue(o.all { it.x in -0.01f..100.01f && it.y in -0.01f..50.01f })
    }

    @Test fun squareKeepsStartCornerAndLargerSide() {
        assertEquals(Pt(40f, 40f), Shapes.square(Pt(10f, 10f), Pt(40f, 20f)))
        assertEquals(Pt(-30f, -30f), Shapes.square(Pt(10f, 10f), Pt(0f, -30f)))
    }

    @Test fun tapIsTooSmall() {
        assertTrue(Shapes.tooSmall(Pt(0f, 0f), Pt(3f, 3f)))
        assertFalse(Shapes.tooSmall(Pt(0f, 0f), Pt(10f, 0f)))
    }

    @Test fun eraserTouchesNearALineOnly() {
        val line = listOf(Pt(0f, 0f), Pt(100f, 0f))
        assertTrue(Shapes.touches(line, Pt(50f, 8f), 10f))
        assertFalse(Shapes.touches(line, Pt(50f, 20f), 10f))
        assertFalse(Shapes.touches(line, Pt(130f, 0f), 10f))   // past the end
        assertTrue(Shapes.touches(listOf(Pt(5f, 5f)), Pt(8f, 5f), 4f))
    }
}

class FadeTest {
    @Test fun holdsThenFadesThenGone() {
        assertEquals(1f, Fade.opacity(0))
        assertEquals(1f, Fade.opacity(2000))
        assertEquals(0.5f, Fade.opacity(2500), 1e-4f)
        assertEquals(0f, Fade.opacity(3000))
        assertEquals(0f, Fade.opacity(60_000))
    }
}

class MarksTest {
    @Test fun undoAndClear() {
        val m = Marks(emptyList<Int>())
        m.commit(listOf(1)); m.commit(listOf(1, 2))
        m.clear()
        assertEquals(emptyList<Int>(), m.drawing)
        assertTrue(m.undo()); assertEquals(listOf(1, 2), m.drawing)
        assertTrue(m.undo()); assertEquals(listOf(1), m.drawing)
        assertTrue(m.undo()); assertEquals(emptyList<Int>(), m.drawing)
        assertFalse(m.undo())
    }

    @Test fun quietChangesAreNotSteps() {
        val m = Marks(emptyList<Int>())
        m.commit(listOf(1)); m.replaceQuietly(emptyList())
        m.commit(listOf(2))
        m.undo(); assertEquals(emptyList<Int>(), m.drawing)
    }

    @Test fun undoSkipsStepsThatOnlyBringBackFadedMarks() {
        val m = Marks(emptyList<Int>())
        m.commit(listOf(1)); m.commit(listOf(1, 7)); m.replaceQuietly(listOf(1))   // 7 faded away
        m.undo { d -> d.filter { it != 7 } }
        assertEquals(emptyList<Int>(), m.drawing)
    }

    @Test fun unchangedCommitIsNotAStepAndHistoryIsCapped() {
        val m = Marks(0, historyLimit = 3)
        m.commit(0); assertFalse(m.canUndo)
        for (i in 1..10) m.commit(i)
        var steps = 0
        while (m.undo()) steps++
        assertEquals(3, steps); assertEquals(7, m.drawing)
    }
}

class SettingsTest {
    @Test fun damagedOrOldSettingsAreSafe() {
        assertEquals(Settings(), Settings.decode(null))
        assertEquals(Settings(), Settings.decode("not settings"))
        val s = Settings.decode("color=99\nwidth=-4\ntool=LASER\nfadingInk=true")
        assertEquals(Settings.COLORS.size - 1, s.color)
        assertEquals(0, s.width)
        assertEquals(Tool.PEN, s.tool)
        assertTrue(s.fadingInk)
    }

    @Test fun roundTrip() {
        val s = Settings(tool = Tool.OVAL, color = 3, width = 2, fingerDraws = false, stylusEraserEnd = false)
        assertEquals(s, Settings.decode(s.encode()))
    }

    @Test fun paletteMatchesTheOtherApps() {
        assertEquals(0xFFFF3B30.toInt(), Settings.COLORS[0])
        assertEquals(6, Settings.COLORS.size)
        assertEquals(30f, Settings.highlighterWidth(6f))
    }

    @Test fun clockFormat() {
        assertEquals("0:00", clock(0))
        assertEquals("4:05", clock(245_000))
        assertEquals("1:04:05", clock(3_845_000))
    }
}

class RecordingTest {
    @Test fun phoneInPortraitKeepsItsShapeInMultiplesOf16() {
        val (w, h) = Recording.videoSize(1080, 2400)
        assertEquals(0, w % 16); assertEquals(0, h % 16)
        assertTrue(h <= 1920)
        assertEquals(1080f / 2400f, w.toFloat() / h, 0.02f)
    }

    @Test fun smallScreenIsNotMadeBigger() {
        assertEquals(720 to 1280, Recording.videoSize(720, 1280))
    }

    @Test fun anEncoderThatRefusesTheSizeGetsASmallerOne() {
        // a common limit: nothing over 1920 x 1088
        val (w, h) = Recording.videoSize(2560, 1600) { a, b -> maxOf(a, b) <= 1920 && minOf(a, b) <= 1088 }
        assertTrue(w <= 1920 && h <= 1088)
        assertEquals(1600f / 2560f, h.toFloat() / w, 0.02f)
    }

    @Test fun anEncoderThatRefusesEverythingStillGetsTheSmallest() {
        assertEquals(640 to 400, Recording.videoSize(2560, 1600) { _, _ -> false })
    }

    @Test fun twoRecordingsInTheSameSecondDontOverwriteEachOther() {
        val taken = setOf("Lecture 2026-11-12 093015.mp4", "Lecture 2026-11-12 093015 (2).mp4")
        assertEquals("Lecture 2026-11-12 093015 (3).mp4", Recording.fileName("2026-11-12 093015") { it in taken })
        assertEquals("Lecture 2026-11-12 093016.mp4", Recording.fileName("2026-11-12 093016") { it in taken })
    }
}

class ButtonNamesSettingTest {
    @Test fun onUnlessSwitchedOffAndRemembered() {
        assertTrue(Settings().showButtonNames)
        assertTrue("an older saved copy keeps the names", Settings.decode("tool=PEN\ncolor=2").showButtonNames)
        assertFalse(Settings.decode(Settings(showButtonNames = false).encode()).showButtonNames)
    }
}
