package ink.contrast

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import android.content.ContentUris
import android.media.MediaMetadataRetriever
import android.provider.MediaStore
import java.io.File
import java.util.regex.Pattern

/**
 * The real app on an Android emulator, over another app (a stand-in in the test package): a tap goes through while drawing is
 * off, every tool draws, undo / clear / eraser work. The number of marks is checked after every step, and a
 * screenshot of every step is kept for a person to look at (CI uploads them as "android-screenshots").
 */
@RunWith(AndroidJUnit4::class)
class ContrastInkTest {
    private val inst = InstrumentationRegistry.getInstrumentation()
    private val device = UiDevice.getInstance(inst)
    private val ctx = inst.targetContext
    private val shots = File(ctx.getExternalFilesDir(null), "shots")
    private val pkg = ctx.packageName

    @Before fun setUp() {
        device.executeShellCommand("appops set $pkg SYSTEM_ALERT_WINDOW allow")
        device.executeShellCommand("pm grant $pkg android.permission.POST_NOTIFICATIONS")
        device.executeShellCommand("pm grant $pkg android.permission.RECORD_AUDIO")
        shots.mkdirs()
        // started as a person starts it: "Start Contrast Ink" on the setup screen (Android 14 lets an app start its
        // drawing layer only while the app is on screen)
        device.executeShellCommand("am start -W -n $pkg/.MainActivity")
        val start = device.wait(Until.findObject(By.text("Start Contrast Ink")), 8000)
        assertNotNull("the setup screen opens", start)
        start.click()
        assertNotNull("the toolbar appears", device.wait(Until.findObject(By.desc("Draw on / off")), 8000))
        // then another app in front (a stand-in in the test package): Contrast Ink must draw over it, and let its
        // taps through
        device.executeShellCommand("am start -W -n ${inst.context.packageName}/ink.contrast.OtherAppActivity")
        assertNotNull("the other app opens", device.wait(Until.findObject(By.text("Not tapped")), 8000))
        assertNotNull("the toolbar stays over the other app", device.wait(Until.findObject(By.desc("Draw on / off")), 4000))
    }

    @After fun tearDown() {
        inst.runOnMainSync { InkService.running?.quit() }
    }

    private fun shot(name: String) { device.takeScreenshot(File(shots, "$name.png")) }

    private fun marks(): Int {
        var n = -1
        inst.runOnMainSync { n = InkService.running?.ink?.markCount ?: -1 }
        return n
    }

    private fun press(name: String): UiObject2 {
        val b = device.wait(Until.findObject(By.desc(name)), 4000)
        assertNotNull("toolbar button \"$name\"", b)
        b.click()
        device.waitForIdle()
        Thread.sleep(300)
        return b
    }

    /** A drag in the lower part of the screen (the toolbar is at the top), as fractions of the screen. */
    private fun drag(x1: Float, y1: Float, x2: Float, y2: Float) {
        val w = device.displayWidth
        val h = device.displayHeight
        device.swipe((x1 * w).toInt(), (y1 * h).toInt(), (x2 * w).toInt(), (y2 * h).toInt(), 40)
        device.waitForIdle()
        Thread.sleep(400)
    }

    private fun drawing(): Boolean {
        var on = false
        inst.runOnMainSync { on = InkService.running?.drawing == true }
        return on
    }

    @Test fun drawsOverAnotherAppAndLetsTapsThrough() {
        shot("01 toolbar over another app")
        assertEquals("starts with no marks", 0, marks())
        assertTrue("starts with drawing off", !drawing())

        // drawing off: a tap reaches the app below (Android 12+ blocks this for an overlay over 80% opaque)
        device.click(device.displayWidth / 2, (device.displayHeight * 0.75).toInt())
        val tapped = device.wait(Until.hasObject(By.text("Tapped")), 4000)
        shot("02 tap went through to the other app")
        assertTrue("with drawing off, a tap goes through to the app below", tapped)

        press("Draw on / off")
        assertTrue("✎ switches drawing on", drawing())
        drag(0.15f, 0.55f, 0.85f, 0.65f)
        assertEquals("pen: one line", 1, marks())
        shot("03 pen line")

        press("Arrow")
        drag(0.2f, 0.85f, 0.5f, 0.7f)
        assertEquals("arrow: one more mark", 2, marks())
        press("Circle")
        drag(0.55f, 0.72f, 0.9f, 0.88f)
        assertEquals("circle: one more mark", 3, marks())
        press("Green (3)")
        press("Highlighter")
        drag(0.1f, 0.5f, 0.6f, 0.5f)
        assertEquals("highlighter: one more mark", 4, marks())
        shot("04 arrow circle highlighter")

        press("Undo")
        assertEquals("undo takes the last mark", 3, marks())
        press("Clear all marks")
        assertEquals("clear takes every mark", 0, marks())
        shot("05 cleared")
        press("Undo")
        assertEquals("undo brings the cleared marks back", 3, marks())
        shot("06 undo brought them back")

        press("Eraser")
        drag(0.5f, 0.56f, 0.5f, 0.63f)   // across the pen line only (at x 0.5 it is at y 0.6; the arrow tip is at 0.7)
        assertEquals("the eraser removes the mark it touches", 2, marks())
        shot("07 erased the pen line")

        press("Draw on / off")
        assertTrue("✎ again switches drawing off", !drawing())
        assertEquals("marks stay when drawing goes off", 2, marks())
        press("Make the toolbar small")
        shot("08 small toolbar, drawing off, marks stay")
        assertNotNull("small toolbar keeps the record button", device.findObject(By.desc("Record the screen")))
        press("Make the toolbar big")
    }

    /** Android's "start recording?" question: the whole screen, then start (its wording differs between versions). */
    private fun answerRecordingQuestion() {
        val single = device.wait(Until.findObject(By.text(Pattern.compile("(?i)a single app|one app"))), 3000)
        if (single != null) {
            single.click()
            device.wait(Until.findObject(By.text(Pattern.compile("(?i)entire screen|full screen"))), 3000)?.click()
        }
        val start = device.wait(Until.findObject(By.text(Pattern.compile("(?i)start( now| recording)?|next"))), 8000)
        assertNotNull("Android asks before recording, with a Start button", start)
        start.click()
        // some versions ask in two steps
        device.wait(Until.findObject(By.text(Pattern.compile("(?i)start( now| recording)?"))), 1500)?.click()
    }

    @Test fun recordsPausesResumesAndSavesToTheGallery() {
        device.executeShellCommand("am start -W -n ${inst.context.packageName}/ink.contrast.OtherAppActivity")
        device.wait(Until.findObject(By.text("Not tapped")), 8000)

        press("Record the screen")
        answerRecordingQuestion()
        assertNotNull("recording: ⏹ replaces ⏺", device.wait(Until.findObject(By.desc("Stop recording")), 8000))
        assertTrue("recording", recorder { it.active })
        press("Draw on / off")
        drag(0.15f, 0.55f, 0.85f, 0.65f)
        Thread.sleep(1500)
        shot("10 recording")

        press("Pause recording")
        assertTrue("paused", recorder { it.paused })
        Thread.sleep(1000)
        press("Resume recording")
        assertTrue("resumed", recorder { it.active && !it.paused })
        drag(0.15f, 0.75f, 0.85f, 0.7f)
        Thread.sleep(1500)

        press("Stop recording")
        val saved = device.wait(Until.findObject(By.desc(Pattern.compile("Saved to the Gallery: .*"))), 30000)
        shot("11 saved")
        assertNotNull("the video is saved to the Gallery (the toolbar says where)", saved)
        val name = saved!!.contentDescription.toString().substringAfterLast('/')
        // it is really there, complete, and plays for a few seconds
        val uri = ctx.contentResolver.query(MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
            arrayOf(MediaStore.Video.Media._ID), "${MediaStore.Video.Media.DISPLAY_NAME} = ?", arrayOf(name), null)!!.use {
            assertTrue("\"$name\" is in the Gallery", it.moveToFirst())
            ContentUris.withAppendedId(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, it.getLong(0))
        }
        val ms = MediaMetadataRetriever().run {
            setDataSource(ctx, uri)
            val d = extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLong() ?: 0
            release(); d
        }
        assertTrue("the video plays for a few seconds (it is ${ms} ms)", ms in 1500..60000)
        ctx.contentResolver.delete(uri, null, null)
    }

    private fun recorder(check: (ScreenRecorder) -> Boolean): Boolean {
        var ok = false
        inst.runOnMainSync { ok = InkService.running?.recorder?.let(check) == true }
        return ok
    }
}
