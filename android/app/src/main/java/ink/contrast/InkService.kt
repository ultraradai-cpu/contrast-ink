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
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.view.Gravity
import android.view.WindowManager
import ink.contrast.core.Settings

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
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) quit()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        recorder.stop(saveToGallery = true)
        runCatching { wm.removeView(bar) }
        runCatching { wm.removeView(ink) }
        running = null
        super.onDestroy()
    }

    fun quit() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun prefs() = getSharedPreferences("contrast-ink", MODE_PRIVATE)

    // ---------- drawing on and off ----------

    fun toggleDrawing() = setDrawing(!drawing)

    fun setDrawing(on: Boolean) {
        if (drawing == on) return
        drawing = on
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
        prefs().edit().putString("settings", settings.encode()).apply()
        bar.refresh()
    }

    fun moveBar(dx: Int, dy: Int) {
        barParams.x += dx
        barParams.y += dy
        runCatching { wm.updateViewLayout(bar, barParams) }
    }

    fun barMoved() { prefs().edit().putInt("barX", barParams.x).putInt("barY", barParams.y).apply() }

    fun barResized() { runCatching { wm.updateViewLayout(bar, barParams) } }

    // ---------- recording ----------

    fun recordTapped() {
        if (recorder.active) { recorder.stop(saveToGallery = true); return }
        // Android asks the presenter first, in its own window: a small invisible screen asks for us
        startActivity(Intent(this, RecordActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    /** Android said yes to recording the screen. Called from [RecordActivity] while it is still on screen. */
    fun startRecording(resultCode: Int, data: Intent) {
        startInForeground(recording = true)   // must come before the screen is asked for (Android 14)
        val problem = recorder.start(resultCode, data)
        if (problem != null) { startInForeground(recording = false); bar.notice(problem) }
        bar.refresh()
    }

    fun recordingEnded(message: String?) {
        main.post {
            startInForeground(recording = false)
            if (message != null) bar.notice(message)
            bar.refresh()
        }
    }

    fun refreshBar() = main.post { bar.refresh() }

    fun micAllowed() = checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun startInForeground(recording: Boolean) {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Contrast Ink running", NotificationManager.IMPORTANCE_LOW))
        val stop = PendingIntent.getService(this, 0, Intent(this, InkService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val note = Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_note)
            .setContentTitle(if (recording) "Contrast Ink is recording" else "Contrast Ink is running")
            .setContentText(if (recording) "Press ⏹ on the toolbar to stop." else "Draw over any app. Tap to change settings.")
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
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && recording) {
            startForeground(NOTE_ID, note, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTE_ID, note)
        }
    }
}
