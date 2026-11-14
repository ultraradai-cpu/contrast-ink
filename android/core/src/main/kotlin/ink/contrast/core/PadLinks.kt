package ink.contrast.core

/**
 * Which link pad mode uses: Wi-Fi (an address and a typed code) or the USB cable (docs/pad-protocol.md, "USB (phase
 * 2)"). No network, no threads and no screens, so the switching rules are tested on any machine. The pad screen
 * tells it what happened and does what it answers:
 *
 * - the cable is tried every [USB_TRY_MS] while nothing is open or under way over it ([tryUsb]);
 * - a USB session open (sealed WELCOME) closes the Wi-Fi session, and Wi-Fi isn't tried while it lasts ([usbOpened],
 *   [startWifi]);
 * - a USB session that drops goes back to Wi-Fi by itself when a code from earlier in this session is held, else to
 *   the connect screen ([usbEnded]);
 * - tries over the cable that fail are quiet; only a PC there with another key than the one remembered is told.
 */
class PadLinks {
    enum class Usb {
        /** Nothing over the cable: tried again every [USB_TRY_MS]. */
        IDLE,
        /** A try is under way (a refused connection to 127.0.0.1 ends it at once). */
        TRYING,
        /** A session is open over the cable: Wi-Fi is off. */
        OPEN,
        /** The presenter disconnected a USB session: not tried again until they tap Connect (or come back to pad mode). */
        PAUSED,
        /** The PC over the cable had another key than the one remembered: not tried again until "Connect anyway". */
        STOPPED,
    }

    /** What the screen does next. */
    enum class Then {
        NOTHING,
        /** The cable took over: close the Wi-Fi connection (and stop its retries). */
        CLOSE_WIFI,
        /** The cable dropped and a code is held: reconnect over Wi-Fi quietly, as after a Wi-Fi blip. */
        BACK_TO_WIFI,
        /** The cable dropped and no code is held: the connect screen. */
        CONNECT_SCREEN,
        /** The PC over the cable isn't the one paired under its name: warn (nothing was sent after HELLO). */
        WARN_KEY_CHANGED,
    }

    var usb = Usb.IDLE
        private set
    /** The code typed this session, in memory only (never saved); null when none is held. */
    var code: String? = null
        private set
    /** A Wi-Fi connection is open or being opened. */
    var wifi = false
        private set

    /** The presenter typed a code and tapped Connect: it is held for this session, and a paused cable is tried again. */
    fun chooseWifi(code: String) {
        this.code = code
        resumeUsb()
    }

    /** The presenter tapped Connect (with or without a code): a cable paused by Disconnect is tried again. */
    fun resumeUsb() {
        if (usb == Usb.PAUSED) usb = Usb.IDLE
    }

    /** May a Wi-Fi connection start now? Never while the cable is open, never without a code. True: it is started. */
    fun startWifi(): Boolean {
        if (usb == Usb.OPEN || code == null) return false
        wifi = true
        return true
    }

    /** The Wi-Fi connection ended or was closed. */
    fun wifiEnded() { wifi = false }

    /** The PC refused the code: it is no longer held (going back to Wi-Fi with it would only use up a guess). */
    fun codeRefused() { code = null }

    /** Time for a try over the cable? True: one is started (and none other until it ends). */
    fun tryUsb(): Boolean {
        if (usb != Usb.IDLE) return false
        usb = Usb.TRYING
        return true
    }

    /** The PC welcomed the tablet over the cable. */
    fun usbOpened(): Then {
        check(usb == Usb.TRYING) { "a USB session opens from a try" }
        usb = Usb.OPEN
        if (!wifi) return Then.NOTHING
        wifi = false
        return Then.CLOSE_WIFI
    }

    /** The connection over the cable ended (a refused try, an unplugged cable, the PC gone). */
    fun usbEnded(keyChanged: Boolean = false): Then {
        val was = usb
        if (was != Usb.TRYING && was != Usb.OPEN) return Then.NOTHING   // already let go (the presenter disconnected)
        if (keyChanged) { usb = Usb.STOPPED; return Then.WARN_KEY_CHANGED }
        usb = Usb.IDLE
        if (was != Usb.OPEN) return Then.NOTHING   // a try that came to nothing: quiet
        return if (code != null) Then.BACK_TO_WIFI else Then.CONNECT_SCREEN
    }

    /**
     * The presenter disconnected (or chose another PC): the code is forgotten. True: a USB session was open, so the
     * screen closes it, and the cable isn't tried again until the presenter taps Connect (else it would open again
     * at once).
     */
    fun disconnect(): Boolean {
        code = null
        wifi = false
        if (usb != Usb.OPEN) return false
        usb = Usb.PAUSED
        return true
    }

    /**
     * The presenter said the PC check of a PC on the cable doesn't match (nothing was sent): the cable isn't tried
     * again until they tap Connect, so whatever answers there can't ask every 2 s.
     */
    fun usbDeclined() {
        if (usb == Usb.TRYING) usb = Usb.PAUSED
    }

    /** "Connect anyway" for the PC over the cable: try it again (the screen lets that one key through). */
    fun connectAnywayOverUsb() {
        if (usb == Usb.STOPPED || usb == Usb.PAUSED) usb = Usb.IDLE
    }

    companion object {
        /** How often the cable is tried while nothing is open over it. */
        const val USB_TRY_MS = 2000L
    }
}
