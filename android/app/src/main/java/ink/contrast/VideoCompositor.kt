package ink.contrast

import android.graphics.Bitmap
import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLUtils
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import ink.contrast.core.CleanRecording
import ink.contrast.core.CleanRecording.Box
import ink.contrast.core.CleanRecording.Mode
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Sits between what Android records and the video encoder, so the app can add to each frame.
 *
 * Android draws what it records (the whole screen, or one app) into [input]. Each new picture is drawn, with OpenGL
 * ES 2, into [output] (the video encoder's surface). When Android records one app only, the marks aren't in its
 * picture (they are in Contrast Ink's own window), so they are drawn on top: [inkFrames] holds copies of the drawing
 * layer the size of a video frame, made on the main thread whenever the layer changes.
 *
 * Everything here runs on its own thread ("Contrast Ink video"), which owns the OpenGL context. Nothing waits for it
 * on the main thread except [release]: OpenGL starts in the background and says so through [Events]. If OpenGL
 * fails, at the start or in the middle of a lecture, everything here is torn down (which lets go of the encoder's
 * surface) and [Events.failed] says so: the recorder then sends Android's picture straight to the encoder.
 */
class VideoCompositor(
    private val output: Surface,
    val width: Int,
    val height: Int,
    private val events: Events,
) {
    /** Called on the video thread: the recorder hands them to the main thread. */
    interface Events {
        /** OpenGL is ready: Android may draw into [input] now. */
        fun ready(input: Surface)
        /**
         * OpenGL failed ([whileRunning]: after [ready]). Everything is torn down and the encoder's surface is free
         * for Android's picture to go to directly.
         */
        fun failed(problem: Throwable, whileRunning: Boolean)
        /** What Android records (or whether it is final, or how it was decided) changed. */
        fun mode(mode: Mode, settled: Boolean, bySize: Boolean, guessed: Boolean)
        /** Back in sight, the picture held is black: Android is asked to draw the app into [input] afresh. */
        fun wantPicture() {}
    }

    /** Where Android draws what it records (the recording's VirtualDisplay draws into this), once [Events.ready]. */
    lateinit var input: Surface
        private set
    /** The drawing layer, as video-frame-sized pictures, handed over from the main thread. */
    val inkFrames = InkFrames(width, height)
    /** Where the toolbar's beacon is, in video-frame pixels (set from the main thread): looked at to tell the two modes apart. */
    @Volatile var beaconBox: Box? = null
    /** What Android records, once known. */
    @Volatile var mode = Mode.UNKNOWN
        private set
    /** Whether the recorded app is in sight (Android 14+ says): out of sight, Android holds its last picture and no new marks go on it. */
    @Volatile var contentVisible = true
        set(v) {
            if (field == v) return
            field = v
            gl.post {
                if (released || !running) return@post
                if (v) {
                    // back in sight: the picture held meanwhile may be black (Android 14). No marks, and no new frame
                    // (the video holds its last one), until Android sends a picture of the app that isn't black
                    awaitingPicture = true
                    pictureAsks = 0
                    gl.removeCallbacks(pictureCheck)
                    gl.postDelayed(pictureCheck, PICTURE_WAIT_MS)
                } else {
                    awaitingPicture = false
                    gl.removeCallbacks(pictureCheck)
                    // a black slide is black of its own: then black after coming back is no sign of a held picture.
                    // Looked up from before the app went (Android may already have sent its black picture)
                    val now = SystemClock.uptimeMillis()
                    blackBeforeHidden = if (lastLookAt in 1..now - LOOK_BEFORE_HIDDEN_MS) lastLookBlack else earlierLookBlack
                    if (haveFrame && mode == Mode.SINGLE_APP) safely { draw(look = false) }   // the marks come off
                }
            }
        }
    /** Back in sight, no picture of the app from Android yet (on the video thread). */
    private var awaitingPicture = false
    private var pictureAsks = 0
    private var blackBeforeHidden = false
    /** About once a second, whether Android's picture of the app was black (and the look before that). */
    private var lastLookAt = 0L
    private var lastLookBlack = false
    private var earlierLookBlack = false
    /** The wait after coming back is over without a picture of the app: look at what is held (CleanRecording.afterShown). */
    private val pictureCheck: Runnable = Runnable {
        if (!awaitingPicture || !running || released) return@Runnable
        safely {
            val black = haveFrame && mode == Mode.SINGLE_APP && heldPictureBlack()
            when (CleanRecording.afterShown(haveFrame, mode, black, pictureAsks, blackBeforeHidden)) {
                CleanRecording.AfterShown.DRAW_MARKS -> { awaitingPicture = false; if (haveFrame) draw(look = false) }
                CleanRecording.AfterShown.ASK_AGAIN -> {
                    pictureAsks++
                    events.wantPicture()
                    gl.postDelayed(pictureCheck, PICTURE_WAIT_MS)
                }
                CleanRecording.AfterShown.NO_MARKS -> Log.w(TAG, "back in sight, Android still holds a black picture: no marks until it sends one")
            }
        }
    }

    private val thread = HandlerThread("Contrast Ink video").apply { start() }
    private val gl = Handler(thread.looper)
    private val detector = CleanRecording.Detector()
    private val startedAt = SystemClock.elapsedRealtime()

    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var context: EGLContext = EGL14.EGL_NO_CONTEXT
    private var surface: EGLSurface = EGL14.EGL_NO_SURFACE
    private lateinit var texture: SurfaceTexture
    private var frameTex = 0
    private var inkTex = 0
    private var inkLoaded = false      // the ink texture has a picture in it
    private var frameProgram = 0
    private var inkProgram = 0
    private var haveFrame = false      // Android has sent a first picture
    private var running = false        // set up, not failed or released
    private var lastTime = 0L
    @Volatile private var released = false
    private val texMatrix = FloatArray(16)
    private var told: List<Any>? = null   // the last mode, settled, bySize and guessed told to [events]
    private var settleCheck = false

    init {
        gl.post {
            try {
                if (failSetUpForTest) { failSetUpForTest = false; throw IllegalStateException("OpenGL made to fail by the app's test") }
                setUp()
                running = true
                events.ready(input)
            } catch (t: Throwable) {
                Log.w(TAG, "the video drawing didn't start", t)
                runCatching { tearDown() }
                events.failed(t, whileRunning = false)
            }
        }
        // no frame looked at in the first seconds (none came, or nothing to look at): the safe default
        gl.postDelayed({ if (running) tell(detector.noLook(since())) }, GIVE_UP_MS)
    }

    /** Android said the recorded content is [w] x [h] on a [screenW] x [screenH] screen (Android 14+). */
    fun contentSize(w: Int, h: Int, screenW: Int, screenH: Int) = gl.post {
        if (running) tell(detector.contentSize(w, h, screenW, screenH))
    }

    /** The main thread put a new picture of the marks in [inkFrames]: redraw the last frame with it. */
    fun inkChanged() = gl.post { if (running && haveFrame && mode == Mode.SINGLE_APP && !awaitingPicture) safely { draw(look = false) } }

    /** Stops drawing and frees everything. Waits (briefly) for the video thread to finish; false when it didn't in time. */
    fun release(): Boolean {
        released = true
        val done = CountDownLatch(1)
        val posted = gl.post {
            runCatching { tearDown() }
            done.countDown()
        }
        val finished = posted && done.await(2, TimeUnit.SECONDS)
        thread.quitSafely()
        return finished
    }

    // ---------- on the video thread ----------

    private fun since() = SystemClock.elapsedRealtime() - startedAt

    /** Runs a frame's OpenGL work; anything thrown ends the compositor (the recording goes on without it). */
    private inline fun safely(work: () -> Unit) {
        try { work() } catch (t: Throwable) {
            if (!running) return
            Log.w(TAG, "the video drawing failed mid-recording", t)
            runCatching { tearDown() }
            events.failed(t, whileRunning = true)
        }
    }

    private fun setUp() {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val version = IntArray(2)
        check(EGL14.eglInitialize(display, version, 0, version, 1)) { "no OpenGL display" }
        val config = chooseConfig()
        context = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0)
        check(context != EGL14.EGL_NO_CONTEXT) { "no OpenGL context" }
        surface = EGL14.eglCreateWindowSurface(display, config, output, intArrayOf(EGL14.EGL_NONE), 0)
        check(surface != EGL14.EGL_NO_SURFACE) { "the video encoder's surface can't be drawn on" }
        check(EGL14.eglMakeCurrent(display, surface, surface, context)) { "OpenGL didn't start" }

        frameProgram = program(VERTEX, FRAGMENT_FRAME)
        inkProgram = program(VERTEX, FRAGMENT_INK)
        val ids = IntArray(2)
        GLES20.glGenTextures(2, ids, 0)
        frameTex = ids[0]
        inkTex = ids[1]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, frameTex)
        textureParameters(GLES11Ext.GL_TEXTURE_EXTERNAL_OES)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, inkTex)
        textureParameters(GLES20.GL_TEXTURE_2D)

        texture = SurfaceTexture(frameTex)
        texture.setDefaultBufferSize(width, height)
        texture.setOnFrameAvailableListener({ newFrame() }, gl)
        input = Surface(texture)
    }

    /** RGBA, OpenGL ES 2, and "recordable": a surface a video encoder can take. */
    private fun chooseConfig(): EGLConfig {
        val attributes = intArrayOf(
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL_RECORDABLE_ANDROID, 1,
            EGL14.EGL_NONE)
        val configs = arrayOfNulls<EGLConfig>(1)
        val count = IntArray(1)
        if (!EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, count, 0) || count[0] == 0) {
            // some phones offer no recordable surface with an alpha channel: the video needs none
            val noAlpha = intArrayOf(EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT, EGL_RECORDABLE_ANDROID, 1, EGL14.EGL_NONE)
            check(EGL14.eglChooseConfig(display, noAlpha, 0, configs, 0, 1, count, 0) && count[0] > 0) { "no OpenGL setup for video" }
        }
        return configs[0]!!
    }

    private fun newFrame() {
        if (!running) return
        safely {
            if (failNextFrameForTest) { failNextFrameForTest = false; throw IllegalStateException("OpenGL made to fail by the app's test") }
            texture.updateTexImage()
            haveFrame = true
            if (mode == Mode.SINGLE_APP && contentVisible && SystemClock.uptimeMillis() - lastLookAt >= 1000) {
                earlierLookBlack = lastLookBlack
                lastLookBlack = heldPictureBlack()
                lastLookAt = SystemClock.uptimeMillis()
            }
            // back in sight: the first pictures may still be the held black one
            if (awaitingPicture && (blackBeforeHidden || !(mode == Mode.SINGLE_APP && heldPictureBlack()))) {
                awaitingPicture = false
                gl.removeCallbacks(pictureCheck)
            }
            draw(look = true)
        }
    }

    /**
     * Draws the last picture Android sent, the marks over it when recording one app, and hands the frame to the video
     * encoder. [look]: a new picture from Android, looked at (until the answer is final) for the toolbar's beacon.
     */
    private fun draw(look: Boolean) {
        GLES20.glViewport(0, 0, width, height)
        GLES20.glDisable(GLES20.GL_BLEND)
        texture.getTransformMatrix(texMatrix)
        quad(frameProgram, GLES11Ext.GL_TEXTURE_EXTERNAL_OES, frameTex, FRAME_COORDS, texMatrix)

        // looked at from the first frame, however late it comes (the time to change its mind runs from there)
        val since = since()
        if (look && !detector.settled(since)) {
            val box = beaconBox
            if (box == null) tell(detector.noLook(since))
            else {
                val (pixels, w) = readPixels(box)
                tell(detector.frame(CleanRecording.beaconSeen(pixels, w), since))
                if (!settleCheck) {
                    // a still app sends no more frames: say "final" when it is, frame or not
                    settleCheck = true
                    gl.postDelayed({ if (running) tell(detector.mode) }, maxOf(0L, detector.settlesAt() - since))
                }
            }
        }

        if (CleanRecording.drawInk(mode, contentVisible) && !awaitingPicture) {
            inkFrames.take()?.let { bitmap ->
                try {
                    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, inkTex)
                    if (inkLoaded) GLUtils.texSubImage2D(GLES20.GL_TEXTURE_2D, 0, 0, 0, bitmap)
                    else GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)
                    inkLoaded = true
                } finally { inkFrames.done() }
            }
            if (inkLoaded) {
                // the marks' picture has premultiplied alpha (as every Android bitmap): "one, one minus alpha"
                GLES20.glEnable(GLES20.GL_BLEND)
                GLES20.glBlendFunc(GLES20.GL_ONE, GLES20.GL_ONE_MINUS_SRC_ALPHA)
                quad(inkProgram, GLES20.GL_TEXTURE_2D, inkTex, INK_COORDS, IDENTITY)
                GLES20.glDisable(GLES20.GL_BLEND)
            }
        }

        // the frame's time in the video: now (the encoder needs times that only go forwards)
        val time = maxOf(System.nanoTime(), lastTime + 1000)
        lastTime = time
        EGLExt.eglPresentationTimeANDROID(display, surface, time)
        check(EGL14.eglSwapBuffers(display, surface)) { "the frame couldn't go to the video encoder (EGL error ${EGL14.eglGetError()})" }
    }

    /** Tells [events] what is known now, when anything about it changed. */
    private fun tell(m: Mode) {
        mode = m
        val now = listOf(m, detector.settled(since()), detector.bySize, detector.guessed)
        if (now == told) return
        told = now
        events.mode(m, now[1] as Boolean, detector.bySize, detector.guessed)
    }

    /** The frame's pixels inside [box] (top-left origin, frame pixels) as ARGB, rows top to bottom, and its width. */
    /** Draws Android's held picture (not handed to the encoder) and looks at nine points of it: all black? */
    private fun heldPictureBlack(): Boolean {
        GLES20.glViewport(0, 0, width, height)
        GLES20.glDisable(GLES20.GL_BLEND)
        texture.getTransformMatrix(texMatrix)
        quad(frameProgram, GLES11Ext.GL_TEXTURE_EXTERNAL_OES, frameTex, FRAME_COORDS, texMatrix)
        val samples = IntArray(9)
        for (i in 0 until 9) {
            val x = width * (1 + 2 * (i % 3)) / 6f
            val y = height * (1 + 2 * (i / 3)) / 6f
            samples[i] = readPixels(Box(x, y, 1f, 1f)).first.firstOrNull() ?: 0
        }
        return CleanRecording.isBlack(samples)
    }

    private fun readPixels(box: Box): Pair<IntArray, Int> {
        val left = box.left.toInt().coerceIn(0, width)
        val right = box.right.toInt().coerceIn(0, width)
        val top = box.top.toInt().coerceIn(0, height)
        val bottom = box.bottom.toInt().coerceIn(0, height)
        val w = right - left
        val h = bottom - top
        if (w <= 0 || h <= 0) return IntArray(0) to 0
        val buffer = ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.nativeOrder())
        // OpenGL counts rows from the bottom
        GLES20.glReadPixels(left, height - bottom, w, h, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, buffer)
        val bytes = ByteArray(w * h * 4)
        buffer.get(bytes)
        // OpenGL's first row is the box's bottom row: turned the right way up
        return IntArray(w * h) { i ->
            val x = i % w
            val y = h - 1 - i / w
            val at = (y * w + x) * 4
            val r = bytes[at].toInt() and 0xFF
            val g = bytes[at + 1].toInt() and 0xFF
            val b = bytes[at + 2].toInt() and 0xFF
            (0xFF shl 24) or (r shl 16) or (g shl 8) or b
        } to w
    }

    private fun quad(program: Int, target: Int, tex: Int, coords: FloatBuffer, matrix: FloatArray) {
        GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(target, tex)
        GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "uTex"), 0)
        GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(program, "uTexMatrix"), 1, false, matrix, 0)
        val pos = GLES20.glGetAttribLocation(program, "aPos")
        val uv = GLES20.glGetAttribLocation(program, "aTex")
        GLES20.glEnableVertexAttribArray(pos)
        GLES20.glVertexAttribPointer(pos, 2, GLES20.GL_FLOAT, false, 0, POSITIONS)
        GLES20.glEnableVertexAttribArray(uv)
        GLES20.glVertexAttribPointer(uv, 2, GLES20.GL_FLOAT, false, 0, coords)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(pos)
        GLES20.glDisableVertexAttribArray(uv)
    }

    /** Frees everything OpenGL, and lets go of the encoder's surface. Safe to call more than once. */
    private fun tearDown() {
        running = false
        if (::texture.isInitialized) {
            runCatching { texture.setOnFrameAvailableListener(null) }
            runCatching { input.release() }
            runCatching { texture.release() }
        }
        if (display != EGL14.EGL_NO_DISPLAY) {
            runCatching {
                if (frameProgram != 0) GLES20.glDeleteProgram(frameProgram)
                if (inkProgram != 0) GLES20.glDeleteProgram(inkProgram)
                if (frameTex != 0) GLES20.glDeleteTextures(2, intArrayOf(frameTex, inkTex), 0)
            }
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            if (surface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, surface)
            if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
            // not eglTerminate: the display is shared with the app's own windows' drawing
            EGL14.eglReleaseThread()
            display = EGL14.EGL_NO_DISPLAY
            surface = EGL14.EGL_NO_SURFACE
            context = EGL14.EGL_NO_CONTEXT
            frameProgram = 0; inkProgram = 0; frameTex = 0
        }
        inkFrames.done()
    }

    /**
     * Three bitmaps the size of a video frame, so the main thread can draw the next picture of the marks while the
     * video thread copies the last one to OpenGL: one being drawn, one ready, one being copied. Made only when the
     * first picture of the marks is (a recording of the entire screen never needs them), and [drop]ped when they
     * are no longer needed.
     */
    class InkFrames(private val width: Int, private val height: Int) {
        private var bitmaps: Array<Bitmap>? = null
        private var ready: Bitmap? = null
        private var inUse: Bitmap? = null
        private var orphan: Bitmap? = null   // dropped while the video thread was copying it: recycled once it's done

        /** Whether the bitmaps exist now (the app's test checks an entire-screen recording has none). */
        val allocated @Synchronized get() = bitmaps != null

        /** A bitmap the main thread may draw on now. */
        @Synchronized fun free(): Bitmap {
            val all = bitmaps ?: Array(3) { Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888) }.also { bitmaps = it }
            return all.first { it !== ready && it !== inUse }
        }
        /** The main thread finished drawing [b]: it is the newest picture. */
        @Synchronized fun publish(b: Bitmap) { if (bitmaps?.any { it === b } == true) ready = b }
        /** The newest picture not yet copied, kept from the main thread until [done]. */
        @Synchronized fun take(): Bitmap? { val b = ready ?: return null; ready = null; inUse = b; return b }
        @Synchronized fun done() {
            val b = inUse
            inUse = null
            if (b != null && b === orphan) { b.recycle(); orphan = null }
        }
        /** The bitmaps' memory back (main thread: where they are drawn). One being copied goes once it's done. */
        @Synchronized fun drop() {
            val all = bitmaps ?: return
            bitmaps = null
            ready = null
            for (b in all) if (b === inUse) orphan = b else b.recycle()
        }
    }

    companion object {
        private const val TAG = "ContrastInk"
        /** No frame looked at this long after the start: the marks go into the video, to be safe. */
        const val GIVE_UP_MS = 4000L
        /** Back in sight: how long to wait for Android's picture of the app before looking at what is held. */
        const val PICTURE_WAIT_MS = 500L
        /** A look at the picture this long before the app went out of sight is from before Android blacked it out. */
        const val LOOK_BEFORE_HIDDEN_MS = 500L
        /** TEST ONLY: the next compositor's OpenGL fails to start (the recorder must still record). */
        @Volatile var failSetUpForTest = false
        /** TEST ONLY: the next frame's OpenGL work fails, mid-recording (the recording must go on). */
        @Volatile var failNextFrameForTest = false

        private const val EGL_RECORDABLE_ANDROID = 0x3142

        private const val VERTEX = """
            attribute vec4 aPos;
            attribute vec4 aTex;
            uniform mat4 uTexMatrix;
            varying vec2 vTex;
            void main() { gl_Position = aPos; vTex = (uTexMatrix * aTex).xy; }"""
        // what Android records arrives as an "external" texture (straight from the VirtualDisplay's buffers)
        private const val FRAGMENT_FRAME = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTex;
            uniform samplerExternalOES uTex;
            void main() { gl_FragColor = texture2D(uTex, vTex); }"""
        private const val FRAGMENT_INK = """
            precision mediump float;
            varying vec2 vTex;
            uniform sampler2D uTex;
            void main() { gl_FragColor = texture2D(uTex, vTex); }"""

        private val IDENTITY = FloatArray(16).also { android.opengl.Matrix.setIdentityM(it, 0) }
        /** The whole frame, as two triangles: bottom left, bottom right, top left, top right. */
        private val POSITIONS = floats(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)
        /** Texture corners for those (the recorded picture's own transform matrix turns them the right way up). */
        private val FRAME_COORDS = floats(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f)
        /** A bitmap's first row is its top, OpenGL's first texture row is its bottom: turned upside down. */
        private val INK_COORDS = floats(0f, 1f, 1f, 1f, 0f, 0f, 1f, 0f)

        private fun floats(vararg v: Float): FloatBuffer =
            ByteBuffer.allocateDirect(v.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply { put(v); position(0) }

        private fun textureParameters(target: Int) {
            GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        }

        private fun shader(type: Int, source: String): Int {
            val s = GLES20.glCreateShader(type)
            GLES20.glShaderSource(s, source)
            GLES20.glCompileShader(s)
            val ok = IntArray(1)
            GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0)
            check(ok[0] != 0) { "shader: " + GLES20.glGetShaderInfoLog(s) }
            return s
        }

        private fun program(vertex: String, fragment: String): Int {
            val p = GLES20.glCreateProgram()
            GLES20.glAttachShader(p, shader(GLES20.GL_VERTEX_SHADER, vertex.trimIndent()))
            GLES20.glAttachShader(p, shader(GLES20.GL_FRAGMENT_SHADER, fragment.trimIndent()))
            GLES20.glLinkProgram(p)
            val ok = IntArray(1)
            GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, ok, 0)
            check(ok[0] != 0) { "program: " + GLES20.glGetProgramInfoLog(p) }
            return p
        }
    }
}
