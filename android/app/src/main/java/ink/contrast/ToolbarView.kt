package ink.contrast

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import ink.contrast.core.Settings
import ink.contrast.core.Tool
import ink.contrast.core.clock

/**
 * The floating toolbar, in Contrast's colours (as on Windows): drag it by the blue mark; ‹ makes it small.
 * Every button has a spoken name (TalkBack, and the app's own test).
 */
@SuppressLint("ViewConstructor", "SetTextI18n")
class ToolbarView(context: Context, private val app: InkService) : LinearLayout(context) {
    private val dp = resources.displayMetrics.density
    private val blue = Color.rgb(0x25, 0x63, 0xEB)
    private val offText = Color.rgb(0xE3, 0xE8, 0xF0)
    private val barColor = Color.rgb(0x14, 0x1A, 0x22)

    private val full = LinearLayout(context).apply { orientation = VERTICAL }
    private val drawBtn: TextView
    private val tools = LinkedHashMap<Tool, TextView>()
    private val colors = ArrayList<TextView>()
    private val widths = ArrayList<TextView>()
    private val fadeBtn: TextView
    private val undoBtn: TextView
    private val recBtn: TextView
    private val pauseBtn: TextView
    private val timeText: TextView
    private val foldBtn: TextView
    private val noticeText: TextView
    private var folded = false
    private val names = HashMap<View, String>()   // every button's name, shown or not as the settings say

    init {
        orientation = VERTICAL
        background = GradientDrawable().apply { setColor(barColor); cornerRadius = 12 * dp }
        setPadding((6 * dp).toInt(), (4 * dp).toInt(), (6 * dp).toInt(), (4 * dp).toInt())

        // row 1 (stays when the toolbar is small): move, drawing on/off, undo, recording, make small, quit
        val row1 = row()
        row1.addView(grip())
        drawBtn = button("✎ Off", "Draw on / off") { app.toggleDrawing() }.also { it.minWidth = (64 * dp).toInt(); row1.addView(it) }
        undoBtn = button("↶", "Undo") { app.ink.undo() }.also { row1.addView(it) }
        recBtn = button("⏺", "Record the screen") { app.recordTapped() }.also { it.setTextColor(Color.rgb(0xFF, 0x3B, 0x30)); row1.addView(it) }
        pauseBtn = button("⏸", "Pause recording") { app.recorder.togglePause()?.let { notice(it) } }.also { row1.addView(it) }
        timeText = TextView(context).apply {
            setTextColor(offText); textSize = 14f; typeface = Typeface.MONOSPACE
            setPadding((4 * dp).toInt(), 0, (4 * dp).toInt(), 0); gravity = Gravity.CENTER_VERTICAL
        }.also { row1.addView(it, LayoutParams(LayoutParams.WRAP_CONTENT, (44 * dp).toInt())) }
        foldBtn = button("‹", "Make the toolbar small") { folded = !folded; refresh(); app.barResized() }.also { row1.addView(it) }
        row1.addView(button("✕", "Quit Contrast Ink") { app.quit() })   // a recording is saved first
        addView(row1)

        // row 2: the tools, fading ink, clear
        val row2 = row()
        listOf(Tool.PEN to ("✎" to "Pen"), Tool.HIGHLIGHTER to ("▬" to "Highlighter"), Tool.ARROW to ("↗" to "Arrow"),
            Tool.OVAL to ("◯" to "Circle"), Tool.ERASER to ("⌫" to "Eraser")).forEach { (t, label) ->
            tools[t] = button(label.first, label.second) {
                app.update { it.copy(tool = t) }
                app.setDrawing(true)   // picking a tool means "draw"
            }.also { row2.addView(it) }
        }
        fadeBtn = button("⏱", "Fading ink: marks go after 3 seconds") { app.update { it.copy(fadingInk = !it.fadingInk) } }.also { row2.addView(it) }
        row2.addView(button("🗑", "Clear all marks") { app.ink.clear() })
        full.addView(row2)

        // row 3: colours and widths
        val row3 = row()
        Settings.COLORS.forEachIndexed { i, c ->
            val dot = button("", "${Settings.COLOR_NAMES[i]} (${i + 1})") {
                app.update { s -> s.copy(color = i, tool = if (s.tool == Tool.ERASER) Tool.PEN else s.tool) }
            }
            dot.tag = c
            colors += dot
            row3.addView(dot)
        }
        Settings.WIDTHS.forEachIndexed { i, _ ->
            widths += button("•", "${Settings.WIDTH_NAMES[i]} line") { app.update { it.copy(width = i) } }
                .also { it.textSize = 10f + i * 6; row3.addView(it) }
        }
        full.addView(row3)
        addView(full)

        noticeText = TextView(context).apply {
            setTextColor(Color.rgb(0xFF, 0x99, 0x8C)); textSize = 12f
            maxWidth = (330 * dp).toInt()
            setPadding((4 * dp).toInt(), (2 * dp).toInt(), (4 * dp).toInt(), (4 * dp).toInt())
            visibility = GONE
            contentDescription = null
            setOnClickListener { visibility = GONE; app.barResized() }   // a message is dismissed by tapping it
        }
        addView(noticeText)
    }

    private fun row() = LinearLayout(context).apply { orientation = HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }

    /** The Contrast mark: drag the toolbar by it. */
    @SuppressLint("ClickableViewAccessibility")
    private fun grip(): View {
        val v = ImageView(context).apply {
            setImageResource(R.mipmap.ic_launcher)
            names[this] = "Move the toolbar"
            setPadding((4 * dp).toInt(), (4 * dp).toInt(), (4 * dp).toInt(), (4 * dp).toInt())
        }
        var lastX = 0f
        var lastY = 0f
        v.setOnTouchListener { _, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> { lastX = e.rawX; lastY = e.rawY }
                MotionEvent.ACTION_MOVE -> {
                    app.moveBar((e.rawX - lastX).toInt(), (e.rawY - lastY).toInt())
                    lastX = e.rawX; lastY = e.rawY
                }
                MotionEvent.ACTION_UP -> app.barMoved()
            }
            true
        }
        v.layoutParams = LayoutParams((40 * dp).toInt(), (40 * dp).toInt())
        return v
    }

    private fun button(text: String, name: String, onClick: () -> Unit) = TextView(context).apply {
        this.text = text
        names[this] = name
        textSize = 18f
        gravity = Gravity.CENTER
        setTextColor(offText)
        minWidth = (40 * dp).toInt()
        minHeight = (44 * dp).toInt()   // a finger-sized target
        setPadding((4 * dp).toInt(), 0, (4 * dp).toInt(), 0)
        isClickable = true
        setOnClickListener { onClick() }
        layoutParams = LayoutParams(LayoutParams.WRAP_CONTENT, (44 * dp).toInt()).apply { setMargins((1 * dp).toInt(), 0, (1 * dp).toInt(), 0) }
    }

    private fun mark(v: TextView, on: Boolean) {
        v.background = if (on) GradientDrawable().apply { setColor(blue); cornerRadius = 8 * dp } else null
        v.setTextColor(if (on) Color.WHITE else offText)
    }

    /** A message about recording, under the buttons, until it is tapped away. */
    fun notice(text: String) {
        noticeText.text = text
        noticeText.contentDescription = text
        noticeText.visibility = VISIBLE
        app.barResized()
    }

    /** Shows the current state: drawing on or off, which tool, colour and width, recording. */
    fun refresh() {
        val s = app.settings
        mark(drawBtn, app.drawing)
        drawBtn.text = if (app.drawing) "✎ On" else "✎ Off"
        tools.forEach { (t, v) -> mark(v, t == s.tool) }
        colors.forEachIndexed { i, v ->
            v.background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(v.tag as Int)
                setSize((24 * dp).toInt(), (24 * dp).toInt())
                setStroke(((if (i == s.color) 3 else 1) * dp).toInt(), if (i == s.color) blue else Color.argb(0x99, 0xE3, 0xE8, 0xF0))
            }
            v.layoutParams = (v.layoutParams as LayoutParams).apply { width = (32 * dp).toInt(); height = (32 * dp).toInt(); setMargins((4 * dp).toInt(), (6 * dp).toInt(), (4 * dp).toInt(), (6 * dp).toInt()) }
        }
        widths.forEachIndexed { i, v -> mark(v, i == s.width) }
        mark(fadeBtn, s.fadingInk)
        undoBtn.alpha = if (app.ink.canUndo) 1f else 0.4f
        val rec = app.recorder
        recBtn.text = if (rec.active) "⏹" else "⏺"
        names[recBtn] = if (rec.active) "Stop recording" else "Record the screen"
        recBtn.setTextColor(if (rec.paused) Color.rgb(0xFF, 0xB0, 0x20) else Color.rgb(0xFF, 0x3B, 0x30))
        pauseBtn.visibility = if (rec.active) VISIBLE else GONE
        pauseBtn.text = if (rec.paused) "▶" else "⏸"
        names[pauseBtn] = if (rec.paused) "Resume recording" else "Pause recording"
        timeText.visibility = if (rec.active) VISIBLE else GONE
        timeText.text = clock(rec.elapsed)
        full.visibility = if (folded) GONE else VISIBLE
        foldBtn.text = if (folded) "›" else "‹"
        names[foldBtn] = if (folded) "Make the toolbar big" else "Make the toolbar small"
        // a stylus hovering over a button (S Pen and others) shows its name: off in the settings, no names
        names.forEach { (v, n) -> v.contentDescription = if (s.showButtonNames) n else null }
    }
}
