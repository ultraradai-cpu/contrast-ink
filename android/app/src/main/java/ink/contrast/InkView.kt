package ink.contrast

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import ink.contrast.core.Fade
import ink.contrast.core.Laser
import ink.contrast.core.Marks
import ink.contrast.core.Pt
import ink.contrast.core.Settings
import ink.contrast.core.Shapes
import ink.contrast.core.Tool

/** One mark on the screen. Shapes are marks too, so undo, clear and fading treat them alike. */
data class Mark(
    val id: Long,
    val points: List<Pt>,
    val color: Int,
    val width: Float,
    val highlighter: Boolean,
    val smooth: Boolean,
)

/**
 * The drawing layer: covers the whole screen, on top of every app. The service decides whether it takes touches
 * (drawing) or lets them through to the app below.
 */
@SuppressLint("ViewConstructor")
class InkView(context: Context, private val host: Host) : View(context) {
    interface Host {
        val settings: Settings
        /** A finger touched the layer while only a stylus may draw: drawing goes off, so the next tap reaches the app. */
        fun fingerTouched()
        /** The marks changed (the toolbar's undo button, the test's mark count). */
        fun marksChanged()
    }

    private val marks = Marks(emptyList<Mark>())
    private val fading = HashMap<Long, Long>()     // mark id -> when it was drawn (uptime ms)
    private val faded = HashSet<Long>()            // gone by fading: undo never brings these back
    private var nextId = 1L

    private val density = resources.displayMetrics.density
    private var live: MutableList<Pt>? = null      // the line being drawn
    private var liveErasing = false
    private var shapeStart: Pt? = null
    private var shapeEnd: Pt? = null
    private var ignoreGesture = false              // a stylus button press: undo, and this touch draws nothing
    // the laser pointer: never a mark
    private class Glow(val x: Float, val y: Float, val at: Long, val line: Int)
    private val laser = ArrayList<Glow>()
    private var laserLine = 0
    private var laserDot: Pt? = null
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }

    val markCount get() = marks.drawing.size
    /** The laser's line is on screen (for the app's own test). */
    val laserShowing get() = laser.isNotEmpty()
    /** The newest mark's opacity, 0 to 1 (for the app's own test). */
    val lastMarkAlpha get() = marks.drawing.lastOrNull()?.let { Color.alpha(it.color) / 255f }
    val canUndo get() = marks.canUndo

    init { updateDescription() }

    // ---------- undo and clear ----------

    fun undo() {
        finishLive(commit = false)
        val gone = faded.toSet()
        marks.undo { d -> d.filter { it.id !in gone } }
        // a mark brought back that was fading starts its time again
        val now = SystemClock.uptimeMillis()
        for (m in marks.drawing) if (fading.containsKey(m.id)) fading[m.id] = now
        changed()
    }

    fun clear() {
        finishLive(commit = false)
        marks.clear()
        changed()
    }

    private fun commit(new: List<Mark>) {
        marks.commit(new)
        changed()
    }

    private fun changed() {
        updateDescription()
        host.marksChanged()
        invalidate()
    }

    private fun updateDescription() {
        contentDescription = "Marks: $markCount"
    }

    // ---------- touch ----------

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        val s = host.settings
        val type = e.getToolType(0)
        if (e.actionMasked == MotionEvent.ACTION_DOWN) {
            ignoreGesture = false
            if (type == MotionEvent.TOOL_TYPE_FINGER && !s.fingerDraws) { host.fingerTouched(); return false }
            // the stylus's side button, pressed as the pen touches: undo (one press, one undo)
            if (s.stylusButtonUndoes && (e.buttonState and MotionEvent.BUTTON_STYLUS_PRIMARY) != 0) {
                ignoreGesture = true
                undo()
                return true
            }
        }
        if (ignoreGesture) return true
        val p = Pt(e.x, e.y)
        val erasing = s.tool == Tool.ERASER || (s.stylusEraserEnd && type == MotionEvent.TOOL_TYPE_ERASER)
        if (s.tool == Tool.LASER && !erasing) { laserTouch(e); return true }
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                liveErasing = erasing
                when {
                    erasing -> eraseAt(p)
                    s.tool == Tool.ARROW || s.tool == Tool.OVAL -> { shapeStart = p; shapeEnd = p }
                    else -> live = mutableListOf(p)
                }
            }
            MotionEvent.ACTION_MOVE -> {
                for (i in 0 until e.historySize) move(Pt(e.getHistoricalX(i), e.getHistoricalY(i)))
                move(p)
            }
            MotionEvent.ACTION_UP -> { move(p); finishLive(commit = true) }
            MotionEvent.ACTION_CANCEL -> finishLive(commit = false)
        }
        invalidate()
        return true
    }

    // ---------- laser pointer ----------

    private fun laserTouch(e: MotionEvent) {
        val now = SystemClock.uptimeMillis()
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> { laserLine++; laser += Glow(e.x, e.y, now, laserLine) }
            MotionEvent.ACTION_MOVE -> {
                for (i in 0 until e.historySize) laser += Glow(e.getHistoricalX(i), e.getHistoricalY(i), e.getHistoricalEventTime(i), laserLine)
                laser += Glow(e.x, e.y, now, laserLine)
            }
        }
        // the dot stays while touching; lifted, a stylus's hover brings it back, a finger's doesn't
        laserDot = if (e.actionMasked == MotionEvent.ACTION_UP || e.actionMasked == MotionEvent.ACTION_CANCEL) null else Pt(e.x, e.y)
        postInvalidateOnAnimation()
    }

    /** A stylus hovering over the layer (with the laser chosen): the dot follows it. */
    override fun onHoverEvent(e: MotionEvent): Boolean {
        if (host.settings.tool != Tool.LASER) return super.onHoverEvent(e)
        laserDot = if (e.actionMasked == MotionEvent.ACTION_HOVER_EXIT) null else Pt(e.x, e.y)
        invalidate()
        return true
    }

    /** The laser was put away (another tool, or drawing off): the dot goes, the line fades as it would. */
    fun hideLaserDot() { laserDot = null; invalidate() }

    private fun drawLaser(c: Canvas, now: Long) {
        laser.removeAll { Laser.opacity(now - it.at) <= 0f }
        val w = Laser.width(Settings.WIDTHS[host.settings.width]) * density
        // three passes: a wide soft glow, the red line, a thin bright core (so it reads as light, not ink)
        for (pass in 0..2) {
            for (i in 1 until laser.size) {
                val a = laser[i - 1]
                val b = laser[i]
                if (a.line != b.line) continue
                val o = Laser.opacity(now - b.at)
                paint.color = glowColor(pass, o)
                paint.strokeWidth = when (pass) { 0 -> w * 2.4f; 1 -> w; else -> w * 0.3f }
                c.drawLine(a.x, a.y, b.x, b.y, paint)
            }
        }
        laserDot?.let { d ->
            paint.style = Paint.Style.FILL
            paint.color = glowColor(0, 1f); c.drawCircle(d.x, d.y, w * 1.3f, paint)
            paint.color = glowColor(1, 1f); c.drawCircle(d.x, d.y, w / 2, paint)
            paint.color = glowColor(2, 1f); c.drawCircle(d.x, d.y, w * 0.18f, paint)
            paint.style = Paint.Style.STROKE
        }
        if (laser.isNotEmpty()) postInvalidateOnAnimation()
    }

    private fun glowColor(pass: Int, o: Float): Int = when (pass) {
        0 -> Color.argb((255 * 0.25f * o).toInt(), Color.red(Laser.COLOR), Color.green(Laser.COLOR), Color.blue(Laser.COLOR))
        1 -> Color.argb((255 * o).toInt(), Color.red(Laser.COLOR), Color.green(Laser.COLOR), Color.blue(Laser.COLOR))
        else -> Color.argb((255 * 0.8f * o).toInt(), 255, 255, 255)
    }

    private fun move(p: Pt) {
        when {
            liveErasing -> eraseAt(p)
            shapeStart != null -> shapeEnd = p
            else -> live?.add(p)
        }
    }

    private fun eraseAt(p: Pt) {
        val radius = 12 * density
        val keep = marks.drawing.filterNot { m -> Shapes.touches(m.points, p, radius + m.width / 2) }
        if (keep.size != marks.drawing.size) commit(keep)
    }

    private fun finishLive(commit: Boolean) {
        val s = host.settings
        val line = live
        val start = shapeStart
        val end = shapeEnd
        live = null; shapeStart = null; shapeEnd = null; liveErasing = false
        if (!commit) { invalidate(); return }
        val mark = when {
            line != null && line.isNotEmpty() -> newMark(line, s, smooth = true)
            start != null && end != null && !Shapes.tooSmall(start, end) -> newMark(shapePoints(start, end, s), s, smooth = false)
            else -> null
        } ?: return
        if (s.fadingInk) { fading[mark.id] = SystemClock.uptimeMillis(); postInvalidateOnAnimation() }
        commit(marks.drawing + mark)
    }

    private fun shapePoints(a: Pt, b: Pt, s: Settings): List<Pt> =
        if (s.tool == Tool.ARROW) Shapes.arrow(a, b, width(s)) else Shapes.oval(a, b)

    private fun width(s: Settings) = Settings.WIDTHS[s.width] * density

    private fun newMark(points: List<Pt>, s: Settings, smooth: Boolean): Mark {
        val hl = s.tool == Tool.HIGHLIGHTER
        val w = if (hl) Settings.highlighterWidth(Settings.WIDTHS[s.width]) * density else width(s)
        return Mark(nextId++, points.toList(), inkColor(s), w, hl, smooth)
    }

    /** The chosen colour at the chosen opacity (the highlighter keeps its own see-through look). */
    private fun inkColor(s: Settings): Int {
        val c = Settings.COLORS[s.color]
        if (s.tool == Tool.HIGHLIGHTER) return c
        return Color.argb((Color.alpha(c) * s.opacity).toInt().coerceIn(0, 255), Color.red(c), Color.green(c), Color.blue(c))
    }

    // ---------- drawing ----------

    override fun onDraw(canvas: Canvas) {
        val now = SystemClock.uptimeMillis()
        tickFading(now)
        for (m in marks.drawing) {
            val o = fading[m.id]?.let { Fade.opacity(now - it) } ?: 1f
            draw(canvas, m.points, m.color, m.width, m.highlighter, m.smooth, o)
        }
        val s = host.settings
        live?.let { draw(canvas, it, inkColor(s), liveWidth(s), s.tool == Tool.HIGHLIGHTER, true, 1f) }
        val a = shapeStart
        val b = shapeEnd
        if (a != null && b != null) draw(canvas, shapePoints(a, b, s), inkColor(s), width(s), false, false, 1f)
        drawLaser(canvas, now)
        if (fading.keys.any { id -> marks.drawing.any { it.id == id } }) postInvalidateOnAnimation()
    }

    private fun liveWidth(s: Settings) =
        if (s.tool == Tool.HIGHLIGHTER) Settings.highlighterWidth(Settings.WIDTHS[s.width]) * density else width(s)

    private fun draw(c: Canvas, pts: List<Pt>, color: Int, width: Float, highlighter: Boolean, smooth: Boolean, opacity: Float) {
        if (pts.isEmpty()) return
        val alpha = (if (highlighter) 0.4f else 1f) * opacity
        paint.color = Color.argb((Color.alpha(color) * alpha).toInt(), Color.red(color), Color.green(color), Color.blue(color))
        paint.strokeWidth = width
        if (pts.size == 1) {
            paint.style = Paint.Style.FILL
            c.drawCircle(pts[0].x, pts[0].y, width / 2, paint)
            paint.style = Paint.Style.STROKE
            return
        }
        val path = Path()
        path.moveTo(pts[0].x, pts[0].y)
        if (smooth) {
            // through the midpoints: a smooth line with no corners from the touch sampling
            for (i in 1 until pts.size) {
                val prev = pts[i - 1]
                val p = pts[i]
                path.quadTo(prev.x, prev.y, (prev.x + p.x) / 2, (prev.y + p.y) / 2)
            }
            path.lineTo(pts.last().x, pts.last().y)
        } else {
            for (i in 1 until pts.size) path.lineTo(pts[i].x, pts[i].y)
        }
        c.drawPath(path, paint)
    }

    /** Marks that have faded away leave quietly (not an undo step). */
    private fun tickFading(now: Long) {
        if (fading.isEmpty()) return
        val gone = fading.filter { (_, born) -> Fade.opacity(now - born) <= 0f }.keys
        if (gone.isEmpty()) return
        faded += gone
        gone.forEach { fading.remove(it) }
        marks.replaceQuietly(marks.drawing.filter { it.id !in gone })
        post { changed() }
    }
}
