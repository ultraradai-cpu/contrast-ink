package ink.contrast

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.view.Gravity
import android.view.WindowManager
import ink.contrast.core.Settings
import ink.contrast.core.Tool

/**
 * Contrast Ink running: a drawing layer over the whole screen and a small toolbar, both on top of every app.
 * Not drawing, the layer lets every touch through to the app below (PowerPoint, a PDF viewer, a DICOM viewer).
 */
class InkService : Service(), InkView.Host {
    companion object {
        const val ACTION_STOP = "ink.contrast.STOP"
        private const val CHANNEL = "running"
        private const val NOTE_ID = 1

        /** The running service, if any (the setup screen and the recording request reach it here). */
        var running: InkService? = null
            private set

        fun start(context: Context) {
            context.startForegroundService(Intent(context, InkService::class.java))
        }
    }

    private lateinit var wm: WindowManager
    lateinit var ink: InkView
        private set
    private lateinit var bar: ToolbarView
    private lateinit var inkParams: WindowManager.LayoutParams
    private lateinit var barParams: WindowManager.LayoutParams
    val recorder by lazy { ScreenRecorder(this) }
    private val main = Handler(Looper.getMainLooper())

    override var settings: Settings = Settings()
        private set
    var drawing = false
        private set
    private var quitting = false     // Quit was pressed while a recording was being saved: go once it's saved
    private var destroyed = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = this
        settings = Settings.decode(prefs().getString("settings", null))
        startInForeground(recording = false)
        wm = getSystemService(WINDOW_SERVICE) as WindowManager

        ink = InkView(this, this)
        inkParams = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            title = "Contrast Ink drawing layer"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
                layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        applyDrawing()
        wm.addView(ink, inkParams)

        bar = ToolbarView(this, this)
        barParams = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply {
            title = "Contrast Ink toolbar"
            gravity = Gravity.TOP or Gravity.START
            x = prefs().getInt("barX", 24)
            y = prefs().getInt("barY", 120)
        }
        wm.addView(bar, barParams)
        bar.refresh()
        bar.post { keepBarOnScreen() }   // a place saved on a bigger screen, or the other way round
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        bar.post { keepBarOnScreen() }   // turned the phone: the toolbar must not end up off the edge
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) quit()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        destroyed = true
        recorder.stop(saveToGallery = true)   // only if Android itself ends the service mid-recording
        hideWindows()
        running = null
        super.onDestroy()
    }

    /**
     * Quit (the toolbar's ✕, or the notification). A recording is stopped and saved first: the drawing layer and the
     * toolbar go at once, the notification says "saving" until the video is in the Gallery, then the service ends.
     */
    fun quit() {
        if (recorder.active || recorder.saving) {
            quitting = true
            hideWindows()
            if (recorder.active) recorder.stop(saveToGallery = true)
            runCatching { startInForeground(recording = false, saving = true) }
            return
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun hideWindows() {
        if (::bar.isInitialized) runCatching { wm.removeView(bar) }
        if (::ink.isInitialized) runCatching { wm.removeView(ink) }
    }

    private fun prefs() = getSharedPreferences("contrast-ink", MODE_PRIVATE)

    // ---------- drawing on and off ----------

    fun toggleDrawing() = setDrawing(!drawing)

    fun setDrawing(on: Boolean) {
        if (drawing == on) return
        drawing = on
        if (!on) ink.hideLaserDot()
        applyDrawing()
        runCatching { wm.updateViewLayout(ink, inkParams) }
        bar.refresh()
    }

    /**
     * Drawing: the layer takes every touch. Not drawing: touches pass through. Android 12 and later only let a touch
     * through a window of another app when that window is at most 80% opaque, so the layer is drawn at 80% then
     * (the marks look a little lighter while you aren't drawing; recordings show them the same way).
     */
    private fun applyDrawing() {
        inkParams.flags = if (drawing) inkParams.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
        else inkParams.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        inkParams.alpha = if (drawing) 1f else 0.8f
    }

    override fun fingerTouched() = setDrawing(false)

    override fun marksChanged() { if (::bar.isInitialized) bar.refresh() }

    // ---------- settings ----------

    fun update(change: (Settings) -> Settings) {
        settings = change(settings).cleaned()
        if (settings.tool != Tool.LASER) ink.hideLaserDot()
        prefs().edit().putString("settings", settings.encode()).apply()
        bar.refresh()
    }

    fun moveBar(dx: Int, dy: Int) {
        barParams.x += dx
        barParams.y += dy
        keepBarOnScreen()
    }

    /** The whole toolbar stays on the screen: dragged past an edge, turned phone, or a place saved on another screen. */
    private fun keepBarOnScreen() {
        val (sw, sh) = screenSize()
        barParams.x = barParams.x.coerceIn(0, maxOf(0, sw - bar.width))
        barParams.y = barParams.y.coerceIn(0, maxOf(0, sh - bar.height))
        runCatching { wm.updateViewLayout(bar, barParams) }
    }

    private fun screenSize(): Pair<Int, Int> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val b = wm.currentWindowMetrics.bounds
            return b.width() to b.height()
        }
        val m = android.util.DisplayMetrics()
        @Suppress("DEPRECATION") wm.defaultDisplay.getRealMetrics(m)
        return m.widthPixels to m.heightPixels
    }

    fun barMoved() { prefs().edit().putInt("barX", barParams.x).putInt("barY", barParams.y).apply() }

    fun barResized() { runCatching { wm.updateViewLayout(bar, barParams) } }

    // ---------- recording ----------

    fun recordTapped() {
        if (recorder.active) { recorder.stop(saveToGallery = true); return }
        if (recorder.saving) { bar.notice("Still saving the last recording to the Gallery: one moment."); return }
        // Android asks the presenter first, in its own window: a small invisible screen asks for us
        startActivity(Intent(this, RecordActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    /** Android said yes to recording the screen. Called from [RecordActivity] while it is still on screen. */
    fun startRecording(resultCode: Int, data: Intent) {
        if (recorder.active || quitting) return   // a second ⏺ answered while the first was asking
        // must come before the screen is asked for (Android 14)
        val fg = runCatching { startInForeground(recording = true) }
        if (fg.isFailure) {
            bar.notice("Recording didn't start: Android refused (${fg.exceptionOrNull()?.message ?: "no reason given"}).")
            return
        }
        val problem = recorder.start(resultCode, data)
        if (problem != null) { runCatching { startInForeground(recording = false) }; bar.notice(problem) }
        bar.refresh()
    }

    /** The recording ended (and is saved, or couldn't be): may be called from the saving thread. */
    fun recordingEnded(message: String?) {
        main.post {
            if (destroyed) return@post
            if (quitting) { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf(); return@post }
            runCatching { startInForeground(recording = false) }
            if (message != null) bar.notice(message)
            bar.refresh()
        }
    }

    fun refreshBar() = main.post { bar.refresh() }

    fun micAllowed() = checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun startInForeground(recording: Boolean, saving: Boolean = false) {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Contrast Ink running", NotificationManager.IMPORTANCE_LOW))
        val stop = PendingIntent.getService(this, 0, Intent(this, InkService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val note = Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_note)
            .setContentTitle(when { saving -> "Contrast Ink is saving the recording"; recording -> "Contrast Ink is recording"; else -> "Contrast Ink is running" })
            .setContentText(when { saving -> "It closes once the video is in the Gallery."; recording -> "Press ⏹ on the toolbar to stop."; else -> "Draw over any app. Tap to change settings." })
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "Quit", stop).build())
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            if (recording) {
                type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                if (micAllowed()) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            }
            startForeground(NOTE_ID, note, type)
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && recording) {
            // Android 11+ gives a service the microphone only when it says it uses it (otherwise: silence)
            var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            if (micAllowed()) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            startForeground(NOTE_ID, note, type)
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && recording) {
            startForeground(NOTE_ID, note, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTE_ID, note)
        }
    }
}
