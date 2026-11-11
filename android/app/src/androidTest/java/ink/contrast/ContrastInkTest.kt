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
import java.io.File
import java.util.regex.Pattern

/**
 * The real app on an Android emulator, over another app (Android's Settings): a tap goes through while drawing is
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
        shots.mkdirs()
        // another app in front: Contrast Ink must draw over it, and let its taps through
        device.executeShellCommand("am start -W -a android.settings.SETTINGS")
        device.wait(Until.hasObject(By.pkg("com.android.settings").depth(0)), 8000)
        inst.runOnMainSync { InkService.start(ctx) }
        assertNotNull("the toolbar appears", device.wait(Until.findObject(By.desc("Draw on / off")), 8000))
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
        shot("01 toolbar over Settings")
        assertEquals("starts with no marks", 0, marks())
        assertTrue("starts with drawing off", !drawing())

        // drawing off: a tap reaches the app below (Android 12+ blocks this for an overlay over 80% opaque)
        val home = Pattern.compile("Network.*|Connected devices|Apps|Notifications|Battery|Storage|Sound.*|Display|" +
            "Wallpaper.*|Accessibility|Security.*|Privacy|Location|Safety.*|Passwords.*|System|About.*")
        device.wait(Until.hasObject(By.text(home)), 6000)
        val items = device.findObjects(By.text(home))
        // one below the toolbar (it starts near the top), and another to tell that Settings moved on
        val target = items.firstOrNull { it.visibleCenter.y > device.displayHeight * 0.45 }
        assertNotNull("Settings lists items: ${items.map { it.text }}", target)
        val targetText = target!!.text
        val other = items.first { it.text != targetText }.text
        val c = target.visibleCenter
        device.click(c.x, c.y)
        val opened = device.wait(Until.gone(By.text(other)), 6000)
        shot("02 tap went through to Settings")
        assertTrue("with drawing off, a tap goes through to the app below (tapped \"$targetText\")", opened)

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
        drag(0.5f, 0.52f, 0.5f, 0.68f)   // across the pen line only
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
}
