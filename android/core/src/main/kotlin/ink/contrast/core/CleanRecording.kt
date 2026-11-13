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

    /** How close (each of red, green, blue) a video pixel must be to count as the toolbar's colour: video compression shifts colours a little. */
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
     * Whether the toolbar is in the picture: most of the inside of the toolbar's rectangle is its dark colour (its
     * buttons and their letters are the rest). A slide that happens to be exactly that colour there would fool it; a
     * black image (CT, MR) does not, as the toolbar's colour is a bluish dark grey, not black.
     */
    fun toolbarSeen(pixelsInToolbarBox: IntArray, toolbarColor: Int): Boolean = share(pixelsInToolbarBox, toolbarColor) >= 0.5f

    /**
     * Works out what Android records. Android doesn't tell an app whether the presenter chose "A single app" or
     * "Entire screen", so:
     *  1. If Android says the recorded content is not the screen's size (onCapturedContentResize, Android 14+), it can
     *     only be one app (an app in split screen or in a window).
     *  2. Otherwise the frames are looked at where the toolbar is on the screen: a recording of the entire screen has
     *     the toolbar there (it is always on top of everything), one app's window never does. The first frame decides.
     *     For the first [settleMs] the answer can still change to "Entire screen" if a later frame shows the toolbar
     *     (a first frame taken while Android's question was still closing); after that it is final, so a dark slide
     *     passing under the toolbar later can't switch the marks off.
     * One frame decides, not several, because an app that doesn't move sends Android very few frames.
     */
    class Detector(private val settleMs: Long = 1500) {
        var mode = Mode.UNKNOWN
            private set
        private var bySize = false   // decided by the content's size: certain, no frame changes it

        /** Android said the recorded content is [contentW] x [contentH] on a [screenW] x [screenH] screen. */
        fun contentSize(contentW: Int, contentH: Int, screenW: Int, screenH: Int): Mode {
            val sameAsScreen = (contentW == screenW && contentH == screenH) || (contentW == screenH && contentH == screenW)
            if (!sameAsScreen && contentW > 0 && contentH > 0 && mode == Mode.UNKNOWN) { mode = Mode.SINGLE_APP; bySize = true }
            return mode
        }

        /** A frame, [msSinceStart] after the recording started, was looked at: was the toolbar in it? */
        fun frame(toolbarSeen: Boolean, msSinceStart: Long): Mode {
            if (bySize) return mode
            if (msSinceStart > settleMs) { if (mode == Mode.UNKNOWN) mode = if (toolbarSeen) Mode.ENTIRE_SCREEN else Mode.SINGLE_APP }
            else if (toolbarSeen) mode = Mode.ENTIRE_SCREEN
            else if (mode == Mode.UNKNOWN) mode = Mode.SINGLE_APP
            return mode
        }

        /** Whether the answer can still change (the compositor keeps looking at frames until then). */
        fun settled(msSinceStart: Long) = bySize || msSinceStart > settleMs
    }
}
