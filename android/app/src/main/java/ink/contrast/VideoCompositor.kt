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
 * Everything here runs on its own thread ("Contrast Ink video"), which owns the OpenGL context.
 */
class VideoCompositor(
    private val output: Surface,
    val width: Int,
    val height: Int,
    /** Told on the main thread's side (the caller posts it) when what Android records is worked out. */
    private val modeFound: (Mode) -> Unit,
) {
    /** Where Android draws what it records (the recording's VirtualDisplay draws into this). */
    lateinit var input: Surface
        private set
    /** The drawing layer, as video-frame-sized pictures, handed over from the main thread. */
    val inkFrames = InkFrames(width, height)
    /** Where the toolbar is, in video-frame pixels (set from the main thread): looked at to tell the two modes apart. */
    @Volatile var toolbarBox: Box? = null
    /** What Android records, once known. */
    @Volatile var mode = Mode.UNKNOWN
        private set

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
    private var lastTime = 0L
    private var released = false
    private val texMatrix = FloatArray(16)

    init {
        val ready = CountDownLatch(1)
        var problem: Throwable? = null
        gl.post {
            try { setUp() } catch (t: Throwable) { problem = t }
            ready.countDown()
        }
        if (!ready.await(5, TimeUnit.SECONDS)) problem = IllegalStateException("the video drawing didn't start")
        problem?.let { release(); throw it }
    }

    /** Android said the recorded content is [w] x [h] on a [screenW] x [screenH] screen (Android 14+). */
    fun contentSize(w: Int, h: Int, screenW: Int, screenH: Int) = gl.post {
        if (released) return@post
        setMode(detector.contentSize(w, h, screenW, screenH))
    }

    /** The main thread put a new picture of the marks in [inkFrames]: redraw the last frame with it. */
    fun inkChanged() = gl.post { if (!released && haveFrame && mode == Mode.SINGLE_APP) draw(look = false) }

    /** Stops drawing and frees everything. Waits (briefly) for the video thread to finish. */
    fun release() {
        val done = CountDownLatch(1)
        val posted = gl.post {
            runCatching { tearDown() }
            done.countDown()
        }
        if (posted) done.await(2, TimeUnit.SECONDS)
        thread.quitSafely()
    }

    // ---------- on the video thread ----------

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
        if (released) return
        texture.updateTexImage()
        haveFrame = true
        draw(look = true)
    }

    /**
     * Draws the last picture Android sent, the marks over it when recording one app, and hands the frame to the video
     * encoder. [look]: a new picture from Android, looked at (while it matters) to see whether the toolbar is in it.
     */
    private fun draw(look: Boolean) {
        GLES20.glViewport(0, 0, width, height)
        GLES20.glDisable(GLES20.GL_BLEND)
        texture.getTransformMatrix(texMatrix)
        quad(frameProgram, GLES11Ext.GL_TEXTURE_EXTERNAL_OES, frameTex, FRAME_COORDS, texMatrix)

        val since = SystemClock.elapsedRealtime() - startedAt
        if (look && !detector.settled(since)) toolbarBox?.let { box ->
            setMode(detector.frame(CleanRecording.toolbarSeen(readPixels(box), TOOLBAR_COLOR), since))
        }

        if (mode == Mode.SINGLE_APP) {
            inkFrames.take()?.let { bitmap ->
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, inkTex)
                if (inkLoaded) GLUtils.texSubImage2D(GLES20.GL_TEXTURE_2D, 0, 0, 0, bitmap)
                else GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)
                inkLoaded = true
                inkFrames.done()
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
        EGL14.eglSwapBuffers(display, surface)
    }

    private fun setMode(m: Mode) {
        if (m == mode) return
        mode = m
        modeFound(m)
    }

    /** The frame's pixels inside [box] (top-left origin, frame pixels), the toolbar's rounded corners left out, as ARGB. */
    private fun readPixels(box: Box): IntArray {
        val inset = 0.15f
        val left = (box.left + box.width * inset).toInt().coerceIn(0, width)
        val right = (box.right - box.width * inset).toInt().coerceIn(0, width)
        val top = (box.top + box.height * inset).toInt().coerceIn(0, height)
        val bottom = (box.bottom - box.height * inset).toInt().coerceIn(0, height)
        val w = right - left
        val h = bottom - top
        if (w <= 0 || h <= 0) return IntArray(0)
        val buffer = ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.nativeOrder())
        // OpenGL counts rows from the bottom
        GLES20.glReadPixels(left, height - bottom, w, h, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, buffer)
        val bytes = ByteArray(w * h * 4)
        buffer.get(bytes)
        return IntArray(w * h) { i ->
            val r = bytes[i * 4].toInt() and 0xFF
            val g = bytes[i * 4 + 1].toInt() and 0xFF
            val b = bytes[i * 4 + 2].toInt() and 0xFF
            (0xFF shl 24) or (r shl 16) or (g shl 8) or b
        }
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

    private fun tearDown() {
        if (released) return
        released = true
        if (::texture.isInitialized) {
            texture.setOnFrameAvailableListener(null)
            input.release()
            texture.release()
        }
        if (display != EGL14.EGL_NO_DISPLAY) {
            if (frameProgram != 0) GLES20.glDeleteProgram(frameProgram)
            if (inkProgram != 0) GLES20.glDeleteProgram(inkProgram)
            if (frameTex != 0) GLES20.glDeleteTextures(2, intArrayOf(frameTex, inkTex), 0)
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            if (surface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, surface)
            if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
            // not eglTerminate: the display is shared with the app's own windows' drawing
            EGL14.eglReleaseThread()
        }
        inkFrames.done()
    }

    /**
     * Three bitmaps the size of a video frame, so the main thread can draw the next picture of the marks while the
     * video thread copies the last one to OpenGL: one being drawn, one ready, one being copied.
     */
    class InkFrames(width: Int, height: Int) {
        private val bitmaps = Array(3) { Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888) }
        private var ready: Bitmap? = null
        private var inUse: Bitmap? = null

        /** A bitmap the main thread may draw on now. */
        @Synchronized fun free(): Bitmap = bitmaps.first { it !== ready && it !== inUse }
        /** The main thread finished drawing [b]: it is the newest picture. */
        @Synchronized fun publish(b: Bitmap) { ready = b }
        /** The newest picture not yet copied, kept from the main thread until [done]. */
        @Synchronized fun take(): Bitmap? { val b = ready ?: return null; ready = null; inUse = b; return b }
        @Synchronized fun done() { inUse = null }
    }

    private companion object {
        const val EGL_RECORDABLE_ANDROID = 0x3142
        /** The toolbar's colour (ToolbarView's background). */
        const val TOOLBAR_COLOR = 0xFF141A22.toInt()

        const val VERTEX = """
            attribute vec4 aPos;
            attribute vec4 aTex;
            uniform mat4 uTexMatrix;
            varying vec2 vTex;
            void main() { gl_Position = aPos; vTex = (uTexMatrix * aTex).xy; }"""
        // what Android records arrives as an "external" texture (straight from the VirtualDisplay's buffers)
        const val FRAGMENT_FRAME = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTex;
            uniform samplerExternalOES uTex;
            void main() { gl_FragColor = texture2D(uTex, vTex); }"""
        const val FRAGMENT_INK = """
            precision mediump float;
            varying vec2 vTex;
            uniform sampler2D uTex;
            void main() { gl_FragColor = texture2D(uTex, vTex); }"""

        val IDENTITY = FloatArray(16).also { android.opengl.Matrix.setIdentityM(it, 0) }
        /** The whole frame, as two triangles: bottom left, bottom right, top left, top right. */
        val POSITIONS = floats(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)
        /** Texture corners for those (the recorded picture's own transform matrix turns them the right way up). */
        val FRAME_COORDS = floats(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f)
        /** A bitmap's first row is its top, OpenGL's first texture row is its bottom: turned upside down. */
        val INK_COORDS = floats(0f, 1f, 1f, 1f, 0f, 0f, 1f, 0f)

        fun floats(vararg v: Float): FloatBuffer =
            ByteBuffer.allocateDirect(v.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply { put(v); position(0) }

        fun textureParameters(target: Int) {
            GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        }

        fun shader(type: Int, source: String): Int {
            val s = GLES20.glCreateShader(type)
            GLES20.glShaderSource(s, source)
            GLES20.glCompileShader(s)
            val ok = IntArray(1)
            GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0)
            check(ok[0] != 0) { "shader: " + GLES20.glGetShaderInfoLog(s) }
            return s
        }

        fun program(vertex: String, fragment: String): Int {
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
