package ink.contrast

import android.Manifest
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodecList
import android.media.MediaRecorder
import android.media.MediaScannerConnection
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
import ink.contrast.core.Recording
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

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
    /** A finished recording is being copied to the Gallery (a long lecture takes a while). */
    @Volatile var saving = false
        private set
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
        // the screen's own shape, at a size this phone's video encoder takes
        val (w, h) = Recording.videoSize(metrics.widthPixels, metrics.heightPixels, ::encoderTakes)

        val folder = service.getExternalFilesDir(Environment.DIRECTORY_MOVIES) ?: service.filesDir
        folder.mkdirs()
        val stamp = SimpleDateFormat("yyyy-MM-dd HHmmss", Locale.US).format(Date())
        val out = File(folder, Recording.fileName(stamp) { File(folder, it).exists() })
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

    /** Null when it worked, otherwise what the presenter should know. */
    fun togglePause(): String? {
        val r = media ?: return null
        val done = runCatching {
            if (paused) { r.resume(); pausedTotal += SystemClock.elapsedRealtime() - pausedAt; paused = false }
            else { r.pause(); pausedAt = SystemClock.elapsedRealtime(); paused = true }
        }
        service.refreshBar()
        return done.exceptionOrNull()?.let { "Couldn't ${if (paused) "resume" else "pause"} the recording: ${it.message ?: it.javaClass.simpleName}" }
    }

    /**
     * Ends the recording. The video is finished here; copying it to the Gallery runs in the background (an hour is
     * a few gigabytes) and [InkService.recordingEnded] says where it went.
     */
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
        if (!saveToGallery) { service.recordingEnded("Saved: ${f.absolutePath}"); return }
        saving = true
        service.refreshBar()
        Thread({
            val where = runCatching { copyToGallery(f) }.getOrNull()
            saving = false
            service.recordingEnded(if (where != null) "Saved to the Gallery: $where" else "Saved: ${f.absolutePath}")
        }, "Contrast Ink saving").start()
    }

    /** Puts the video in Movies/Contrast Ink, where the Gallery and Files apps show it. Null when it couldn't. */
    private fun copyToGallery(f: File): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return copyToMoviesFolder(f)
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, f.name)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/Contrast Ink")
            put(MediaStore.Video.Media.IS_PENDING, 1)   // the Gallery doesn't show it until it's all there
        }
        val resolver = service.contentResolver
        val uri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values) ?: return null
        return runCatching {
            resolver.openOutputStream(uri)!!.use { out -> f.inputStream().use { it.copyTo(out, 1 shl 20) } }
            resolver.update(uri, ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }, null, null)
            f.delete()
            "Movies/Contrast Ink/${f.name}"
        }.getOrElse { resolver.delete(uri, null, null); null }
    }

    /** Android 8–9: straight into the shared Movies/Contrast Ink folder (needs the storage permission). */
    @Suppress("DEPRECATION")
    private fun copyToMoviesFolder(f: File): String? {
        if (service.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) return null
        val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES), "Contrast Ink")
        if (!dir.isDirectory && !dir.mkdirs()) return null
        val stem = f.name.removeSuffix(".mp4").replace(Regex(" \\(\\d+\\)$"), "")
        val target = File(dir, Recording.fileName(stem.removePrefix("Lecture ")) { File(dir, it).exists() })
        return runCatching {
            f.inputStream().use { input -> target.outputStream().use { input.copyTo(it, 1 shl 20) } }
            f.delete()
            MediaScannerConnection.scanFile(service, arrayOf(target.absolutePath), arrayOf("video/mp4"), null)
            "Movies/Contrast Ink/${target.name}"
        }.getOrElse { target.delete(); null }
    }

    /** Whether this phone's H.264 encoder takes a w x h video (when Android can't say, assume yes). */
    private fun encoderTakes(w: Int, h: Int): Boolean {
        val caps = runCatching {
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
                .filter { it.isEncoder && it.supportedTypes.any { t -> t.equals("video/avc", ignoreCase = true) } }
                .mapNotNull { runCatching { it.getCapabilitiesForType("video/avc").videoCapabilities }.getOrNull() }
        }.getOrDefault(emptyList())
        return caps.isEmpty() || caps.any { it.isSizeSupported(w, h) }
    }

    private val main = Handler(Looper.getMainLooper())
    private val ticker = object : Runnable {
        override fun run() {
            service.refreshBar()
            if (active) main.postDelayed(this, 500)
        }
    }
}
