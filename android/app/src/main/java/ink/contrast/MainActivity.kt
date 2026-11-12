package ink.contrast

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings as AndroidSettings
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import ink.contrast.core.Settings

/** Setting up: the two permissions Contrast Ink needs, start / quit, and the stylus settings. */
@SuppressLint("SetTextI18n", "UseSwitchCompatOrMaterialCode")
class MainActivity : Activity() {
    private val dp by lazy { resources.displayMetrics.density }
    private val blue = Color.rgb(0x25, 0x63, 0xEB)
    private val ink = Color.rgb(0x14, 0x1A, 0x22)
    private val light = Color.rgb(0xE3, 0xE8, 0xF0)
    private lateinit var overlayStep: TextView
    private lateinit var micStep: TextView
    private lateinit var startButton: Button
    private val switches = ArrayList<Pair<Switch, (Settings, Boolean) -> Settings>>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding((24 * dp).toInt(), (40 * dp).toInt(), (24 * dp).toInt(), (24 * dp).toInt())
        }
        col.addView(text("Contrast Ink", 28f, bold = true))
        col.addView(text("Draw on your screen while you lecture: over PowerPoint, a PDF, a DICOM viewer, anything. " +
            "Record it with your voice.", 16f))
        col.addView(space(16))

        overlayStep = text("", 16f)
        col.addView(overlayStep)
        col.addView(button("Allow drawing over other apps") {
            startActivity(Intent(AndroidSettings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")))
        })
        micStep = text("", 16f)
        col.addView(micStep)
        col.addView(button("Allow the microphone (for recording)") {
            val ask = mutableListOf(Manifest.permission.RECORD_AUDIO)
            if (Build.VERSION.SDK_INT >= 33) ask += Manifest.permission.POST_NOTIFICATIONS
            if (Build.VERSION.SDK_INT < 29) ask += Manifest.permission.WRITE_EXTERNAL_STORAGE   // recordings into Movies
            requestPermissions(ask.toTypedArray(), 1)
        })
        col.addView(space(12))
        startButton = button("Start Contrast Ink") {
            if (InkService.running != null) InkService.running?.quit()
            else if (AndroidSettings.canDrawOverlays(this)) { InkService.start(this); moveTaskToBack(true) }
            refresh()
        }.apply { background = GradientDrawable().apply { setColor(blue); cornerRadius = 10 * dp }; setTextColor(Color.WHITE) }
        col.addView(startButton)
        col.addView(space(12))
        // pad mode: this tablet draws on a PC's screen instead of its own (the PC runs Contrast Ink too)
        col.addView(button("Use as a pad for a PC") { startActivity(Intent(this, PadActivity::class.java)) })
        col.addView(space(20))

        col.addView(text("Settings", 20f, bold = true))
        col.addView(toggle("A finger draws too", "Off: only a stylus draws, and touching the drawing layer with a finger switches drawing off.") { s, on -> s.copy(fingerDraws = on) })
        col.addView(toggle("The stylus side button undoes", "Hold the button as the pen touches the screen.") { s, on -> s.copy(stylusButtonUndoes = on) })
        col.addView(toggle("The stylus eraser end erases", "On styluses that have one.") { s, on -> s.copy(stylusEraserEnd = on) })
        col.addView(toggle("Show button names", "Off: hovering the stylus over the toolbar (S Pen and others) shows no names like \"Pen\" or \"Highlighter\". Screen readers then can't name the buttons either.") { s, on -> s.copy(showButtonNames = on) })
        col.addView(space(20))
        col.addView(text("How to use", 20f, bold = true))
        col.addView(text(
            "• ✎ Off / On on the toolbar: drawing on or off. Off, every tap goes to the app below.\n" +
            "• Picking a tool switches drawing on.\n" +
            "• Drag the toolbar by the blue Contrast mark. ‹ makes it small (do this while recording: the toolbar is in the video).\n" +
            "• ⏺ records the whole screen with your voice. When Android asks, choose \"Entire screen\" (a single app would leave out your marks). " +
            "Videos go to Movies/Contrast Ink in the Gallery.\n" +
            "• Quit from the toolbar (✕) or the notification.", 15f))
        setContentView(ScrollView(this).apply { setBackgroundColor(ink); addView(col) })
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        refresh()
    }

    private fun refresh() {
        val overlay = AndroidSettings.canDrawOverlays(this)
        val mic = checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        overlayStep.text = (if (overlay) "✓ " else "1. ") + "Drawing over other apps" + if (overlay) " is allowed" else ": needed"
        micStep.text = (if (mic) "✓ " else "2. ") + "Microphone" + if (mic) " is allowed" else ": needed for sound in recordings"
        if (Build.VERSION.SDK_INT < 29 && checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED)
            micStep.text = "${micStep.text}\nStorage: needed to put recordings in Movies (otherwise they stay in the app's own folder)"
        startButton.isEnabled = overlay
        startButton.alpha = if (overlay) 1f else 0.5f
        startButton.text = if (InkService.running != null) "Quit Contrast Ink" else "Start Contrast Ink"
        val s = InkService.running?.settings ?: Settings.decode(getSharedPreferences("contrast-ink", MODE_PRIVATE).getString("settings", null))
        switches.forEachIndexed { i, (sw, _) ->
            sw.setOnCheckedChangeListener(null)
            sw.isChecked = when (i) { 0 -> s.fingerDraws; 1 -> s.stylusButtonUndoes; 2 -> s.stylusEraserEnd; else -> s.showButtonNames }
            sw.setOnCheckedChangeListener { _, on -> change(switches[i].second, on) }
        }
    }

    private fun change(f: (Settings, Boolean) -> Settings, on: Boolean) {
        val svc = InkService.running
        if (svc != null) svc.update { f(it, on) }
        else {
            val prefs = getSharedPreferences("contrast-ink", MODE_PRIVATE)
            val s = f(Settings.decode(prefs.getString("settings", null)), on)
            prefs.edit().putString("settings", s.encode()).apply()
        }
    }

    private fun text(t: String, size: Float, bold: Boolean = false) = TextView(this).apply {
        text = t; textSize = size; setTextColor(light)
        if (bold) typeface = Typeface.DEFAULT_BOLD
        setPadding(0, (4 * dp).toInt(), 0, (4 * dp).toInt())
    }

    private fun button(t: String, onClick: () -> Unit) = Button(this).apply {
        text = t; isAllCaps = false; textSize = 16f
        setOnClickListener { onClick() }
        minHeight = (48 * dp).toInt()
    }

    private fun toggle(title: String, hint: String, f: (Settings, Boolean) -> Settings): View {
        val sw = Switch(this).apply { text = title; textSize = 16f; setTextColor(light); minHeight = (48 * dp).toInt() }
        switches += sw to f
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(sw)
            addView(text(hint, 13f).apply { setTextColor(Color.rgb(0x8A, 0x95, 0xA6)) })
        }
    }

    private fun space(h: Int) = View(this).apply { minimumHeight = (h * dp).toInt(); layoutParams = LinearLayout.LayoutParams(1, (h * dp).toInt()) }
}
