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
import android.util.Log
import android.view.Surface
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
 * goes into the video as it is. Which one the presenter chose is worked out from the first frames, where the
 * toolbar shows a beacon meanwhile (see [CleanRecording.Detector]). If OpenGL fails, at the start or later, the
 * picture goes straight to the encoder (as on Android 8–13) and the recording goes on.
 *
 * A lecture is never lost to one failure: an encoder error stops the recording and keeps what was recorded, a file
 * nearing MP4's size limit goes on in a new part, free space is checked every minute, and a file is only ever deleted
 * when it is too small to hold anything.
 */
class ScreenRecorder(private val service: InkService) {
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var media: MediaRecorder? = null
    private var encoderSurface: Surface? = null
    private var compositor: VideoCompositor? = null
    private var folder: File? = null
    /** The recording's files, in order: one, or more when a long lecture went on in new parts. */
    private val parts = ArrayList<File>()
    /** The next part, handed to the encoder and not started yet. */
    private var nextPart: File? = null
    private var startedAt = 0L
    private var pausedAt = 0L
    private var pausedTotal = 0L
    private var withSound = true
    private var density = 0
    // the video's size (a VirtualDisplay may be made once OpenGL is ready, or after it failed)
    private var videoW = 0
    private var videoH = 0
    // the recorded app's size, as Android says (Android 14+, one app); 0 until it does: then the screen's size
    private var contentW = 0
    private var contentH = 0
    private var contentVisible = true
    private var hiddenSaid = false
    private var lastModeNotice: String? = null
    private var lowSpaceSaid = false
    /** What the start had to say (little space, no sound), said with what is recorded on Android 14+. */
    private var startNews = ""

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
    /** Marks go into the video by OpenGL (false: OpenGL failed or isn't used, the picture goes straight to the encoder). */
    val compositing get() = compositor != null
    /** Whether the bitmaps for drawing the marks into the video exist (none for a recording of the entire screen). */
    val inkBitmapsAllocated get() = compositor?.inkFrames?.allocated == true
    /** How many files the current recording is in so far. */
    val partCount get() = parts.size
    /** Whether the recorded app is in sight (Android 14+, one app). */
    val recordedAppVisible get() = contentVisible
    /** Whether the compositor draws the marks into the video's frames now. */
    val drawsInkIntoVideo get() = compositor?.let { CleanRecording.drawInk(it.mode, it.contentVisible) } == true

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
        val dir = service.getExternalFilesDir(Environment.DIRECTORY_MOVIES) ?: service.filesDir
        dir.mkdirs()
        val space = Recording.space(freeBytes(dir))
        if (space == Recording.Space.STOP)
            return "Not enough space to record (${freeBytes(dir) / 1_000_000} MB free): free some space on the tablet first."

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
            override fun onCapturedContentVisibilityChanged(isVisible: Boolean) { visibilityChanged(isVisible) }
        }, main)

        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        (service.getSystemService(WindowManager::class.java)).defaultDisplay.getRealMetrics(metrics)
        density = metrics.densityDpi
        // the screen's own shape, at a size this phone's video encoder takes
        val (w, h) = Recording.videoSize(metrics.widthPixels, metrics.heightPixels, ::encoderTakes)
        videoW = w; videoH = h

        val stamp = SimpleDateFormat("yyyy-MM-dd HHmmss", Locale.US).format(Date())
        val out = File(dir, Recording.fileName(stamp) { File(dir, it).exists() })
        withSound = service.micAllowed()
        contentW = 0; contentH = 0
        contentVisible = true; hiddenSaid = false; lastModeNotice = null; lowSpaceSaid = false; startNews = ""
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
            // near this size the video goes on in a new file ("part 2"), well before MP4's 4 GB
            r.setMaxFileSize(maxFileBytesForTest ?: Recording.MAX_FILE_BYTES)
            r.setOnErrorListener { mr, what, extra -> main.post { encoderFailed(mr, "error $what/$extra") } }
            r.setOnInfoListener { mr, what, _ -> main.post { encoderInfo(mr, what) } }
            r.prepare()
            val surface = r.surface
            encoderSurface = surface
            // the encoder starts first, so the first frame has somewhere to go
            r.start()
            media = r
            folder = dir
            parts.clear(); parts += out
            nextPart = null
            if (clean) {
                // Android draws into the compositor, the compositor into the encoder (marks added for one app).
                // OpenGL starts on its own thread; Android's picture goes to it once it's ready (compositorReady).
                compositor = VideoCompositor(surface, w, h, compositorEvents)
                updateBeaconBox()
                service.ink.onDrawn = ::inkChanged
            } else {
                // Android 8–13: the whole screen, straight into the encoder
                display = p.createVirtualDisplay("Contrast Ink recording", w, h, density,
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, surface, null, null)
            }
        } catch (e: Exception) {
            media = null
            service.ink.onDrawn = null
            display?.release(); display = null
            compositor?.let { it.release(); it.inkFrames.drop() }; compositor = null
            runCatching { r.reset() }
            runCatching { r.release() }
            p.stop(); projection = null
            encoderSurface = null
            parts.clear()
            out.delete()   // nothing was recorded into it
            return "Recording didn't start: ${e.message ?: e.javaClass.simpleName}"
        }
        startedAt = SystemClock.elapsedRealtime()
        pausedTotal = 0
        paused = false
        ticker.run()
        main.postDelayed(spaceCheck, SPACE_CHECK_MS)
        // Android 14+: said with what is recorded, once that is known (modeFound), so one message doesn't hide the other
        val news = listOfNotNull(
            if (space == Recording.Space.LOW) lowSpace().also { lowSpaceSaid = true } else null,
            if (!withSound) NO_SOUND else null).joinToString(" ")
        if (clean && compositor != null) startNews = news
        else if (news.isNotEmpty()) service.notice(news)
        return null
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
     * a few gigabytes) and [InkService.recordingEnded] says where it went. [why]: said first (a recording stopped by
     * itself, and why).
     */
    fun stop(saveToGallery: Boolean, why: String? = null) {
        val r = media ?: return
        lastLength = elapsed
        media = null
        main.removeCallbacks(ticker)
        main.removeCallbacks(spaceCheck)
        main.removeCallbacks(snapshotRunner)
        main.removeCallbacks(displayLater)
        snapshotPending = false
        service.ink.onDrawn = null
        service.showBeacon(false)
        // Android 14+: no more frames, then the compositor stops, then the encoder
        display?.release(); display = null
        compositor?.let { c -> c.release(); c.inkFrames.drop() }
        compositor = null
        val stopped = runCatching { r.stop() }
        if (stopped.isFailure) Log.w(TAG, "the recording didn't stop cleanly", stopped.exceptionOrNull())
        runCatching { r.release() }
        encoderSurface = null
        projection?.let { p -> projection = null; runCatching { p.stop() } }
        paused = false
        // a part handed to the encoder but never started is empty
        nextPart?.let { if (it !in parts) it.delete() }
        nextPart = null
        val names = names()
        var files = parts.toList()
        parts.clear()
        var incomplete = false
        if (stopped.isFailure) {
            // MediaRecorder throws when nothing was recorded yet (stopped at once): only then is the file worthless.
            // Anything bigger may be a whole lecture: kept, and most players play it.
            val (keep, drop) = files.partition { Recording.keepAfterFailedStop(it.length()) }
            drop.forEach { it.delete() }
            files = keep
            incomplete = true
        }
        val before = listOfNotNull(why, if (incomplete && files.isNotEmpty()) "The video may be incomplete." else null).joinToString(" ")
        fun say(s: String) = service.recordingEnded(if (before.isEmpty()) s else "$before $s")
        if (files.isEmpty()) { say("Nothing was recorded (stopped too soon)."); return }
        if (!saveToGallery) { say("Saved: ${files.joinToString(", ") { it.absolutePath }}"); return }
        saving = true
        service.refreshBar()
        Thread({
            val where = files.map { f -> f to runCatching { copyToGallery(f, names[f] ?: f.name) }.getOrNull() }
            saving = false
            say(when {
                where.all { it.second != null } && where.size == 1 -> "Saved to the Gallery: ${where[0].second}"
                where.all { it.second != null } -> "Saved to the Gallery in ${where.size} parts: ${where.joinToString(", ") { it.second!! }}"
                else -> "Saved: " + where.joinToString(", ") { (f, w) -> w ?: f.absolutePath }
            })
        }, "Contrast Ink saving").start()
    }

    /** The names the files get in the Gallery: as they are, or "… part 1", "… part 2" when there are several. */
    private fun names(): Map<File, String> {
        if (parts.size < 2) return parts.associateWith { it.name }
        val first = parts[0].name
        return parts.withIndex().associate { (i, f) -> f to Recording.partName(first, i + 1) }
    }

    // ---------- the encoder's news, free space ----------

    /** The video encoder failed (MediaRecorder's error callback): stop, keeping what was recorded. */
    private fun encoderFailed(r: MediaRecorder, detail: String) {
        if (media !== r) return
        Log.w(TAG, "the video encoder failed: $detail")
        stop(saveToGallery = true, why = "The recording stopped: the tablet's video encoder failed ($detail).")
    }

    private fun encoderInfo(r: MediaRecorder, what: Int) {
        if (media !== r) return
        when (what) {
            // the file nears its size limit: the next part is handed over, and the encoder moves to it by itself
            MediaRecorder.MEDIA_RECORDER_INFO_MAX_FILESIZE_APPROACHING -> {
                if (nextPart != null) return
                val dir = folder ?: return
                val f = File(dir, Recording.partName(parts[0].name, parts.size + 1))
                runCatching { r.setNextOutputFile(f); nextPart = f }
                    .onFailure { Log.w(TAG, "no next part", it) }
            }
            MediaRecorder.MEDIA_RECORDER_INFO_NEXT_OUTPUT_FILE_STARTED -> {
                val f = nextPart ?: return
                nextPart = null
                parts += f
                service.notice("The video goes on in part ${parts.size} (a long lecture is saved in several files: all of them go to the Gallery).")
            }
            // the limit was reached without a next part: stop, and keep it
            MediaRecorder.MEDIA_RECORDER_INFO_MAX_FILESIZE_REACHED ->
                stop(saveToGallery = true, why = "The recording stopped: the video reached the largest size a file can have.")
            MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED ->
                stop(saveToGallery = true, why = "The recording stopped: the video reached its longest length.")
        }
    }

    private fun freeBytes(dir: File): Long = freeBytesForTest ?: dir.usableSpace

    private fun lowSpace() = "Less than 1 GB free on the tablet: the recording stops by itself, and is kept, under 200 MB."

    /** Every minute: free space. Low: warned once. Nearly none: stopped and kept (a full disk would break the file). */
    private val spaceCheck = object : Runnable {
        override fun run() {
            if (!active) return
            checkSpace()
            if (active) main.postDelayed(this, SPACE_CHECK_MS)
        }
    }

    /** Checks the free space now (the minute's check; the app's test calls it directly). */
    fun checkSpace() {
        val dir = folder ?: return
        if (!active) return
        when (Recording.space(freeBytes(dir))) {
            Recording.Space.STOP -> stop(saveToGallery = true, why = "The recording stopped: less than 200 MB free on the tablet.")
            Recording.Space.LOW -> if (!lowSpaceSaid) { lowSpaceSaid = true; service.notice(lowSpace()) }
            Recording.Space.OK -> {}
        }
    }

    // ---------- clean recording (Android 14+) ----------

    /** The compositor's news, on its own thread: handed to the main thread. */
    private val compositorEvents = object : VideoCompositor.Events {
        override fun ready(input: Surface) { main.post { compositorReady(input) } }
        override fun failed(problem: Throwable, whileRunning: Boolean) { main.post { compositorFailed(problem) } }
        override fun mode(mode: Mode, settled: Boolean, bySize: Boolean, guessed: Boolean) {
            main.post { modeFound(mode, settled, bySize, guessed) }
        }
    }

    private var pendingInput: Surface? = null
    private val displayLater = Runnable { pendingInput?.let { showTo(it) }; pendingInput = null }

    /** OpenGL is ready: Android's picture goes to it. */
    private fun compositorReady(input: Surface) {
        if (compositor == null || !active) return
        val delay = displayDelayForTest
        if (delay > 0) { pendingInput = input; main.postDelayed(displayLater, delay); return }
        showTo(input)
    }

    /** Android starts drawing what it records into [target] (or, once it does, moves there). */
    private fun showTo(target: Surface) {
        val p = projection ?: return
        if (!active) return
        try {
            val d = display
            if (d != null) d.surface = target
            else {
                display = p.createVirtualDisplay("Contrast Ink recording", videoW, videoH, density,
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, target, null, null)
            }
        } catch (e: Exception) {
            Log.w(TAG, "the recording's display didn't start", e)
            stop(saveToGallery = true, why = "The recording stopped: Android didn't hand over the screen (${e.message ?: e.javaClass.simpleName}).")
        }
    }

    /**
     * OpenGL failed (at the start, or mid-lecture): its surfaces are gone, so Android's picture goes straight to the
     * encoder from now on, and the recording goes on. A recording of one app then has no marks drawn in.
     */
    private fun compositorFailed(problem: Throwable) {
        val c = compositor ?: return
        if (!active) return
        compositor = null
        main.removeCallbacks(displayLater); pendingInput = null
        main.removeCallbacks(snapshotRunner); snapshotPending = false
        service.ink.onDrawn = null
        c.release()
        c.inkFrames.drop()
        service.showBeacon(false)
        val wasOneApp = mode == Mode.SINGLE_APP
        encoderSurface?.let { showTo(it) }
        if (!active) return
        service.notice(if (wasOneApp)
            "Your marks can't be drawn into this video any more (the tablet's graphics failed: ${problem.message ?: problem.javaClass.simpleName}). The recording goes on: to have the marks, stop and record the entire screen."
        else
            "The recording goes on without Contrast Ink's video drawing (the tablet's graphics failed: ${problem.message ?: problem.javaClass.simpleName}). With \"A single app\" the marks aren't in the video: record the entire screen to have them.")
        service.refreshBar()
    }

    /** The compositor worked out what Android records: say so, and start adding the marks if it's one app. */
    private fun modeFound(m: Mode, settled: Boolean, bySize: Boolean, guessed: Boolean) {
        if (!active || compositor == null) return
        mode = m
        if (settled) service.showBeacon(false)
        when (m) {
            Mode.SINGLE_APP -> snapshot()
            Mode.ENTIRE_SCREEN -> {
                main.removeCallbacks(snapshotRunner); snapshotPending = false
                compositor?.inkFrames?.drop()   // never needed: the marks are in the picture
            }
            Mode.UNKNOWN -> {}
        }
        val text = CleanRecording.modeNotice(m, bySize, guessed) ?: return
        if (text == lastModeNotice) return
        lastModeNotice = text
        service.notice(if (startNews.isEmpty()) text else "$text $startNews")
        if (m == Mode.SINGLE_APP && !contentVisible) sayHidden()
    }

    private fun contentResized(width: Int, height: Int) {
        val c = compositor ?: return
        contentW = width
        contentH = height
        val (sw, sh) = service.screenSize()
        c.contentSize(width, height, sw, sh)
        inkChanged()
    }

    private fun visibilityChanged(visible: Boolean) {
        if (!active) return
        contentVisible = visible
        compositor?.contentVisible = visible
        if (!visible && mode == Mode.SINGLE_APP) sayHidden()
        if (visible) inkChanged()
    }

    private fun sayHidden() {
        if (hiddenSaid) return
        hiddenSaid = true
        service.notice(CleanRecording.HIDDEN_NOTICE)
    }

    /** Where the toolbar's beacon is in a frame of the entire screen (the screen fitted into the frame), for the compositor to look at. */
    private fun updateBeaconBox() {
        val c = compositor ?: return
        val beacon = service.beaconOnScreen()
        if (beacon == null) { c.beaconBox = null; return }
        val (sw, sh) = service.screenSize()
        val f = CleanRecording.fit(sw, sh, c.width, c.height)
        val s = f.width / sw
        c.beaconBox = Box(f.left + beacon.left * s, f.top + beacon.top * s, beacon.width() * s, beacon.height() * s)
    }

    private var snapshotPending = false
    private var lastSnapshot = 0L
    private var lastSnapshotVersion = -1L
    private val snapshotRunner = Runnable { snapshotPending = false; snapshot() }

    /** The drawing layer was redrawn: copy it for the video, at most 30 times a second (15 when only the laser moves). */
    private fun inkChanged() {
        val c = compositor ?: return
        if (snapshotPending || c.mode != Mode.SINGLE_APP || !contentVisible) return
        snapshotPending = true
        val onlyLaser = service.ink.marksVersion == lastSnapshotVersion
        main.postDelayed(snapshotRunner, CleanRecording.snapshotDelay(lastSnapshot, SystemClock.uptimeMillis(), onlyLaser))
    }

    /**
     * Paints the drawing layer into a bitmap the size of a video frame, where the recorded app is in the frame (see
     * [CleanRecording.inkPlacement]), and hands it to the compositor. On the main thread, where the layer lives.
     */
    private fun snapshot() {
        val c = compositor ?: return
        if (c.mode != Mode.SINGLE_APP) return
        lastSnapshot = SystemClock.uptimeMillis()
        val ink = service.ink
        lastSnapshotVersion = ink.marksVersion
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

    /** Puts the video in Movies/Contrast Ink, named [name], where the Gallery and Files apps show it. Null when it couldn't. */
    private fun copyToGallery(f: File, name: String): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return copyToMoviesFolder(f, name)
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, name)
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
            "Movies/Contrast Ink/$name"
        }.getOrElse { resolver.delete(uri, null, null); null }
    }

    /** Android 8–9: straight into the shared Movies/Contrast Ink folder (needs the storage permission). */
    @Suppress("DEPRECATION")
    private fun copyToMoviesFolder(f: File, name: String): String? {
        if (service.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) return null
        val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES), "Contrast Ink")
        if (!dir.isDirectory && !dir.mkdirs()) return null
        val stem = name.removeSuffix(".mp4").replace(Regex(" \\(\\d+\\)$"), "")
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
            updateBeaconBox()   // it may have been moved, made small, or grown a message
            if (active) main.postDelayed(this, 500)
        }
    }

    companion object {
        private const val TAG = "ContrastInk"
        const val NO_SOUND = "Recording without sound: allow the microphone in Contrast Ink's settings screen."
        const val SPACE_CHECK_MS = 60_000L
        /** TEST ONLY: Android's picture reaches the compositor this much later (a slow first frame). */
        @Volatile var displayDelayForTest = 0L
        /** TEST ONLY: a small size limit, so the app's test sees a recording go on in a second part. */
        @Volatile var maxFileBytesForTest: Long? = null
        /** TEST ONLY: the free space the recorder sees. */
        @Volatile var freeBytesForTest: Long? = null
    }
}
