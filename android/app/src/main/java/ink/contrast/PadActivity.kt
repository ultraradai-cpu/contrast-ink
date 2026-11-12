package ink.contrast

import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.pm.ApplicationInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputFilter
import android.text.InputType
import android.text.TextUtils
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import ink.contrast.core.PadCrypto
import ink.contrast.core.PadLinks
import ink.contrast.core.PadProtocol
import ink.contrast.core.PcMessage
import ink.contrast.core.Tool
import java.util.Base64
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * Pad mode: this tablet becomes a wireless drawing pad for a PC running Contrast Ink (same Wi-Fi). It shows a
 * live picture of the PC's screen; what is drawn here, the PC draws on its own drawing layer (so OBS records it).
 * The link is written down in docs/pad-protocol.md.
 *
 * Two screens: finding the PC (the PCs found on the network, or an address typed by hand, and the 6-digit code
 * the PC shows), then the pad itself (the picture, the glass to draw on, and a toolbar). The link is version 2:
 * encrypted, the code never sent, and each PC recognised by its key (PadConnection).
 *
 * The USB cable (docs/pad-protocol.md, "USB (phase 2)"): with USB debugging on and the PC's `adb reverse`, the
 * tablet's 127.0.0.1:47830 reaches the PC. It is tried every 2 s on both screens; once open, it takes over from
 * Wi-Fi, and when it drops the pad goes back to Wi-Fi by itself (with the code typed earlier) or to the connect
 * screen. Which link to use is decided by PadLinks (core, tested on the JVM).
 */
@SuppressLint("SetTextI18n")
class PadActivity : Activity(), PadConnection.Listener, PadView.Host {
    companion object {
        /**
         * Connect at once to this address ("192.168.1.20" or "192.168.1.20:47820") with [EXTRA_CODE], without
         * looking for PCs on the network: for the app's test (a stand-in PC on this device) and for starting the
         * pad from a typed address. The code is never stored.
         */
        const val EXTRA_ADDRESS = "ink.contrast.pad.ADDRESS"
        const val EXTRA_CODE = "ink.contrast.pad.CODE"
        /**
         * TEST ONLY: let screenshots see the pad (FLAG_SECURE off), so the emulator test's pictures aren't black.
         * Honoured only by a debuggable build; the APK people install ignores it.
         */
        const val EXTRA_TEST_SCREENSHOTS = "ink.contrast.pad.TEST_SCREENSHOTS"
        private const val PREFS = "contrast-ink"
        /** The PCs' keys the tablet has seen, one per PC name: "pad.pin.<name>" = base64 of the 65 bytes. */
        const val PIN_PREFIX = "pad.pin."
        /** A picture wider or taller than this is refused: a real PC sends at most 1600 px wide. */
        const val MAX_PICTURE_PX = 4096
        /** After a session drops, quiet tries before "Lost the PC" shows (a Wi-Fi blip is usually over by then). */
        const val QUIET_RETRIES = 2
        private const val CHECK_WIFI = "Check the tablet and the PC are on the same Wi-Fi, and that Contrast Ink on the PC has ⚙ Settings → Let a Tablet Draw Here ticked."
    }

    private val dp by lazy { resources.displayMetrics.density }
    private val blue = Color.rgb(0x25, 0x63, 0xEB)
    private val ink = Color.rgb(0x14, 0x1A, 0x22)
    private val light = Color.rgb(0xE3, 0xE8, 0xF0)
    private val grey = Color.rgb(0x8A, 0x95, 0xA6)
    private val warn = Color.rgb(0xFF, 0x99, 0x8C)
    private val main = Handler(Looper.getMainLooper())

    // the connect screen
    private lateinit var connectScreen: View
    private lateinit var statusText: TextView
    private lateinit var anywayButton: Button
    private lateinit var foundList: LinearLayout
    private lateinit var addressField: EditText
    private lateinit var codeField: EditText
    private lateinit var connectButton: Button
    /** The first time with a PC: "does the PC show this PC check?", over either screen, until answered. */
    private lateinit var checkPanel: LinearLayout
    private lateinit var checkText: TextView

    // the pad
    private lateinit var padScreen: LinearLayout
    lateinit var pad: PadView
        private set
    private lateinit var titleText: TextView
    private lateinit var toolbar: PadToolbar
    private lateinit var lostPanel: LinearLayout
    private lateinit var lostText: TextView
    private lateinit var lostDetail: TextView

    /** The Wi-Fi connection (open or being opened). */
    private var connection: PadConnection? = null
    /** The connection over the USB cable (a try, or open). */
    private var usbConnection: PadConnection? = null
    /** Which link is used, and the code held for this session (in memory only). */
    private val links = PadLinks()
    /** The PC's name over the cable, from its CHALLENGE (shown once it is open). */
    private var usbPcName = ""
    /** The key the presenter said to connect to anyway over the cable. */
    private var usbAcceptAnyway: ByteArray? = null
    /** The "not the PC you paired with" warning is about the PC on the cable (Connect anyway tries the cable). */
    private var changedOnCable = false
    private val usbTry = object : Runnable {
        override fun run() { tryUsb(); main.postDelayed(this, PadLinks.USB_TRY_MS) }
    }
    /** The connection the pad draws through: the cable's while it is open, else Wi-Fi's. */
    private val active get() = if (links.usb == PadLinks.Usb.OPEN) usbConnection else connection
    private var target: Pair<String, Int>? = null
    /** The key the presenter said to connect to anyway (after the "not the PC you paired with" warning). */
    private var acceptAnyway: ByteArray? = null
    private var changedKey: ByteArray? = null
    private var pcName = ""
    /** The PC tapped in the list: its address as shown, and its network name (its key is remembered under that name). */
    private var picked: Pair<String, String>? = null
    /** The name the presenter chose the PC by, for this connection: the tapped PC's, or null for a typed address. */
    private var chosenName: String? = null
    private var retries = 0
    private var reconnecting = false
    private val retry = Runnable { if (connection == null && padScreen.visibility == View.VISIBLE) open() }
    private val decoder = Executors.newSingleThreadExecutor { Thread(it, "pad-pictures") }
    /** A picture is being decoded: a PC that sends the next before FRAME_ACK is not pacing, its extra is dropped. */
    private var decoding = false

    private val pins by lazy {
        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        object : PadConnection.Pins {
            override fun remembered(name: String): ByteArray? = prefs.getString(PIN_PREFIX + name, null)?.let {
                try { Base64.getDecoder().decode(it) } catch (e: IllegalArgumentException) { null }
            }
            override fun remember(name: String, key: ByteArray) {
                prefs.edit().putString(PIN_PREFIX + name, Base64.getEncoder().encodeToString(key)).apply()
            }
        }
    }

    // what the PC says is chosen (the live stroke looks like it)
    private var state = PcMessage.State(Tool.PEN, 0, 1, 1f, fading = false, canUndo = false)
    override val tool get() = state.tool ?: Tool.PEN
    override val color get() = state.color
    override val width get() = state.width

    // finding PCs on the network
    private var nsd: NsdManager? = null
    private var discovering: NsdManager.DiscoveryListener? = null
    private var multicast: WifiManager.MulticastLock? = null
    private val found = LinkedHashMap<String, Pair<String, Int>>()   // name -> address, port
    private val toResolve = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private var resumed = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        connectScreen = buildConnectScreen()
        padScreen = buildPadScreen()
        checkPanel = buildCheckPanel()
        val root = FrameLayout(this).apply {
            setBackgroundColor(ink)
            addView(connectScreen)
            addView(padScreen)
            addView(checkPanel, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        }
        setContentView(root)
        fullscreen()

        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        // the code is never kept: the PC makes a new one each run, and yesterday's would only use up a guess.
        // (Earlier versions kept it: forget it.)
        prefs.edit().remove("pad.code").apply()
        addressField.setText(intent.getStringExtra(EXTRA_ADDRESS) ?: prefs.getString("pad.address", ""))
        codeField.setText(intent.getStringExtra(EXTRA_CODE) ?: "")
        if (intent.hasExtra(EXTRA_ADDRESS) && intent.hasExtra(EXTRA_CODE)) connect() else showConnect(null)
        main.post(usbTry)   // the cable, from now until the pad closes
    }

    override fun onResume() {
        super.onResume()
        resumed = true
        if (connection == null && connectScreen.visibility == View.VISIBLE) startDiscovery()
    }

    override fun onPause() {
        super.onPause()
        resumed = false
        stopDiscovery()
    }

    override fun onDestroy() {
        super.onDestroy()
        main.removeCallbacks(retry)
        main.removeCallbacks(usbTry)
        connection?.close()
        connection = null
        usbConnection?.close()
        usbConnection = null
        decoder.shutdownNow()
    }

    /** On the pad, Back asks first: a stray press (or an edge swipe while drawing) shouldn't end the lecture's link. */
    @Deprecated("Still called with targetSdk 35 (no predictive back opt-in)")
    override fun onBackPressed() {
        if (padScreen.visibility != View.VISIBLE) { @Suppress("DEPRECATION") super.onBackPressed(); return }
        AlertDialog.Builder(this)
            .setMessage("Disconnect from ${pcName.ifEmpty { "the PC" }}?")
            .setPositiveButton("Disconnect") { _, _ -> disconnect() }
            .setNegativeButton("Keep drawing", null)
            .show()
    }

    // ---- the connect screen ----

    private fun buildConnectScreen(): View {
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding((24 * dp).toInt(), (32 * dp).toInt(), (24 * dp).toInt(), (24 * dp).toInt())
        }
        col.addView(text("Use this tablet as a pad", 26f, bold = true))
        col.addView(text("On the PC, open Contrast Ink and tick ⚙ Settings → Let a Tablet Draw Here: it shows a 6-digit code. Both must be on the same Wi-Fi.", 15f))
        col.addView(text("Or plug the tablet into the PC with a USB cable (USB debugging on): the pad opens by itself, no code needed.", 15f).apply {
            setTextColor(grey)
        })
        statusText = text("", 15f).apply { setTextColor(warn); visibility = View.GONE }
        col.addView(statusText)
        anywayButton = button("Connect anyway") {
            // the presenter knows the PC was reinstalled: this key, and only this one, is let through
            if (changedOnCable) {
                changedOnCable = false
                usbAcceptAnyway = changedKey
                links.connectAnywayOverUsb()
                statusText.text = "Connecting over the USB cable…"
                statusText.setTextColor(light)
                anywayButton.visibility = View.GONE
                tryUsb()
            } else {
                acceptAnyway = changedKey
                connect()
            }
        }.apply { visibility = View.GONE }
        col.addView(anywayButton)
        col.addView(space(8))
        col.addView(text("PCs on this network", 18f, bold = true))
        foundList = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        col.addView(foundList)
        col.addView(space(8))
        col.addView(text("Or the PC's address (shown under its code)", 15f))
        addressField = field("192.168.1.20 or 192.168.1.20:47820", "PC address", InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI)
        col.addView(addressField)
        col.addView(text("Code", 15f))
        codeField = field("123456", "Code", InputType.TYPE_CLASS_NUMBER).apply {
            filters = arrayOf(InputFilter.LengthFilter(6))
            imeOptions = EditorInfo.IME_ACTION_GO
            setOnEditorActionListener { _, _, _ -> acceptAnyway = null; connect(); true }
        }
        col.addView(codeField)
        col.addView(space(8))
        connectButton = button("Connect") { acceptAnyway = null; connect() }.apply {
            background = GradientDrawable().apply { setColor(blue); cornerRadius = 10 * dp }
            setTextColor(Color.WHITE)
        }
        col.addView(connectButton)
        col.addView(space(8))
        col.addView(text("Pictures of the PC's screen come over the Wi-Fi encrypted. For patient images, a private network " +
            "or the PC's own hotspot is still the safest. The first time you connect to a PC, this tablet asks you to " +
            "compare its PC check with the one next to the code on the PC.", 14f).apply { setTextColor(grey) })
        col.addView(button("Back") { finish() })
        return ScrollView(this).apply { addView(col) }
    }

    /** "First time with <PC>: does the PC show the PC check …?" with It matches / It doesn't. */
    private fun buildCheckPanel(): LinearLayout {
        checkText = text("", 20f, bold = true).apply { gravity = Gravity.CENTER }
        val matches = button("It matches") {
            hideCheck()
            connection?.confirm()
            if (connectScreen.visibility == View.VISIBLE) statusText.text = "Connecting to $pcName…"
        }.apply {
            background = GradientDrawable().apply { setColor(blue); cornerRadius = 10 * dp }
            setTextColor(Color.WHITE)
        }
        val doesnt = button("It doesn't") {
            hideCheck()
            connection?.decline()
            connection = null
            links.wifiEnded()
            showConnect("Don't connect: this may not be your PC.")
        }
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.argb(0xEE, 0x14, 0x1A, 0x22))
            setPadding((32 * dp).toInt(), (32 * dp).toInt(), (32 * dp).toInt(), (32 * dp).toInt())
            addView(checkText)
            addView(space(16))
            addView(matches, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
            addView(space(8))
            addView(doesnt, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
            visibility = View.GONE
            isClickable = true   // nothing under it is touched while the question is open
        }
    }

    private fun hideCheck() { checkPanel.visibility = View.GONE }

    private fun showConnect(message: String?, keyChanged: Boolean = false) {
        hideCheck()
        main.removeCallbacks(retry)
        reconnecting = false
        statusText.text = message ?: ""
        statusText.setTextColor(warn)
        statusText.visibility = if (message.isNullOrEmpty()) View.GONE else View.VISIBLE
        anywayButton.visibility = if (keyChanged) View.VISIBLE else View.GONE
        connectButton.isEnabled = true
        connectScreen.visibility = View.VISIBLE
        padScreen.visibility = View.GONE
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or WindowManager.LayoutParams.FLAG_SECURE)
        refreshFound()
        if (resumed) startDiscovery()
    }

    /** From the connect screen: a PC chosen afresh. Its picture starts empty (not the last PC's). */
    private fun connect() {
        links.resumeUsb()   // a cable paused by Disconnect is tried again too
        val address = addressField.text.toString().trim()
        val c = codeField.text.toString().trim()
        val t = PadProtocol.parseAddress(address)
        when {
            t == null -> { showConnect("Type the PC's address (like 192.168.1.20), or pick a PC from the list."); return }
            !PadProtocol.validCode(c) -> { showConnect("Type the 6-digit code the PC shows."); return }
        }
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().putString("pad.address", address).apply()
        target = t
        links.chooseWifi(c)
        // a PC tapped in the list (and its address left as it was) is remembered under its network name
        chosenName = picked?.takeIf { it.first == address }?.second
        retries = 0
        pcName = ""
        pad.clearPicture()
        stopDiscovery()
        open()
    }

    /** Opens the Wi-Fi connection with the code held (never while the cable is open). */
    private fun open() {
        val (host, port) = target ?: return
        main.removeCallbacks(retry)
        connection?.close()
        connection = null
        links.wifiEnded()
        val code = links.code ?: return
        if (!links.startWifi()) return
        if (connectScreen.visibility == View.VISIBLE) {
            statusText.text = "Connecting to $host:$port…"
            statusText.setTextColor(light)
            statusText.visibility = View.VISIBLE
            anywayButton.visibility = View.GONE
            connectButton.isEnabled = false
        }
        connection = PadConnection(host, port, code, deviceName(), pins, chosenName, acceptAnyway, this).also { it.start() }
    }

    private fun deviceName() = Build.MODEL?.takeIf { it.isNotBlank() } ?: "Android tablet"

    /** A quiet try over the USB cable, when nothing is open or under way over it. */
    private fun tryUsb() {
        if (isFinishing || !links.tryUsb()) return
        usbConnection = PadConnection(PadProtocol.USB_HOST, PadProtocol.USB_PORT, "", deviceName(), pins, null,
            usbAcceptAnyway, this, overCable = true).also { it.start() }
    }

    /** The cable's connection ended: a try that found nothing is quiet; an open session hands back to Wi-Fi or the connect screen. */
    private fun usbEnded(end: PadConnection.End) {
        if (isFinishing) return
        when (links.usbEnded(keyChanged = end.why == PadConnection.Why.KEY_CHANGED)) {
            PadLinks.Then.BACK_TO_WIFI -> {
                // as after a Wi-Fi blip: quietly, with the code typed earlier, the pad and its picture staying
                retries = 0
                reconnecting = true
                updateTitle()
                open()
            }
            PadLinks.Then.CONNECT_SCREEN -> showConnect("The USB connection to the PC ended. Plug the cable back in, or type the code to connect over Wi-Fi.")
            PadLinks.Then.WARN_KEY_CHANGED -> {
                changedKey = end.pcKey
                val check = end.pcKey?.let { PadCrypto.pcCheck(it) } ?: "?"
                val warning = "The PC on the USB cable is not the PC you paired with as “${end.pcName}”: its PC check is now $check. " +
                    "If you didn't reinstall Contrast Ink on it, don't connect."
                if (padScreen.visibility == View.VISIBLE || connection != null) {
                    Toast.makeText(this, warning, Toast.LENGTH_LONG).show()   // the Wi-Fi session goes on
                } else {
                    changedOnCable = true
                    showConnect(warning, keyChanged = true)
                }
            }
            else -> {}
        }
    }

    // ---- the pad ----

    private fun buildPadScreen(): LinearLayout {
        pad = PadView(this, this)
        toolbar = PadToolbar(this) { active?.send(PadProtocol.command(it)) }
        // the title row: Disconnect on the left, far from the toolbar's Next slide, and the PC's name
        titleText = text("", 15f).apply {
            setPadding((12 * dp).toInt(), 0, (12 * dp).toInt(), 0)
            gravity = Gravity.CENTER_VERTICAL
            setSingleLine()
            ellipsize = TextUtils.TruncateAt.END
        }
        val titleRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setBackgroundColor(ink)
            addView(button("✕ Disconnect") { disconnect() }.apply { contentDescription = "Disconnect" },
                LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, (48 * dp).toInt()))
            addView(titleText, LinearLayout.LayoutParams(0, (48 * dp).toInt(), 1f))
        }
        lostText = text("Lost the PC", 20f, bold = true).apply { gravity = Gravity.CENTER }
        lostDetail = text("", 15f).apply { gravity = Gravity.CENTER }
        lostPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.argb(0xCC, 0x14, 0x1A, 0x22))
            setPadding((24 * dp).toInt(), (24 * dp).toInt(), (24 * dp).toInt(), (24 * dp).toInt())
            addView(lostText)
            addView(lostDetail)
            addView(button("Reconnect") { lostText.text = "Reconnecting…"; lostDetail.text = ""; retries = 0; open() })
            addView(button("Choose another PC") { disconnect() })
            visibility = View.GONE
            isClickable = true   // the glass under it takes no strokes while the PC is gone
        }
        val glass = FrameLayout(this).apply {
            addView(pad, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
            addView(lostPanel, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        }
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.BLACK)
            addView(titleRow, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
            addView(toolbar, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
            addView(glass, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
            visibility = View.GONE
        }
    }

    private fun updateTitle() {
        val name = pcName.ifEmpty { "the PC" }
        titleText.text = when {
            reconnecting -> "Reconnecting to $name…"
            links.usb == PadLinks.Usb.OPEN -> "$name · By the USB cable"
            else -> name
        }
        titleText.contentDescription = titleText.text
        titleText.setTextColor(if (reconnecting) warn else light)
    }

    private fun disconnect() {
        // the code is forgotten; a USB session closed here isn't tried again until Connect (it would just reopen)
        if (links.disconnect()) { usbConnection?.close(); usbConnection = null }
        connection?.close()
        connection = null
        showConnect(null)
    }

    override fun send(bytes: ByteArray) { active?.send(bytes) }

    override fun frameShown() { active?.send(PadProtocol.frameAck()) }

    override fun onPc(c: PadConnection, name: String, pcCheck: String, needsCheck: Boolean) {
        if (c === usbConnection) {
            usbPcName = name
            usbAcceptAnyway = null   // used once: from now on the new key is the one remembered
            return
        }
        if (c !== connection) return
        pcName = name
        acceptAnyway = null   // used once: from now on the new key is the one remembered
        if (connectScreen.visibility == View.VISIBLE) statusText.text = "Connecting to $name (PC check $pcCheck)…"
        if (needsCheck) {
            // nothing goes to the PC until the presenter has compared: a machine pretending to be it learns nothing
            checkText.text = "First time with $name: does the PC show the PC check $pcCheck? (⚙ Settings, beside the code)"
            checkText.contentDescription = checkText.text
            checkPanel.visibility = View.VISIBLE
        }
        updateTitle()
    }

    override fun onMessage(c: PadConnection, m: PcMessage) {
        if (c === usbConnection && m is PcMessage.Welcome) {
            // the cable takes over: the Wi-Fi session closes and Wi-Fi isn't tried while the cable lasts
            if (connectScreen.visibility == View.VISIBLE) pad.clearPicture()
            links.usbOpened()
            main.removeCallbacks(retry)
            connection?.close()
            connection = null
            hideCheck()
            stopDiscovery()
            pcName = usbPcName
        }
        if (c !== active) return
        when (m) {
            is PcMessage.Welcome -> {
                if (m.screenW > 0 && m.screenH > 0) { pad.screenW = m.screenW; pad.screenH = m.screenH }
                retries = 0
                reconnecting = false
                statusText.visibility = View.GONE
                lostPanel.visibility = View.GONE
                connectScreen.visibility = View.GONE
                padScreen.visibility = View.VISIBLE
                updateTitle()
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)   // a lecture: the screen stays on
                // the PC's screen may show a patient: keep it out of screenshots and the recent-apps thumbnail
                val testShots = intent.getBooleanExtra(EXTRA_TEST_SCREENSHOTS, false) &&
                    (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
                if (!testShots) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                pad.invalidate()
            }
            is PcMessage.State -> { state = m; toolbar.show(m) }
            is PcMessage.Frame -> showFrame(c, m.jpeg)
            else -> {}   // PONG; REJECT is kept by the connection and shown by onClosed
        }
    }

    /** Decodes a picture off the main thread (a big JPEG takes a while), within bounds, and shows it. */
    private fun showFrame(from: PadConnection, jpeg: ByteArray) {
        if (decoding) { Log.w(PadConnection.TAG, "a picture before FRAME_ACK: dropped"); return }
        decoding = true
        try {
            decoder.execute {
                // anything thrown on this thread would end the app: a hostile picture must only be skipped
                val b = try { decode(jpeg) } catch (t: Throwable) { Log.w(PadConnection.TAG, "picture not shown", t); null }
                runOnUiThread {
                    decoding = false
                    if (active !== from) return@runOnUiThread
                    if (b != null) pad.showPicture(b) else frameShown()   // a picture we can't show: ask for the next
                }
            }
        } catch (e: RejectedExecutionException) { decoding = false /* closing */ }
    }

    private fun decode(jpeg: ByteArray): Bitmap? {
        // its size first, without its pixels: a 30000 × 30000 "picture" would take gigabytes
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, bounds)
        val w = bounds.outWidth
        val h = bounds.outHeight
        if (w <= 0 || h <= 0) return null
        if (w > MAX_PICTURE_PX || h > MAX_PICTURE_PX) { Log.w(PadConnection.TAG, "a $w × $h picture refused"); return null }
        // the picture before last, if it is the same size: decoded into, rather than a new bitmap ten times a second
        val reuse = pad.spare.getAndSet(null)
            ?.takeIf { !it.isRecycled && it.isMutable && it.width == w && it.height == h && it.config == Bitmap.Config.ARGB_8888 }
        val opts = BitmapFactory.Options().apply {
            inMutable = true
            inPreferredConfig = Bitmap.Config.ARGB_8888
            inBitmap = reuse
        }
        return try {
            BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, opts)
        } catch (e: IllegalArgumentException) {   // the spare couldn't take it after all: a fresh bitmap
            BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, BitmapFactory.Options().apply { inMutable = true })
        }
    }

    override fun onClosed(c: PadConnection, end: PadConnection.End) {
        if (c === usbConnection) { usbConnection = null; usbEnded(end); return }
        if (c !== connection) return   // an old connection's end: a newer one is already running
        connection = null
        links.wifiEnded()
        if (isFinishing) return
        hideCheck()
        val inSession = padScreen.visibility == View.VISIBLE
        when {
            end.why == PadConnection.Why.CHECK_TIMEOUT -> showConnect(sentence(end))
            end.why == PadConnection.Why.KEY_CHANGED -> {
                changedKey = end.pcKey
                changedOnCable = false
                val check = end.pcKey?.let { PadCrypto.pcCheck(it) } ?: "?"
                showConnect("This is not the PC you paired with as “${end.pcName}”: its PC check is now $check. " +
                    "If you didn't reinstall Contrast Ink on it, don't connect.", keyChanged = true)
            }
            inSession && end.why in quietEnds && retries < QUIET_RETRIES -> {
                // a Wi-Fi blip: try again quietly (the PC lets the same code back in, replacing the old link)
                retries++
                reconnecting = true
                updateTitle()
                main.postDelayed(retry, 1000L * retries)
            }
            inSession -> {   // the pad stays, with its last picture, to reconnect
                reconnecting = false
                updateTitle()
                lostText.text = "Lost the PC"
                lostDetail.text = sentence(end)
                lostPanel.visibility = View.VISIBLE
            }
            else -> {
                if (end.why == PadConnection.Why.REJECTED) links.codeRefused()   // not worth going back to after the cable
                showConnect(sentence(end))
            }
        }
    }

    /** The ends worth a quiet retry: the network, not the PC saying no. */
    private val quietEnds = setOf(PadConnection.Why.LOST, PadConnection.Why.UNREACHABLE, PadConnection.Why.BROKEN)

    /** Why the link ended, in words for the presenter (the technical detail went to the log). */
    private fun sentence(end: PadConnection.End): String = when (end.why) {
        PadConnection.Why.REJECTED -> end.pcText ?: "The PC said no."
        PadConnection.Why.UNREACHABLE -> "Couldn't reach the PC. $CHECK_WIFI"
        PadConnection.Why.LOST -> if (end.everConnected) "The connection to the PC dropped. $CHECK_WIFI" else "The PC didn't answer. $CHECK_WIFI"
        PadConnection.Why.OLD_PC -> "This PC has an older Contrast Ink. Update Contrast Ink on the PC, then connect again."
        PadConnection.Why.BROKEN -> "The PC's answer couldn't be read. Make sure Contrast Ink is up to date on the PC and on this tablet."
        PadConnection.Why.KEY_CHANGED -> "This is not the PC you paired with."
        PadConnection.Why.CHECK_TIMEOUT -> "Took too long: tap Connect again."
    }

    // ---- finding PCs (DNS-SD, "_contrastink._tcp") ----

    private fun startDiscovery() {
        if (discovering != null || connection != null || links.usb == PadLinks.Usb.OPEN) return
        val manager = getSystemService(Context.NSD_SERVICE) as? NsdManager ?: return
        nsd = manager
        // many phones and tablets drop multicast packets (mDNS) to save battery unless an app holds this lock
        multicast = (applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager)
            ?.createMulticastLock("contrast-ink-pad")?.apply { setReferenceCounted(false); acquire() }
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) { runOnUiThread { if (discovering === this) discovering = null } }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) { runOnUiThread { toResolve.addLast(info); resolveNext() } }
            override fun onServiceLost(info: NsdServiceInfo) { runOnUiThread { found.remove(info.serviceName); refreshFound() } }
        }
        discovering = l
        try { manager.discoverServices(PadProtocol.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l) }
        catch (e: Exception) { discovering = null }
    }

    private fun stopDiscovery() {
        discovering?.let { l -> try { nsd?.stopServiceDiscovery(l) } catch (e: Exception) {} }
        discovering = null
        toResolve.clear()
        try { multicast?.release() } catch (e: Exception) {}
        multicast = null
    }

    /** Older Androids resolve one service at a time: the others wait their turn. */
    @Suppress("DEPRECATION")   // resolveService: its replacement needs Android 14
    private fun resolveNext() {
        if (resolving) return
        val info = toResolve.removeFirstOrNull() ?: return
        val manager = nsd ?: return
        resolving = true
        manager.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(i: NsdServiceInfo, errorCode: Int) { runOnUiThread { resolving = false; resolveNext() } }
            override fun onServiceResolved(i: NsdServiceInfo) {
                runOnUiThread {
                    resolving = false
                    val address = i.host?.hostAddress
                    if (address != null && discovering != null) { found[i.serviceName] = address to i.port; refreshFound() }
                    resolveNext()
                }
            }
        })
    }

    private fun refreshFound() {
        foundList.removeAllViews()
        if (found.isEmpty()) foundList.addView(text("Looking… (if your PC doesn't appear, type its address below)", 14f).apply {
            setTextColor(grey)
        })
        for ((name, at) in found) {
            val (host, port) = at
            val shown = if (host.contains(':')) "[$host]:$port" else "$host:$port"
            foundList.addView(button("$name   ($shown)") {
                addressField.setText(shown)
                picked = shown to name
                // picking a PC fills its address; the presenter then types the code that PC shows now (an old code
                // sent on its own to whichever PC is tapped would only use up one of its guesses)
                codeField.setText("")
                codeField.requestFocus()
            })
        }
    }

    // ---- small helpers, in the setup screen's look ----

    private fun fullscreen() {
        // the whole glass for the picture: the system bars come back with a swipe from the edge
        if (Build.VERSION.SDK_INT >= 30) {
            window.insetsController?.let {
                it.hide(WindowInsets.Type.systemBars())
                it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
        }
    }

    private fun text(t: String, size: Float, bold: Boolean = false) = TextView(this).apply {
        text = t; textSize = size; setTextColor(light)
        if (bold) typeface = Typeface.DEFAULT_BOLD
        setPadding(0, (4 * dp).toInt(), 0, (4 * dp).toInt())
    }

    private fun field(hint: String, name: String, type: Int) = EditText(this).apply {
        this.hint = hint; inputType = type; textSize = 18f; setSingleLine()
        contentDescription = name
        setTextColor(Color.WHITE); setHintTextColor(Color.rgb(0x8A, 0x95, 0xA6))
        minHeight = (48 * dp).toInt()
    }

    private fun button(t: String, onClick: () -> Unit) = Button(this).apply {
        text = t; isAllCaps = false; textSize = 16f
        contentDescription = t
        setOnClickListener { onClick() }
        minHeight = (48 * dp).toInt()
    }

    private fun space(h: Int) = View(this).apply { layoutParams = LinearLayout.LayoutParams(1, (h * dp).toInt()) }
}
