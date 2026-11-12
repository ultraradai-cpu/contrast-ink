package ink.contrast.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

data class Pt(val x: Float, val y: Float)

/** Points for the shape tools (the same rules as the Windows app's Shapes.cs and the iPad app). */
object Shapes {
    /**
     * An arrow from [from] to [to]: the shaft, then the two sides of the head.
     * The head grows with the line width and the arrow's length (but never past half the arrow).
     */
    fun arrow(from: Pt, to: Pt, width: Float): List<Pt> {
        val dx = to.x - from.x
        val dy = to.y - from.y
        val len = sqrt(dx * dx + dy * dy)
        if (len < 1f) return listOf(from, to)
        val head = min(max(width * 4f, len * 0.25f), len * 0.5f)
        val ux = dx / len
        val uy = dy / len
        val angle = PI / 7   // about 26° each side
        fun side(a: Double) = Pt(
            (to.x - head * (ux * cos(a) - uy * sin(a))).toFloat(),
            (to.y - head * (uy * cos(a) + ux * sin(a))).toFloat(),
        )
        return listOf(from, to, side(angle), to, side(-angle))
    }

    /** An oval fitting the box from [a] to [b] (any corner order), closed. */
    fun oval(a: Pt, b: Pt, segments: Int = 72): List<Pt> {
        val cx = (a.x + b.x) / 2
        val cy = (a.y + b.y) / 2
        val rx = abs(b.x - a.x) / 2
        val ry = abs(b.y - a.y) / 2
        val pts = (0..segments).map { i ->
            val t = 2 * PI * i / segments
            Pt((cx + rx * cos(t)).toFloat(), (cy + ry * sin(t)).toFloat())
        }.toMutableList()
        pts[segments] = pts[0]   // exactly closed
        return pts
    }

    /** A perfect circle (the larger side wins), keeping the starting corner. */
    fun square(start: Pt, end: Pt): Pt {
        val w = end.x - start.x
        val h = end.y - start.y
        val s = max(abs(w), abs(h))
        return Pt(start.x + if (w < 0) -s else s, start.y + if (h < 0) -s else s)
    }

    /** A drag too small to be a shape (a tap) leaves nothing behind. */
    fun tooSmall(a: Pt, b: Pt): Boolean = abs(b.x - a.x) < 4f && abs(b.y - a.y) < 4f

    /** Whether a line through [points] passes within [radius] of [p] (the eraser touching a mark). */
    fun touches(points: List<Pt>, p: Pt, radius: Float): Boolean {
        if (points.size == 1) return hypot(points[0].x - p.x, points[0].y - p.y) <= radius
        for (i in 1 until points.size) if (distanceToSegment(p, points[i - 1], points[i]) <= radius) return true
        return false
    }

    fun distanceToSegment(p: Pt, a: Pt, b: Pt): Float {
        val dx = b.x - a.x
        val dy = b.y - a.y
        val len2 = dx * dx + dy * dy
        if (len2 == 0f) return hypot(p.x - a.x, p.y - a.y)
        val t = (((p.x - a.x) * dx + (p.y - a.y) * dy) / len2).coerceIn(0f, 1f)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/** Fading ink: a mark stays fully visible for a while, then fades out and is removed. */
object Fade {
    const val HOLD_MS = 2000L
    const val OUT_MS = 1000L

    /** How visible a fading mark is at this age: 1 = fully, 0 = gone (remove it). */
    fun opacity(ageMs: Long): Float {
        if (ageMs <= HOLD_MS) return 1f
        val t = (ageMs - HOLD_MS).toFloat() / OUT_MS
        return if (t >= 1f) 0f else 1f - t
    }
}

/**
 * The marks on screen and their undo history. Every change the presenter makes is a step that can be undone
 * (Clear too); a change that is not the presenter's (fading ink going away) is not.
 * Generic over the drawing type, so it is tested with plain values.
 */
class Marks<D>(private val empty: D, private val historyLimit: Int = 300) {
    var drawing: D = empty
        private set
    private val history = ArrayDeque<D>()

    val canUndo get() = history.isNotEmpty()

    fun commit(new: D) {
        if (new == drawing) return
        history.addLast(drawing)
        while (history.size > historyLimit) history.removeFirst()
        drawing = new
    }

    fun replaceQuietly(new: D) { drawing = new }

    fun clear() = commit(empty)

    /**
     * Goes back one step. [cleaning] takes out what must not come back (marks that already faded away); a step that
     * only differed by those is skipped, as in the Windows app. False when there was nothing to undo.
     */
    fun undo(cleaning: (D) -> D = { it }): Boolean {
        while (history.isNotEmpty()) {
            val restored = cleaning(history.removeLast())
            if (restored == drawing) continue
            drawing = restored
            return true
        }
        return false
    }
}

enum class Tool { PEN, HIGHLIGHTER, ARROW, OVAL, ERASER }

/** What the app remembers between lectures. The same colours, widths and tools as the Windows and iPad apps. */
data class Settings(
    val tool: Tool = Tool.PEN,
    val color: Int = 0,
    val width: Int = 1,
    val fadingInk: Boolean = false,
    /** Off: only a stylus draws; a finger touching the drawing layer switches drawing off (so the next tap reaches the app below). */
    val fingerDraws: Boolean = true,
    /** The stylus's side button undoes the last mark. */
    val stylusButtonUndoes: Boolean = true,
    /** The stylus's eraser end removes the marks it touches, whatever tool is chosen. */
    val stylusEraserEnd: Boolean = true,
) {
    /** Keeps every value in range, so an old or damaged saved copy can't break the app. */
    fun cleaned() = copy(color = color.coerceIn(0, COLORS.size - 1), width = width.coerceIn(0, WIDTHS.size - 1))

    companion object {
        // red, yellow, green, cyan and white stand out on dark MR/CT images; black is for white slides; red works on both
        val COLORS = listOf(0xFFFF3B30, 0xFFFFD60A, 0xFF34C759, 0xFF00D4FF, 0xFFFFFFFF, 0xFF111111).map { it.toInt() }
        val COLOR_NAMES = listOf("Red", "Yellow", "Green", "Cyan", "White", "Black")
        /** Pen thickness in density-independent pixels: thin for labels, thick to be seen in a video. */
        val WIDTHS = listOf(3f, 6f, 10f)
        val WIDTH_NAMES = listOf("Thin", "Medium", "Thick")

        /** The highlighter is a wide, see-through version of the same thickness. */
        fun highlighterWidth(width: Float) = width * 4 + 6

        /** Reads a saved copy ("key=value" lines). Anything missing or unreadable keeps its default. */
        fun decode(text: String?): Settings {
            if (text.isNullOrBlank()) return Settings()
            val v = text.lines().mapNotNull { l -> l.split('=', limit = 2).takeIf { it.size == 2 }?.let { it[0].trim() to it[1].trim() } }.toMap()
            val d = Settings()
            return Settings(
                tool = v["tool"]?.let { t -> Tool.entries.firstOrNull { it.name == t } } ?: d.tool,
                color = v["color"]?.toIntOrNull() ?: d.color,
                width = v["width"]?.toIntOrNull() ?: d.width,
                fadingInk = v["fadingInk"]?.toBooleanStrictOrNull() ?: d.fadingInk,
                fingerDraws = v["fingerDraws"]?.toBooleanStrictOrNull() ?: d.fingerDraws,
                stylusButtonUndoes = v["stylusButtonUndoes"]?.toBooleanStrictOrNull() ?: d.stylusButtonUndoes,
                stylusEraserEnd = v["stylusEraserEnd"]?.toBooleanStrictOrNull() ?: d.stylusEraserEnd,
            ).cleaned()
        }
    }

    fun encode(): String = listOf(
        "tool=${tool.name}", "color=$color", "width=$width", "fadingInk=$fadingInk", "fingerDraws=$fingerDraws",
        "stylusButtonUndoes=$stylusButtonUndoes", "stylusEraserEnd=$stylusEraserEnd",
    ).joinToString("\n")
}

/** "4:05", or "1:04:05" past an hour: the recording timer on the toolbar. */
fun clock(ms: Long): String {
    val s = max(0L, ms) / 1000
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
}

/** The recording's size and file name, decided without Android so they are tested anywhere. */
object Recording {
    /**
     * The video's size for a screen of [screenW] x [screenH]: the screen's shape, at most 1920 on the long side,
     * both sides multiples of 16 (what hardware video encoders handle everywhere). [supported] says whether the
     * phone's encoder takes a size; when it doesn't, smaller sizes are tried, down to 640 on the long side.
     */
    fun videoSize(screenW: Int, screenH: Int, supported: (Int, Int) -> Boolean = { _, _ -> true }): Pair<Int, Int> {
        val long = maxOf(screenW, screenH, 1)
        var last = 0 to 0
        for (limit in intArrayOf(1920, 1600, 1280, 960, 640)) {
            val scale = minOf(1f, limit.toFloat() / long)
            val w = maxOf(16, (screenW * scale).toInt() / 16 * 16)
            val h = maxOf(16, (screenH * scale).toInt() / 16 * 16)
            last = w to h
            if (supported(w, h)) return last
        }
        return last
    }

    /** "Lecture 2026-11-12 093015.mp4", or "Lecture 2026-11-12 093015 (2).mp4" when that name is taken. */
    fun fileName(stamp: String, taken: (String) -> Boolean): String {
        var name = "Lecture $stamp.mp4"
        var n = 2
        while (taken(name)) name = "Lecture $stamp (${n++}).mp4"
        return name
    }
}
