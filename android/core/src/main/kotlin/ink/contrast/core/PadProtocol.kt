package ink.contrast.core

import java.io.ByteArrayOutputStream

/**
 * Pad mode: the tablet is a wireless drawing pad for a PC running Contrast Ink. This is the link between them,
 * exactly as docs/pad-protocol.md writes it down (the Windows and iPad apps follow the same page). Plain Kotlin
 * with no Android code, so every byte is checked by the tests on any machine.
 *
 * Every message is [type: 1 byte][length: 4 bytes, big-endian][payload]. Coordinates are fractions of the PC's
 * screen (0 = left/top, 1 = right/bottom), so the tablet never needs to know the PC's pixels.
 */
object PadProtocol {
    const val SERVICE_TYPE = "_contrastink._tcp"
    const val DEFAULT_PORT = 47820
    const val VERSION = 1
    /** A length over this closes the connection: no real message is that big, so the stream is broken. */
    const val MAX_LENGTH = 16 * 1024 * 1024

    // tablet -> PC
    const val HELLO = 0x01
    const val PING = 0x02
    const val FRAME_ACK = 0x03
    const val STROKE_BEGIN = 0x10
    const val STROKE_POINTS = 0x11
    const val STROKE_END = 0x12
    const val STROKE_CANCEL = 0x13
    const val HOVER = 0x14
    const val HOVER_END = 0x15
    const val COMMAND = 0x20

    // PC -> tablet
    const val WELCOME = 0x81
    const val REJECT = 0x82
    const val FRAME = 0x83
    const val STATE = 0x84
    const val PONG = 0x85

    /** The most points one STROKE_POINTS can carry (its count is a u16); more are split over several messages. */
    const val MAX_POINTS = 0xFFFF

    /** One message: the type, the length and the payload. */
    fun message(type: Int, payload: ByteArray = ByteArray(0)): ByteArray {
        require(type in 0..255) { "type is one byte" }
        require(payload.size <= MAX_LENGTH) { "payload over 16 MB" }
        val out = ByteArray(5 + payload.size)
        out[0] = type.toByte()
        putInt(out, 1, payload.size)
        payload.copyInto(out, 5)
        return out
    }

    /** The first message, always: the code the PC shows, and what the tablet is (shown on the PC). */
    fun hello(code: String, device: String): ByteArray = message(HELLO,
        Json.obj("code" to code, "device" to device, "version" to VERSION).toByteArray(Charsets.UTF_8))

    fun ping() = message(PING)
    fun frameAck() = message(FRAME_ACK)

    /** A pen or finger touched the picture. [eraserEnd]: the stylus's eraser end touched, not its tip. */
    fun strokeBegin(x: Float, y: Float, eraserEnd: Boolean): ByteArray {
        val p = ByteArray(9)
        putFloat(p, 0, x); putFloat(p, 4, y)
        p[8] = if (eraserEnd) 1 else 0
        return message(STROKE_BEGIN, p)
    }

    /**
     * More points of the stroke, [xy] as x, y, x, y... Batched (every ~16 ms) rather than one message per touch
     * event: fewer packets on a busy Wi-Fi, and the PC draws a whole batch at once.
     */
    fun strokePoints(xy: FloatArray, count: Int = xy.size / 2): ByteArray {
        require(count * 2 <= xy.size) { "fewer coordinates than points" }
        val out = ByteArrayOutputStream()
        var start = 0
        do {   // an empty batch is still one (valid) message
            val n = minOf(count - start, MAX_POINTS)
            val p = ByteArray(2 + n * 8)
            p[0] = (n shr 8).toByte(); p[1] = n.toByte()
            for (i in 0 until n) {
                putFloat(p, 2 + i * 8, xy[(start + i) * 2])
                putFloat(p, 6 + i * 8, xy[(start + i) * 2 + 1])
            }
            out.write(message(STROKE_POINTS, p))
            start += n
        } while (start < count)
        return out.toByteArray()
    }

    fun strokeEnd() = message(STROKE_END)
    /** A palm or a second finger: the PC drops the stroke instead of keeping it. */
    fun strokeCancel() = message(STROKE_CANCEL)

    /** The pen above the glass (the laser's dot). */
    fun hover(x: Float, y: Float): ByteArray {
        val p = ByteArray(8)
        putFloat(p, 0, x); putFloat(p, 4, y)
        return message(HOVER, p)
    }

    fun hoverEnd() = message(HOVER_END)

    /** A toolbar button: one of [Commands]. */
    fun command(text: String) = message(COMMAND, text.toByteArray(Charsets.UTF_8))

    /** The words of COMMAND messages. */
    object Commands {
        const val UNDO = "undo"
        const val CLEAR = "clear"
        const val NEXT = "next"
        const val PREVIOUS = "previous"
        const val FADE_ON = "fade:on"
        const val FADE_OFF = "fade:off"
        /** pen, highlighter, arrow, oval, eraser or laser. */
        fun tool(t: Tool) = "tool:" + toolName(t)
        fun color(n: Int): String { require(n in 0..5); return "color:$n" }
        fun width(n: Int): String { require(n in 0..2); return "width:$n" }
        fun opacity(f: Float) = "opacity:" + f.coerceIn(Settings.MIN_OPACITY, 1f)
    }

    /** The protocol's name for a tool (the circle tool is "oval" on the wire, as in the Windows app). */
    fun toolName(t: Tool) = t.name.lowercase()
    fun toolFromName(name: String?): Tool? = Tool.entries.firstOrNull { it.name.equals(name, ignoreCase = true) }

    /**
     * Where to reach a PC typed by hand: "192.168.1.20" or "192.168.1.20:47820" (an IPv6 address in brackets
     * when it has a port: "[fe80::1]:47820"). Null when it can't be an address.
     */
    fun parseAddress(text: String): Pair<String, Int>? {
        val t = text.trim()
        if (t.isEmpty() || t.any { it.isWhitespace() }) return null
        val host: String
        val port: Int
        if (t.startsWith("[")) {
            val close = t.indexOf(']')
            if (close < 2) return null
            host = t.substring(1, close)
            val rest = t.substring(close + 1)
            port = when {
                rest.isEmpty() -> DEFAULT_PORT
                rest.startsWith(":") -> rest.substring(1).toIntOrNull() ?: return null
                else -> return null
            }
        } else if (t.count { it == ':' } > 1) {
            host = t; port = DEFAULT_PORT   // a bare IPv6 address
        } else {
            val colon = t.indexOf(':')
            host = if (colon < 0) t else t.substring(0, colon)
            port = if (colon < 0) DEFAULT_PORT else t.substring(colon + 1).toIntOrNull() ?: return null
        }
        if (host.isEmpty() || port !in 1..65535) return null
        return host to port
    }

    /** A 6-digit code, as the PC shows it. */
    fun validCode(code: String) = code.length == 6 && code.all { it in '0'..'9' }

    internal fun putInt(b: ByteArray, at: Int, v: Int) {
        b[at] = (v ushr 24).toByte(); b[at + 1] = (v ushr 16).toByte(); b[at + 2] = (v ushr 8).toByte(); b[at + 3] = v.toByte()
    }

    internal fun putFloat(b: ByteArray, at: Int, f: Float) = putInt(b, at, java.lang.Float.floatToIntBits(f))
}

/** What the PC sends. */
sealed class PcMessage {
    data class Welcome(val name: String, val screenW: Int, val screenH: Int, val version: Int) : PcMessage()
    data class Reject(val reason: String) : PcMessage()
    class Frame(val jpeg: ByteArray) : PcMessage()
    /** The PC's current tool, colour, width... (the PC is the one place they live; the tablet's toolbar follows). */
    data class State(val tool: Tool?, val color: Int, val width: Int, val opacity: Float, val fading: Boolean,
                     val canUndo: Boolean) : PcMessage()
    object Pong : PcMessage()
}

class PadProtocolException(message: String) : Exception(message)

/**
 * Reads the PC's messages from a stream of bytes that arrive in pieces of any size (TCP gives no message
 * boundaries). Unknown types are skipped without keeping their bytes, so a newer PC can add messages; a length
 * over 16 MB means the stream is broken, and [feed] throws.
 */
class PadDecoder {
    private val header = ByteArray(5)
    private var headerHave = 0
    private var type = 0
    private var payload: ByteArray? = null   // null while skipping an unknown type
    private var remaining = 0                // payload bytes still to come
    private var payloadHave = 0
    private var failed: String? = null

    fun feed(bytes: ByteArray, offset: Int = 0, length: Int = bytes.size - offset): List<PcMessage> {
        failed?.let { throw PadProtocolException(it) }
        val out = ArrayList<PcMessage>()
        var i = offset
        val end = offset + length
        while (i < end) {
            if (headerHave < 5) {
                val n = minOf(5 - headerHave, end - i)
                bytes.copyInto(header, headerHave, i, i + n)
                headerHave += n; i += n
                if (headerHave < 5) break
                type = header[0].toInt() and 0xFF
                val len = ((header[1].toLong() and 0xFF) shl 24) or ((header[2].toLong() and 0xFF) shl 16) or
                    ((header[3].toLong() and 0xFF) shl 8) or (header[4].toLong() and 0xFF)
                if (len > PadProtocol.MAX_LENGTH) {
                    failed = "A message of $len bytes (over 16 MB): the connection is broken"
                    throw PadProtocolException(failed!!)
                }
                remaining = len.toInt()
                payloadHave = 0
                payload = if (known(type)) ByteArray(remaining) else null
            }
            val n = minOf(remaining, end - i)
            payload?.let { bytes.copyInto(it, payloadHave, i, i + n) }
            payloadHave += n; remaining -= n; i += n
            if (remaining == 0) {
                payload?.let { p -> parse(type, p)?.let { out += it } }
                headerHave = 0
                payload = null
            }
        }
        return out
    }

    private fun known(t: Int) = t == PadProtocol.WELCOME || t == PadProtocol.REJECT || t == PadProtocol.FRAME ||
        t == PadProtocol.STATE || t == PadProtocol.PONG

    /** A known message, or null when its JSON can't be read (one bad message doesn't drop the connection). */
    private fun parse(t: Int, p: ByteArray): PcMessage? = when (t) {
        PadProtocol.WELCOME -> Json.parseObject(p.toString(Charsets.UTF_8))?.let { o ->
            PcMessage.Welcome(o["name"] as? String ?: "PC", (o["screenW"] as? Double)?.toInt() ?: 0,
                (o["screenH"] as? Double)?.toInt() ?: 0, (o["version"] as? Double)?.toInt() ?: PadProtocol.VERSION)
        }
        PadProtocol.REJECT -> PcMessage.Reject(p.toString(Charsets.UTF_8))
        PadProtocol.FRAME -> PcMessage.Frame(p)
        PadProtocol.STATE -> Json.parseObject(p.toString(Charsets.UTF_8))?.let { o ->
            PcMessage.State(PadProtocol.toolFromName(o["tool"] as? String), (o["color"] as? Double)?.toInt() ?: 0,
                (o["width"] as? Double)?.toInt() ?: 1, (o["opacity"] as? Double)?.toFloat() ?: 1f,
                o["fading"] as? Boolean ?: false, o["canUndo"] as? Boolean ?: false)
        }
        PadProtocol.PONG -> PcMessage.Pong
        else -> null
    }
}

/**
 * Just enough JSON for the pad's small messages (core has no JSON library and needs none). Reads objects, arrays,
 * strings, numbers (as Double), true, false and null; anything malformed gives null rather than an exception.
 * Nesting is limited, so a hostile message can't overflow the stack.
 */
object Json {
    fun obj(vararg fields: Pair<String, Any?>): String = fields.joinToString(",", "{", "}") { (k, v) ->
        quote(k) + ":" + when (v) {
            null -> "null"
            is String -> quote(v)
            is Boolean, is Int, is Long -> v.toString()
            is Number -> if (v.toDouble().isFinite()) v.toString() else "null"
            else -> quote(v.toString())
        }
    }

    fun quote(s: String): String {
        val b = StringBuilder(s.length + 2).append('"')
        for (c in s) when {
            c == '"' -> b.append("\\\"")
            c == '\\' -> b.append("\\\\")
            c == '\n' -> b.append("\\n")
            c == '\r' -> b.append("\\r")
            c == '\t' -> b.append("\\t")
            c < ' ' -> b.append("\\u%04x".format(c.code))
            else -> b.append(c)
        }
        return b.append('"').toString()
    }

    @Suppress("UNCHECKED_CAST")
    fun parseObject(text: String): Map<String, Any?>? = parse(text) as? Map<String, Any?>

    fun parse(text: String): Any? = try {
        val r = Reader(text)
        val v = r.value(0)
        r.space()
        if (r.i != text.length) null else v
    } catch (e: IllegalArgumentException) { null } catch (e: IndexOutOfBoundsException) { null }

    private class Reader(val s: String) {
        var i = 0
        fun space() { while (i < s.length && s[i].isWhitespace()) i++ }
        fun value(depth: Int): Any? {
            require(depth < 32)
            space()
            return when (s[i]) {
                '{' -> {
                    i++
                    val m = LinkedHashMap<String, Any?>()
                    space()
                    if (s[i] == '}') { i++; return m }
                    while (true) {
                        space()
                        require(s[i] == '"')
                        val k = string()
                        space(); require(s[i++] == ':')
                        m[k] = value(depth + 1)
                        space()
                        when (s[i++]) { ',' -> continue; '}' -> return m; else -> throw IllegalArgumentException() }
                    }
                }
                '[' -> {
                    i++
                    val l = ArrayList<Any?>()
                    space()
                    if (s[i] == ']') { i++; return l }
                    while (true) {
                        l += value(depth + 1)
                        space()
                        when (s[i++]) { ',' -> continue; ']' -> return l; else -> throw IllegalArgumentException() }
                    }
                }
                '"' -> string()
                't' -> word("true", true)
                'f' -> word("false", false)
                'n' -> word("null", null)
                else -> number()
            }
        }

        fun word(w: String, v: Any?): Any? { require(s.startsWith(w, i)); i += w.length; return v }

        fun number(): Double {
            val start = i
            while (i < s.length && (s[i].isDigit() || s[i] in "+-.eE")) i++
            return s.substring(start, i).toDoubleOrNull()?.takeIf { it.isFinite() } ?: throw IllegalArgumentException()
        }

        fun string(): String {
            i++   // the opening quote
            val b = StringBuilder()
            while (true) {
                val c = s[i++]
                when {
                    c == '"' -> return b.toString()
                    c == '\\' -> when (val e = s[i++]) {
                        '"', '\\', '/' -> b.append(e)
                        'b' -> b.append('\b'); 'f' -> b.append('\u000C'); 'n' -> b.append('\n')
                        'r' -> b.append('\r'); 't' -> b.append('\t')
                        'u' -> { b.append(s.substring(i, i + 4).toInt(16).toChar()); i += 4 }
                        else -> throw IllegalArgumentException()
                    }
                    else -> b.append(c)
                }
            }
        }
    }
}
