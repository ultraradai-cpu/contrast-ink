package ink.contrast

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import ink.contrast.core.Json
import ink.contrast.core.PadCrypto
import ink.contrast.core.PadHints
import ink.contrast.core.PadProtocol
import ink.contrast.core.PadSeal
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.security.PrivateKey
import java.security.SecureRandom
import java.util.Base64
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Pad mode on an Android emulator, against a stand-in PC in the test itself (a server on 127.0.0.1 that speaks
 * version 2 of docs/pad-protocol.md as the Windows app does): the code is checked through the PROOF, the PC's
 * picture shows, a swipe reaches the PC as a stroke in fractions of the picture, the toolbar's buttons reach it as
 * commands, a dropped link comes back, a wrong code shows the PC's words, and a PC whose key changed is stopped.
 * The first time with a PC, nothing goes after HELLO until the presenter says its PC check matches.
 * The USB cable is stood in for by a fake PC on this device's 127.0.0.1:47830, where the PC's `adb reverse` puts it:
 * the pad opens over it with no code typed, it takes over from Wi-Fi, and Wi-Fi comes back when it goes.
 * Screenshots of each step are kept.
 */
@RunWith(AndroidJUnit4::class)
class PadTest {
    private val inst = InstrumentationRegistry.getInstrumentation()
    private val device = UiDevice.getInstance(inst)
    private val ctx = inst.targetContext
    private val shots = File(ctx.getExternalFilesDir(null), "shots")
    private lateinit var pc: FakePc
    /** The PC at the other end of the USB cable, when a test starts one. */
    private var cable: FakePc? = null

    /** A message from the tablet (opened, when it came sealed). */
    class Msg(val type: Int, val payload: ByteArray) {
        val text get() = payload.toString(Charsets.UTF_8)
        fun f(i: Int) = ByteBuffer.wrap(payload).getFloat(i)
    }

    /**
     * A stand-in for Contrast Ink on a PC, version 2: HELLO with the tablet's key → CHALLENGE with the PC's own key
     * (the spec's vector key unless told otherwise), a salt and its name → the tablet's PROOF must open with the
     * keys made from the code (else the PC's exact REJECT) → WELCOME, STATE and a picture, sealed; the next picture
     * only after FRAME_ACK. A new session replaces the old one, as on the PC. Everything the tablet sends lands in
     * [got] (HELLO and PROOF as they came, the rest opened; PING is answered with PONG and left out).
     */
    class FakePc(
        private val code: String,
        private val privateKey: PrivateKey = PadCrypto.privateKey(ByteArray(32) { 0x22 }),
        val publicKey: ByteArray = VECTOR_PC_KEY,
        private val name: String = "TEST-PC",
        /** 0: any free port (a PC on "Wi-Fi"); [PadProtocol.USB_PORT]: the PC at the other end of the USB cable. */
        port: Int = 0,
    ) {
        val server = ServerSocket().apply {
            reuseAddress = true   // the cable's port, again in the next test
            bind(java.net.InetSocketAddress(InetAddress.getByName("127.0.0.1"), port), 4)
        }
        val got = LinkedBlockingQueue<Msg>()
        /** One entry each time a welcomed session ends (the tablet closed it, or the test dropped it). */
        val ended = LinkedBlockingQueue<Long>()
        /** Accept a connection and close it at once (the PC not answering), to see "Lost the PC". */
        @Volatile var refuse = false
        @Volatile private var session: Session? = null

        private class Session(val socket: Socket, val out: OutputStream, val seal: PadSeal)

        /** The PC's screen: white with a black square (a slide, as JPEG, 1600 × 900). */
        private val picture: ByteArray by lazy {
            val b = Bitmap.createBitmap(1600, 900, Bitmap.Config.ARGB_8888)
            Canvas(b).apply {
                drawColor(Color.WHITE)
                drawRect(600f, 250f, 1000f, 650f, Paint().apply { color = Color.BLACK })
            }
            ByteArrayOutputStream().also { b.compress(Bitmap.CompressFormat.JPEG, 80, it) }.toByteArray()
        }

        init { Thread({ acceptLoop() }, "fake-pc").apply { isDaemon = true }.start() }

        private fun acceptLoop() {
            while (!server.isClosed) {
                val s = try { server.accept() } catch (e: IOException) { return }
                if (refuse) { try { s.close() } catch (e: IOException) {}; continue }
                Thread({ serve(s) }, "fake-pc-client").apply { isDaemon = true }.start()
            }
        }

        private fun reject(s: Socket, why: String) {
            s.getOutputStream().write(PadProtocol.message(PadProtocol.REJECT, why.toByteArray()))
            s.getOutputStream().flush()
            s.close()
        }

        private fun serve(s: Socket) {
            var welcomed = false
            try {
                val input = DataInputStream(s.getInputStream())
                fun read(): Msg {
                    val type = input.readUnsignedByte()
                    val len = input.readInt()
                    if (len < 0 || len > PadProtocol.MAX_LENGTH) throw IOException("too long")
                    return Msg(type, ByteArray(len).also { input.readFully(it) })
                }
                val hello = read()
                got += hello
                val json = if (hello.type == PadProtocol.HELLO && hello.payload.size <= 1024) Json.parseObject(hello.text) else null
                if (json == null || json.containsKey("code") || json["version"] != 2.0) {
                    reject(s, "Please update Contrast Ink on the tablet."); return
                }
                val tabletKey = Base64.getDecoder().decode(json["key"] as String)
                val salt = ByteArray(16).also { SecureRandom().nextBytes(it) }
                s.getOutputStream().write(PadProtocol.message(PadProtocol.CHALLENGE, Json.obj(
                    "key" to Base64.getEncoder().encodeToString(publicKey),
                    "salt" to Base64.getEncoder().encodeToString(salt), "name" to name).toByteArray()))

                val proof = read()
                got += proof
                val keys = PadCrypto.keys(privateKey, tabletKey, salt, code)
                val open = keys?.let { PadSeal(it.first) }
                val said = if (proof.type == PadProtocol.PROOF) open?.open(proof.payload) else null
                if (said == null || !said.contentEquals(PadProtocol.command("hello"))) {
                    reject(s, "Wrong code: type the code Contrast Ink shows on the PC (⚙ Settings)."); return
                }
                val me = Session(s, s.getOutputStream(), PadSeal(keys!!.second))
                val old = session
                session = me   // the right code replaces a connected tablet (the same one, back after a drop)
                try { old?.socket?.close() } catch (e: IOException) {}
                welcomed = true
                sealed(me, PadProtocol.message(PadProtocol.WELCOME,
                    """{"name":"$name","screenW":1600,"screenH":900,"version":2}""".toByteArray()))
                sealed(me, state(0))
                sealed(me, PadProtocol.message(PadProtocol.FRAME, picture))

                while (true) {
                    val m = read()
                    if (m.type != PadProtocol.SEALED) throw IOException("unsealed ${m.type}")
                    val inner = open!!.open(m.payload) ?: throw IOException("doesn't open, or a replay")
                    val msg = Msg(inner[0].toInt() and 0xFF, inner.copyOfRange(5, inner.size))
                    when (msg.type) {
                        PadProtocol.PING -> sealed(me, PadProtocol.message(PadProtocol.PONG))
                        PadProtocol.FRAME_ACK -> {
                            got += msg
                            // the next picture about 10 a second, as the PC does, only once the last was shown
                            Thread({
                                Thread.sleep(100)
                                if (session === me) try { sealed(me, PadProtocol.message(PadProtocol.FRAME, picture)) } catch (e: IOException) {}
                            }, "fake-pc-frame").apply { isDaemon = true }.start()
                        }
                        else -> got += msg
                    }
                }
            } catch (e: IOException) { /* the tablet left, or the test closed it */ }
            finally { if (welcomed) ended += System.currentTimeMillis() }
        }

        private fun sealed(to: Session, message: ByteArray) = synchronized(to) {
            to.out.write(PadProtocol.message(PadProtocol.SEALED, to.seal.seal(message)))
            to.out.flush()
        }

        fun state(color: Int) = PadProtocol.message(PadProtocol.STATE,
            """{"tool":"pen","color":$color,"width":1,"opacity":1.0,"fading":false,"canUndo":true}""".toByteArray())

        fun send(message: ByteArray) { session?.let { sealed(it, message) } }

        /** The Wi-Fi drops: the connection goes without a word. */
        fun drop() { try { session?.socket?.close() } catch (e: IOException) {} }

        /** The next message of [type] (others before it are passed over), or null after [ms]. */
        fun next(type: Int, ms: Long = 8000): Msg? {
            val until = System.currentTimeMillis() + ms
            while (true) {
                val left = until - System.currentTimeMillis()
                if (left <= 0) return null
                val m = got.poll(left, TimeUnit.MILLISECONDS) ?: return null
                if (m.type == type) return m
            }
        }

        fun close() { try { server.close(); session?.socket?.close() } catch (e: IOException) {} }

        companion object {
            /** The spec's "PC public key" (private key 22..22): its PC check is 6FC6-6A90-4861-71CA. */
            val VECTOR_PC_KEY = ByteArray(65) {
                "04D65A93977CAA3D1B081852FF57A79E465F1660577304BAEAD505DD3A48589CF350185E895372DF6221EA3A137557E473FDDB6755F05BD507C3C533FCE9C91285"
                    .substring(it * 2, it * 2 + 2).toInt(16).toByte()
            }
        }
    }

    private val prefs get() = ctx.getSharedPreferences("contrast-ink", Context.MODE_PRIVATE)

    @Before fun setUp() {
        shots.mkdirs()
        // Android 15 explains full screen ("Viewing full screen ... Got it") over the pad the first time: a person
        // reads it once; the test says it has been seen, so it doesn't cover the pad's buttons
        device.executeShellCommand("settings put secure immersive_mode_confirmations confirmed")
        // no PC remembered from an earlier test
        prefs.edit().apply { prefs.all.keys.filter { it.startsWith(PadActivity.PIN_PREFIX) }.forEach { remove(it) } }.commit()
        pc = FakePc("123456")
    }

    @After fun tearDown() {
        inst.runOnMainSync {
            val monitor = ActivityLifecycleMonitorRegistry.getInstance()
            Stage.values().flatMap { monitor.getActivitiesInStage(it) }.filterIsInstance<PadActivity>().forEach { it.finish() }
        }
        pc.close()
        cable?.close()
    }

    /** The pad on screen (found through the test runner's record of activities, not a field in the app). */
    private fun padActivity(): PadActivity {
        var a: PadActivity? = null
        inst.runOnMainSync {
            a = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
                .filterIsInstance<PadActivity>().firstOrNull()
        }
        return a ?: throw AssertionError("the pad isn't on screen")
    }

    private fun shot(name: String) { device.takeScreenshot(File(shots, "$name.png")) }

    /**
     * The fake PC's picture really is on the tablet's screen, not only acknowledged (FRAME_ACK): a screenshot, sampled
     * where the picture should be. The PC's slide is white with a black square in the middle (600..1000 x 250..650
     * of 1600 x 900): the middle must be dark, four points of the white around it must be white. Kept as [name].png.
     */
    private fun assertPcPictureOnScreen(name: String) {
        device.waitForIdle()
        var r = RectF()
        val activity = padActivity()
        val until = System.currentTimeMillis() + 4000
        while (System.currentTimeMillis() < until) {
            inst.runOnMainSync { r = activity.pad.pictureOnScreen() }
            if (r.width() > 0 && r.height() > 0) break
            Thread.sleep(100)
        }
        val taken = inst.uiAutomation.takeScreenshot()
        assertNotNull("a screenshot of the pad", taken)
        val screen = taken!!.copy(Bitmap.Config.ARGB_8888, false)
        File(shots, "$name.png").outputStream().use { screen.compress(Bitmap.CompressFormat.PNG, 100, it) }
        fun px(fx: Float, fy: Float): Int {
            val x = (r.left + fx * r.width()).toInt().coerceIn(0, screen.width - 1)
            val y = (r.top + fy * r.height()).toInt().coerceIn(0, screen.height - 1)
            return screen.getPixel(x, y)
        }
        fun hex(c: Int) = String.format("#%06X", c and 0xFFFFFF)
        val middle = px(0.5f, 0.5f)
        assertTrue("the PC's black square shows in the middle of its picture on the tablet ($r): ${hex(middle)}",
            Color.red(middle) < 60 && Color.green(middle) < 60 && Color.blue(middle) < 60)
        for ((fx, fy) in listOf(0.15f to 0.5f, 0.85f to 0.5f, 0.5f to 0.12f, 0.5f to 0.88f)) {
            val c = px(fx, fy)
            assertTrue("the PC's white slide shows on the tablet at ($fx, $fy) of its picture ($r): ${hex(c)}",
                Color.red(c) > 200 && Color.green(c) > 200 && Color.blue(c) > 200)
        }
    }

    private fun openPad(code: String) {
        ctx.startActivity(Intent(ctx, PadActivity::class.java)
            .putExtra(PadActivity.EXTRA_ADDRESS, "127.0.0.1:${pc.server.localPort}")
            .putExtra(PadActivity.EXTRA_CODE, code)
            .putExtra(PadActivity.EXTRA_TEST_SCREENSHOTS, true)   // a debug build only: FLAG_SECURE off for the shots
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
    }

    /** The first-time question about the PC check: shown, with nothing sent after HELLO while it is open. */
    private fun firstTimeCheckShows(check: String = "6FC6-6A90-4861-71CA") {
        assertNotNull("the first time, the PC check is asked about before anything else is sent", device.wait(Until.findObject(
            By.text("First time with TEST-PC: does the PC show the PC check $check? (⚙ Settings, beside the code)")), 8000))
        assertNull("nothing is sent after HELLO while the check is open", pc.got.poll(2, TimeUnit.SECONDS))
    }

    /** The pad with nothing typed: the connect screen (and the cable, tried every 2 s). */
    private fun openPadEmpty() {
        prefs.edit().remove("pad.address").commit()
        ctx.startActivity(Intent(ctx, PadActivity::class.java)
            .putExtra(PadActivity.EXTRA_TEST_SCREENSHOTS, true)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
    }

    private fun press(name: String) {
        val b = device.wait(Until.findObject(By.desc(name)), 4000)
        assertNotNull("button \"$name\"", b)
        b.click()
    }

    /**
     * No PC in the list (the emulator's network has none), Wi-Fi on: after about 8 s the connect screen says why that
     * often happens (hospital Wi-Fi keeping devices apart) and what to do instead. Not before: looked at until 6.5 s.
     */
    @Test fun saysToTryAHotspotWhenNoPcIsFound() {
        device.executeShellCommand("svc wifi enable")
        openPadEmpty()
        assertNotNull("the connect screen", device.wait(Until.findObject(By.text("PCs on this network")), 8000))
        val shownAt = System.currentTimeMillis()
        val quietUntil = shownAt + PadActivity.NO_PC_HINT_MS - 1500
        while (System.currentTimeMillis() < quietUntil) {
            val early = device.findObject(By.text(PadActivity.HOTSPOT_HINT))
            if (early != null) shot("18a the hotspot hint too early")
            assertNull("no hint ${(System.currentTimeMillis() - shownAt) / 100 / 10.0} s after the connect screen opened " +
                "(it waits ${PadActivity.NO_PC_HINT_MS / 1000} s for a PC)", early)
            Thread.sleep(250)
        }
        val hint = device.wait(Until.findObject(By.text(PadActivity.HOTSPOT_HINT)), 6000)
        shot("18 no PC found, the hotspot hint")
        assertNotNull("with no PC found for ${PadActivity.NO_PC_HINT_MS / 1000} s, the hotspot hint shows", hint)
        assertNull("Wi-Fi is on: not told to turn it on", device.findObject(By.text(PadHints.Hint.TURN_ON_WIFI.text!!)))
    }

    /** Wi-Fi off and no PC found: told to turn Wi-Fi on, not sent to a hotspot. */
    @Test fun saysToTurnOnWifiWhenItIsOff() {
        device.executeShellCommand("svc wifi disable")
        try {
            Thread.sleep(2000)
            openPadEmpty()
            val hint = device.wait(Until.findObject(By.text(PadHints.Hint.TURN_ON_WIFI.text!!)), PadActivity.NO_PC_HINT_MS + 6000)
            shot("18b Wi-Fi off")
            assertNotNull("Wi-Fi off: \"turn on Wi-Fi\"", hint)
            assertNull("not the hotspot hint", device.findObject(By.text(PadActivity.HOTSPOT_HINT)))
        } finally {
            device.executeShellCommand("svc wifi enable")
            Thread.sleep(2000)
        }
    }

    /** A typed address where nothing listens (the PC's tablet link off): told to switch it on, not sent to a hotspot. */
    @Test fun saysThePcIsNotAcceptingTabletsWhenRefused() {
        device.executeShellCommand("svc wifi enable")
        val closedPort = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { it.localPort }
        ctx.startActivity(Intent(ctx, PadActivity::class.java)
            .putExtra(PadActivity.EXTRA_ADDRESS, "127.0.0.1:$closedPort")
            .putExtra(PadActivity.EXTRA_CODE, "123456")
            .putExtra(PadActivity.EXTRA_TEST_SCREENSHOTS, true)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
        val hint = device.wait(Until.findObject(By.text(PadHints.Hint.NOT_ACCEPTING.text!!)), 10000)
        shot("18c refused, the PC isn't accepting tablets")
        assertNotNull("refused: \"the PC isn't accepting tablets yet\"", hint)
        assertNull("not the hotspot hint", device.findObject(By.text(PadActivity.HOTSPOT_HINT)))
    }

    @Test fun drawsOnThePcsPictureAndSendsCommands() {
        openPad("123456")
        val hello = pc.next(PadProtocol.HELLO)
        assertNotNull("the tablet says HELLO", hello)
        val json = Json.parseObject(hello!!.text)!!
        assertNull("HELLO never carries the code", json["code"])
        assertEquals("HELLO carries version 2", 2.0, json["version"])
        assertEquals("and the tablet's 65-byte public key", 65, Base64.getDecoder().decode(json["key"] as String).size)
        firstTimeCheckShows()
        shot("19 first time, the PC check")
        press("It matches")
        assertNotNull("once it matches, the tablet proves it knows the code (PROOF)", pc.next(PadProtocol.PROOF))
        assertNotNull("the tablet acknowledges the picture once it is on screen (FRAME_ACK)", pc.next(PadProtocol.FRAME_ACK))
        assertNotNull("the toolbar shows", device.wait(Until.findObject(By.desc("Undo")), 4000))
        assertNotNull("the PC's name shows", device.wait(Until.findObject(By.text("TEST-PC")), 4000))
        assertPcPictureOnScreen("20a the PC's picture, as pixels")
        assertArrayEquals("the PC's key is remembered under its name", FakePc.VECTOR_PC_KEY,
            Base64.getDecoder().decode(prefs.getString(PadActivity.PIN_PREFIX + "TEST-PC", "")))
        assertNull("the code is never saved", prefs.getString("pad.code", null))
        device.waitForIdle()
        shot("20 pad shows the PC's screen")

        // a swipe across the picture: from 20% to 80% across, 40% to 60% down
        var r = RectF()
        val activity = padActivity()
        inst.runOnMainSync { r = activity.pad.pictureOnScreen() }
        assertTrue("the picture has the PC's shape (16:9): $r", Math.abs(r.width() / r.height() - 16f / 9f) < 0.05f)
        fun sx(f: Float) = (r.left + f * r.width()).toInt()
        fun sy(f: Float) = (r.top + f * r.height()).toInt()
        pc.got.clear()
        device.swipe(sx(0.2f), sy(0.4f), sx(0.8f), sy(0.6f), 40)
        shot("21 the stroke on the pad")   // the tablet's own copy shows at once

        val begin = pc.next(PadProtocol.STROKE_BEGIN)
        assertNotNull("STROKE_BEGIN", begin)
        assertEquals("begins where the swipe starts (x)", 0.2f, begin!!.f(0), 0.05f)
        assertEquals("begins where the swipe starts (y)", 0.4f, begin.f(4), 0.05f)
        assertEquals("the pen's tip, not its eraser end", 0, begin.payload[8].toInt())
        val points = ArrayList<Pair<Float, Float>>()
        var batches = 0
        while (true) {
            val m = pc.got.poll(5, TimeUnit.SECONDS)
            assertNotNull("the stroke ends (STROKE_END)", m)
            if (m!!.type == PadProtocol.STROKE_END) break
            if (m.type != PadProtocol.STROKE_POINTS) continue
            batches++
            val n = ByteBuffer.wrap(m.payload).getShort(0).toInt() and 0xFFFF
            assertEquals("STROKE_POINTS length", 2 + n * 8, m.payload.size)
            for (i in 0 until n) points += m.f(2 + i * 8) to m.f(6 + i * 8)
        }
        assertTrue("at least one STROKE_POINTS ($batches)", batches >= 1)
        assertTrue("every point inside 0..1", points.all { (x, y) -> x in 0f..1f && y in 0f..1f })
        val (lx, ly) = points.last()
        assertEquals("ends where the swipe ends (x)", 0.8f, lx, 0.05f)
        assertEquals("ends where the swipe ends (y)", 0.6f, ly, 0.05f)

        press("Undo")
        assertEquals("Undo sends COMMAND undo", "undo", pc.next(PadProtocol.COMMAND)?.text)
        press("Green (3)")
        assertEquals("the green dot sends color:2", "color:2", pc.next(PadProtocol.COMMAND)?.text)
        press("Circle")
        assertEquals("the circle sends tool:oval", "tool:oval", pc.next(PadProtocol.COMMAND)?.text)
        press("Next slide")
        assertEquals("next slide", "next", pc.next(PadProtocol.COMMAND)?.text)
        // the PC says green is chosen: the toolbar follows
        pc.send(pc.state(2))
        Thread.sleep(500)
        shot("22 green chosen by the PC")

        // the Wi-Fi drops for a moment: the tablet comes back by itself, without "Lost the PC"
        pc.got.clear()
        pc.drop()
        assertNotNull("after a drop, the tablet says HELLO again by itself", pc.next(PadProtocol.HELLO, 10000))
        assertNotNull("the same code gets it back in (PROOF)", pc.next(PadProtocol.PROOF))
        assertNotNull("and the pictures come back", pc.next(PadProtocol.FRAME_ACK))
        assertNull("no \"Lost the PC\" for a blip", device.findObject(By.text("Lost the PC")))
        assertNotNull("the PC's name is back in the title", device.wait(Until.findObject(By.textStartsWith("TEST-PC")), 4000))

        // the PC stays away: after its quiet tries the pad says so and offers to reconnect
        pc.refuse = true
        pc.drop()
        assertNotNull("\"Lost the PC\" shows", device.wait(Until.findObject(By.text("Lost the PC")), 15000))
        assertNotNull("in plain words", device.findObject(By.textContains("same Wi-Fi")))
        shot("23 lost the PC")
        pc.refuse = false
        pc.got.clear()
        press("Reconnect")
        assertNotNull("Reconnect says HELLO again", pc.next(PadProtocol.HELLO))
        assertNotNull("and the picture comes back", pc.next(PadProtocol.FRAME_ACK))
        assertTrue("the lost message goes", device.wait(Until.gone(By.text("Lost the PC")), 4000))
    }

    @Test fun aWrongCodeShowsThePcsWords() {
        openPad("000000")
        assertNotNull("the tablet says HELLO", pc.next(PadProtocol.HELLO))
        firstTimeCheckShows()
        press("It matches")
        assertNotNull("and tries its PROOF", pc.next(PadProtocol.PROOF))
        assertNotNull("the PC's reason shows, word for word", device.wait(Until.findObject(
            By.text("Wrong code: type the code Contrast Ink shows on the PC (⚙ Settings).")), 8000))
        shot("24 wrong code")
        assertNotNull("back on the connect screen", device.findObject(By.desc("Connect")))
        assertNull("a PC that never knew the code isn't remembered", prefs.getString(PadActivity.PIN_PREFIX + "TEST-PC", null))
    }

    @Test fun anotherKeyUnderARememberedNameIsStopped() {
        // the tablet has paired with TEST-PC (the vector key); now something by that name has another key
        prefs.edit().putString(PadActivity.PIN_PREFIX + "TEST-PC", Base64.getEncoder().encodeToString(FakePc.VECTOR_PC_KEY)).commit()
        pc.close()
        val other = PadCrypto.newKeyPair()
        pc = FakePc("123456", other.private, other.point)
        openPad("123456")
        assertNotNull("the tablet says HELLO", pc.next(PadProtocol.HELLO))
        assertNotNull("the warning shows", device.wait(Until.findObject(By.textContains("This is not the PC you paired with as “TEST-PC”")), 8000))
        assertNotNull("with the new PC check", device.findObject(By.textContains(PadCrypto.pcCheck(other.point))))
        assertNull("nothing is sent after HELLO (no PROOF, nothing made with the code)", pc.got.poll(2, TimeUnit.SECONDS))
        shot("25 not the PC you paired with")

        // the presenter knows the PC was reinstalled
        press("Connect anyway")
        assertNotNull("Connect anyway says HELLO again", pc.next(PadProtocol.HELLO))
        firstTimeCheckShows(PadCrypto.pcCheck(other.point))
        press("It matches")
        assertNotNull("then the PROOF", pc.next(PadProtocol.PROOF))
        assertNotNull("and the pictures", pc.next(PadProtocol.FRAME_ACK))
        assertArrayEquals("the new key is remembered now", other.point,
            Base64.getDecoder().decode(prefs.getString(PadActivity.PIN_PREFIX + "TEST-PC", "")))
    }

    @Test fun aPcCheckThatDoesntMatchSendsNothing() {
        openPad("123456")
        assertNotNull("the tablet says HELLO", pc.next(PadProtocol.HELLO))
        firstTimeCheckShows()
        press("It doesn't")
        assertNotNull("the presenter is told plainly", device.wait(Until.findObject(By.text("Don't connect: this may not be your PC.")), 4000))
        shot("26 the PC check doesn't match")
        assertNull("nothing is sent after HELLO, ever", pc.got.poll(3, TimeUnit.SECONDS))
        assertNotNull("back on the connect screen", device.findObject(By.desc("Connect")))
        assertNull("the PC isn't remembered", prefs.getString(PadActivity.PIN_PREFIX + "TEST-PC", null))
    }

    @Test fun aPcCheckLeftUnansweredCloses() {
        openPad("123456")
        assertNotNull("the tablet says HELLO", pc.next(PadProtocol.HELLO))
        firstTimeCheckShows()
        assertNotNull("after about 25 s the tablet gives up and says so", device.wait(Until.findObject(
            By.text("Took too long: tap Connect again.")), PadConnection.CHECK_WAIT_MS + 8000))
        assertNull("nothing was sent after HELLO", pc.got.poll(1, TimeUnit.SECONDS))
        assertNull("the question is gone", device.findObject(By.desc("It matches")))
    }

    @Test fun theUsbCableOpensThePadWithNoCodeTyped() {
        val usb = FakePc("", port = PadProtocol.USB_PORT).also { cable = it }
        openPadEmpty()
        assertNotNull("the tablet tries the cable by itself (HELLO)", usb.next(PadProtocol.HELLO, 10000))
        // the cable proves nothing (any app on the tablet can listen there): the first time, the PC check is asked
        // about, as on Wi-Fi, before anything else goes
        assertNotNull("the first time over the cable, the PC check is asked about", device.wait(Until.findObject(
            By.text("First time with TEST-PC on the USB cable: does the PC show the PC check 6FC6-6A90-4861-71CA? (⚙ Settings, beside the code)")), 8000))
        assertNull("nothing is sent after HELLO while the check is open", usb.got.poll(2, TimeUnit.SECONDS))
        shot("27a first time over the cable, the PC check")
        press("It matches")
        assertNotNull("then the PROOF, made with the empty code", usb.next(PadProtocol.PROOF))
        assertNotNull("the pictures come", usb.next(PadProtocol.FRAME_ACK))
        assertNotNull("the title says the cable", device.wait(Until.findObject(By.text("TEST-PC · By the USB cable")), 4000))
        assertNull("the question is gone", device.findObject(By.desc("It matches")))
        assertArrayEquals("the PC's key is remembered under its own name", FakePc.VECTOR_PC_KEY,
            Base64.getDecoder().decode(prefs.getString(PadActivity.PIN_PREFIX + "TEST-PC", "")))
        device.waitForIdle()
        shot("27 by the USB cable")

        // unplugged, with no code typed this session: the connect screen
        usb.close()
        assertNotNull("back to the connect screen", device.wait(Until.findObject(By.desc("Connect")), 10000))
        assertNotNull("saying why", device.findObject(By.textStartsWith("The USB connection to the PC ended.")))
    }

    /** Something on the cable that isn't the PC (another app on the tablet): "It doesn't", nothing sent, not asked again. */
    @Test fun aPcCheckThatDoesntMatchOverTheCableSendsNothing() {
        val usb = FakePc("", port = PadProtocol.USB_PORT).also { cable = it }
        openPadEmpty()
        assertNotNull("the tablet tries the cable by itself (HELLO)", usb.next(PadProtocol.HELLO, 10000))
        assertNotNull("the PC check is asked about", device.wait(Until.findObject(By.textStartsWith("First time with TEST-PC on the USB cable")), 8000))
        press("It doesn't")
        assertNotNull("the presenter is told plainly", device.wait(Until.findObject(By.text("Don't connect: this may not be your PC.")), 4000))
        assertNull("nothing is sent after HELLO, and the cable isn't tried again by itself", usb.got.poll(6, TimeUnit.SECONDS))
        assertNull("the PC isn't remembered", prefs.getString(PadActivity.PIN_PREFIX + "TEST-PC", null))
        shot("27c the cable's PC check doesn't match")
    }

    @Test fun theCableTakesOverFromWifiAndHandsBack() {
        openPad("123456")
        assertNotNull(pc.next(PadProtocol.HELLO))
        firstTimeCheckShows()
        press("It matches")
        assertNotNull("connected over Wi-Fi", pc.next(PadProtocol.FRAME_ACK))
        assertNotNull(device.wait(Until.findObject(By.text("TEST-PC")), 4000))

        // plugged in: the cable takes over (the same PC: its key is known, nothing asked)
        val usb = FakePc("", port = PadProtocol.USB_PORT).also { cable = it }
        assertNotNull("the tablet tries the cable (HELLO)", usb.next(PadProtocol.HELLO, 10000))
        assertNotNull("PROOF over the cable", usb.next(PadProtocol.PROOF))
        assertNotNull("pictures over the cable", usb.next(PadProtocol.FRAME_ACK))
        assertNotNull("the tablet closed its Wi-Fi session", pc.ended.poll(5, TimeUnit.SECONDS))
        assertNotNull("the title says the cable", device.wait(Until.findObject(By.text("TEST-PC · By the USB cable")), 4000))
        pc.got.clear()
        assertNull("no Wi-Fi tries while the cable is open", pc.next(PadProtocol.HELLO, 5000))
        shot("28 the cable took over")

        // unplugged: back to Wi-Fi by itself, with the code typed earlier
        usb.close()
        assertNotNull("the tablet says HELLO on Wi-Fi again by itself", pc.next(PadProtocol.HELLO, 10000))
        assertNotNull("the code it held gets it back in (PROOF)", pc.next(PadProtocol.PROOF))
        assertNotNull("and the pictures come back over Wi-Fi", pc.next(PadProtocol.FRAME_ACK))
        assertNotNull("the title no longer says the cable", device.wait(Until.findObject(By.text("TEST-PC")), 4000))
        assertNull("no \"Lost the PC\"", device.findObject(By.text("Lost the PC")))
        shot("29 back on Wi-Fi")
    }
}
