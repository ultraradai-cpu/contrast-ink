package ink.contrast.core

/**
 * The one line the pad's connect screen adds when no PC turns up or a typed address fails: said for the cause, so a
 * presenter isn't sent to a hotspot when Wi-Fi is simply off, or when the PC just hasn't switched the tablet link on.
 */
object PadHints {
    /** Why a connection to a typed address failed, as far as the tablet can tell. */
    enum class Cause {
        /** The PC answered "no one listening here": Contrast Ink's tablet link is off on it. */
        REFUSED,
        /** Nothing answered (timed out, or no route to the PC): often a network that keeps devices apart. */
        NO_ANSWER,
        /** Anything else (a wrong address, a broken answer): the screen's own message says enough. */
        OTHER,
    }

    enum class Hint(val text: String?) {
        TURN_ON_WIFI("Wi-Fi is off on this tablet: turn on Wi-Fi (or use the USB cable)."),
        NOT_ACCEPTING("The PC is there but isn't accepting tablets yet: on the PC, tick ⚙ Settings → Let a Tablet Draw Here."),
        HOTSPOT("Can't find the PC? Hospital Wi-Fi often blocks this. Join the PC's hotspot (Windows: Mobile hotspot, " +
            "usually 192.168.137.1) or your phone's hotspot, or use the USB cable."),
        NONE(null),
    }

    /** No PC in the list for a while. */
    fun noPcFound(wifiOn: Boolean): Hint = if (wifiOn) Hint.HOTSPOT else Hint.TURN_ON_WIFI

    /** A typed address that was never connected to. */
    fun connectFailed(wifiOn: Boolean, cause: Cause): Hint = when {
        cause == Cause.REFUSED -> Hint.NOT_ACCEPTING
        !wifiOn -> Hint.TURN_ON_WIFI
        cause == Cause.NO_ANSWER -> Hint.HOTSPOT
        else -> Hint.NONE
    }
}
