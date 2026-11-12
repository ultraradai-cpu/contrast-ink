package ink.contrast

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import ink.contrast.core.PadDecoder
import ink.contrast.core.PadProtocol
import ink.contrast.core.PcMessage
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * One connection to a PC in pad mode. The network never runs on the main thread (Android forbids it, and a slow
 * Wi-Fi would freeze the drawing): a reader thread takes the PC's messages, one writer thread sends ours in order,
 * and a timer pings every 2 s. Everything the screen needs is handed back on the main thread through [Listener].
 */
class PadConnection(
    private val host: String,
    private val port: Int,
    private val code: String,
    private val device: String,
    private val listener: Listener,
) {
    interface Listener {
        /** Every message from the PC, on the main thread (FRAME too: decode its JPEG off the main thread). */
        fun onMessage(m: PcMessage)
        /** The link is gone: [reason] is for the presenter. [everConnected]: WELCOME had arrived. Called once. */
        fun onClosed(reason: String, everConnected: Boolean)
    }

    private val main = Handler(Looper.getMainLooper())
    private val writer = Executors.newSingleThreadExecutor { Thread(it, "pad-writer") }
    private val timer: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { Thread(it, "pad-timer") }
    @Volatile private var socket: Socket? = null
    @Volatile private var out: OutputStream? = null
    @Volatile private var lastHeard = SystemClock.elapsedRealtime()
    @Volatile private var welcomed = false
    @Volatile private var closed = false
    @Volatile private var rejected: String? = null

    fun start() {
        Thread({ run() }, "pad-reader").start()
    }

    /** Sends one message (or several, already joined) after the ones before it. Dropped once closed. */
    fun send(bytes: ByteArray) {
        if (closed) return
        try {
            writer.execute {
                val o = out ?: return@execute
                try { o.write(bytes); o.flush() } catch (e: IOException) { fail("Lost the PC") }
            }
        } catch (e: java.util.concurrent.RejectedExecutionException) { /* closing */ }
    }

    /** The presenter left: close quietly (no "lost" message). */
    fun close() {
        closed = true
        shutdown()
    }

    private fun run() {
        try {
            val s = Socket()
            socket = s
            s.tcpNoDelay = true   // strokes are small messages that must leave at once, not wait to be batched
            s.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
            if (closed) { s.close(); return }
            out = s.getOutputStream()
            lastHeard = SystemClock.elapsedRealtime()
            send(PadProtocol.hello(code, device))
            // PING every 2 s; a PC that says nothing for 6 s (not even PONG) is gone, even if TCP hasn't noticed
            timer.scheduleWithFixedDelay({
                if (SystemClock.elapsedRealtime() - lastHeard > SILENCE_MS) fail("Lost the PC")
                else send(PadProtocol.ping())
            }, PING_MS, PING_MS, TimeUnit.MILLISECONDS)
            read(s.getInputStream())
            fail(rejected ?: "Lost the PC")   // the PC closed the connection
        } catch (e: IOException) {
            fail(rejected ?: if (welcomed) "Lost the PC" else "Couldn't reach the PC at $host:$port (${e.message ?: "no answer"})")
        } catch (e: Exception) {
            fail(rejected ?: "Lost the PC (${e.message})")
        }
    }

    private fun read(input: InputStream) {
        val decoder = PadDecoder()
        val buf = ByteArray(64 * 1024)
        while (!closed) {
            val n = input.read(buf)
            if (n < 0) return
            lastHeard = SystemClock.elapsedRealtime()
            for (m in decoder.feed(buf, 0, n)) {   // throws on a broken stream: the connection closes
                when (m) {
                    is PcMessage.Welcome -> welcomed = true
                    is PcMessage.Reject -> rejected = m.reason.ifBlank { "The PC said no" }
                    else -> {}
                }
                main.post { if (!closed) listener.onMessage(m) }
            }
        }
    }

    private fun fail(reason: String) {
        if (closed) return
        closed = true
        shutdown()
        val ever = welcomed
        main.post { listener.onClosed(reason, ever) }
    }

    private fun shutdown() {
        timer.shutdownNow()
        writer.shutdown()
        // closing the socket wakes the reader thread from its blocking read; done off the main thread
        Thread { try { socket?.close() } catch (e: IOException) {} }.start()
    }

    companion object {
        const val CONNECT_TIMEOUT_MS = 5000
        const val PING_MS = 2000L
        const val SILENCE_MS = 6000L
    }
}
