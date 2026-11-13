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
import ink.contrast.core.CleanRecording
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
        // a recording stopped by quitting is saved first: the service ends after that
        val until = System.currentTimeMillis() + 30000
        while (InkService.running != null && System.currentTimeMillis() < until) Thread.sleep(200)
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

        // laser pointer: a glowing line while touching, gone a moment later, and never a mark
        press("Laser pointer")
        drag(0.15f, 0.8f, 0.85f, 0.8f)
        var lit = false
        inst.runOnMainSync { lit = InkService.running?.ink?.laserShowing == true }
        shot("07b laser")
        assertTrue("laser: its glowing line shows while drawing", lit)
        assertEquals("laser: never a mark", 2, marks())
        Thread.sleep(2000)
        inst.runOnMainSync { lit = InkService.running?.ink?.laserShowing == true }
        assertTrue("laser: the line is gone 2 s later", !lit)

        // opacity: new pen marks at the chosen opacity
        inst.runOnMainSync { InkService.running?.update { it.copy(opacity = 0.5f) } }
        press("Pen")
        drag(0.15f, 0.9f, 0.85f, 0.9f)
        var alpha: Float? = null
        inst.runOnMainSync { alpha = InkService.running?.ink?.lastMarkAlpha }
        shot("07c half opacity line")
        assertEquals("opacity 50%: the new line is half see-through", 0.5f, alpha ?: -1f, 0.02f)
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

    /**
     * Android's "start recording?" question (its wording differs between versions). Android 14+ asks "A single app" or
     * "Entire screen" first; [singleApp] picks which, and for one app, the stand-in "Other app" in Android's app picker.
     */
    private fun answerRecordingQuestion(singleApp: Boolean, shotName: String) {
        val want = if (singleApp) oneApp else entireScreen
        val choice = device.wait(Until.findObject(By.text(Pattern.compile("${oneApp.pattern()}|${entireScreen.pattern().removePrefix("(?i)")}"))), 5000)
        shot("$shotName a, Android asks")
        if (choice == null) runCatching { device.dumpWindowHierarchy(File(shots, "$shotName a, Android asks.xml")) }
        if (singleApp && choice == null) {
            // some Android 14 builds ask without offering one app: nothing to test there
            device.pressBack()
            assumeTrue("this Android doesn't offer \"A single app\"", false)
        }
        if (choice != null && !want.matcher(choice.text).matches()) {
            choice.click()   // opens the list of the two
            val option = device.wait(Until.findObject(By.text(want)), 3000)
            if (singleApp && option == null) {
                repeat(2) { device.pressBack(); Thread.sleep(300) }
                assumeTrue("this Android doesn't offer \"A single app\"", false)
            }
            assertNotNull("Android's list has \"${if (singleApp) "A single app" else "Entire screen"}\"", option)
            option!!.click()
            device.waitForIdle()
        }
        val start = device.wait(Until.findObject(By.text(Pattern.compile("(?i)start( now| recording)?|next|share screen|record( screen| app)?"))), 8000)
        assertNotNull("Android asks before recording, with a Start button", start)
        start.click()
        if (singleApp) { pickOtherApp(shotName); return }
        // some versions ask in two steps
        // (the question may close as it is found: then there was no second step)
        runCatching { device.wait(Until.findObject(By.text(Pattern.compile("(?i)start( now| recording)?"))), 1500)?.click() }
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

    /** The red line drawn by [drag] (0.15, 0.55) to (0.85, 0.65) is in the frame: checked at three points along it. */
    private fun assertRedLine(frame: Bitmap, what: String) {
        for (t in floatArrayOf(0.25f, 0.5f, 0.75f)) {
            val (x, y) = inFrame(frame, 0.15f + 0.7f * t, 0.55f + 0.1f * t)
            assertTrue("$what: the red line is in the video at (${x.toInt()}, ${y.toInt()}) of ${frame.width} x ${frame.height}", redNear(frame, x, y))
        }
    }

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

        press("Pause recording")
        assertTrue("paused", recorder { it.paused })
        Thread.sleep(1000)
        press("Resume recording")
        assertTrue("resumed", recorder { it.active && !it.paused })
        drag(0.15f, 0.75f, 0.85f, 0.7f)
        Thread.sleep(1500)
        val bar = toolbarOnScreen()

        press("Stop recording")
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
        assertRedLine(frame, "entire screen")
        val share = toolbarShare(frame, bar)
        assertTrue("entire screen: the toolbar is in the video (${(share * 100).toInt()}% of its box is its colour)", share > 0.3f)
        // as long as the toolbar's clock said (the pause is cut out), not the wall time
        // the toolbar's clock when it stopped (paused time left out). Not read by the test before pressing ⏹: each
        // step of the test waits for the screen to settle, and the ticking clock keeps it from settling for ~10 s.
        var timer = 0L
        inst.runOnMainSync { timer = InkService.running?.recorder?.lastLength ?: 0 }
        assertTrue("the video \"$name\" ($ms ms: $tracks) is as long as the toolbar's clock said ($timer ms)",
            ms >= 1500 && Math.abs(ms - timer) <= 2500)
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
        assertRedLine(frame, "one app")
        if (background == Color.WHITE) {
            val share = toolbarShare(frame, bar)
            assertTrue("one app: no toolbar in the video (${(share * 1000).toInt() / 10f}% of its box is its colour)", share < 0.02f)
        }
    }

    /**
     * Android 14+, one app: the recorded app goes out of sight (the home screen in front). The recorder knows, says
     * so once, and draws no marks over the app's frozen last picture meanwhile; back in sight, they are drawn again.
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

        device.pressHome()
        assertTrue("the recorder knows the app is out of sight", waitFor { !it.recordedAppVisible })
        assertTrue("and says so", device.wait(Until.hasObject(By.desc(CleanRecording.HIDDEN_NOTICE)), 5000))
        assertTrue("no marks are drawn into the video meanwhile", !compositorDrawsInk())
        shot("61 the recorded app out of sight")

        device.executeShellCommand("am start -W -n ${inst.context.packageName}/ink.contrast.OtherAppActivity")
        assertTrue("back in sight", waitFor { it.recordedAppVisible })
        assertTrue("the marks are drawn into the video again", compositorDrawsInk())
        press("Stop recording")
        val (_, uri) = savedVideo("62 saved")
        ctx.contentResolver.delete(uri, null, null)
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
        press("Stop recording")
        val (_, uri) = savedVideo("42 saved")
        val frame = lastFrame(uri, "42b last frame, the graphics failed at the start")
        ctx.contentResolver.delete(uri, null, null)
        assertRedLine(frame, "graphics failed at the start, entire screen")
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
        assertRedLine(frame, "after the graphics failed: the picture goes straight to the encoder")
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

    /** Little space left: warned when it starts; nearly none: it stops by itself, and the video is kept. */
    @Test fun lowSpaceWarnsThenStopsAndKeepsTheVideo() {
        ScreenRecorder.freeBytesForTest = 600_000_000
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

        ScreenRecorder.freeBytesForTest = 100_000_000
        inst.runOnMainSync { InkService.running?.recorder?.checkSpace() }
        assertTrue("stopped by itself", !recorder { it.active })
        val saved = device.wait(Until.findObject(By.desc(Pattern.compile("(?s)The recording stopped: less than 200 MB free.*Saved to the Gallery: .*"))), 30000)
        shot("56 stopped for space, kept")
        assertNotNull("says why, and the video is kept", saved)
        val (_, uri) = savedVideo("56b saved")
        val frame = lastFrame(uri, "56c last frame, stopped for space")
        ctx.contentResolver.delete(uri, null, null)
        assertRedLine(frame, "stopped for space")
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
        /** The toolbar's background (ToolbarView). */
        const val TOOLBAR_COLOR = 0xFF141A22.toInt()
    }
}
