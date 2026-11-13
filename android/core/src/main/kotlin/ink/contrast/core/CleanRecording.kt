package ink.contrast.core

/**
 * "Clean recording": a video without Contrast Ink's own toolbar.
 *
 * Android can't leave one window out of a recording of the whole screen. But from Android 14, when Android asks
 * "start recording?", the presenter can choose "A single app" (their slides app) instead of "Entire screen". Android
 * then records only that app's window: not the toolbar, but not the drawing layer either. So the app draws the marks
 * into the video itself, on top of each frame. The rules for that are here, plain Kotlin, so they are tested on any
 * machine.
 */
object CleanRecording {
    /** What Android records, as far as the app knows. */
    enum class Mode {
        /** Not known yet (the first frames haven't been looked at). Marks are not drawn into the video yet. */
        UNKNOWN,
        /** The whole screen: the toolbar and the marks are already in the picture, so nothing is added. */
        ENTIRE_SCREEN,
        /** One app's window only: the marks are drawn into the video by the app. */
        SINGLE_APP,
    }

    /** A rectangle as left, top, width, height, in pixels of whatever it is in (the screen, or a video frame). */
    data class Box(val left: Float, val top: Float, val width: Float, val height: Float) {
        val right get() = left + width
        val bottom get() = top + height
    }

    /**
     * Where content of [contentW] x [contentH] lands in a video frame of [frameW] x [frameH]: made as big as fits,
     * keeping its shape, centred, with black bars on the sides that are left over. This is what Android does both when
     * it mirrors the whole screen into the recording and when it records one app (Android 14's screen capture scales
     * the captured window to fit the recording's surface and centres it).
     */
    fun fit(contentW: Int, contentH: Int, frameW: Int, frameH: Int): Box {
        if (contentW <= 0 || contentH <= 0) return Box(0f, 0f, frameW.toFloat(), frameH.toFloat())
        val scale = minOf(frameW.toFloat() / contentW, frameH.toFloat() / contentH)
        val w = contentW * scale
        val h = contentH * scale
        return Box((frameW - w) / 2f, (frameH - h) / 2f, w, h)
    }

    /**
     * Where the marks go in a single-app video frame. The drawing layer covers the screen ([screenW] x [screenH]); the
     * recorded app is [appW] x [appH] (Android says so through MediaProjection's onCapturedContentResize).
     *
     * Assumption: the app's top left corner is the screen's top left corner. That is exactly right for an app shown
     * full screen (how slides are presented: the app is then the size of the screen, and the marks line up one to one),
     * and for the upper or left app of a split screen. Android doesn't tell an app where the recorded window sits on
     * the screen, so for the lower or right app of a split screen the marks would be shifted.
     *
     * Returns the box the whole screen-sized drawing layer is drawn into, and the box to clip it to (the app's
     * picture: marks outside the recorded app are left out rather than drawn on the black bars).
     */
    fun inkPlacement(screenW: Int, screenH: Int, appW: Int, appH: Int, frameW: Int, frameH: Int): Pair<Box, Box> {
        val w = if (appW > 0) appW else screenW
        val h = if (appH > 0) appH else screenH
        val app = fit(w, h, frameW, frameH)
        val scale = if (w > 0) app.width / w else 1f
        val ink = Box(app.left, app.top, screenW * scale, screenH * scale)
        return ink to app
    }

    /** How close (each of red, green, blue) a video pixel must be to a colour to count as it: video compression shifts colours a little. */
    const val COLOR_TOLERANCE = 10

    /** Whether [argb] is [color] give or take [tolerance] on each of red, green and blue. */
    fun near(argb: Int, color: Int, tolerance: Int = COLOR_TOLERANCE): Boolean =
        Math.abs(((argb shr 16) and 0xFF) - ((color shr 16) and 0xFF)) <= tolerance &&
            Math.abs(((argb shr 8) and 0xFF) - ((color shr 8) and 0xFF)) <= tolerance &&
            Math.abs((argb and 0xFF) - (color and 0xFF)) <= tolerance

    /** The share (0 to 1) of [pixels] (ARGB) that are [color]. */
    fun share(pixels: IntArray, color: Int, tolerance: Int = COLOR_TOLERANCE): Float =
        if (pixels.isEmpty()) 0f else pixels.count { near(it, color, tolerance) }.toFloat() / pixels.size

    /**
     * The beacon: while the app works out what Android records, the toolbar shows a thin strip of three saturated
     * colours side by side, magenta, cyan, yellow (left to right). The toolbar's own dark colour can't tell the two
     * apart: a dark slide (a #1E1E1E background, a CT) is within a hair of it. Three pure colours in that order, in
     * exactly the strip's place, are not something a slide shows.
     */
    val BEACON_COLORS = intArrayOf(0xFFFF00FF.toInt(), 0xFF00FFFF.toInt(), 0xFFFFFF00.toInt())

    /**
     * Whether a pixel is "the same saturated colour" as [color], one of [BEACON_COLORS]: each channel that is full in
     * it is high (at least 150), each that is empty is low (at most 110). Wide margins, as video compression and
     * colour conversion move saturated colours a long way; still no grey, black or white pixel passes.
     */
    fun beaconPixel(argb: Int, color: Int): Boolean {
        for (shift in intArrayOf(16, 8, 0)) {
            val v = (argb shr shift) and 0xFF
            val full = ((color shr shift) and 0xFF) > 0x80
            if (full && v < 150) return false
            if (!full && v > 110) return false
        }
        return true
    }

    /**
     * Whether the beacon is in the picture: [pixels] (ARGB, [w] wide, rows top to bottom) is the strip's rectangle
     * in a video frame. Each third (its middle, away from the edges compression blurs) must be mostly its colour.
     */
    fun beaconSeen(pixels: IntArray, w: Int): Boolean {
        if (w < 3 || pixels.size < w) return false
        val h = pixels.size / w
        val top = h / 5
        val bottom = maxOf(top + 1, h - h / 5)
        for (part in 0 until 3) {
            val left = w * part / 3
            val right = w * (part + 1) / 3
            val inset = (right - left) / 6
            var hits = 0
            var all = 0
            for (y in top until bottom) for (x in left + inset until right - inset) {
                all++
                if (beaconPixel(pixels[y * w + x], BEACON_COLORS[part])) hits++
            }
            if (all == 0 || hits * 10 < all * 6) return false
        }
        return true
    }

    /**
     * Works out what Android records. Android doesn't tell an app whether the presenter chose "A single app" or
     * "Entire screen", so:
     *  1. If Android says the recorded content is not the screen's size (onCapturedContentResize, Android 14+), it can
     *     only be one app (an app in split screen or in a window): certain, no frame changes it ([bySize]).
     *  2. Otherwise frames are looked at where the toolbar's beacon is on the screen: a recording of the entire screen
     *     has it (the toolbar is on top of everything), one app's window never does. The first frame looked at decides,
     *     whenever it comes (starting the mic and the encoder can hold the first frame up for seconds). For [settleMs]
     *     after that first look a later frame with the beacon still changes it to "Entire screen" (a first frame taken
     *     while Android's question was still closing); then it is final.
     *  3. No frame could be looked at [giveUpMs] after the start (none came, or the toolbar isn't showing): the marks
     *     are drawn into the video ([guessed]). That is the safe side: in a recording of one app they would otherwise
     *     be missing, in one of the entire screen they land exactly on themselves. A frame looked at later still decides.
     * One frame decides, not several, because an app that doesn't move sends Android very few frames.
     */
    class Detector(private val settleMs: Long = 2000, private val giveUpMs: Long = 4000) {
        var mode = Mode.UNKNOWN
            private set
        /** Decided by the content's size: one app in split screen or a window (the marks' place is a guess there). */
        var bySize = false
            private set
        /** Decided by no frame at all: marks drawn in to be safe. */
        var guessed = false
            private set
        private var firstLook = -1L

        /** Android said the recorded content is [contentW] x [contentH] on a [screenW] x [screenH] screen. */
        fun contentSize(contentW: Int, contentH: Int, screenW: Int, screenH: Int): Mode {
            val sameAsScreen = (contentW == screenW && contentH == screenH) || (contentW == screenH && contentH == screenW)
            if (!sameAsScreen && contentW > 0 && contentH > 0 && mode != Mode.ENTIRE_SCREEN) {
                mode = Mode.SINGLE_APP; bySize = true; guessed = false
            }
            return mode
        }

        /** A frame, [msSinceStart] after the recording started, was looked at: was the beacon in it? */
        fun frame(beaconSeen: Boolean, msSinceStart: Long): Mode {
            if (bySize) return mode
            if (firstLook < 0) firstLook = msSinceStart
            if (msSinceStart - firstLook > settleMs) return mode
            if (beaconSeen) { mode = Mode.ENTIRE_SCREEN; guessed = false }
            else if (mode == Mode.UNKNOWN || guessed) { mode = Mode.SINGLE_APP; guessed = false }
            return mode
        }

        /** Time passed with no frame looked at (none came, or there was nothing to look at). */
        fun noLook(msSinceStart: Long): Mode {
            if (mode == Mode.UNKNOWN && msSinceStart >= giveUpMs) { mode = Mode.SINGLE_APP; guessed = true }
            return mode
        }

        /** Whether the answer is final (until then the compositor keeps looking at frames, and the beacon shows). */
        fun settled(msSinceStart: Long) = bySize || (firstLook >= 0 && msSinceStart - firstLook > settleMs)

        /** When it becomes final (ms since the start), once a first frame has been looked at; else -1. */
        fun settlesAt() = if (firstLook < 0) -1L else firstLook + settleMs + 1
    }

    /** Whether the marks are drawn into the video now: one app's recording, while that app is in sight. */
    fun drawInk(mode: Mode, contentVisible: Boolean) = mode == Mode.SINGLE_APP && contentVisible

    /** Back in sight, Android hasn't sent a picture of the app within the wait: what the compositor does. */
    enum class AfterShown {
        /** The picture it holds is the app's (or no marks go on it anyway): the marks go back on. */
        DRAW_MARKS,
        /** It holds a black picture: ask Android for a fresh one, and look again after the wait. */
        ASK_AGAIN,
        /** Still black after every ask: no marks over black; the video holds its last frame until Android sends one. */
        NO_MARKS,
    }

    /** How many times a fresh picture is asked for before the compositor stops asking. */
    const val PICTURE_ASKS = 4

    /** [blackBefore]: the app's picture was black already when it went out of sight (a black slide): black is its own. */
    fun afterShown(haveFrame: Boolean, mode: Mode, heldBlack: Boolean, asks: Int, blackBefore: Boolean = false): AfterShown = when {
        !haveFrame || mode != Mode.SINGLE_APP || !heldBlack || blackBefore -> AfterShown.DRAW_MARKS
        asks < PICTURE_ASKS -> AfterShown.ASK_AGAIN
        else -> AfterShown.NO_MARKS
    }

    /** Whether sampled pixels (ARGB) are all black: what Android 14 holds for an app out of sight. */
    fun isBlack(pixels: IntArray, tolerance: Int = 10): Boolean = pixels.isNotEmpty() && pixels.all {
        ((it shr 16) and 0xFF) <= tolerance && ((it shr 8) and 0xFF) <= tolerance && (it and 0xFF) <= tolerance
    }

    /** What the toolbar says once the recorder knows what Android records (null: nothing yet). */
    fun modeNotice(mode: Mode, bySize: Boolean, guessed: Boolean): String? = when {
        mode == Mode.SINGLE_APP && guessed ->
            "Couldn't see yet what Android records: your marks are drawn into the video to be safe (over the entire screen they land on themselves)."
        mode == Mode.SINGLE_APP && bySize ->
            "Recording one app: the toolbar stays out of the video, your marks are in it. $SPLIT_SCREEN"
        mode == Mode.SINGLE_APP -> "Recording one app: the toolbar stays out of the video, your marks are in it."
        mode == Mode.ENTIRE_SCREEN -> "Recording the entire screen: the toolbar is in the video — make it small (‹)."
        else -> null
    }

    /** Android doesn't say where a split-screen or floating app sits on the screen (see [inkPlacement]). */
    const val SPLIT_SCREEN = "In split screen or a floating window the marks may be misplaced: show the app full screen."

    /** Said once, when the recorded app goes out of sight: Android holds its last picture meanwhile. */
    const val HIDDEN_NOTICE = "The recorded app is out of sight: until you go back to it, the video holds its last picture and new marks aren't in it."

    /**
     * How long to wait before the next copy of the drawing layer for the video, the last copy made at [lastMs], now
     * [nowMs]. A mark changing is copied up to 30 times a second; only the laser's glow moving, 15 times (each copy is
     * a whole video frame drawn on the main thread).
     */
    fun snapshotDelay(lastMs: Long, nowMs: Long, onlyLaser: Boolean): Long =
        maxOf(0L, lastMs + (if (onlyLaser) 66 else 33) - nowMs)
}
