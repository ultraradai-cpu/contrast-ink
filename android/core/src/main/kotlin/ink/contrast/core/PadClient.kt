package ink.contrast.core

/**
 * The tablet's side of a version 2 handshake and the sealing after it (docs/pad-protocol.md, "Version 2"), with no
 * network and no threads, so every step is tested on any machine. The connection feeds it what the PC sends and
 * sends what it gives back:
 *
 *   [hello] → the PC's CHALLENGE → [answer] (the PC's key against the one remembered for it) → the PROOF, at once
 *   for a PC it knows, or once the presenter [confirm]s the PC check the first time → the PC's WELCOME (sealed) →
 *   [seal] / [receive] both ways.
 *
 * [overCable]: the link goes through the USB cable (docs/pad-protocol.md, "USB (phase 2)"): the code is empty, and a
 * PC met for the first time gets its PROOF at once (the cable is the proof of being in the room), while a
 * remembered key that differs still stops, as on Wi-Fi.
 *
 * Threads: [proof] and [seal] are called from the one thread that writes, [receive] from the one that reads; each
 * direction's seal is only ever used by its own thread.
 */
class PadClient(
    private val code: String,
    private val device: String,
    private val own: PadCrypto.KeyPair = PadCrypto.newKeyPair(),
    private val overCable: Boolean = false,
) {
    init { require(!overCable || code.isEmpty()) { "over the USB cable the code is empty" } }

    enum class Phase {
        HELLO, CHALLENGED,
        /** A PC met for the first time: nothing is sent until the presenter says its PC check matches ([confirm]). */
        AWAITING_CHECK,
        /** Stopped before the PROOF: another key under a remembered name, or the presenter said the check differs. */
        STOPPED,
        PROOF_SENT, OPEN,
    }

    /** What [answer] decided about the PC's CHALLENGE. */
    sealed class Answer {
        /** The PC the tablet remembers: send this PROOF now. */
        class Proof(val bytes: ByteArray) : Answer()
        /** The first time with this PC ([Phase.AWAITING_CHECK]): show [pcCheck], then [confirm] or [decline]. */
        data class Check(val pcCheck: String) : Answer()
        /** Another key under a remembered name ([Phase.STOPPED]): warn; nothing is sent. */
        object Changed : Answer()
    }

    @Volatile var phase = Phase.HELLO
        private set
    @Volatile private var toPc: PadSeal? = null
    @Volatile private var toTablet: PadSeal? = null
    private val inner = PadDecoder()
    @Volatile private var challenge: PcMessage.Challenge? = null

    /**
     * The CHALLENGE's key against [remembered], the key kept for this PC's name (null: never met).
     * [acceptAnyway]: the key the presenter chose "Connect anyway" for, after the warning; it is checked like a new PC.
     * A PC met before goes on at once (and a new one over the cable); a new one on Wi-Fi waits for the presenter to compare the PC check, so a machine
     * pretending to be the PC never gets a PROOF to try codes against; a changed key stops here.
     */
    fun answer(c: PcMessage.Challenge, remembered: ByteArray?, acceptAnyway: ByteArray? = null): Answer {
        check(phase == Phase.CHALLENGED) { "one answer to one CHALLENGE" }
        return when (PcKey.check(remembered, c.key, acceptAnyway)) {
            PcKey.SAME -> Answer.Proof(proof(c))
            PcKey.CHANGED -> { phase = Phase.STOPPED; Answer.Changed }
            PcKey.NEW -> {
                if (PadCrypto.readPoint(c.key) == null) throw PadProtocolException("The PC's key isn't a P-256 public key")
                if (overCable) return Answer.Proof(proof(c))   // no "It matches" over the cable
                challenge = c
                phase = Phase.AWAITING_CHECK
                Answer.Check(PadCrypto.pcCheck(c.key))
            }
        }
    }

    /** The presenter says the PC shows this PC check: the PROOF to send. */
    @Synchronized fun confirm(): ByteArray {
        val c = challenge
        check(phase == Phase.AWAITING_CHECK && c != null) { "nothing to confirm" }
        phase = Phase.CHALLENGED
        return proof(c)
    }

    /** The presenter says the PC shows another PC check (or took too long): nothing is ever sent. */
    @Synchronized fun decline() {
        if (phase == Phase.AWAITING_CHECK) phase = Phase.STOPPED
    }

    /** The first message: what the tablet is, and its fresh public key. */
    fun hello(): ByteArray = PadProtocol.hello(device, own.point)

    /**
     * The answer to the PC's CHALLENGE: the keys are made with the code, and the PROOF (a sealed COMMAND "hello",
     * tablet→PC counter 1) shows the PC the tablet knows it. Throws when the PC's key isn't a P-256 point.
     */
    fun proof(c: PcMessage.Challenge): ByteArray {
        check(phase == Phase.CHALLENGED) { "PROOF answers one CHALLENGE" }
        val (a, b) = PadCrypto.keys(own.private, c.key, c.salt, code)
            ?: throw PadProtocolException("The PC's key isn't a P-256 public key")
        val seal = PadSeal(a)
        toPc = seal
        toTablet = PadSeal(b)
        phase = Phase.PROOF_SENT
        return PadProtocol.message(PadProtocol.PROOF, seal.seal(PadProtocol.command(PadCrypto.PROOF_TEXT)))
    }

    /** Our messages (one, or several joined), each sealed into its own SEALED message. Only once the PC welcomed us. */
    fun seal(messages: ByteArray): ByteArray {
        val seal = toPc
        check(phase == Phase.OPEN && seal != null) { "nothing is sent before WELCOME" }
        val parts = PadProtocol.split(messages)
        if (parts.size == 1) return PadProtocol.message(PadProtocol.SEALED, seal.seal(parts[0]))
        val out = java.io.ByteArrayOutputStream()
        for (m in parts) out.write(PadProtocol.message(PadProtocol.SEALED, seal.seal(m)))
        return out.toByteArray()
    }

    /**
     * One message from the PC → what it says. In the clear only CHALLENGE (once, in answer to HELLO) and REJECT are
     * taken; everything else must be sealed with the PC→tablet key, its counter higher than the last, and the first
     * sealed one must be WELCOME. Anything else throws (the connection closes): it is not our PC talking, or the
     * stream is broken. A version 1 PC (WELCOME in the clear) throws [OldPc].
     */
    fun receive(m: PcMessage): List<PcMessage> = when (m) {
        is PcMessage.Reject -> listOf(m)   // wrong code, locked out, an old tablet: the PC closes after it
        is PcMessage.Challenge -> {
            if (phase != Phase.HELLO) throw PadProtocolException("A second CHALLENGE")
            phase = Phase.CHALLENGED
            listOf(m)
        }
        is PcMessage.Welcome -> if (phase == Phase.HELLO) throw OldPc() else throw PadProtocolException("WELCOME in the clear")
        is PcMessage.Sealed -> {
            val seal = toTablet
            if (seal == null || (phase != Phase.PROOF_SENT && phase != Phase.OPEN)) throw PadProtocolException("A sealed message before the keys")
            val bytes = seal.open(m.payload) ?: throw PadProtocolException("A sealed message that doesn't open (altered, replayed or another key)")
            val got = inner.feed(bytes)
            if (got.size != 1 || !inner.atBoundary) throw PadProtocolException("A sealed message must hold one whole message")
            val msg = got[0]
            if (msg is PcMessage.Challenge || msg is PcMessage.Sealed) throw PadProtocolException("A handshake message inside a sealed one")
            if (phase == Phase.PROOF_SENT) {
                if (msg !is PcMessage.Welcome) throw PadProtocolException("The first sealed message must be WELCOME")
                phase = Phase.OPEN
            }
            listOf(msg)
        }
        else -> throw PadProtocolException("A message in the clear after the hello")
    }

    /** The PC speaks version 1: it needs updating (the tablet won't send pictures' worth of data unencrypted). */
    class OldPc : PadProtocolException("The PC runs an older Contrast Ink (version 1)")
}

/** What the tablet makes of a PC's key, given the one it remembers under that PC's name. */
enum class PcKey {
    /** Never seen under this name: show the PC check so the presenter can compare it with the PC's screen. */
    NEW,
    /** The key it remembers: the same PC. */
    SAME,
    /** Another key under a remembered name: stop and warn, unless the presenter chose "Connect anyway" for it. */
    CHANGED;

    companion object {
        /** [acceptAnyway]: the key the presenter said to connect to anyway (after the warning), or null. */
        fun check(remembered: ByteArray?, offered: ByteArray, acceptAnyway: ByteArray? = null): PcKey = when {
            remembered == null -> NEW
            remembered.contentEquals(offered) -> SAME
            acceptAnyway != null && acceptAnyway.contentEquals(offered) -> NEW   // shown and remembered as new
            else -> CHANGED
        }
    }
}
