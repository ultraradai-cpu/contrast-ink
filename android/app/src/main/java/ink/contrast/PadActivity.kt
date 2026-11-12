package ink.contrast

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.text.InputFilter
import android.text.InputType
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
import ink.contrast.core.PadProtocol
import ink.contrast.core.PcMessage
import ink.contrast.core.Tool
import java.util.concurrent.Executors

/**
 * Pad mode: this tablet becomes a wireless drawing pad for a PC running Contrast Ink (same Wi-Fi). It shows a
 * live picture of the PC's screen; what is drawn here, the PC draws on its own drawing layer (so OBS records it).
 * The link is written down in docs/pad-protocol.md.
 *
 * Two screens: finding the PC (the PCs found on the network, or an address typed by hand, and the 6-digit code
 * the PC shows), then the pad itself (the picture, the glass to draw on, and a toolbar).
 */
@SuppressLint("SetTextI18n")
class PadActivity : Activity(), PadConnection.Listener, PadView.Host {
    companion object {
        /**
         * Connect at once to this address ("192.168.1.20" or "192.168.1.20:47820") with [EXTRA_CODE], without
         * looking for PCs on the network: for the app's test (a stand-in PC on this device) and for starting the
         * pad from a typed address.
         */
        const val EXTRA_ADDRESS = "ink.contrast.pad.ADDRESS"
        const val EXTRA_CODE = "ink.contrast.pad.CODE"
        private const val PREFS = "contrast-ink"

        /** The pad on screen, if any (the test reaches it here). */
        var running: PadActivity? = null
            private set
    }

    private val dp by lazy { resources.displayMetrics.density }
    private val blue = Color.rgb(0x25, 0x63, 0xEB)
    private val ink = Color.rgb(0x14, 0x1A, 0x22)
    private val light = Color.rgb(0xE3, 0xE8, 0xF0)
    private val warn = Color.rgb(0xFF, 0x99, 0x8C)

    // the connect screen
    private lateinit var connectScreen: View
    private lateinit var statusText: TextView
    private lateinit var foundList: LinearLayout
    private lateinit var addressField: EditText
    private lateinit var codeField: EditText
    private lateinit var connectButton: Button

    // the pad
    private lateinit var padScreen: LinearLayout
    lateinit var pad: PadView
        private set
    private lateinit var toolbar: PadToolbar
    private lateinit var lostPanel: LinearLayout
    private lateinit var lostText: TextView

    private var connection: PadConnection? = null
    private var target: Pair<String, Int>? = null
    private var code = ""
    private val decoder = Executors.newSingleThreadExecutor { Thread(it, "pad-pictures") }

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
        running = this
        connectScreen = buildConnectScreen()
        padScreen = buildPadScreen()
        val root = FrameLayout(this).apply {
            setBackgroundColor(ink)
            addView(connectScreen)
            addView(padScreen)
        }
        setContentView(root)
        fullscreen()

        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        addressField.setText(intent.getStringExtra(EXTRA_ADDRESS) ?: prefs.getString("pad.address", ""))
        codeField.setText(intent.getStringExtra(EXTRA_CODE) ?: prefs.getString("pad.code", ""))
        if (intent.hasExtra(EXTRA_ADDRESS) && intent.hasExtra(EXTRA_CODE)) connect() else showConnect(null)
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
        if (running === this) running = null
        connection?.close()
        connection = null
        decoder.shutdownNow()
    }

    // ---- the connect screen ----

    private fun buildConnectScreen(): View {
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding((24 * dp).toInt(), (32 * dp).toInt(), (24 * dp).toInt(), (24 * dp).toInt())
        }
        col.addView(text("Use this tablet as a pad", 26f, bold = true))
        col.addView(text("On the PC, open Contrast Ink and choose Tablet: it shows a 6-digit code. Both must be on the same Wi-Fi.", 15f))
        statusText = text("", 15f).apply { setTextColor(warn); visibility = View.GONE }
        col.addView(statusText)
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
            setOnEditorActionListener { _, _, _ -> connect(); true }
        }
        col.addView(codeField)
        col.addView(space(8))
        connectButton = button("Connect") { connect() }.apply {
            background = GradientDrawable().apply { setColor(blue); cornerRadius = 10 * dp }
            setTextColor(Color.WHITE)
        }
        col.addView(connectButton)
        col.addView(button("Back") { finish() })
        return ScrollView(this).apply { addView(col) }
    }

    private fun showConnect(message: String?) {
        statusText.text = message ?: ""
        statusText.setTextColor(warn)
        statusText.visibility = if (message.isNullOrEmpty()) View.GONE else View.VISIBLE
        connectButton.isEnabled = true
        connectScreen.visibility = View.VISIBLE
        padScreen.visibility = View.GONE
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        refreshFound()
        if (resumed) startDiscovery()
    }

    private fun connect() {
        val address = addressField.text.toString().trim()
        val c = codeField.text.toString().trim()
        val t = PadProtocol.parseAddress(address)
        when {
            t == null -> { showConnect("Type the PC's address (like 192.168.1.20), or pick a PC from the list."); return }
            !PadProtocol.validCode(c) -> { showConnect("Type the 6-digit code the PC shows."); return }
        }
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().putString("pad.address", address).putString("pad.code", c).apply()
        target = t
        code = c
        stopDiscovery()
        open()
    }

    private fun open() {
        val (host, port) = target ?: return
        connection?.close()
        statusText.text = "Connecting to $host:$port…"
        statusText.setTextColor(light)
        statusText.visibility = View.VISIBLE
        connectButton.isEnabled = false
        val name = Build.MODEL?.takeIf { it.isNotBlank() } ?: "Android tablet"
        connection = PadConnection(host, port, code, name, this).also { it.start() }
    }

    // ---- the pad ----

    private fun buildPadScreen(): LinearLayout {
        pad = PadView(this, this)
        toolbar = PadToolbar(this, { connection?.send(PadProtocol.command(it)) }, { disconnect() })
        lostText = text("Lost the PC", 20f, bold = true).apply { gravity = Gravity.CENTER }
        lostPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.argb(0xCC, 0x14, 0x1A, 0x22))
            setPadding((24 * dp).toInt(), (24 * dp).toInt(), (24 * dp).toInt(), (24 * dp).toInt())
            addView(lostText)
            addView(button("Reconnect") { lostText.text = "Reconnecting…"; open() })
            addView(button("Choose another PC") { showConnect(null) })
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
            addView(toolbar, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
            addView(glass, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
            visibility = View.GONE
        }
    }

    private fun disconnect() {
        connection?.close()
        connection = null
        showConnect(null)
    }

    override fun send(bytes: ByteArray) { connection?.send(bytes) }

    override fun frameShown() { connection?.send(PadProtocol.frameAck()) }

    override fun onMessage(m: PcMessage) {
        when (m) {
            is PcMessage.Welcome -> {
                if (m.screenW > 0 && m.screenH > 0) { pad.screenW = m.screenW; pad.screenH = m.screenH }
                statusText.visibility = View.GONE
                lostPanel.visibility = View.GONE
                connectScreen.visibility = View.GONE
                padScreen.visibility = View.VISIBLE
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)   // a lecture: the screen stays on
                pad.invalidate()
            }
            is PcMessage.State -> { state = m; toolbar.show(m) }
            is PcMessage.Frame -> {
                val from = connection
                // JPEG decoding takes a while for a big picture: off the main thread, so drawing never stutters
                try {
                    decoder.execute {
                        val b = BitmapFactory.decodeByteArray(m.jpeg, 0, m.jpeg.size)
                        runOnUiThread {
                            if (connection !== from || connection == null) return@runOnUiThread
                            if (b != null) pad.showPicture(b) else frameShown()   // a broken picture: ask for the next
                        }
                    }
                } catch (e: java.util.concurrent.RejectedExecutionException) { /* closing */ }
            }
            is PcMessage.Reject, PcMessage.Pong -> {}   // REJECT: the PC closes, and onClosed shows its reason
        }
    }

    override fun onClosed(reason: String, everConnected: Boolean) {
        connection = null
        if (isFinishing) return
        if (padScreen.visibility == View.VISIBLE) {   // the pad stays, with its last picture, to reconnect
            lostText.text = reason
            lostPanel.visibility = View.VISIBLE
        } else {
            showConnect(reason)
        }
    }

    // ---- finding PCs (DNS-SD, "_contrastink._tcp") ----

    private fun startDiscovery() {
        if (discovering != null || connection != null) return
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
            setTextColor(Color.rgb(0x8A, 0x95, 0xA6))
        })
        for ((name, at) in found) {
            val (host, port) = at
            val shown = if (host.contains(':')) "[$host]:$port" else "$host:$port"
            foundList.addView(button("$name   ($shown)") {
                addressField.setText(shown)
                // picking a PC: the code is all that's left to type
                if (PadProtocol.validCode(codeField.text.toString().trim())) connect() else codeField.requestFocus()
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
