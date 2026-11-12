package ink.contrast

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import ink.contrast.core.PadClient
import ink.contrast.core.PadCrypto
import ink.contrast.core.PadDecoder
import ink.contrast.core.PadProtocol
import ink.contrast.core.PcMessage
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * One connection to a PC in pad mode, version 2 of docs/pad-protocol.md: HELLO with a fresh key, the PC's
 * CHALLENGE (its key checked against the one remembered for its name), PROOF, then everything sealed (PadClient).
 * The first time with a PC, the PROOF waits until the presenter says the PC check matches ([confirm]).
 *
 * The network never runs on the main thread (Android forbids it, and a slow Wi-Fi would freeze the drawing): a
 * reader thread takes the PC's messages, one writer thread seals and sends ours in order (the seal's counter must
 * follow the order on the wire), and a timer pings every 2 s. Everything the screen needs is handed back on the main
 * thread through [Listener], always with the connection it came from, so the screen can ignore an old one.
 */
class PadConnection(
    private val host: String,
    private val port: Int,
    code: String,
    device: String,
    private val pins: Pins,
    /** The name the presenter chose the PC by (its name on the network), or null for a typed address (the PC's own name). */
    private val chosenName: String?,
    /** The key the presenter chose "Connect anyway" for, after the warning that the PC's key changed; or null. */
    private val acceptAnyway: ByteArray?,
    private val listener: Listener,
) {
    interface Listener {
        /**
         * The PC said who it is (CHALLENGE). [needsCheck]: met for the first time: nothing is sent until the presenter
         * compares [pcCheck] with the PC's and calls [confirm] (or [decline]); after [CHECK_WAIT_MS] it ends.
         */
        fun onPc(c: PadConnection, name: String, pcCheck: String, needsCheck: Boolean)
        /** Every message from the PC, opened, on the main thread (FRAME too: decode its JPEG off the main thread). */
        fun onMessage(c: PadConnection, m: PcMessage)
        /** The link is gone (called once, never after [close]). */
        fun onClosed(c: PadConnection, end: End)
    }

    /** The PCs' keys the tablet remembers, by the PC's name. Called on the reader thread. */
    interface Pins {
        fun remembered(name: String): ByteArray?
        fun remember(name: String, key: ByteArray)
    }

    enum class Why {
        /** No connection at all (wrong address, other network, the PC's pad switched off). */
        UNREACHABLE,
        /** Connected, then gone (Wi-Fi drop, the PC closed Contrast Ink, silence). */
        LOST,
        /** The PC said no: [End.pcText] is its reason. */
        REJECTED,
        /** Another key under a remembered name: nothing was sent after HELLO. */
        KEY_CHANGED,
        /** The PC runs version 1. */
        OLD_PC,
        /** The PC sent something that breaks the protocol (or can't be opened). */
        BROKEN,
        /** The first-time PC check wasn't answered in time: nothing was sent after HELLO. */
        CHECK_TIMEOUT,
    }

    class End(val why: Why, val everConnected: Boolean, val pcText: String? = null,
              val pcName: String? = null, val pcKey: ByteArray? = null)

    private val main = Handler(Looper.getMainLooper())
    private val writer = Executors.newSingleThreadExecutor { Thread(it, "pad-writer") }
    private val timer: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { Thread(it, "pad-timer") }
    private val client = PadClient(code, device)
    private val closed = AtomicBoolean(false)
    @Volatile private var socket: Socket? = null
    @Volatile private var out: OutputStream? = null
    @Volatile private var connected = false
    @Volatile private var lastHeard = SystemClock.elapsedRealtime()
    @Volatile private var welcomed = false
    @Volatile private var rejected: String? = null
    @Volatile private var pcName: String? = null
    @Volatile private var pcKey: ByteArray? = null
    /** True while the first-time PC check waits for the presenter; whoever turns it off (confirm, decline, the clock) decides. */
    private val awaitingCheck = AtomicBoolean(false)
    @Volatile private var checkTimeout: java.util.concurrent.ScheduledFuture<*>? = null

    fun start() {
        Thread({ run() }, "pad-reader").start()
    }

    /** Sends one message (or several, already joined), sealed, after the ones before it. Dropped until WELCOME and once closed. */
    fun send(bytes: ByteArray) {
        if (closed.get() || !welcomed) return
        write { client.seal(bytes) }
    }

    /** The presenter says the PC shows the same PC check: the PROOF goes. */
    fun confirm() {
        if (!awaitingCheck.compareAndSet(true, false)) return
        checkTimeout?.cancel(false)
        lastHeard = SystemClock.elapsedRealtime()   // the PC said nothing while it waited: that wasn't silence
        write { client.confirm() }
    }

    /** The presenter says the PC shows another PC check: close, nothing sent (no [Listener.onClosed]). */
    fun decline() {
        if (!awaitingCheck.compareAndSet(true, false)) return
        client.decline()
        close()
    }

    /** The presenter left: close quietly (no [Listener.onClosed]). */
    fun close() {
        if (closed.compareAndSet(false, true)) shutdown()
    }

    /** Runs [make] on the writer thread (where sealing happens, in order) and sends what it gives. */
    private fun write(make: () -> ByteArray) {
        try {
            writer.execute {
                val o = out ?: return@execute
                try { o.write(make()); o.flush() }
                catch (e: IOException) { fail(End(Why.LOST, welcomed), e) }
                catch (e: Exception) { fail(End(Why.BROKEN, welcomed), e) }
            }
        } catch (e: RejectedExecutionException) { /* closing */ }
    }

    private fun run() {
        try {
            val s = Socket()
            socket = s
            s.tcpNoDelay = true   // strokes are small messages that must leave at once, not wait to be batched
            s.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
            connected = true
            if (closed.get()) { s.close(); return }
            out = s.getOutputStream()
            lastHeard = SystemClock.elapsedRealtime()
            write { client.hello() }
            // PING every 2 s once in; a PC that says nothing for 6 s (not even PONG) is gone, even if TCP hasn't noticed
            timer.scheduleWithFixedDelay({
                // while the PC check waits for the presenter, the PC waits for the PROOF and says nothing
                if (awaitingCheck.get()) return@scheduleWithFixedDelay
                if (SystemClock.elapsedRealtime() - lastHeard > SILENCE_MS) fail(End(Why.LOST, welcomed), null)
                else send(PadProtocol.ping())
            }, PING_MS, PING_MS, TimeUnit.MILLISECONDS)
            read(s.getInputStream())
            ended(null)   // the PC closed the connection
        } catch (e: PadClient.OldPc) {
            fail(End(Why.OLD_PC, welcomed), e)
        } catch (e: IOException) {
            ended(e)
        } catch (e: Exception) {   // a broken stream, a message that doesn't open, a bad key: never the app's end
            fail(End(Why.BROKEN, welcomed), e)
        }
    }

    /** The socket closed or failed: the PC's own reason if it gave one, else lost or unreachable. */
    private fun ended(e: IOException?) {
        val r = rejected
        fail(when {
            r != null -> End(Why.REJECTED, welcomed, r)
            connected -> End(Why.LOST, welcomed)
            else -> End(Why.UNREACHABLE, false)
        }, e)
    }

    private fun read(input: InputStream) {
        val decoder = PadDecoder()
        val buf = ByteArray(64 * 1024)
        while (!closed.get()) {
            val n = input.read(buf)
            if (n < 0) return
            lastHeard = SystemClock.elapsedRealtime()
            for (outer in decoder.feed(buf, 0, n)) {   // throws on a broken stream: the connection closes
                for (m in client.receive(outer)) {     // throws on anything not sealed by our PC
                    if (closed.get()) return
                    handle(m)
                }
            }
        }
    }

    private fun handle(m: PcMessage) {
        when (m) {
            is PcMessage.Challenge -> {
                // remembered under the name the presenter chose it by: its network name, else the name it gives
                val name = chosenName ?: clean(m.name, 64).ifEmpty { "PC" }
                val check = PadCrypto.pcCheck(m.key)
                when (val a = client.answer(m, pins.remembered(name), acceptAnyway)) {
                    PadClient.Answer.Changed -> {
                        // not the machine paired under this name: stop before sending anything made with the code
                        fail(End(Why.KEY_CHANGED, false, pcName = name, pcKey = m.key), null)
                        return
                    }
                    is PadClient.Answer.Proof -> {
                        pcName = name; pcKey = m.key
                        main.post { if (!closed.get()) listener.onPc(this, name, check, false) }
                        write { a.bytes }
                    }
                    is PadClient.Answer.Check -> {
                        // the first time: no PROOF until the presenter has compared the PC check with the PC's screen
                        pcName = name; pcKey = m.key
                        awaitingCheck.set(true)
                        try {
                            checkTimeout = timer.schedule({
                                if (awaitingCheck.compareAndSet(true, false)) {
                                    client.decline()
                                    fail(End(Why.CHECK_TIMEOUT, false, pcName = name), null)
                                }
                            }, CHECK_WAIT_MS, TimeUnit.MILLISECONDS)
                        } catch (e: RejectedExecutionException) { return /* closing */ }
                        main.post { if (!closed.get()) listener.onPc(this, name, a.pcCheck, true) }
                    }
                }
            }
            is PcMessage.Welcome -> {
                welcomed = true
                // only a PC that knew the code could seal WELCOME: now its key is worth remembering
                val name = pcName; val key = pcKey
                if (name != null && key != null) pins.remember(name, key)
                post(m)
            }
            is PcMessage.Reject -> rejected = clean(m.reason, 300).ifBlank { "The PC said no." }
            else -> post(m)
        }
    }

    private fun post(m: PcMessage) = main.post { if (!closed.get()) listener.onMessage(this, m) }

    private fun fail(end: End, e: Exception?) {
        if (!closed.compareAndSet(false, true)) return
        // the detail is for the log (adb logcat); the presenter gets a plain sentence (PadActivity)
        Log.w(TAG, "pad link to $host:$port ended: ${end.why}", e)
        shutdown()
        main.post { listener.onClosed(this, end) }
    }

    private fun shutdown() {
        timer.shutdownNow()
        writer.shutdown()
        // closing the socket wakes the reader thread from its blocking read; done off the main thread
        Thread { try { socket?.close() } catch (e: IOException) {} }.start()
    }

    /** Text from the PC, shown on screen: no control characters, not endless. */
    private fun clean(s: String, max: Int) = s.filter { !it.isISOControl() }.trim().take(max)

    companion object {
        const val TAG = "ContrastInkPad"
        const val CONNECT_TIMEOUT_MS = 5000
        const val PING_MS = 2000L
        const val SILENCE_MS = 6000L
        /** How long the first-time PC check waits for the presenter (the PC waits 30 s for the PROOF). */
        const val CHECK_WAIT_MS = 25_000L
    }
}
