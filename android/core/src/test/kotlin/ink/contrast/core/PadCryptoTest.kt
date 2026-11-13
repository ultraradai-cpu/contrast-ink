package ink.contrast.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.math.BigInteger

/**
 * Version 2 of the pad link: the spec's test vectors byte for byte (docs/pad-protocol.md, "Version 2 test
 * vectors"; the Windows and iPad tests assert the same), then the handshake's rules.
 */
class PadCryptoTest {
    private fun hex(s: String) = PadCrypto.hex(s.replace(" ", ""))

    private val tabletD = ByteArray(32) { 0x11 }
    private val pcD = ByteArray(32) { 0x22 }
    private val salt = hex("000102030405060708090A0B0C0D0E0F")
    private val tabletPublic = hex("040217E617F0B6443928278F96999E69A23A4F2C152BDF6D6CDF66E5B80282D4ED194A7DEBCB97712D2DDA3CA85AA8765A56F45FC758599652F2897C65306E5794")
    private val pcPublic = hex("04D65A93977CAA3D1B081852FF57A79E465F1660577304BAEAD505DD3A48589CF350185E895372DF6221EA3A137557E473FDDB6755F05BD507C3C533FCE9C91285")
    private val toPcKey = hex("DF563C024C91B19647C1653F3A8E43A1F43779F68708CF133853BCD3BC3A5A98")
    private val toTabletKey = hex("A848F926D9916CEE78F6203D58A043C11A99389BE63198DE580581A4CBAAB8D2")
    private val firstProof = hex("0000000000000000000000012DCC2D016D67988C73F5CD844EA2BE5AFB2499203A49A95C4546")

    /**
     * The public point of a fixed private key, d × G, worked out here with plain arithmetic on the curve (the JDK
     * has no call for it). Test-only: slow and not constant-time, which is fine for two fixed keys.
     */
    private object P256 {
        val p = BigInteger("FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF", 16)
        val gx = BigInteger("6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296", 16)
        val gy = BigInteger("4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5", 16)

        fun add(a: Pair<BigInteger, BigInteger>?, b: Pair<BigInteger, BigInteger>?): Pair<BigInteger, BigInteger>? {
            if (a == null) return b
            if (b == null) return a
            val (x1, y1) = a; val (x2, y2) = b
            val l = if (x1 == x2) {
                if ((y1 + y2).mod(p) == BigInteger.ZERO) return null
                (x1 * x1 * BigInteger.valueOf(3) - BigInteger.valueOf(3)) * (y1 * BigInteger.TWO).modInverse(p)
            } else (y2 - y1) * (x2 - x1).modInverse(p)
            val x3 = (l * l - x1 - x2).mod(p)
            return x3 to (l * (x1 - x3) - y1).mod(p)
        }

        fun point(d: ByteArray): ByteArray {
            var r: Pair<BigInteger, BigInteger>? = null
            var q: Pair<BigInteger, BigInteger>? = gx to gy
            val k = BigInteger(1, d)
            for (i in 0 until k.bitLength()) { if (k.testBit(i)) r = add(r, q); q = add(q, q) }
            fun b32(v: BigInteger) = v.toByteArray().let { if (it.size > 32) it.copyOfRange(it.size - 32, it.size) else ByteArray(32 - it.size) + it }
            return byteArrayOf(4) + b32(r!!.first) + b32(r.second)
        }
    }

    private fun tablet() = PadCrypto.KeyPair(PadCrypto.privateKey(tabletD), P256.point(tabletD))

    // ---- the spec's vectors ----

    @Test fun vectorPublicKeys() {
        assertArrayEquals("tablet public key", tabletPublic, P256.point(tabletD))
        assertArrayEquals("PC public key", pcPublic, P256.point(pcD))
    }

    @Test fun vectorKeysFromBothSides() {
        val (a, b) = PadCrypto.keys(PadCrypto.privateKey(tabletD), pcPublic, salt, "123456")!!
        assertArrayEquals("tablet->PC key", toPcKey, a)
        assertArrayEquals("PC->tablet key", toTabletKey, b)
        // the PC, from its side, gets the same two
        val (c, d) = PadCrypto.keys(PadCrypto.privateKey(pcD), tabletPublic, salt, "123456")!!
        assertArrayEquals(toPcKey, c)
        assertArrayEquals(toTabletKey, d)
    }

    @Test fun vectorFirstSealedProof() {
        val client = PadClient("123456", "t", tablet())
        assertArrayEquals("the hello carries the tablet's key",
            PadProtocol.hello("t", tabletPublic), client.hello())
        client.receive(PcMessage.Challenge(pcPublic, salt, "LAPTOP"))
        val proof = client.proof(PcMessage.Challenge(pcPublic, salt, "LAPTOP"))
        assertArrayEquals("PROOF = 04, length, then the sealed COMMAND \"hello\"",
            PadProtocol.message(PadProtocol.PROOF, firstProof), proof)
        assertArrayEquals(firstProof, PadSeal(toPcKey).seal(PadProtocol.command("hello")))
    }

    @Test fun vectorPcCheck() = assertEquals("all 16 digits: the first 8 bytes of SHA-256", "6FC6-6A90-4861-71CA", PadCrypto.pcCheck(pcPublic))

    @Test fun hkdfRfc5869Case1() = assertArrayEquals(
        hex("3CB25F25FAACD57A90434F64D0362F2A2D2D0A90CF1A5A4C5DB02D56ECC4C5BF34007208D5B887185865"),
        PadCrypto.hkdf(hex("0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B"), hex("000102030405060708090A0B0C"),
            hex("F0F1F2F3F4F5F6F7F8F9"), 42))

    // ---- keys and points ----

    @Test fun freshKeysWorkBothWays() {
        val t = PadCrypto.newKeyPair()
        val p = PadCrypto.newKeyPair()
        assertEquals(65, t.point.size)
        val a = PadCrypto.keys(t.private, p.point, salt, "000111")!!
        val b = PadCrypto.keys(p.private, t.point, salt, "000111")!!
        assertArrayEquals(a.first, b.first); assertArrayEquals(a.second, b.second)
        val wrong = PadCrypto.keys(p.private, t.point, salt, "000112")!!
        assertTrue("another code, other keys", !a.first.contentEquals(wrong.first))
    }

    @Test fun badPointsAreRefused() {
        assertNull(PadCrypto.readPoint(ByteArray(65)))
        assertNull(PadCrypto.readPoint(byteArrayOf(4, 1, 2)))
        assertNull("not on the curve", PadCrypto.readPoint(pcPublic.copyOf().also { it[64] = (it[64] + 1).toByte() }))
        assertNull("compressed form", PadCrypto.readPoint(pcPublic.copyOf().also { it[0] = 2 }))
        assertNotNull(PadCrypto.readPoint(pcPublic))
        assertNull(PadCrypto.keys(PadCrypto.privateKey(tabletD), ByteArray(65), salt, "123456"))
    }

    // ---- sealing ----

    @Test fun sealOpensOnceAndOnlyInOrder() {
        val s = PadSeal(toPcKey)
        val o = PadSeal(toPcKey)
        val one = s.seal(PadProtocol.ping())
        val two = s.seal(PadProtocol.frameAck())
        assertEquals(12 + 5 + 16, one.size)
        assertArrayEquals(PadProtocol.ping(), o.open(one))
        assertNull("a replay", o.open(one))
        assertArrayEquals(PadProtocol.frameAck(), o.open(two))
        assertNull("an older one", o.open(one))
        val three = s.seal(PadProtocol.ping())
        assertNull("altered", PadSeal(toPcKey).open(three.copyOf().also { it[14] = (it[14] + 1).toByte() }))
        assertNull("another key", PadSeal(toTabletKey).open(three))
        assertNull("nonce must start with 4 zero bytes", PadSeal(toPcKey).open(three.copyOf().also { it[0] = 1 }))
        assertNull("too short", o.open(ByteArray(27)))
        assertArrayEquals(PadProtocol.ping(), o.open(three))
    }

    // ---- the handshake, against a PC written from the spec ----

    /** The PC's side, for these tests: its keys from the tablet's hello and the code. */
    private class Pc(code: String, tabletPoint: ByteArray) {
        val keys = PadCrypto.keys(PadCrypto.privateKey(ByteArray(32) { 0x22 }), tabletPoint, ByteArray(16) { it.toByte() }, code)!!
        val open = PadSeal(keys.first)
        val seal = PadSeal(keys.second)
        fun sealed(m: ByteArray) = PcMessage.Sealed(seal.seal(m))
    }

    private fun challenge() = PcMessage.Challenge(pcPublic, salt, "LAPTOP")
    private fun welcome() = PadProtocol.message(PadProtocol.WELCOME, """{"name":"LAPTOP","screenW":1920,"screenH":1080,"version":2}""".toByteArray())

    @Test fun aWholeSession() {
        val client = PadClient("123456", "t")
        val hello = PadDecoderForPc.hello(client.hello())
        val pc = Pc("123456", hello)
        assertEquals(1, client.receive(challenge()).size)
        val proof = client.proof(challenge())
        assertArrayEquals("the PC opens the PROOF: COMMAND hello", PadProtocol.command("hello"), pc.open.open(proof.copyOfRange(5, proof.size)))
        assertEquals(PcMessage.Welcome("LAPTOP", 1920, 1080, 2), client.receive(pc.sealed(welcome())).single())
        assertEquals(PadClient.Phase.OPEN, client.phase)
        assertEquals(PcMessage.Pong, client.receive(pc.sealed(PadProtocol.message(PadProtocol.PONG))).single())
        // several joined messages go as several SEALED ones, in order
        val out = client.seal(PadProtocol.strokePoints(FloatArray((PadProtocol.MAX_POINTS + 1) * 2)) + PadProtocol.strokeEnd())
        val got = PadDecoderForPc.sealedPayloads(out).map { pc.open.open(it)!![0].toInt() and 0xFF }
        assertEquals(listOf(PadProtocol.STROKE_POINTS, PadProtocol.STROKE_POINTS, PadProtocol.STROKE_END), got)
    }

    @Test fun aWrongCodeCantBeOpened() {
        val client = PadClient("654321", "t")
        val pc = Pc("123456", PadDecoderForPc.hello(client.hello()))
        client.receive(challenge())
        val proof = client.proof(challenge())
        assertNull(pc.open.open(proof.copyOfRange(5, proof.size)))
    }

    @Test fun theClientsRules() {
        fun throws(what: String, f: () -> Unit) { try { f(); fail(what) } catch (e: PadProtocolException) {} }
        // nothing in the clear but CHALLENGE and REJECT
        throws("a FRAME in the clear") { PadClient("123456", "t").receive(PcMessage.Frame(ByteArray(3))) }
        throws("STATE in the clear") { PadClient("123456", "t").receive(PcMessage.Pong) }
        try { PadClient("123456", "t").receive(PcMessage.Welcome("PC", 1, 1, 1)); fail("v1 PC") } catch (e: PadClient.OldPc) {}
        throws("sealed before the keys") { PadClient("123456", "t").receive(PcMessage.Sealed(ByteArray(40))) }
        assertEquals(1, PadClient("123456", "t").receive(PcMessage.Reject("Wrong code")).size)

        val client = PadClient("123456", "t")
        val pc = Pc("123456", PadDecoderForPc.hello(client.hello()))
        client.receive(challenge())
        throws("a second challenge") { client.receive(challenge()) }
        client.proof(challenge())
        throws("not WELCOME first") { client.receive(pc.sealed(PadProtocol.message(PadProtocol.PONG))) }
        val w = pc.sealed(welcome())
        client.receive(w)
        throws("a replay") { client.receive(w) }
        throws("sealed with the wrong direction's key") { client.receive(PcMessage.Sealed(PadSeal(pc.keys.first).seal(PadProtocol.message(PadProtocol.PONG)))) }
        throws("two messages in one") {
            client.receive(pc.sealed(PadProtocol.message(PadProtocol.PONG) + PadProtocol.message(PadProtocol.PONG)))
        }
        try { PadClient("1", "t").seal(PadProtocol.ping()); fail("nothing sent before WELCOME") } catch (e: IllegalStateException) {}
    }

    @Test fun badChallengeStops() {
        val c = PadDecoder().feed(PadProtocol.message(PadProtocol.CHALLENGE, "{nonsense".toByteArray())).single() as PcMessage.Challenge
        assertEquals(0, c.key.size)
        val client = PadClient("123456", "t")
        client.receive(c)
        try { client.proof(c); fail("an unreadable key stops the handshake") } catch (e: PadProtocolException) {}
    }

    @Test fun challengeDecodes() {
        val json = Json.obj("key" to java.util.Base64.getEncoder().encodeToString(pcPublic), "salt" to "AAECAwQFBgcICQoLDA0ODw==", "name" to "LAPTOP")
        val c = PadDecoder().feed(PadProtocol.message(PadProtocol.CHALLENGE, json.toByteArray())).single() as PcMessage.Challenge
        assertArrayEquals(pcPublic, c.key)
        assertArrayEquals(salt, c.salt)
        assertEquals("LAPTOP", c.name)
    }

    @Test fun pinning() {
        val a = pcPublic
        val b = tabletPublic
        assertEquals(PcKey.NEW, PcKey.check(null, a))
        assertEquals(PcKey.SAME, PcKey.check(a, a))
        assertEquals(PcKey.CHANGED, PcKey.check(a, b))
        assertEquals("connect anyway, to that key", PcKey.NEW, PcKey.check(a, b, acceptAnyway = b))
        assertEquals("but not to a third", PcKey.CHANGED, PcKey.check(a, b, acceptAnyway = a + byteArrayOf(1)))
    }

    /** The tablet's side of a handshake, with everything it sends after HELLO kept in [sent]. */
    private inner class Tablet(code: String = "123456") {
        val client = PadClient(code, "t")
        val pc = Pc("123456", PadDecoderForPc.hello(client.hello()))
        val sent = ArrayList<ByteArray>()
        fun challenged(remembered: ByteArray?, acceptAnyway: ByteArray? = null): PadClient.Answer {
            client.receive(challenge())
            return client.answer(challenge(), remembered, acceptAnyway).also { if (it is PadClient.Answer.Proof) sent += it.bytes }
        }
        fun confirm() { sent += client.confirm() }
        fun proofOpens() = sent.size == 1 && (sent[0][0].toInt() and 0xFF) == PadProtocol.PROOF &&
            PadProtocol.command("hello").contentEquals(pc.open.open(sent[0].copyOfRange(5, sent[0].size)))
    }

    @Test fun firstTimeWaitsForTheCheck() {
        val t = Tablet()
        assertEquals(PadClient.Answer.Check("6FC6-6A90-4861-71CA"), t.challenged(null))
        assertEquals(PadClient.Phase.AWAITING_CHECK, t.client.phase)
        assertTrue("nothing sent after HELLO until the presenter confirms", t.sent.isEmpty())
        try { t.client.receive(t.pc.sealed(welcome())); fail("nothing sealed is taken before the PROOF") } catch (e: PadProtocolException) {}
        try { t.client.seal(PadProtocol.ping()); fail("nothing sealed is sent before WELCOME") } catch (e: IllegalStateException) {}
        assertTrue(t.sent.isEmpty())

        t.confirm()
        assertTrue("confirmed: the PROOF, opened by the PC", t.proofOpens())
        assertEquals(PadClient.Phase.PROOF_SENT, t.client.phase)
        t.client.receive(t.pc.sealed(welcome()))
        assertEquals(PadClient.Phase.OPEN, t.client.phase)
        try { t.client.confirm(); fail("one PROOF only") } catch (e: IllegalStateException) {}
    }

    @Test fun firstTimeDeclinedSendsNothing() {
        val t = Tablet()
        assertTrue(t.challenged(null) is PadClient.Answer.Check)
        t.client.decline()
        assertEquals(PadClient.Phase.STOPPED, t.client.phase)
        try { t.confirm(); fail("no PROOF once declined") } catch (e: IllegalStateException) {}
        assertTrue("nothing sent after HELLO", t.sent.isEmpty())
    }

    @Test fun rememberedKeyGoesOnAtOnce() {
        val t = Tablet()
        assertTrue(t.challenged(pcPublic) is PadClient.Answer.Proof)
        assertTrue("the PROOF at once", t.proofOpens())
        assertEquals(PadClient.Phase.PROOF_SENT, t.client.phase)
    }

    @Test fun changedKeyStopsUntilConnectAnyway() {
        val t = Tablet()
        assertEquals(PadClient.Answer.Changed, t.challenged(tabletPublic))
        assertEquals(PadClient.Phase.STOPPED, t.client.phase)
        try { t.confirm(); fail("no PROOF for a changed key") } catch (e: IllegalStateException) {}
        assertTrue("nothing sent after HELLO", t.sent.isEmpty())

        // "Connect anyway" connects again, letting this key through: it shows the check like a first time
        val again = Tablet()
        assertEquals(PadClient.Answer.Check("6FC6-6A90-4861-71CA"), again.challenged(tabletPublic, acceptAnyway = pcPublic))
        assertTrue("nothing until the check is confirmed", again.sent.isEmpty())
        again.confirm()
        assertTrue("then the PROOF", again.proofOpens())
    }

    @Test fun aBadKeyIsNeverShownAsACheck() {
        val client = PadClient("123456", "t")
        val c = PcMessage.Challenge(ByteArray(65), salt, "LAPTOP")
        client.receive(c)
        try { client.answer(c, null); fail("an unreadable key stops the handshake") } catch (e: PadProtocolException) {}
    }

    /**
     * USB: the code is empty ("contrastink pad v2 " as info). The cable proves nothing (any app on the tablet can
     * listen where the PC would be), so a PC met for the first time waits for the PC check, as on Wi-Fi.
     */
    @Test fun overTheCable() {
        try { PadClient("123456", "t", overCable = true); fail("no code over the cable") } catch (e: IllegalArgumentException) {}
        val client = PadClient("", "t", overCable = true)
        val point = PadDecoderForPc.hello(client.hello())
        val pc = Pc("", point)
        client.receive(challenge())
        assertEquals("the first time, the PC check before anything is sent", PadClient.Answer.Check("6FC6-6A90-4861-71CA"), client.answer(challenge(), null))
        assertEquals(PadClient.Phase.AWAITING_CHECK, client.phase)
        val proof = client.confirm()
        assertArrayEquals("opened with the empty code's keys", PadProtocol.command("hello"), pc.open.open(proof.copyOfRange(5, proof.size)))
        assertNull("not with a code's", Pc("123456", point).open.open(proof.copyOfRange(5, proof.size)))
        client.receive(pc.sealed(welcome()))
        assertEquals(PadClient.Phase.OPEN, client.phase)

        // a remembered key that matches: the PROOF at once
        val known = PadClient("", "t", overCable = true)
        known.receive(challenge())
        assertTrue("a remembered PC goes on at once over the cable", known.answer(challenge(), pcPublic) is PadClient.Answer.Proof)

        // "It doesn't": nothing is ever sent
        val declined = PadClient("", "t", overCable = true)
        declined.receive(challenge())
        assertTrue(declined.answer(challenge(), null) is PadClient.Answer.Check)
        declined.decline()
        try { declined.confirm(); fail("no PROOF once declined") } catch (e: IllegalStateException) {}

        // a remembered key that differs still stops, over the cable too
        val other = PadClient("", "t", overCable = true)
        other.receive(challenge())
        assertEquals(PadClient.Answer.Changed, other.answer(challenge(), tabletPublic))
        assertEquals(PadClient.Phase.STOPPED, other.phase)
    }

    /** Reading what the tablet sends, as the PC would. */
    private object PadDecoderForPc {
        fun hello(m: ByteArray): ByteArray {
            val json = Json.parseObject(m.copyOfRange(5, m.size).toString(Charsets.UTF_8))!!
            return java.util.Base64.getDecoder().decode(json["key"] as String)
        }

        fun sealedPayloads(bytes: ByteArray) = PadProtocol.split(bytes).map {
            assertEquals(PadProtocol.SEALED, it[0].toInt() and 0xFF)
            it.copyOfRange(5, it.size)
        }
    }
}
