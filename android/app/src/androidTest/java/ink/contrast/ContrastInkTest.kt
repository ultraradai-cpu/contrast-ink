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
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Rect
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import ink.contrast.core.CleanRecording
import ink.contrast.core.Settings
import org.junit.Assume.assumeTrue
import android.media.MediaExtractor
import android.media.MediaFormat
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
        // a test that failed while Android's recording question or app picker was up: close it for the next test
        if (InkService.running?.recorder?.active != true) repeat(2) { device.pressBack(); Thread.sleep(300) }
        inst.runOnMainSync { InkService.running?.quit() }
        // what a test made fail or slow is back to normal for the next one
        VideoCompositor.failSetUpForTest = false
        VideoCompositor.failNextFrameForTest = false
        ScreenRecorder.displayDelayForTest = 0
        ScreenRecorder.maxFileBytesForTest = null
        ScreenRecorder.freeBytesForTest = null
        ScreenRecorder.spaceCheckMsForTest = null
        // a recording stopped by quitting is saved first: the service ends after that
        val until = System.currentTimeMillis() + 30000
        while (InkService.running != null && System.currentTimeMillis() < until) Thread.sleep(200)
    }

    private fun shot(name: String) { device.takeScreenshot(File(shots, "$name.png")) }

    /** What is on the screen now (the drawing layer and the app below it), as pixels; kept as [name].png. */
    private fun screenNow(name: String): Bitmap {
        val taken = inst.uiAutomation.takeScreenshot()
        assertNotNull("a screenshot ($name)", taken)
        val b = taken!!.copy(Bitmap.Config.ARGB_8888, false)
        File(shots, "$name.png").outputStream().use { b.compress(Bitmap.CompressFormat.PNG, 100, it) }
        return b
    }

    /** A point given as fractions of the screen (as [drag] takes them), in screen pixels. */
    private fun at(fx: Float, fy: Float) = (fx * device.displayWidth).toInt() to (fy * device.displayHeight).toInt()

    private fun close(a: Int, b: Int, tolerance: Int) = Math.abs(Color.red(a) - Color.red(b)) <= tolerance &&
        Math.abs(Color.green(a) - Color.green(b)) <= tolerance && Math.abs(Color.blue(a) - Color.blue(b)) <= tolerance

    private fun hex(c: Int) = String.format("#%06X", c and 0xFFFFFF)

    /** Whether a pixel within [r] of (x, y) passes [ok]. */
    private fun anyNear(b: Bitmap, x: Int, y: Int, r: Int, ok: (Int) -> Boolean): Boolean {
        for (dy in -r..r) for (dx in -r..r) {
            val px = x + dx
            val py = y + dy
            if (px in 0 until b.width && py in 0 until b.height && ok(b.getPixel(px, py))) return true
        }
        return false
    }

    /**
     * How much of [color] is in [pixel] laid over [background] (0 = none, 1 = solid): the best fit over the three
     * channels of pixel = background + a * (color - background).
     */
    private fun coverage(pixel: Int, color: Int, background: Int): Float {
        var num = 0f
        var den = 0f
        for (ch in listOf<(Int) -> Int>({ Color.red(it) }, { Color.green(it) }, { Color.blue(it) })) {
            val d = (ch(color) - ch(background)).toFloat()
            num += (ch(pixel) - ch(background)) * d
            den += d * d
        }
        return if (den == 0f) Float.NaN else num / den
    }

    /** The middle of a stroke drawn by [drag] from (x1, y1) to (x2, y2), [t] of the way along, in screen pixels. */
    private fun along(x1: Float, y1: Float, x2: Float, y2: Float, t: Float) = at(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t)

    /** Laser red (the line's solid pass): strongly red, not the pen's own red. */
    private fun laserRed(c: Int) = Color.red(c) > 200 && Color.green(c) < 110 && Color.blue(c) < 110

    /** Pixels along the laser's row that are laser red now but weren't in [before]. */
    private fun newLaserPixels(before: Bitmap, now: Bitmap, fy: Float): Int {
        val (x1, y) = at(0.15f, fy)
        val (x2, _) = at(0.85f, fy)
        var n = 0
        for (yy in y - 4..y + 4) for (x in x1..x2) {
            if (yy !in 0 until now.height || x !in 0 until now.width) continue
            if (laserRed(now.getPixel(x, yy)) && !laserRed(before.getPixel(x, yy))) n++
        }
        return n
    }

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
        val pen = screenNow("03 pen line")
        val red = Settings.COLORS[0]
        for (t in floatArrayOf(0.25f, 0.5f, 0.75f)) {
            val (x, y) = along(0.15f, 0.55f, 0.85f, 0.65f, t)
            assertTrue("pen: the line is on the screen in the pen's red ${hex(red)} at ($x, $y), not ${hex(pen.getPixel(x, y))}",
                anyNear(pen, x, y, 4) { close(it, red, 40) })
        }

        press("Arrow")
        drag(0.2f, 0.85f, 0.5f, 0.7f)
        assertEquals("arrow: one more mark", 2, marks())
        press("Circle")
        drag(0.55f, 0.72f, 0.9f, 0.88f)
        assertEquals("circle: one more mark", 3, marks())
        press("Green (3)")
        press("Highlighter")
        // over the stand-in's white slide, above the toolbar (which opens downwards from its place)
        val beforeHighlight = screenNow("03b before the highlighter")
        drag(0.1f, 0.12f, 0.6f, 0.12f)
        assertEquals("highlighter: one more mark", 4, marks())
        val highlight = screenNow("04 arrow circle highlighter")
        val green = Settings.COLORS[2]
        for (t in floatArrayOf(0.3f, 0.5f, 0.7f)) {
            val (x, y) = along(0.1f, 0.12f, 0.6f, 0.12f, t)
            val bg = beforeHighlight.getPixel(x, y)
            val px = highlight.getPixel(x, y)
            assertTrue("highlighter: the slide under it is light (${hex(bg)} at ($x, $y)), to see it blend", Color.red(bg) > 200 && Color.green(bg) > 200 && Color.blue(bg) > 200)
            val a = coverage(px, green, bg)
            // the app lays the highlighter on at 40% (told from 50%: within 5 points)
            assertTrue("highlighter: green ${hex(green)} blended over the slide ${hex(bg)} at 40%: ${hex(px)} at ($x, $y) is ${(a * 100).toInt()}%",
                a in 0.35f..0.45f && close(px, Color.rgb(
                    (Color.red(bg) + a * (Color.red(green) - Color.red(bg))).toInt(),
                    (Color.green(bg) + a * (Color.green(green) - Color.green(bg))).toInt(),
                    (Color.blue(bg) + a * (Color.blue(green) - Color.blue(bg))).toInt()), 20))
        }

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

        // laser pointer: a glowing dot and line while touching, gone a moment later, and never a mark
        press("Laser pointer")
        val beforeLaser = screenNow("07a before the laser")
        val (lx1, ly) = at(0.15f, 0.8f)
        val (lx2, _) = at(0.85f, 0.8f)
        // a slow swipe (about 1.5 s), looked at while the finger is still down
        val swipe = Thread { device.swipe(lx1, ly, lx2, ly, 300) }
        swipe.start()
        Thread.sleep(900)
        val laserOn = screenNow("07b laser")
        var lit = false
        inst.runOnMainSync { lit = InkService.running?.ink?.laserShowing == true }
        swipe.join()
        assertTrue("laser: its glowing line shows while drawing", lit)
        val glow = newLaserPixels(beforeLaser, laserOn, 0.8f)
        assertTrue("laser: its red dot and line are on the screen while touching ($glow new laser-red pixels along the swipe)", glow >= 40)
        device.waitForIdle()
        assertEquals("laser: never a mark", 2, marks())
        Thread.sleep(2000)
        inst.runOnMainSync { lit = InkService.running?.ink?.laserShowing == true }
        assertTrue("laser: the line is gone 2 s later", !lit)
        val left = newLaserPixels(beforeLaser, screenNow("07b2 laser gone"), 0.8f)
        assertTrue("laser: nothing of it is left on the screen 2 s later ($left laser-red pixels)", left < 5)

        // opacity: new pen marks at the chosen opacity
        inst.runOnMainSync { InkService.running?.update { it.copy(opacity = 0.5f) } }
        press("Pen")
        val beforeHalf = screenNow("07c0 before the half opacity line")
        drag(0.15f, 0.9f, 0.85f, 0.9f)
        var alpha: Float? = null
        inst.runOnMainSync { alpha = InkService.running?.ink?.lastMarkAlpha }
        val half = screenNow("07c half opacity line")
        assertEquals("opacity 50%: the new line is half see-through", 0.5f, alpha ?: -1f, 0.02f)
        for (t in floatArrayOf(0.25f, 0.5f, 0.75f)) {
            val (x, y) = along(0.15f, 0.9f, 0.85f, 0.9f, t)
            // the line's middle: the pixel within a few of (x, y) with the most green in it
            var best = Float.NaN
            var bestPx = 0
            var bestBg = 0
            for (dy in -3..3) {
                val yy = y + dy
                if (yy !in 0 until half.height) continue
                val a = coverage(half.getPixel(x, yy), green, beforeHalf.getPixel(x, yy))
                if (best.isNaN() || a > best) { best = a; bestPx = half.getPixel(x, yy); bestBg = beforeHalf.getPixel(x, yy) }
            }
            assertTrue("opacity 50%: green ${hex(green)} over ${hex(bestBg)} shows at 50% (told from 40%: within 5 points): ${hex(bestPx)} at ($x, $y) is ${(best * 100).toInt()}%",
                best in 0.45f..0.55f)
        }
        inst.runOnMainSync { InkService.running?.update { it.copy(opacity = 1f) } }

        // a drawing pad on USB or Bluetooth (Wacom One, XP-Pen, Huion): Android gets a stylus, or a mouse
        val w = device.displayWidth
        val h = device.displayHeight
        device.executeShellCommand("input stylus swipe ${w / 6} ${h * 85 / 100} ${w * 5 / 6} ${h * 85 / 100} 300")
        Thread.sleep(600)
        assertEquals("a drawing pad's pen (as a stylus) draws", 4, marks())
        device.executeShellCommand("input mouse swipe ${w / 6} ${h * 78 / 100} ${w * 5 / 6} ${h * 78 / 100} 300")
        Thread.sleep(600)
        assertEquals("a drawing pad's pen (as a mouse) draws", 5, marks())
        shot("07d drawing pad lines")
        press("Undo"); press("Undo")
        assertEquals("undo takes the pad's lines back", 3, marks())

        press("Draw on / off")
        assertTrue("✎ again switches drawing off", !drawing())
        assertEquals("marks stay when drawing goes off", 3, marks())
        press("Make the toolbar small")
        shot("08 small toolbar, drawing off, marks stay")
        assertNotNull("small toolbar keeps the record button", device.findObject(By.desc("Record the screen")))
        press("Make the toolbar big")
    }

    // ---------- recording ----------

    private val oneApp = Pattern.compile("(?i)(a )?single app|one app|(record|share) (a single|one) app")
    private val entireScreen = Pattern.compile("(?i)(the )?(entire|full|whole) screen|(record|share) (the )?(entire|full|whole) screen")

    /** SystemUI's "A single app / Entire screen" drop-down (Android 14 and 15 name it differently). */
    private val modeChooser = By.res(Pattern.compile("com\\.android\\.systemui:id/screen_share_mode_(spinner|options|selector)"))

    /** When the test pressed Android's Start button (the last one, where Android asks in two steps). */
    private var startPressedAt = 0L

    private fun shows(o: UiObject2, p: Pattern) = o.text?.let { p.matcher(it).matches() } == true || o.hasObject(By.text(p))

    /**
     * Taps [o] at once and says when (elapsedRealtime, just before the tap). UiObject2.click() first waits for the
     * screen to settle, which the recording's ticking clock delays by up to 10 s: the time taken before it would be
     * that much off. The button's place is read first, then the tap goes straight in.
     */
    private fun clickTimed(o: UiObject2): Long {
        val p = o.visibleCenter
        val at = SystemClock.elapsedRealtime()
        device.click(p.x, p.y)
        return at
    }

    private fun dump(name: String) { runCatching { device.dumpWindowHierarchy(File(shots, "$name.xml")) } }

    /**
     * Android's "start recording?" question (its wording differs between versions). Android 14+ asks "A single app" or
     * "Entire screen" first; [singleApp] picks which, and for one app, the stand-in "Other app" in Android's app picker.
     * The choice is found by its words or, failing that, by SystemUI's resource id. From Android 14 one app must be
     * offered: a question without it fails the test (it doesn't skip it).
     */
    private fun answerRecordingQuestion(singleApp: Boolean, shotName: String) {
        if (singleApp) offerOneAppOnAndroid14()
        val want = if (singleApp) oneApp else entireScreen
        val either = Pattern.compile("${oneApp.pattern()}|${entireScreen.pattern().removePrefix("(?i)")}")
        val choice = device.wait(Until.findObject(By.text(either)), 5000) ?: device.findObject(modeChooser)
        shot("$shotName a, Android asks")
        if (choice == null) dump("$shotName a, Android asks")
        if (singleApp && choice == null) {
            device.pressBack()
            throw AssertionError("Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT}) asked to record without " +
                "offering \"A single app\": no choice matching /$either/ and no $modeChooser. Android 14+ should offer it. " +
                "What Android showed: \"$shotName a, Android asks.png\" and \".xml\" in the screenshots.")
        }
        if (choice != null && !shows(choice, want)) {
            choice.click()   // opens the list of the two
            val option = device.wait(Until.findObject(By.text(want)), 3000)
            if (option == null) { shot("$shotName a2, Android's list"); dump("$shotName a2, Android's list") }
            if (singleApp && option == null) {
                repeat(2) { device.pressBack(); Thread.sleep(300) }
                throw AssertionError("Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT}) has a recording choice " +
                    "(\"${choice.text}\") but its list has nothing matching /${oneApp.pattern()}/: see \"$shotName a2, Android's list\".")
            }
            assertNotNull("Android's list has \"${if (singleApp) "A single app" else "Entire screen"}\"", option)
            option!!.click()
            device.waitForIdle()
        }
        val start = device.wait(Until.findObject(By.text(Pattern.compile("(?i)start( now| recording)?|next|share screen|record( screen| app)?"))), 8000)
        assertNotNull("Android asks before recording, with a Start button", start)
        startPressedAt = clickTimed(start)
        if (singleApp) { pickOtherApp(shotName); return }
        // some versions ask in two steps
        // (the question may close as it is found: then there was no second step)
        runCatching {
            device.wait(Until.findObject(By.text(Pattern.compile("(?i)start( now| recording)?"))), 1500)?.let {
                startPressedAt = clickTimed(it)
            }
        }
    }

    /**
     * Android 14's emulator image keeps "A single app" behind SystemUI's flag window_manager/record_task_content
     * (Pixels have it on): switched on, and SystemUI restarted to read it. Once per test run.
     */
    private fun offerOneAppOnAndroid14() {
        if (Build.VERSION.SDK_INT != 34 || oneAppFlagSet) return
        oneAppFlagSet = true
        if (device.executeShellCommand("device_config get window_manager record_task_content").trim() == "true") return
        device.executeShellCommand("device_config set_sync_disabled_for_tests persistent")
        device.executeShellCommand("device_config put window_manager record_task_content true")
        device.pressBack()   // Android's question, asked by the SystemUI about to restart
        device.executeShellCommand("am crash com.android.systemui")
        Thread.sleep(8000)
        // "System UI has stopped": closed if it shows
        device.wait(Until.findObject(By.text(Pattern.compile("(?i)close app|ok"))), 2000)?.click()
        shot("00 SystemUI restarted with one-app recording on")
        press("Record the screen")   // asked again, by the new SystemUI
    }

    /** Android's app picker (recent apps): the stand-in "Other app" (its label, or its package's name). */
    private fun pickOtherApp(shotName: String) {
        // "\b": not the stand-in's own text "A slide in another app", which may show behind the picker
        val label = Pattern.compile("(?i).*\\b(other app|ink\\.contrast\\.test)\\b.*")
        val app = device.wait(Until.findObject(By.desc(label)), 8000) ?: device.findObject(By.text(label))
        shot("$shotName b, app picker")
        if (app == null) runCatching { device.dumpWindowHierarchy(File(shots, "$shotName b, app picker.xml")) }
        assertNotNull("Android's app picker lists the stand-in \"Other app\"", app)
        app!!.click()
    }

    /** Waits for "Saved to the Gallery", and finds that video in the Gallery. */
    private fun savedVideo(shotName: String): Pair<String, Uri> {
        // (a recording that stopped by itself says why first)
        val saved = device.wait(Until.findObject(By.desc(Pattern.compile("(?s).*Saved to the Gallery: .*"))), 30000)
        shot(shotName)
        assertNotNull("the video is saved to the Gallery (the toolbar says where)", saved)
        val name = saved!!.contentDescription.toString().substringAfterLast('/')
        val uri = ctx.contentResolver.query(MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
            arrayOf(MediaStore.Video.Media._ID), "${MediaStore.Video.Media.DISPLAY_NAME} = ?", arrayOf(name), null)!!.use {
            assertTrue("\"$name\" is in the Gallery", it.moveToFirst())
            ContentUris.withAppendedId(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, it.getLong(0))
        }
        return name to uri
    }

    /** The video's last frame (after everything was drawn), saved as [shotName].png for a person to look at. */
    private fun lastFrame(uri: Uri, shotName: String): Bitmap {
        val lastUs = MediaExtractor().run {
            setDataSource(ctx, uri, null)
            val video = (0 until trackCount).first { getTrackFormat(it).getString(MediaFormat.KEY_MIME)!!.startsWith("video/") }
            selectTrack(video)
            var last = 0L
            while (sampleTrackIndex >= 0) { last = maxOf(last, sampleTime); advance() }
            release(); last
        }
        val frame = MediaMetadataRetriever().run {
            setDataSource(ctx, uri)
            val f = getFrameAtTime(lastUs, MediaMetadataRetriever.OPTION_CLOSEST)
            release(); f
        }
        assertNotNull("a frame from the video at ${lastUs / 1000} ms", frame)
        File(shots, "$shotName.png").outputStream().use { frame!!.compress(Bitmap.CompressFormat.PNG, 100, it) }
        return frame!!
    }

    private fun screen(): Pair<Int, Int> {
        var s = 0 to 0
        inst.runOnMainSync { s = InkService.running!!.screenSize() }
        return s
    }

    private fun toolbarOnScreen(): Rect {
        var r: Rect? = null
        inst.runOnMainSync { r = InkService.running?.toolbarOnScreen() }
        assertNotNull("the toolbar's place on the screen", r)
        return r!!
    }

    /** A point on the screen, as fractions of the screen as [drag] takes them, in the frame's pixels. */
    private fun inFrame(frame: Bitmap, fx: Float, fy: Float): Pair<Float, Float> {
        val (sw, sh) = screen()
        val box = CleanRecording.fit(sw, sh, frame.width, frame.height)
        val s = box.width / sw
        return (box.left + fx * device.displayWidth * s) to (box.top + fy * device.displayHeight * s)
    }

    /** Whether there is a red pixel (the pen's red, give or take video compression) within [r] pixels of a point. */
    private fun redNear(frame: Bitmap, x: Float, y: Float, r: Int = 16): Boolean {
        for (dy in -r..r) for (dx in -r..r) {
            val px = x.toInt() + dx
            val py = y.toInt() + dy
            if (px !in 0 until frame.width || py !in 0 until frame.height) continue
            val c = frame.getPixel(px, py)
            if (Color.red(c) > 170 && Color.green(c) < 110 && Color.blue(c) < 110) return true
        }
        return false
    }

    /** The share of the toolbar's rectangle (its rounded corners left out) in the frame that is the toolbar's colour. */
    private fun toolbarShare(frame: Bitmap, bar: Rect): Float {
        val (sw, sh) = screen()
        val box = CleanRecording.fit(sw, sh, frame.width, frame.height)
        val s = box.width / sw
        val left = (box.left + (bar.left + bar.width() * 0.15f) * s).toInt().coerceIn(0, frame.width)
        val right = (box.left + (bar.right - bar.width() * 0.15f) * s).toInt().coerceIn(0, frame.width)
        val top = (box.top + (bar.top + bar.height() * 0.15f) * s).toInt().coerceIn(0, frame.height)
        val bottom = (box.top + (bar.bottom - bar.height() * 0.15f) * s).toInt().coerceIn(0, frame.height)
        if (right <= left || bottom <= top) return 0f
        val pixels = IntArray((right - left) * (bottom - top))
        frame.getPixels(pixels, 0, right - left, left, top, right - left, bottom - top)
        return CleanRecording.share(pixels, TOOLBAR_COLOR)
    }

    /**
     * The red line drawn by [drag] (0.15, 0.55) to (0.85, 0.65) is in the frame: checked at three points along it.
     * And the recorded picture around it is what the app showed: [screen], a screenshot taken just before the video
     * ended, compared pixel by pixel in a band either side of the line (the red marks and the toolbar [bar] left out).
     * A video of the marks over black, or over a blank picture, fails here.
     */
    private fun assertRedLine(frame: Bitmap, what: String, screen: Bitmap, bar: Rect) {
        for (t in floatArrayOf(0.25f, 0.5f, 0.75f)) {
            val (x, y) = inFrame(frame, 0.15f + 0.7f * t, 0.55f + 0.1f * t)
            assertTrue("$what: the red line is in the video at (${x.toInt()}, ${y.toInt()}) of ${frame.width} x ${frame.height}", redNear(frame, x, y))
        }
        var compared = 0
        var same = 0
        var blackInVideo = 0
        var blackOnScreen = 0
        val misses = ArrayList<String>()
        for (i in 1..9) for (d in floatArrayOf(-0.08f, -0.06f, -0.04f, 0.04f, 0.06f, 0.08f)) {
            val fx = 0.15f + 0.07f * i
            val fy = 0.55f + 0.01f * i + d
            val (sx, sy) = at(fx, fy)
            if (sx !in 0 until screen.width || sy !in 0 until screen.height || bar.contains(sx, sy)) continue
            val want = screen.getPixel(sx, sy)
            val (vx, vy) = inFrame(frame, fx, fy)
            if (vx.toInt() !in 0 until frame.width || vy.toInt() !in 0 until frame.height) continue
            val got = frame.getPixel(vx.toInt(), vy.toInt())
            if (reddish(want) || reddish(got)) continue
            compared++
            if (close(got, want, 60)) same++ else if (misses.size < 6) misses += "(${sx},${sy}) screen ${hex(want)} video ${hex(got)}"
            if (Color.red(got) + Color.green(got) + Color.blue(got) < 60) blackInVideo++
            if (Color.red(want) + Color.green(want) + Color.blue(want) < 60) blackOnScreen++
        }
        assertTrue("$what: enough of the picture around the line to compare ($compared points)", compared >= 20)
        assertTrue("$what: the recorded app around the line is what the screen showed, not black or blank: " +
            "$same of $compared points match ($blackInVideo black in the video, $blackOnScreen on the screen); e.g. $misses",
            same >= compared * 0.8f && blackInVideo <= blackOnScreen + compared / 10)
    }

    /** Red enough to be a mark (or its edge, blurred by the video), left out of the picture comparison. */
    private fun reddish(c: Int) = Color.red(c) > 140 && Color.red(c) > Color.green(c) + 60 && Color.red(c) > Color.blue(c) + 40

    private fun waitForMode(m: CleanRecording.Mode): Boolean {
        val until = System.currentTimeMillis() + 8000
        while (System.currentTimeMillis() < until) {
            if (recorder { it.mode == m }) return true
            Thread.sleep(200)
        }
        return false
    }

    /** Red pen, with drawing off (so the taps on Android's question and picker reach them). */
    private fun redPen() {
        press("Pen")
        press("Red (1)")
        if (drawing()) press("Draw on / off")
    }

    @Test fun recordsPausesResumesAndSavesToTheGallery() {
        device.executeShellCommand("am start -W -n ${inst.context.packageName}/ink.contrast.OtherAppActivity")
        device.wait(Until.findObject(By.text("Not tapped")), 8000)
        redPen()

        press("Record the screen")
        answerRecordingQuestion(singleApp = false, shotName = "09")
        assertNotNull("recording: ⏹ replaces ⏺", device.wait(Until.findObject(By.desc("Stop recording")), 8000))
        assertTrue("recording", recorder { it.active })
        if (Build.VERSION.SDK_INT >= 34) {
            assertTrue("Android 14+: the recorder sees the toolbar's beacon in the picture: the entire screen", waitForMode(CleanRecording.Mode.ENTIRE_SCREEN))
            assertTrue("no frame-sized bitmaps for the marks: the picture has them", !recorder { it.inkBitmapsAllocated })
        }
        press("Draw on / off")
        drag(0.15f, 0.55f, 0.85f, 0.65f)
        Thread.sleep(1500)
        shot("10 recording")

        // paused for about 5 s, timed by the test itself (not by the app's clock)
        val pauseButton = device.wait(Until.findObject(By.desc("Pause recording")), 4000)
        assertNotNull("the pause button", pauseButton)
        val pausedAt = clickTimed(pauseButton)
        assertTrue("paused", waitFor { it.paused })
        Thread.sleep(maxOf(0L, pausedAt + 5000 - SystemClock.elapsedRealtime()))
        val resumeButton = device.wait(Until.findObject(By.desc("Resume recording")), 4000)
        assertNotNull("the resume button", resumeButton)
        val resumedAt = clickTimed(resumeButton)
        val pause = resumedAt - pausedAt
        assertTrue("resumed", waitFor { it.active && !it.paused })
        drag(0.15f, 0.75f, 0.85f, 0.7f)
        Thread.sleep(1500)
        val bar = toolbarOnScreen()
        val screen = screenNow("10b the screen before stopping")

        val stopButton = device.wait(Until.findObject(By.desc("Stop recording")), 4000)
        assertNotNull("the stop button", stopButton)
        val stoppedAt = clickTimed(stopButton)
        val wall = stoppedAt - startPressedAt
        val (name, uri) = savedVideo("11 saved")
        // it is really there, complete, and plays for a few seconds
        val ms = MediaMetadataRetriever().run {
            setDataSource(ctx, uri)
            val d = extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLong() ?: 0
            release(); d
        }
        // each track's length and first/last sample times, and a copy of the video, for a person to look at
        val tracks = MediaExtractor().run {
            setDataSource(ctx, uri, null)
            val info = (0 until trackCount).joinToString("; ") { i ->
                val f = getTrackFormat(i)
                selectTrack(i)
                seekTo(0, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                val first = sampleTime
                var last = first; var n = 0
                while (sampleTrackIndex >= 0) { if (sampleTrackIndex == i) { last = sampleTime; n++ }; advance() }
                unselectTrack(i)
                "${f.getString(MediaFormat.KEY_MIME)} ${if (f.containsKey(MediaFormat.KEY_DURATION)) f.getLong(MediaFormat.KEY_DURATION) / 1000 else -1} ms, " +
                    "samples $n from ${first / 1000} to ${last / 1000} ms"
            }
            release(); info
        }
        ctx.contentResolver.openInputStream(uri)!!.use { input -> File(shots, "12 the recording.mp4").outputStream().use { input.copyTo(it) } }
        // the entire screen: the marks and the toolbar are both in the picture
        val frame = lastFrame(uri, "12b last frame of the entire-screen video")
        ctx.contentResolver.delete(uri, null, null)
        assertRedLine(frame, "entire screen", screen, bar)
        val share = toolbarShare(frame, bar)
        assertTrue("entire screen: the toolbar is in the video (${(share * 100).toInt()}% of its box is its colour)", share > 0.3f)
        // as long as the toolbar's clock said (the pause is cut out), not the wall time
        // the toolbar's clock when it stopped (paused time left out). Not read by the test before pressing ⏹: each
        // step of the test waits for the screen to settle, and the ticking clock keeps it from settling for ~10 s.
        var timer = 0L
        inst.runOnMainSync { timer = InkService.running?.recorder?.lastLength ?: 0 }
        assertTrue("the video \"$name\" ($ms ms: $tracks) is as long as the toolbar's clock said ($timer ms)",
            ms >= 1500 && Math.abs(ms - timer) <= 2500)
        // and as long as the test's own clock says: from Android's Start to ⏹, less the pause
        val expected = wall - pause
        assertTrue("the video \"$name\" ($ms ms: $tracks) is the recorded time without the pause: ${wall} ms from Start to ⏹, " +
            "less ${pause} ms paused = $expected ms (allowed ${expected - 1500} to ${expected + 500} ms)",
            ms <= expected + 500 && ms >= expected - 1500)
    }

    /**
     * Android 14+: "A single app" (the stand-in other app) records that app without the toolbar, and the marks are
     * drawn into the video by Contrast Ink. Checked in the saved video's last frame: the red line is there, the
     * toolbar's rectangle has none of the toolbar's colour.
     */
    @Test fun recordsOneAppWithoutTheToolbar() = recordOneApp("3", Color.WHITE)

    /**
     * A dark slide, here exactly the toolbar's own colour (a #1E1E1E background was close enough before), under the
     * toolbar: the old check took it for the toolbar ("entire screen") and the one-app video had no marks at all.
     */
    @Test fun recordsOneAppOverADarkSlide() = recordOneApp("4", TOOLBAR_COLOR)

    /**
     * The first frame comes 3 s late (starting the mic and the encoder can take that long): before, the recorder had
     * stopped looking after 1.5 s, never decided, and the one-app video had no marks at all.
     */
    @Test fun recordsOneAppWhenTheFirstFrameIsLate() {
        ScreenRecorder.displayDelayForTest = 3000
        recordOneApp("5", Color.WHITE)
    }

    /**
     * Android 14+: "A single app" (the stand-in other app) records that app without the toolbar, and the marks are
     * drawn into the video by Contrast Ink. Checked in the saved video's last frame: the red line is there, and (on a
     * light slide) the toolbar's rectangle has none of the toolbar's colour. [n]: the screenshots' number.
     */
    private fun recordOneApp(n: String, background: Int) {
        assumeTrue("one app can be recorded from Android 14", Build.VERSION.SDK_INT >= 34)
        device.executeShellCommand("am start -W --activity-clear-task -n ${inst.context.packageName}/ink.contrast.OtherAppActivity " +
            "--ei ${OtherAppActivity.EXTRA_BACKGROUND} $background")
        device.wait(Until.findObject(By.text("Not tapped")), 8000)
        redPen()

        press("Record the screen")
        answerRecordingQuestion(singleApp = true, shotName = "${n}0")
        assertNotNull("recording: ⏹ replaces ⏺", device.wait(Until.findObject(By.desc("Stop recording")), 10000))
        assertTrue("the recorder sees no toolbar in the picture: one app", waitForMode(CleanRecording.Mode.SINGLE_APP))
        assertTrue("it says so", device.wait(Until.hasObject(By.desc(Pattern.compile("Recording one app: .*"))), 6000))
        assertNotNull("the stand-in app is in front", device.wait(Until.findObject(By.text(Pattern.compile("Not tapped|Tapped"))), 4000))
        press("Draw on / off")
        drag(0.15f, 0.55f, 0.85f, 0.65f)
        Thread.sleep(1500)
        shot("${n}1 recording one app, red line")
        val beaconGone = System.currentTimeMillis() + 5000
        while (beaconShowing() && System.currentTimeMillis() < beaconGone) Thread.sleep(200)
        assertTrue("decided for good: the toolbar's beacon is gone", !beaconShowing())
        val bar = toolbarOnScreen()
        val screen = screenNow("${n}1b the screen before stopping")

        press("Stop recording")
        val (_, uri) = savedVideo("${n}2 saved")
        ctx.contentResolver.openInputStream(uri)!!.use { input -> File(shots, "${n}3 the one-app recording.mp4").outputStream().use { input.copyTo(it) } }
        val frame = lastFrame(uri, "${n}3b last frame of the one-app video")
        ctx.contentResolver.delete(uri, null, null)

        // it is the stand-in app: its blue lower half
        val (bx, by) = inFrame(frame, 0.5f, 0.9f)
        val blue = frame.getPixel(bx.toInt(), by.toInt())
        assertTrue("the video shows the stand-in app (its blue button), not ${Integer.toHexString(blue)}",
            Color.blue(blue) > 150 && Color.red(blue) < 120)
        assertRedLine(frame, "one app", screen, bar)
        if (background == Color.WHITE) {
            val share = toolbarShare(frame, bar)
            assertTrue("one app: no toolbar in the video (${(share * 1000).toInt() / 10f}% of its box is its colour)", share < 0.02f)
        }
    }

    /**
     * Android 14+, one app: the recorded app goes out of sight (the home screen in front). The recorder knows, says
     * so once, and draws no marks over the app's frozen last picture meanwhile; back in sight, they are drawn again.
     * Checked in the video itself: a frame from while the app was out of sight has no red, the last frame has the line.
     */
    @Test fun noMarksOverTheRecordedAppWhileItIsOutOfSight() {
        assumeTrue("one app can be recorded from Android 14", Build.VERSION.SDK_INT >= 34)
        device.executeShellCommand("am start -W -n ${inst.context.packageName}/ink.contrast.OtherAppActivity")
        device.wait(Until.findObject(By.text("Not tapped")), 8000)
        redPen()
        press("Record the screen")
        answerRecordingQuestion(singleApp = true, shotName = "60")
        assertNotNull(device.wait(Until.findObject(By.desc("Stop recording")), 10000))
        assertTrue(waitForMode(CleanRecording.Mode.SINGLE_APP))
        press("Draw on / off")
        drag(0.15f, 0.55f, 0.85f, 0.65f)
        Thread.sleep(1500)
        assertTrue("the marks are drawn into the video while the app is in sight", compositorDrawsInk())

        device.pressHome()
        assertTrue("the recorder knows the app is out of sight", waitFor { !it.recordedAppVisible })
        val hiddenFrom = videoClock()
        assertTrue("and says so", device.wait(Until.hasObject(By.desc(CleanRecording.HIDDEN_NOTICE)), 5000))
        assertTrue("no marks are drawn into the video meanwhile", !compositorDrawsInk())
        shot("61 the recorded app out of sight")
        Thread.sleep(4000)
        val hiddenTo = videoClock()

        device.executeShellCommand("am start -W -n ${inst.context.packageName}/ink.contrast.OtherAppActivity")
        assertTrue("back in sight", waitFor { it.recordedAppVisible })
        assertTrue("the marks are drawn into the video again", compositorDrawsInk())
        Thread.sleep(1500)
        val bar = toolbarOnScreen()
        val screen = screenNow("61c the screen before stopping")
        press("Stop recording")
        val (_, uri) = savedVideo("62 saved")
        ctx.contentResolver.openInputStream(uri)!!.use { input -> File(shots, "62 the recording, app out of sight midway.mp4").outputStream().use { input.copyTo(it) } }
        // coming back (a still stand-in app): every frame from out of sight to 1.5 s after the return. Android 14
        // holds a black picture meanwhile; no frame may have the marks over it
        val overBlack = framesBetween(uri, hiddenFrom, hiddenTo + 1500).filter { (_, f) -> mostlyBlack(f) && redPixels(f) >= 20 }
        overBlack.firstOrNull()?.let { (us, f) ->
            File(shots, "62d marks over black at ${us / 1000} ms.png").outputStream().use { f.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        assertTrue("coming back in sight: no frame has the marks over Android's held black picture " +
            "(${overBlack.size} did, at ${overBlack.map { it.first / 1000 }} ms)", overBlack.isEmpty())
        val middle = (hiddenFrom + hiddenTo) / 2
        val hidden = frameAt(uri, middle, "62b frame at $middle ms, the recorded app out of sight ($hiddenFrom to $hiddenTo ms)")
        val last = lastFrame(uri, "62c last frame, back in sight")
        ctx.contentResolver.delete(uri, null, null)

        // (what Android holds meanwhile differs: the app's last picture on Android 15, black on Android 14)
        for (t in floatArrayOf(0.25f, 0.5f, 0.75f)) {
            val (x, y) = inFrame(hidden, 0.15f + 0.7f * t, 0.55f + 0.1f * t)
            assertTrue("out of sight ($middle ms into the video): no red line at (${x.toInt()}, ${y.toInt()})", !redNear(hidden, x, y))
        }
        val reds = redPixels(hidden)
        assertTrue("out of sight ($middle ms into the video): no red anywhere in the frame ($reds red pixels)", reds < 20)
        assertRedLine(last, "back in sight", screen, bar)
    }

    private fun pixelsOf(f: Bitmap) = IntArray(f.width * f.height).also { f.getPixels(it, 0, f.width, 0, 0, f.width, f.height) }

    private fun redPixels(f: Bitmap) = pixelsOf(f).count { Color.red(it) > 170 && Color.green(it) < 110 && Color.blue(it) < 110 }

    /** Over 80% black, not counting red (the marks): Android's held picture of an app out of sight (Android 14). */
    private fun mostlyBlack(f: Bitmap): Boolean {
        val p = pixelsOf(f).filterNot { Color.red(it) > 170 && Color.green(it) < 110 && Color.blue(it) < 110 }
        return p.isNotEmpty() && p.count { Color.red(it) + Color.green(it) + Color.blue(it) < 40 } > p.size * 0.8
    }

    /** Every video frame that starts between [fromMs] and [toMs], with its time in µs. */
    private fun framesBetween(uri: Uri, fromMs: Long, toMs: Long): List<Pair<Long, Bitmap>> {
        val times = MediaExtractor().run {
            setDataSource(ctx, uri, null)
            val video = (0 until trackCount).first { getTrackFormat(it).getString(MediaFormat.KEY_MIME)!!.startsWith("video/") }
            selectTrack(video)
            val t = ArrayList<Long>()
            while (sampleTrackIndex >= 0) { if (sampleTime in fromMs * 1000..toMs * 1000) t += sampleTime; advance() }
            release(); t.sorted()
        }
        assertTrue("the video has frames between $fromMs and $toMs ms", times.isNotEmpty())
        return MediaMetadataRetriever().run {
            setDataSource(ctx, uri)
            val frames = times.mapNotNull { us -> getFrameAtTime(us, MediaMetadataRetriever.OPTION_CLOSEST)?.let { us to it } }
            release(); frames
        }
    }

    /** How long the video is so far by the recorder's clock (paused time left out), in ms. */
    private fun videoClock(): Long {
        var ms = -1L
        inst.runOnMainSync { ms = InkService.running?.recorder?.elapsed ?: -1L }
        assertTrue("the recorder's clock", ms >= 0)
        return ms
    }

    /**
     * The frame the video shows at [ms]: the last one that starts at or before it (a still app sends no frames for
     * a while, and the closest frame may be one from after), saved as [shotName].png for a person to look at.
     */
    private fun frameAt(uri: Uri, ms: Long, shotName: String): Bitmap {
        val us = MediaExtractor().run {
            setDataSource(ctx, uri, null)
            val video = (0 until trackCount).first { getTrackFormat(it).getString(MediaFormat.KEY_MIME)!!.startsWith("video/") }
            selectTrack(video)
            var shown = -1L
            while (sampleTrackIndex >= 0) { if (sampleTime <= ms * 1000) shown = maxOf(shown, sampleTime); advance() }
            release(); shown
        }
        assertTrue("the video has a frame at or before $ms ms", us >= 0)
        val frame = MediaMetadataRetriever().run {
            setDataSource(ctx, uri)
            val f = getFrameAtTime(us, MediaMetadataRetriever.OPTION_CLOSEST)
            release(); f
        }
        assertNotNull("a frame from the video at ${us / 1000} ms (shown at $ms ms)", frame)
        File(shots, "$shotName.png").outputStream().use { frame!!.compress(Bitmap.CompressFormat.PNG, 100, it) }
        return frame!!
    }

    /** Android 14+: OpenGL doesn't start. The recording goes on all the same, straight to the encoder, and says so. */
    @Test fun recordsWhenTheGraphicsFailToStart() {
        assumeTrue("the video drawing is used from Android 14", Build.VERSION.SDK_INT >= 34)
        VideoCompositor.failSetUpForTest = true
        device.executeShellCommand("am start -W -n ${inst.context.packageName}/ink.contrast.OtherAppActivity")
        device.wait(Until.findObject(By.text("Not tapped")), 8000)
        redPen()
        press("Record the screen")
        answerRecordingQuestion(singleApp = false, shotName = "40")
        assertNotNull("recording all the same", device.wait(Until.findObject(By.desc("Stop recording")), 10000))
        assertTrue("it says the video drawing failed", device.wait(Until.hasObject(By.desc(Pattern.compile("(?s).*graphics failed.*"))), 6000))
        dismissNotice()   // a long message makes the toolbar tall: out of the way of the line drawn next
        assertTrue("straight to the encoder", recorder { it.active && !it.compositing })
        press("Draw on / off")
        drag(0.15f, 0.55f, 0.85f, 0.65f)
        Thread.sleep(1500)
        shot("41 recording without the video drawing")
        val bar = toolbarOnScreen()
        val screen = screenNow("41b the screen before stopping")
        press("Stop recording")
        val (_, uri) = savedVideo("42 saved")
        val frame = lastFrame(uri, "42b last frame, the graphics failed at the start")
        ctx.contentResolver.delete(uri, null, null)
        assertRedLine(frame, "graphics failed at the start, entire screen", screen, bar)
    }

    /** Android 14+: OpenGL fails in the middle of a lecture. The recording goes on (and keeps what came before). */
    @Test fun keepsRecordingWhenTheGraphicsFailMidway() {
        assumeTrue("the video drawing is used from Android 14", Build.VERSION.SDK_INT >= 34)
        device.executeShellCommand("am start -W -n ${inst.context.packageName}/ink.contrast.OtherAppActivity")
        device.wait(Until.findObject(By.text("Not tapped")), 8000)
        redPen()
        press("Record the screen")
        answerRecordingQuestion(singleApp = false, shotName = "43")
        assertNotNull(device.wait(Until.findObject(By.desc("Stop recording")), 10000))
        assertTrue(waitForMode(CleanRecording.Mode.ENTIRE_SCREEN))
        assertTrue("through the video drawing at first", recorder { it.compositing })
        Thread.sleep(1500)

        VideoCompositor.failNextFrameForTest = true
        press("Draw on / off")   // the screen changes: a new frame, which fails
        assertTrue("the video drawing gave up", waitFor { !it.compositing })
        assertTrue("still recording", recorder { it.active })
        assertTrue("it says so", device.wait(Until.hasObject(By.desc(Pattern.compile("(?s).*graphics failed.*"))), 6000))
        dismissNotice()   // a long message makes the toolbar tall: out of the way of the line drawn next
        drag(0.15f, 0.55f, 0.85f, 0.65f)
        Thread.sleep(2000)
        shot("44 recording after the graphics failed")
        val bar = toolbarOnScreen()
        val screen = screenNow("44b the screen before stopping")
        press("Stop recording")
        val (_, uri) = savedVideo("45 saved")
        val ms = MediaMetadataRetriever().run {
            setDataSource(ctx, uri)
            val d = extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLong() ?: 0
            release(); d
        }
        val frame = lastFrame(uri, "45b last frame, the graphics failed midway")
        ctx.contentResolver.delete(uri, null, null)
        assertTrue("the video holds both halves ($ms ms)", ms >= 4000)
        assertRedLine(frame, "after the graphics failed: the picture goes straight to the encoder", screen, bar)
    }

    /** A file nearing its size limit: the recording goes on in part 2, and every part reaches the Gallery. */
    @Test fun aLongLectureGoesOnInASecondPart() {
        ScreenRecorder.maxFileBytesForTest = 1_500_000
        device.executeShellCommand("am start -W -n ${inst.context.packageName}/ink.contrast.OtherAppActivity")
        device.wait(Until.findObject(By.text("Not tapped")), 8000)
        press("Laser pointer")
        if (drawing()) press("Draw on / off")
        press("Record the screen")
        answerRecordingQuestion(singleApp = false, shotName = "50")
        assertNotNull(device.wait(Until.findObject(By.desc("Stop recording")), 10000))
        press("Draw on / off")
        // the laser moving keeps the picture changing, and the file growing
        val until = System.currentTimeMillis() + 60000
        var i = 0
        while (System.currentTimeMillis() < until && !recorder { it.partCount >= 2 }) {
            drag(0.1f, 0.5f + (i % 4) * 0.1f, 0.9f, 0.9f - (i % 4) * 0.1f); i++
        }
        assertTrue("the recording went on in a second file", recorder { it.partCount >= 2 })
        assertTrue("still recording", recorder { it.active })
        shot("51 recording, part 2")
        drag(0.1f, 0.6f, 0.9f, 0.7f)
        press("Stop recording")
        val saved = device.wait(Until.findObject(By.desc(Pattern.compile("Saved to the Gallery in \\d+ parts: .*"))), 60000)
        shot("52 saved in parts")
        assertNotNull("saved in parts, all of them in the Gallery", saved)
        val names = saved!!.contentDescription.toString().substringAfter(": ").split(", ").map { it.substringAfterLast('/') }
        assertTrue("named part 1, part 2 … ($names)", names[0].endsWith(" part 1.mp4") && names[1].endsWith(" part 2.mp4"))
        for (name in names) {
            ctx.contentResolver.query(MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.Video.Media._ID), "${MediaStore.Video.Media.DISPLAY_NAME} = ?", arrayOf(name), null)!!.use {
                assertTrue("\"$name\" is in the Gallery", it.moveToFirst())
                val uri = ContentUris.withAppendedId(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, it.getLong(0))
                val ms = MediaMetadataRetriever().run {
                    setDataSource(ctx, uri)
                    val d = extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLong() ?: 0
                    release(); d
                }
                assertTrue("\"$name\" plays ($ms ms)", ms > 0)
                ctx.contentResolver.delete(uri, null, null)
            }
        }
    }

    /**
     * Little space left: warned when it starts; nearly none: it stops by itself at its next scheduled check, and the
     * video is kept. (The check runs every second here, not every minute; nothing in the test calls it.)
     */
    @Test fun lowSpaceWarnsThenStopsAndKeepsTheVideo() {
        ScreenRecorder.freeBytesForTest = 600_000_000
        ScreenRecorder.spaceCheckMsForTest = 1000
        device.executeShellCommand("am start -W -n ${inst.context.packageName}/ink.contrast.OtherAppActivity")
        device.wait(Until.findObject(By.text("Not tapped")), 8000)
        redPen()
        press("Record the screen")
        answerRecordingQuestion(singleApp = false, shotName = "55")
        assertNotNull(device.wait(Until.findObject(By.desc("Stop recording")), 10000))
        assertTrue("warned: under 1 GB", device.wait(Until.hasObject(By.desc(Pattern.compile("(?s).*Less than 1 GB free.*"))), 6000))
        press("Draw on / off")
        drag(0.15f, 0.55f, 0.85f, 0.65f)
        Thread.sleep(2000)
        assertTrue("still recording: low, not nearly none, at the checks so far", recorder { it.active })
        val bar = toolbarOnScreen()
        val screen = screenNow("55b the screen before the space runs out")

        ScreenRecorder.freeBytesForTest = 100_000_000
        assertTrue("stopped by itself at the next scheduled space check", waitFor { !it.active })
        val saved = device.wait(Until.findObject(By.desc(Pattern.compile("(?s)The recording stopped: less than 200 MB free.*Saved to the Gallery: .*"))), 30000)
        shot("56 stopped for space, kept")
        assertNotNull("says why, and the video is kept", saved)
        val (_, uri) = savedVideo("56b saved")
        val frame = lastFrame(uri, "56c last frame, stopped for space")
        ctx.contentResolver.delete(uri, null, null)
        assertRedLine(frame, "stopped for space", screen, bar)
    }

    /** Taps the toolbar's message about the graphics away (as a presenter would), so the toolbar is small again. */
    private fun dismissNotice() {
        val notice = Pattern.compile("(?s).*graphics failed.*")
        device.findObject(By.desc(notice))?.click()
        assertTrue("the message goes when tapped", device.wait(Until.gone(By.desc(notice)), 4000))
        Thread.sleep(500)
    }

    private fun waitFor(check: (ScreenRecorder) -> Boolean): Boolean {
        val until = System.currentTimeMillis() + 8000
        while (System.currentTimeMillis() < until) {
            if (recorder(check)) return true
            Thread.sleep(200)
        }
        return false
    }

    private fun beaconShowing(): Boolean {
        var on = false
        inst.runOnMainSync { on = InkService.running?.beaconOnScreen() != null }
        return on
    }

    /** Whether the compositor draws the marks into frames now. */
    private fun compositorDrawsInk(): Boolean {
        var on = false
        inst.runOnMainSync { on = InkService.running?.recorder?.drawsInkIntoVideo == true }
        return on
    }

    private fun recorder(check: (ScreenRecorder) -> Boolean): Boolean {
        var ok = false
        inst.runOnMainSync { ok = InkService.running?.recorder?.let(check) == true }
        return ok
    }

    private companion object {
        /** Android 14's one-app flag was looked at (it stays on for the rest of the run). */
        @Volatile var oneAppFlagSet = false
        /** The toolbar's background (ToolbarView). */
        const val TOOLBAR_COLOR = 0xFF141A22.toInt()
    }
}
