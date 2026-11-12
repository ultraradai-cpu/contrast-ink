package ink.contrast

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.os.Build
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import ink.contrast.core.PadProtocol
import ink.contrast.core.Pt
import ink.contrast.core.Settings
import ink.contrast.core.Shapes
import ink.contrast.core.Tool
import java.util.concurrent.atomic.AtomicReference

/**
 * The PC's screen on the tablet, and the glass to draw on. The picture is fitted whole (letterboxed), and every
 * touch is sent as a fraction of the picture, so the PC draws exactly where the pen is over its picture.
 *
 * The tablet draws its own stroke at once (the PC's next picture takes a moment over Wi-Fi) and lets it go
 * 0.6 s after the pen lifts, by which time the PC's picture has it.
 */
@SuppressLint("ViewConstructor")
class PadView(context: Context, private val host: Host) : View(context) {
    interface Host {
        fun send(bytes: ByteArray)
        /** A new picture was drawn on the screen: the PC may send the next. */
        fun frameShown()
        /** The PC's tool, colour and width (the live stroke looks like what the PC will draw). */
        val tool: Tool
        val color: Int
        val width: Int
    }

    private val density = resources.displayMetrics.density
    private var picture: Bitmap? = null
    private var pictureNew = false
    /** The picture just replaced: once the new one is drawn, it can take the next picture's pixels (see [spare]). */
    private var retired: Bitmap? = null
    /**
     * A bitmap no longer on screen, for the next picture to be decoded into (BitmapFactory's inBitmap): about ten
     * pictures a second would otherwise each need a fresh few megabytes. Taken by the decoding thread.
     */
    val spare = AtomicReference<Bitmap?>()
    /** The PC's screen size from WELCOME: the picture's shape before the first picture arrives. */
    var screenW = 16; var screenH = 9
    /** Where the picture is in this view (the letterbox leaves the rest black). */
    val pictureRect = RectF()

    private class Stroke(val points: ArrayList<Pt>, val tool: Tool, val color: Int, val width: Int, var liftedAt: Long = 0)
    private val strokes = ArrayList<Stroke>()   // the one being drawn, and the ones lifted in the last 0.6 s
    private var live: Stroke? = null
    private val batch = FloatArray(512)
    private var batchCount = 0
    private var lastFlush = 0L
    private var hovering = false
    private var lastHover = 0L

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND
    }
    private val bitmapPaint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val path = Path()

    init {
        contentDescription = "The PC's screen"
        setBackgroundColor(Color.BLACK)
    }

    fun showPicture(b: Bitmap) {
        val old = picture
        if (old != null && old !== b) retired = old
        picture = b
        pictureNew = true
        invalidate()
    }

    /** Another PC: its picture isn't this one's (and may have shown a patient). */
    fun clearPicture() {
        picture = null
        retired = null
        spare.set(null)
        strokes.clear()
        live = null
        invalidate()
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        super.onLayout(changed, left, top, right, bottom)
        if (Build.VERSION.SDK_INT >= 29) {
            // a pen that starts a line at the screen's left or right edge would otherwise be the Back gesture.
            // Android honours at most 200 dp of such exclusions per edge, so: a strip that tall on each side,
            // centred, where a line across the picture most often starts
            val w = (EDGE_DP * density).toInt()
            val h = minOf(bottom - top, (MAX_EXCLUDE_DP * density).toInt())
            val y = (bottom - top - h) / 2
            systemGestureExclusionRects = listOf(Rect(0, y, w, y + h), Rect(right - left - w, y, right - left, y + h))
        }
    }

    private fun layoutPicture() {
        val bw = picture?.width ?: screenW
        val bh = picture?.height ?: screenH
        if (bw <= 0 || bh <= 0 || width == 0 || height == 0) { pictureRect.set(0f, 0f, width.toFloat(), height.toFloat()); return }
        val scale = minOf(width.toFloat() / bw, height.toFloat() / bh)
        val w = bw * scale
        val h = bh * scale
        pictureRect.set((width - w) / 2, (height - h) / 2, (width + w) / 2, (height + h) / 2)
    }

    override fun onDraw(canvas: Canvas) {
        layoutPicture()
        picture?.let { canvas.drawBitmap(it, null, pictureRect, bitmapPaint) }
        val now = SystemClock.uptimeMillis()
        strokes.removeAll { it.liftedAt != 0L && now - it.liftedAt > KEEP_MS }
        for (s in strokes) drawStroke(canvas, s)
        if (strokes.any { it.liftedAt != 0L }) postInvalidateDelayed(100)   // to let them go on time
        if (pictureNew) {
            pictureNew = false
            retired?.let { spare.set(it) }   // no longer drawn from: the next picture may be decoded into it
            retired = null
            // drawn: on screen with the next refresh. Only now may the PC send another (one picture at a time,
            // so a slow Wi-Fi gets fewer pictures rather than a growing queue)
            host.frameShown()
        }
    }

    private fun drawStroke(canvas: Canvas, s: Stroke) {
        if (s.tool == Tool.ERASER) return   // the PC shows what the eraser took
        val px = s.points.map { Pt(pictureRect.left + it.x * pictureRect.width(), pictureRect.top + it.y * pictureRect.height()) }
        if (px.isEmpty()) return
        // in the tablet's own pixels: it only has to look like the PC's line for a moment
        val w = Settings.WIDTHS[s.width.coerceIn(0, 2)] * density
        val color = Settings.COLORS[s.color.coerceIn(0, 5)]
        paint.color = color
        paint.strokeWidth = w
        paint.alpha = 255
        val shape = when (s.tool) {
            Tool.ARROW -> Shapes.arrow(px.first(), px.last(), w)
            Tool.OVAL -> Shapes.oval(px.first(), px.last())
            Tool.HIGHLIGHTER -> { paint.strokeWidth = Settings.highlighterWidth(w); paint.alpha = 90; px }
            Tool.LASER -> { paint.color = 0xFFFF2D2D.toInt(); px }
            else -> px
        }
        path.reset()
        path.moveTo(shape[0].x, shape[0].y)
        if (shape.size == 1) path.lineTo(shape[0].x + 0.1f, shape[0].y)
        for (i in 1 until shape.size) path.lineTo(shape[i].x, shape[i].y)
        canvas.drawPath(path, paint)
    }

    /** A touch position as a fraction of the picture, kept inside it (a pen in the black border draws on its edge). */
    private fun fx(x: Float) = if (pictureRect.width() > 0) ((x - pictureRect.left) / pictureRect.width()).coerceIn(0f, 1f) else 0f
    private fun fy(y: Float) = if (pictureRect.height() > 0) ((y - pictureRect.top) / pictureRect.height()).coerceIn(0f, 1f) else 0f

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        layoutPicture()
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                if (hovering) { hovering = false; host.send(PadProtocol.hoverEnd()) }
                val x = fx(e.x); val y = fy(e.y)
                val eraserEnd = e.getToolType(0) == MotionEvent.TOOL_TYPE_ERASER
                val s = Stroke(arrayListOf(Pt(x, y)), if (eraserEnd) Tool.ERASER else host.tool, host.color, host.width)
                live = s
                strokes += s
                batchCount = 0
                lastFlush = SystemClock.uptimeMillis()
                host.send(PadProtocol.strokeBegin(x, y, eraserEnd))
                invalidate()
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                // a second finger (or a palm): this wasn't a stroke, the PC drops it. Nothing more is drawn
                // until every finger is up (live stays empty, so the moves are ignored)
                if (live != null) {
                    strokes.remove(live!!)
                    live = null
                    batchCount = 0
                    host.send(PadProtocol.strokeCancel())
                    invalidate()
                }
            }
            MotionEvent.ACTION_MOVE -> {
                val s = live ?: return true
                // every point Android gathered since the last event (a fast pen gives several per screen refresh)
                for (h in 0 until e.historySize) add(s, fx(e.getHistoricalX(0, h)), fy(e.getHistoricalY(0, h)))
                add(s, fx(e.x), fy(e.y))
                if (SystemClock.uptimeMillis() - lastFlush >= BATCH_MS) flush()
                invalidate()
            }
            MotionEvent.ACTION_UP -> {
                val s = live ?: return true
                add(s, fx(e.x), fy(e.y))
                flush()
                host.send(PadProtocol.strokeEnd())
                s.liftedAt = SystemClock.uptimeMillis()
                live = null
                invalidate()
            }
            MotionEvent.ACTION_CANCEL -> {
                live?.let { strokes.remove(it); host.send(PadProtocol.strokeCancel()) }
                live = null
                batchCount = 0
                invalidate()
            }
        }
        return true
    }

    private fun add(s: Stroke, x: Float, y: Float) {
        val last = s.points.last()
        if (last.x == x && last.y == y) return
        s.points += Pt(x, y)
        if (batchCount * 2 + 2 > batch.size) flush()
        batch[batchCount * 2] = x
        batch[batchCount * 2 + 1] = y
        batchCount++
    }

    /** Sends the points gathered since the last batch (one message every ~16 ms rather than one per point). */
    private fun flush() {
        if (batchCount == 0) return
        host.send(PadProtocol.strokePoints(batch, batchCount))
        batchCount = 0
        lastFlush = SystemClock.uptimeMillis()
    }

    /** A stylus above the glass: the PC shows the laser's dot there. Mice hover too, but aren't a pen. */
    override fun onHoverEvent(e: MotionEvent): Boolean {
        val type = e.getToolType(0)
        if (type != MotionEvent.TOOL_TYPE_STYLUS && type != MotionEvent.TOOL_TYPE_ERASER) return super.onHoverEvent(e)
        layoutPicture()
        when (e.actionMasked) {
            MotionEvent.ACTION_HOVER_ENTER, MotionEvent.ACTION_HOVER_MOVE -> {
                val now = SystemClock.uptimeMillis()
                if (!hovering || now - lastHover >= BATCH_MS) {
                    hovering = true
                    lastHover = now
                    host.send(PadProtocol.hover(fx(e.x), fy(e.y)))
                }
            }
            MotionEvent.ACTION_HOVER_EXIT -> if (hovering) { hovering = false; host.send(PadProtocol.hoverEnd()) }
        }
        return true
    }

    /** The test reads where the picture is on the screen, to draw on it. */
    fun pictureOnScreen(): RectF {
        layoutPicture()
        val at = IntArray(2)
        getLocationOnScreen(at)
        return RectF(pictureRect).apply { offset(at[0].toFloat(), at[1].toFloat()) }
    }

    val liveStrokes: Int get() = strokes.size

    companion object {
        const val BATCH_MS = 16L
        /** How long the tablet keeps its own copy of a lifted stroke (the PC's picture has it by then). */
        const val KEEP_MS = 600L
        /** Each side's strip kept from the Back gesture: wider than the gesture's own edge (about 24-32 dp). */
        const val EDGE_DP = 48
        /** The most Android excludes per edge (View.setSystemGestureExclusionRects). */
        const val MAX_EXCLUDE_DP = 200
    }
}
