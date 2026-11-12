package ink.contrast

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import ink.contrast.core.PadProtocol
import ink.contrast.core.PcMessage
import ink.contrast.core.Settings
import ink.contrast.core.Tool

/**
 * The pad's toolbar, in the look of the drawing toolbar (dark bar, blue for what is chosen). Its buttons only ask
 * the PC (COMMAND): the PC keeps the tool, colour and width, and its STATE says what to mark as chosen, so the
 * tablet never shows a choice the PC didn't make. The buttons wrap onto a second row on a narrow screen.
 * Every button has a spoken name (TalkBack, and the app's test finds buttons by it).
 */
@SuppressLint("ViewConstructor")
class PadToolbar(context: Context, private val send: (String) -> Unit, private val disconnect: () -> Unit) : ViewGroup(context) {
    private val dp = resources.displayMetrics.density
    private val blue = Color.rgb(0x25, 0x63, 0xEB)
    private val offText = Color.rgb(0xE3, 0xE8, 0xF0)
    private val tools = LinkedHashMap<Tool, TextView>()
    private val colors = ArrayList<TextView>()
    private val widths = ArrayList<TextView>()
    private val fadeBtn: TextView
    private val undoBtn: TextView
    private var state = PcMessage.State(Tool.PEN, 0, 1, 1f, fading = false, canUndo = false)

    init {
        setBackgroundColor(Color.rgb(0x14, 0x1A, 0x22))
        setPadding((6 * dp).toInt(), (2 * dp).toInt(), (6 * dp).toInt(), (2 * dp).toInt())
        listOf(Tool.PEN to ("✎" to "Pen"), Tool.HIGHLIGHTER to ("▬" to "Highlighter"), Tool.ARROW to ("↗" to "Arrow"),
            Tool.OVAL to ("◯" to "Circle"), Tool.ERASER to ("⌫" to "Eraser"), Tool.LASER to ("●" to "Laser pointer")).forEach { (t, label) ->
            tools[t] = button(label.first, label.second) { send(PadProtocol.Commands.tool(t)) }
        }
        Settings.COLORS.forEachIndexed { i, c ->
            colors += button("", "${Settings.COLOR_NAMES[i]} (${i + 1})") { send(PadProtocol.Commands.color(i)) }.also { it.tag = c }
        }
        Settings.WIDTHS.forEachIndexed { i, _ ->
            widths += button("•", "${Settings.WIDTH_NAMES[i]} line") { send(PadProtocol.Commands.width(i)) }.also { it.textSize = 10f + i * 6 }
        }
        fadeBtn = button("⏱", "Fading ink: marks go after 3 seconds") {
            send(if (state.fading) PadProtocol.Commands.FADE_OFF else PadProtocol.Commands.FADE_ON)
        }
        undoBtn = button("↶", "Undo") { send(PadProtocol.Commands.UNDO) }
        button("🗑", "Clear all marks") { send(PadProtocol.Commands.CLEAR) }
        button("◀", "Previous slide") { send(PadProtocol.Commands.PREVIOUS) }
        button("▶", "Next slide") { send(PadProtocol.Commands.NEXT) }
        button("✕", "Disconnect") { disconnect() }
        show(state)
    }

    private fun button(text: String, name: String, onClick: () -> Unit) = TextView(context).apply {
        this.text = text
        contentDescription = name
        textSize = 18f
        gravity = Gravity.CENTER
        setTextColor(offText)
        minWidth = (44 * dp).toInt()
        setPadding((4 * dp).toInt(), 0, (4 * dp).toInt(), 0)
        isClickable = true
        setOnClickListener { onClick() }
        layoutParams = LayoutParams(LayoutParams.WRAP_CONTENT, (44 * dp).toInt())   // a finger-sized target
    }.also { addView(it) }

    private fun mark(v: TextView, on: Boolean) {
        v.background = if (on) GradientDrawable().apply { setColor(blue); cornerRadius = 8 * dp } else null
        v.setTextColor(if (on) Color.WHITE else offText)
    }

    /** What the PC says is chosen. */
    fun show(s: PcMessage.State) {
        state = s
        tools.forEach { (t, v) -> mark(v, t == s.tool) }
        tools[Tool.LASER]?.setTextColor(if (s.tool == Tool.LASER) Color.WHITE else Color.rgb(0xFF, 0x2D, 0x2D))
        colors.forEachIndexed { i, v ->
            v.background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(v.tag as Int)
                setStroke(((if (i == s.color) 3 else 1) * dp).toInt(), if (i == s.color) blue else Color.argb(0x99, 0xE3, 0xE8, 0xF0))
            }
        }
        widths.forEachIndexed { i, v -> mark(v, i == s.width) }
        mark(fadeBtn, s.fading)
        undoBtn.alpha = if (s.canUndo) 1f else 0.4f
    }

    // A simple wrapping row: buttons left to right, onto the next row when one doesn't fit.
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val maxW = MeasureSpec.getSize(widthMeasureSpec).takeIf { MeasureSpec.getMode(widthMeasureSpec) != MeasureSpec.UNSPECIFIED } ?: Int.MAX_VALUE
        var x = paddingLeft; var y = paddingTop; var rowH = 0; var widest = 0
        for (i in 0 until childCount) {
            val c = child(i) ?: continue
            c.measure(MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED), MeasureSpec.makeMeasureSpec(c.layoutParams.height, MeasureSpec.EXACTLY))
            val w = itemWidth(c)
            if (x + w > maxW - paddingRight && x > paddingLeft) { x = paddingLeft; y += rowH; rowH = 0 }
            x += w
            rowH = maxOf(rowH, c.measuredHeight + 2 * margin())
            widest = maxOf(widest, x)
        }
        val w = if (maxW == Int.MAX_VALUE) widest + paddingRight else maxW
        setMeasuredDimension(w, y + rowH + paddingBottom)
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        var x = paddingLeft; var y = paddingTop; var rowH = 0
        for (i in 0 until childCount) {
            val c = child(i) ?: continue
            val w = itemWidth(c)
            if (x + w > (r - l) - paddingRight && x > paddingLeft) { x = paddingLeft; y += rowH; rowH = 0 }
            val m = margin()
            if (c in colors) {
                // a colour is a dot, not a full-height button: centred in its slot
                val d = (30 * dp).toInt()
                val top = y + m + (c.measuredHeight - d) / 2
                c.layout(x + m + (w - 2 * m - d) / 2, top, x + m + (w - 2 * m - d) / 2 + d, top + d)
            } else c.layout(x + m, y + m, x + m + c.measuredWidth, y + m + c.measuredHeight)
            x += w
            rowH = maxOf(rowH, c.measuredHeight + 2 * m)
        }
    }

    private fun child(i: Int): View? = getChildAt(i).takeIf { it.visibility != GONE }
    private fun margin() = (1 * dp).toInt()
    private fun itemWidth(c: View) = (if (c in colors) (40 * dp).toInt() else c.measuredWidth) + 2 * margin()
}
