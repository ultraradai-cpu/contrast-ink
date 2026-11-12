package ink.contrast

import android.Manifest
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
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
    private var media: MediaRecorder? = null       // the part being recorded now (none while paused)
    private var part: File? = null
    private val parts = ArrayList<File>()           // finished parts, joined into one video at the end
    private var out: File? = null
    private var size = 0 to 0
    private var dpi = 0
    private var withSound = false
    private var recording = false
    private var startedAt = 0L
    private var pausedAt = 0L
    private var pausedTotal = 0L

    val active get() = recording
    /** A finished recording is being joined and copied to the Gallery (a long lecture takes a while). */
    @Volatile var saving = false
        private set
    /** How many parts the last recording was joined from (1 + the number of pauses that recorded after them). */
    @Volatile var lastParts = 0
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
        size = Recording.videoSize(metrics.widthPixels, metrics.heightPixels, ::encoderTakes)
        dpi = metrics.densityDpi

        val folder = service.getExternalFilesDir(Environment.DIRECTORY_MOVIES) ?: service.filesDir
        folder.mkdirs()
        val stamp = SimpleDateFormat("yyyy-MM-dd HHmmss", Locale.US).format(Date())
        val video = File(folder, Recording.fileName(stamp) { File(folder, it).exists() })
        withSound = service.micAllowed()
        parts.clear()
        try {
            val r = newPart(File(folder, video.name.removeSuffix(".mp4") + " part 1.mp4"))
            display = p.createVirtualDisplay("Contrast Ink recording", size.first, size.second, dpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, r.surface, null, null)
            r.start()
        } catch (e: Exception) {
            dropPart()
            display?.release(); display = null
            p.stop(); projection = null
            return "Recording didn't start: ${e.message ?: e.javaClass.simpleName}"
        }
        out = video
        recording = true
        startedAt = SystemClock.elapsedRealtime()
        pausedTotal = 0
        paused = false
        ticker.run()
        return if (withSound) null else "Recording without sound: allow the microphone in Contrast Ink's settings screen."
    }

    /** A recorder for one part of the video (between a start or resume and the next pause or stop), prepared. */
    private fun newPart(f: File): MediaRecorder {
        val r = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) MediaRecorder(service) else @Suppress("DEPRECATION") MediaRecorder()
        media = r; part = f
        if (withSound) r.setAudioSource(MediaRecorder.AudioSource.MIC)
        r.setVideoSource(MediaRecorder.VideoSource.SURFACE)
        r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
        r.setOutputFile(f.absolutePath)
        r.setVideoEncoder(MediaRecorder.VideoEncoder.H264)
        r.setVideoSize(size.first, size.second)
        r.setVideoFrameRate(30)
        r.setVideoEncodingBitRate(6_000_000)
        if (withSound) {
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioSamplingRate(44_100)
            r.setAudioEncodingBitRate(96_000)
            r.setAudioChannels(1)
        }
        r.prepare()
        return r
    }

    /** Ends the part being recorded and keeps it (when anything was recorded in it). */
    private fun endPart() {
        val r = media ?: return
        val f = part
        media = null; part = null
        val ok = runCatching { r.stop() }.isSuccess   // fails when nothing was recorded in it
        r.release()
        if (f != null) { if (ok) parts += f else f.delete() }
    }

    private fun dropPart() {
        media?.let { runCatching { it.release() } }
        part?.delete()
        media = null; part = null
    }

    /**
     * ⏸ / ▶. Pausing ends the part being recorded; resuming starts a new one. (MediaRecorder's own pause is not
     * used: on some Androids the paused time stays in the video.) Null when it worked, otherwise what to tell.
     */
    fun togglePause(): String? {
        if (!active) return null
        val problem = if (paused) {
            val n = parts.size + 1
            val o = out ?: return null
            runCatching {
                val r = newPart(File(o.parentFile, o.name.removeSuffix(".mp4") + " part $n.mp4"))
                display?.surface = r.surface
                r.start()
            }.exceptionOrNull()?.let { dropPart(); "Couldn't resume the recording: ${it.message ?: it.javaClass.simpleName}" }
        } else {
            display?.surface = null   // nothing goes to the encoder while paused
            endPart()
            null
        }
        if (problem == null) {
            if (paused) { pausedTotal += SystemClock.elapsedRealtime() - pausedAt; paused = false }
            else { pausedAt = SystemClock.elapsedRealtime(); paused = true }
        }
        service.refreshBar()
        return problem
    }

    /**
     * Ends the recording. Joining its parts and copying the video to the Gallery run in the background (an hour is
     * a few gigabytes) and [InkService.recordingEnded] says where it went.
     */
    fun stop(saveToGallery: Boolean) {
        if (!active) return
        recording = false
        main.removeCallbacks(ticker)
        display?.surface = null
        endPart()
        display?.release(); display = null
        projection?.let { p -> projection = null; runCatching { p.stop() } }
        paused = false
        val f = out ?: return
        out = null
        val pieces = parts.toList()
        parts.clear()
        lastParts = pieces.size
        if (pieces.isEmpty()) { service.recordingEnded("Nothing was recorded (stopped too soon)."); return }
        saving = true
        service.refreshBar()
        Thread({
            val joined = runCatching { join(pieces, f) }.getOrNull()
            val where = if (joined != null && saveToGallery) runCatching { copyToGallery(joined) }.getOrNull() else null
            saving = false
            service.recordingEnded(when {
                where != null -> "Saved to the Gallery: $where"
                joined != null -> "Saved: ${joined.absolutePath}"
                else -> "Couldn't put the recording together; its parts are in ${f.parentFile?.absolutePath}"
            })
        }, "Contrast Ink saving").start()
    }

    /** The parts, one after the other, as one video (the parts are deleted once it's made). */
    private fun join(pieces: List<File>, into: File): File {
        if (pieces.size == 1) { if (!pieces[0].renameTo(into)) error("couldn't rename"); return into }
        val muxer = MediaMuxer(into.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        try {
            val tracks = HashMap<String, Int>()   // "video/..." or "audio/..." -> the joined video's track
            // every track the joined video has comes from the first part's formats
            MediaExtractor().apply { setDataSource(pieces[0].absolutePath) }.let { ex ->
                for (i in 0 until ex.trackCount) {
                    val f = ex.getTrackFormat(i)
                    val kind = f.getString(MediaFormat.KEY_MIME)?.substringBefore('/') ?: continue
                    if (kind !in tracks) tracks[kind] = muxer.addTrack(f)
                }
                ex.release()
            }
            muxer.start()
            val buffer = java.nio.ByteBuffer.allocate(4 shl 20)
            val info = MediaCodec.BufferInfo()
            var offset = 0L
            for (piece in pieces) {
                val ex = MediaExtractor().apply { setDataSource(piece.absolutePath) }
                val map = HashMap<Int, Int>()
                for (i in 0 until ex.trackCount) {
                    val kind = ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME)?.substringBefore('/') ?: continue
                    tracks[kind]?.let { map[i] = it; ex.selectTrack(i) }
                }
                var end = offset
                while (true) {
                    val track = ex.sampleTrackIndex
                    if (track < 0) break
                    info.size = ex.readSampleData(buffer, 0)
                    if (info.size < 0) break
                    info.offset = 0
                    info.presentationTimeUs = offset + ex.sampleTime
                    info.flags = if (ex.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
                    map[track]?.let { muxer.writeSampleData(it, buffer, info) }
                    end = maxOf(end, info.presentationTimeUs)
                    ex.advance()
                }
                ex.release()
                offset = end + 33_333   // the next part starts one frame after this one's last sample
            }
            muxer.stop()
        } finally {
            runCatching { muxer.release() }
        }
        pieces.forEach { it.delete() }
        return into
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
