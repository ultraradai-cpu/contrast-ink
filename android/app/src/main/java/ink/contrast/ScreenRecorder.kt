package ink.contrast

import android.Manifest
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Canvas
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
import ink.contrast.core.CleanRecording
import ink.contrast.core.CleanRecording.Box
import ink.contrast.core.CleanRecording.Mode
import ink.contrast.core.Recording
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Records the screen with your voice, to Movies/Contrast Ink in the Gallery.
 *
 * Android 8–13: the whole screen is recorded (the app below, your marks, and the toolbar: make the toolbar small with
 * ‹ so it stays out of the way). Android can't leave one window out of it.
 *
 * Android 14 and later ("clean recording"): Android asks whether to record "A single app" or the "Entire screen".
 * The picture goes through [VideoCompositor] (OpenGL) on its way to the video encoder. With "A single app" (the slides
 * app), Android records only that app: the toolbar is not in the video, and the marks, which aren't either, are drawn
 * into each frame by the compositor. With "Entire screen" the picture already has the marks (and the toolbar), so it
 * goes into the video as it is. Which one the presenter chose is worked out from the first frames (see
 * [CleanRecording.Detector]).
 */
class ScreenRecorder(private val service: InkService) {
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var media: MediaRecorder? = null
    private var compositor: VideoCompositor? = null
    private var file: File? = null
    private var startedAt = 0L
    private var pausedAt = 0L
    private var pausedTotal = 0L
    private var withSound = true
    // the recorded app's size, as Android says (Android 14+, one app); 0 until it does: then the screen's size
    private var contentW = 0
    private var contentH = 0

    val active get() = media != null
    /** A finished recording is being copied to the Gallery (a long lecture takes a while). */
    @Volatile var saving = false
        private set
    /** The last recording's length by the toolbar's clock, in ms, when it stopped (the emulator check compares it). */
    @Volatile var lastLength = 0L
        private set
    var paused = false
        private set
    /** What the last (or current) recording records: the entire screen, or one app (Android 14+). */
    var mode = Mode.UNKNOWN
        private set

    /** Whether this Android lets the presenter record one app only (and so leave the toolbar out). */
    val clean get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE

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

            // Android 14+: the recorded content's size (one app: its window; the entire screen: the screen), and
            // again when it changes (the phone turned, split screen)
            override fun onCapturedContentResize(width: Int, height: Int) { contentResized(width, height) }

            // Android 14+: the recorded app went out of sight (another app in front) or came back
            override fun onCapturedContentVisibilityChanged(isVisible: Boolean) {
                if (!isVisible && mode == Mode.SINGLE_APP && active)
                    service.notice("The recorded app is out of sight: the video shows it again when you go back to it.")
            }
        }, main)

        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        (service.getSystemService(WindowManager::class.java)).defaultDisplay.getRealMetrics(metrics)
        // the screen's own shape, at a size this phone's video encoder takes
        val (w, h) = Recording.videoSize(metrics.widthPixels, metrics.heightPixels, ::encoderTakes)

        val folder = service.getExternalFilesDir(Environment.DIRECTORY_MOVIES) ?: service.filesDir
        folder.mkdirs()
        val stamp = SimpleDateFormat("yyyy-MM-dd HHmmss", Locale.US).format(Date())
        val out = File(folder, Recording.fileName(stamp) { File(folder, it).exists() })
        withSound = service.micAllowed()
        contentW = 0; contentH = 0
        mode = if (clean) Mode.UNKNOWN else Mode.ENTIRE_SCREEN
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
            if (clean) {
                // Android draws into the compositor, the compositor into the encoder (marks added for one app).
                // The encoder starts first, so the compositor's first frame has somewhere to go.
                val c = VideoCompositor(r.surface, w, h) { m -> main.post { modeFound(m) } }
                compositor = c
                updateToolbarBox()
                service.ink.onDrawn = ::inkChanged
                r.start()
                display = p.createVirtualDisplay("Contrast Ink recording", w, h, metrics.densityDpi,
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, c.input, null, null)
            } else {
                // Android 8–13: the whole screen, straight into the encoder
                display = p.createVirtualDisplay("Contrast Ink recording", w, h, metrics.densityDpi,
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, r.surface, null, null)
                r.start()
            }
        } catch (e: Exception) {
            service.ink.onDrawn = null
            display?.release(); display = null
            compositor?.release(); compositor = null
            runCatching { r.release() }
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
        // Android 14+: what is recorded is said once it is known (modeFound)
        return if (withSound || clean) null else NO_SOUND
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
        lastLength = elapsed
        media = null
        main.removeCallbacks(ticker)
        main.removeCallbacks(snapshotRunner)
        snapshotPending = false
        service.ink.onDrawn = null
        // Android 14+: no more frames, then the compositor stops, then the encoder
        compositor?.let { c ->
            display?.release(); display = null
            c.release(); compositor = null
        }
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

    // ---------- clean recording (Android 14+) ----------

    /** The compositor worked out what Android records: say so, and start adding the marks if it's one app. */
    private fun modeFound(m: Mode) {
        if (!active) return
        mode = m
        val sound = if (withSound) "" else " $NO_SOUND"
        when (m) {
            Mode.SINGLE_APP -> {
                snapshot()
                service.notice("Recording one app: the toolbar stays out of the video, your marks are in it.$sound")
            }
            Mode.ENTIRE_SCREEN ->
                service.notice("Recording the entire screen: the toolbar is in the video — make it small (‹).$sound")
            Mode.UNKNOWN -> {}
        }
    }

    private fun contentResized(width: Int, height: Int) {
        val c = compositor ?: return
        contentW = width
        contentH = height
        val (sw, sh) = service.screenSize()
        c.contentSize(width, height, sw, sh)
        inkChanged()
    }

    /** Where the toolbar is in a frame of the entire screen (the screen fitted into the frame), for the compositor to look at. */
    private fun updateToolbarBox() {
        val c = compositor ?: return
        val bar = service.toolbarOnScreen() ?: return
        val (sw, sh) = service.screenSize()
        val f = CleanRecording.fit(sw, sh, c.width, c.height)
        val s = f.width / sw
        c.toolbarBox = Box(f.left + bar.left * s, f.top + bar.top * s, bar.width() * s, bar.height() * s)
    }

    private var snapshotPending = false
    private var lastSnapshot = 0L
    private val snapshotRunner = Runnable { snapshotPending = false; snapshot() }

    /** The drawing layer was redrawn: copy it for the video, at most about 30 times a second. */
    private fun inkChanged() {
        val c = compositor ?: return
        if (snapshotPending || c.mode == Mode.ENTIRE_SCREEN) return
        snapshotPending = true
        main.postDelayed(snapshotRunner, maxOf(0L, lastSnapshot + 33 - SystemClock.uptimeMillis()))
    }

    /**
     * Paints the drawing layer into a bitmap the size of a video frame, where the recorded app is in the frame (see
     * [CleanRecording.inkPlacement]), and hands it to the compositor. On the main thread, where the layer lives.
     */
    private fun snapshot() {
        val c = compositor ?: return
        if (c.mode == Mode.ENTIRE_SCREEN) return
        lastSnapshot = SystemClock.uptimeMillis()
        val ink = service.ink
        val (sw, sh) = service.screenSize()
        val (box, clip) = CleanRecording.inkPlacement(sw, sh, contentW, contentH, c.width, c.height)
        val bitmap = c.inkFrames.free()
        bitmap.eraseColor(0)
        val canvas = Canvas(bitmap)
        canvas.clipRect(clip.left, clip.top, clip.right, clip.bottom)
        canvas.translate(box.left, box.top)
        canvas.scale(box.width / sw, box.height / sh)
        val at = IntArray(2)
        ink.getLocationOnScreen(at)   // the layer's own top left on the screen (normally the corner)
        canvas.translate(at[0].toFloat(), at[1].toFloat())
        ink.paintMarks(canvas)
        c.inkFrames.publish(bitmap)
        c.inkChanged()
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
            updateToolbarBox()   // it may have been moved, made small, or grown a message
            if (active) main.postDelayed(this, 500)
        }
    }

    private companion object {
        const val NO_SOUND = "Recording without sound: allow the microphone in Contrast Ink's settings screen."
    }
}
