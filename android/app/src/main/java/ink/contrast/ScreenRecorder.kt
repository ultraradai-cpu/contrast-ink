package ink.contrast

import android.content.ContentValues
import android.content.Intent
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.MediaStore
import android.util.DisplayMetrics
import android.view.WindowManager
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.min

/**
 * Records the whole screen (the app below, your marks, and the toolbar: make the toolbar small with ‹ so it
 * stays out of the way) with your voice, to Movies/Contrast Ink in the Gallery.
 */
class ScreenRecorder(private val service: InkService) {
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var media: MediaRecorder? = null
    private var file: File? = null
    private var startedAt = 0L
    private var pausedAt = 0L
    private var pausedTotal = 0L

    val active get() = media != null
    var paused = false
        private set

    /** How long the video is so far, in ms (paused time left out). */
    val elapsed: Long
        get() {
            if (!active) return 0
            val now = SystemClock.elapsedRealtime()
            return now - startedAt - pausedTotal - if (paused) now - pausedAt else 0
        }

    /** Starts recording. Null when it started, otherwise what the presenter should know. */
    fun start(resultCode: Int, data: Intent): String? {
        if (active) return null
        val mpm = service.getSystemService(MediaProjectionManager::class.java)
        val p = runCatching { mpm.getMediaProjection(resultCode, data) }.getOrNull()
            ?: return "Android didn't allow recording the screen. Press ⏺ to try again."
        projection = p
        p.registerCallback(object : MediaProjection.Callback() {
            // the presenter stopped it from Android's own controls, or the screen locked
            override fun onStop() { stop(saveToGallery = true) }
        }, Handler(Looper.getMainLooper()))

        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        (service.getSystemService(WindowManager::class.java)).defaultDisplay.getRealMetrics(metrics)
        // the screen's own shape, at most 1920 on the long side, even numbers (video encoders need them)
        val scale = min(1f, 1920f / maxOf(metrics.widthPixels, metrics.heightPixels))
        val w = ((metrics.widthPixels * scale).toInt() / 2) * 2
        val h = ((metrics.heightPixels * scale).toInt() / 2) * 2

        val folder = service.getExternalFilesDir(Environment.DIRECTORY_MOVIES) ?: service.filesDir
        folder.mkdirs()
        val name = "Lecture " + SimpleDateFormat("yyyy-MM-dd HHmm", Locale.US).format(Date()) + ".mp4"
        val out = File(folder, name)
        val withSound = service.micAllowed()
        val r = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) MediaRecorder(service) else @Suppress("DEPRECATION") MediaRecorder()
        try {
            if (withSound) r.setAudioSource(MediaRecorder.AudioSource.MIC)
            r.setVideoSource(MediaRecorder.VideoSource.SURFACE)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setOutputFile(out.absolutePath)
            r.setVideoEncoder(MediaRecorder.VideoEncoder.H264)
            r.setVideoSize(w, h)
            r.setVideoFrameRate(30)
            r.setVideoEncodingBitRate(6_000_000)
            if (withSound) {
                r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                r.setAudioSamplingRate(44_100)
                r.setAudioEncodingBitRate(96_000)
                r.setAudioChannels(1)
            }
            r.prepare()
            display = p.createVirtualDisplay("Contrast Ink recording", w, h, metrics.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, r.surface, null, null)
            r.start()
        } catch (e: Exception) {
            runCatching { r.release() }
            display?.release(); display = null
            p.stop(); projection = null
            out.delete()
            return "Recording didn't start: ${e.message ?: e.javaClass.simpleName}"
        }
        media = r
        file = out
        startedAt = SystemClock.elapsedRealtime()
        pausedTotal = 0
        paused = false
        ticker.run()
        return if (withSound) null else "Recording without sound: allow the microphone in Contrast Ink's settings screen."
    }

    fun togglePause() {
        val r = media ?: return
        if (paused) { r.resume(); pausedTotal += SystemClock.elapsedRealtime() - pausedAt; paused = false }
        else { r.pause(); pausedAt = SystemClock.elapsedRealtime(); paused = true }
        service.refreshBar()
    }

    fun stop(saveToGallery: Boolean) {
        val r = media ?: return
        media = null
        main.removeCallbacks(ticker)
        val ok = runCatching { r.stop() }.isSuccess   // fails when nothing was recorded yet
        r.release()
        display?.release(); display = null
        projection?.let { p -> projection = null; runCatching { p.stop() } }
        paused = false
        val f = file ?: return
        file = null
        if (!ok) { f.delete(); service.recordingEnded("Nothing was recorded (stopped too soon)."); return }
        val where = if (saveToGallery) copyToGallery(f) else null
        service.recordingEnded(if (where != null) "Saved to the Gallery: $where" else "Saved: ${f.absolutePath}")
    }

    /** Puts the video in Movies/Contrast Ink, where the Gallery and Files apps show it. */
    private fun copyToGallery(f: File): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null   // Android 8–9: it stays in the app's folder
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, f.name)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/Contrast Ink")
        }
        val resolver = service.contentResolver
        val uri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values) ?: return null
        return runCatching {
            resolver.openOutputStream(uri)!!.use { out -> f.inputStream().use { it.copyTo(out) } }
            f.delete()
            "Movies/Contrast Ink/${f.name}"
        }.getOrElse { resolver.delete(uri, null, null); null }
    }

    private val main = Handler(Looper.getMainLooper())
    private val ticker = object : Runnable {
        override fun run() {
            service.refreshBar()
            if (active) main.postDelayed(this, 500)
        }
    }
}
