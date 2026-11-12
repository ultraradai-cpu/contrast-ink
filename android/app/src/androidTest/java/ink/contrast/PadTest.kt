package ink.contrast

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import ink.contrast.core.Json
import ink.contrast.core.PadProtocol
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Pad mode on an Android emulator, against a stand-in PC in the test itself (a server on 127.0.0.1 that speaks
 * docs/pad-protocol.md): the code is checked, the PC's picture shows, a swipe on the pad reaches the PC as a stroke
 * in fractions of the picture, and the toolbar's buttons reach it as commands. Screenshots of each step are kept.
 */
@RunWith(AndroidJUnit4::class)
class PadTest {
    private val inst = InstrumentationRegistry.getInstrumentation()
    private val device = UiDevice.getInstance(inst)
    private val ctx = inst.targetContext
    private val shots = File(ctx.getExternalFilesDir(null), "shots")
    private lateinit var pc: FakePc

    /** A message from the tablet. */
    class Msg(val type: Int, val payload: ByteArray) {
        val text get() = payload.toString(Charsets.UTF_8)
        fun f(i: Int) = ByteBuffer.wrap(payload).getFloat(i)
    }

    /**
     * A stand-in for Contrast Ink on a PC: accepts the tablet, checks HELLO's code, then WELCOME, STATE and one
     * picture. Everything the tablet sends lands in [got] (PING is answered with PONG and left out).
     */
    class FakePc(private val code: String) {
        val server = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
        val got = LinkedBlockingQueue<Msg>()
        @Volatile var client: Socket? = null

        init { Thread({ acceptLoop() }, "fake-pc").apply { isDaemon = true }.start() }

        private fun acceptLoop() {
            while (!server.isClosed) {
                val s = try { server.accept() } catch (e: IOException) { return }
                client = s
                Thread({ serve(s) }, "fake-pc-client").apply { isDaemon = true }.start()
            }
        }

        private fun serve(s: Socket) {
            try {
                val input = DataInputStream(s.getInputStream())
                val out = s.getOutputStream()
                while (true) {
                    val type = input.readUnsignedByte()
                    val payload = ByteArray(input.readInt()).also { input.readFully(it) }
                    val m = Msg(type, payload)
                    when (type) {
                        PadProtocol.PING -> synchronized(out) { out.write(PadProtocol.message(PadProtocol.PONG)) }
                        PadProtocol.HELLO -> {
                            got += m
                            if (Json.parseObject(m.text)?.get("code") != code) {
                                out.write(PadProtocol.message(PadProtocol.REJECT, "Wrong code".toByteArray()))
                                out.flush(); s.close(); return
                            }
                            synchronized(out) {
                                out.write(PadProtocol.message(PadProtocol.WELCOME,
                                    """{"name":"TEST-PC","screenW":1600,"screenH":900,"version":1}""".toByteArray()))
                                out.write(state(0))
                                out.write(PadProtocol.message(PadProtocol.FRAME, picture()))
                            }
                        }
                        else -> got += m
                    }
                }
            } catch (e: IOException) { /* the tablet left, or the test closed it */ }
        }

        fun state(color: Int) = PadProtocol.message(PadProtocol.STATE,
            """{"tool":"pen","color":$color,"width":1,"opacity":1.0,"fading":false,"canUndo":true}""".toByteArray())

        fun send(bytes: ByteArray) { client?.getOutputStream()?.let { synchronized(it) { it.write(bytes) } } }

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

        fun close() { try { server.close(); client?.close() } catch (e: IOException) {} }

        /** The PC's screen: white with a black square (a slide, as JPEG, 1600 × 900). */
        private fun picture(): ByteArray {
            val b = Bitmap.createBitmap(1600, 900, Bitmap.Config.ARGB_8888)
            Canvas(b).apply {
                drawColor(Color.WHITE)
                drawRect(600f, 250f, 1000f, 650f, Paint().apply { color = Color.BLACK })
            }
            return ByteArrayOutputStream().also { b.compress(Bitmap.CompressFormat.JPEG, 80, it) }.toByteArray()
        }
    }

    @Before fun setUp() {
        shots.mkdirs()
        pc = FakePc("123456")
    }

    @After fun tearDown() {
        inst.runOnMainSync { PadActivity.running?.finish() }
        pc.close()
    }

    private fun shot(name: String) { device.takeScreenshot(File(shots, "$name.png")) }

    private fun openPad(code: String) {
        ctx.startActivity(Intent(ctx, PadActivity::class.java)
            .putExtra(PadActivity.EXTRA_ADDRESS, "127.0.0.1:${pc.server.localPort}")
            .putExtra(PadActivity.EXTRA_CODE, code)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
    }

    private fun press(name: String) {
        val b = device.wait(Until.findObject(By.desc(name)), 4000)
        assertNotNull("pad toolbar button \"$name\"", b)
        b.click()
    }

    @Test fun drawsOnThePcsPictureAndSendsCommands() {
        openPad("123456")
        val hello = pc.next(PadProtocol.HELLO)
        assertNotNull("the tablet says HELLO", hello)
        val json = Json.parseObject(hello!!.text)!!
        assertEquals("HELLO carries the code", "123456", json["code"])
        assertEquals("HELLO carries the version", 1.0, json["version"])
        assertNotNull("the tablet acknowledges the picture once it is on screen (FRAME_ACK)", pc.next(PadProtocol.FRAME_ACK))
        assertNotNull("the toolbar shows", device.wait(Until.findObject(By.desc("Undo")), 4000))
        device.waitForIdle()
        shot("20 pad shows the PC's screen")

        // a swipe across the picture: from 20% to 80% across, 40% to 60% down
        var r = RectF()
        inst.runOnMainSync { r = PadActivity.running!!.pad.pictureOnScreen() }
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

        // the PC goes away: the pad says so and offers to reconnect
        pc.client?.close()
        assertNotNull("\"Lost the PC\" shows", device.wait(Until.findObject(By.text("Lost the PC")), 10000))
        shot("23 lost the PC")
        pc.got.clear()
        press("Reconnect")
        assertNotNull("Reconnect says HELLO again", pc.next(PadProtocol.HELLO))
        assertNotNull("and the picture comes back", pc.next(PadProtocol.FRAME_ACK))
        assertTrue("the lost message goes", device.wait(Until.gone(By.text("Lost the PC")), 4000))
    }

    @Test fun aWrongCodeIsRefused() {
        openPad("000000")
        assertNotNull("the tablet says HELLO", pc.next(PadProtocol.HELLO))
        assertNotNull("the PC's reason shows", device.wait(Until.findObject(By.text("Wrong code")), 8000))
        shot("24 wrong code")
        assertNotNull("back on the connect screen", device.findObject(By.desc("Connect")))
    }
}
