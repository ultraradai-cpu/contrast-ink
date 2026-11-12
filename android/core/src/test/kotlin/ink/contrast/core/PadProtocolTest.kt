package ink.contrast.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** The pad link, byte for byte as docs/pad-protocol.md says (the Windows and iPad apps check the same bytes). */
class PadProtocolTest {
    private fun hex(s: String) = s.split(' ').filter { it.isNotEmpty() }.map { it.toInt(16).toByte() }.toByteArray()

    @Test fun helloVersion2() {
        val key = ByteArray(65) { if (it == 0) 4 else it.toByte() }
        val m = PadProtocol.hello("t", key)
        assertEquals(PadProtocol.HELLO.toByte(), m[0])
        val json = Json.parseObject(m.copyOfRange(5, m.size).toString(Charsets.UTF_8))!!
        assertEquals(mapOf("device" to "t", "version" to 2.0, "key" to java.util.Base64.getEncoder().encodeToString(key)), json)
        assertTrue("no code in the hello", !json.containsKey("code"))
        assertTrue("at most 1 KB", PadProtocol.hello("x".repeat(5000), key).size <= 1024 + 5)
    }

    @Test fun strokeBeginTestVector() =
        assertArrayEquals(hex("10 00 00 00 09 3F 00 00 00 3E 80 00 00 00"), PadProtocol.strokeBegin(0.5f, 0.25f, false))

    @Test fun strokeBeginEraserEnd() = assertEquals(1.toByte(), PadProtocol.strokeBegin(0f, 0f, true)[13])

    @Test fun strokePointsTestVector() = assertArrayEquals(
        hex("11 00 00 00 12 00 02 3F 00 00 00 3F 00 00 00 3F 80 00 00 00 00 00 00"),
        PadProtocol.strokePoints(floatArrayOf(0.5f, 0.5f, 1f, 0f)))

    @Test fun strokeEndTestVector() = assertArrayEquals(hex("12 00 00 00 00"), PadProtocol.strokeEnd())
    @Test fun commandUndoTestVector() = assertArrayEquals(hex("20 00 00 00 04 75 6E 64 6F"), PadProtocol.command("undo"))
    @Test fun frameAckTestVector() = assertArrayEquals(hex("03 00 00 00 00"), PadProtocol.frameAck())

    @Test fun theOtherEmptyMessages() {
        assertArrayEquals(hex("02 00 00 00 00"), PadProtocol.ping())
        assertArrayEquals(hex("13 00 00 00 00"), PadProtocol.strokeCancel())
        assertArrayEquals(hex("15 00 00 00 00"), PadProtocol.hoverEnd())
    }

    @Test fun hover() = assertArrayEquals(hex("14 00 00 00 08 3F 00 00 00 3E 80 00 00"), PadProtocol.hover(0.5f, 0.25f))

    @Test fun manyPointsAreSplitOverSeveralMessages() {
        val n = PadProtocol.MAX_POINTS + 3
        val bytes = PadProtocol.strokePoints(FloatArray(n * 2) { 0.5f })
        assertEquals(5 + 2 + PadProtocol.MAX_POINTS * 8 + 5 + 2 + 3 * 8, bytes.size)
        assertEquals(0xFF.toByte(), bytes[5]); assertEquals(0xFF.toByte(), bytes[6])
        val second = 5 + 2 + PadProtocol.MAX_POINTS * 8
        assertEquals(0x11.toByte(), bytes[second]); assertEquals(3.toByte(), bytes[second + 6])
    }

    @Test fun commandWords() {
        assertEquals("tool:oval", PadProtocol.Commands.tool(Tool.OVAL))
        assertEquals("tool:laser", PadProtocol.Commands.tool(Tool.LASER))
        assertEquals("color:2", PadProtocol.Commands.color(2))
        assertEquals("width:0", PadProtocol.Commands.width(0))
        assertEquals("opacity:0.5", PadProtocol.Commands.opacity(0.5f))
    }

    private fun welcome() = PadProtocol.message(PadProtocol.WELCOME,
        """{"name":"LAPTOP","screenW":1920,"screenH":1080,"version":1}""".toByteArray())
    private fun state() = PadProtocol.message(PadProtocol.STATE,
        """{"tool":"oval","color":3,"width":2,"opacity":0.5,"fading":true,"canUndo":false}""".toByteArray())

    @Test fun decodesEveryPcMessage() {
        val jpeg = ByteArray(1000) { it.toByte() }
        val all = welcome() + state() + PadProtocol.message(PadProtocol.FRAME, jpeg) + PadProtocol.message(PadProtocol.PONG) +
            PadProtocol.message(PadProtocol.REJECT, "Wrong code".toByteArray())
        val got = PadDecoder().feed(all)
        assertEquals(5, got.size)
        assertEquals(PcMessage.Welcome("LAPTOP", 1920, 1080, 1), got[0])
        assertEquals(PcMessage.State(Tool.OVAL, 3, 2, 0.5f, true, false), got[1])
        assertArrayEquals(jpeg, (got[2] as PcMessage.Frame).jpeg)
        assertEquals(PcMessage.Pong, got[3])
        assertEquals(PcMessage.Reject("Wrong code"), got[4])
    }

    @Test fun decodesAcrossSplitReads() {
        val all = welcome() + PadProtocol.message(PadProtocol.FRAME, ByteArray(300) { 7 }) + state() + PadProtocol.message(PadProtocol.PONG)
        for (chunk in listOf(1, 2, 3, 4, 5, 6, 7, 13, 64, 1000)) {
            val d = PadDecoder()
            val got = ArrayList<PcMessage>()
            var i = 0
            while (i < all.size) { val n = minOf(chunk, all.size - i); got += d.feed(all, i, n); i += n }
            assertEquals("pieces of $chunk bytes", 4, got.size)
            assertTrue(got[0] is PcMessage.Welcome && got[1] is PcMessage.Frame && got[2] is PcMessage.State && got[3] == PcMessage.Pong)
            assertEquals(300, (got[1] as PcMessage.Frame).jpeg.size)
        }
    }

    @Test fun skipsUnknownTypes() {
        val all = PadProtocol.message(0x99, ByteArray(70000) { 1 }) + PadProtocol.message(0x01, ByteArray(3)) +
            PadProtocol.message(0x87) + PadProtocol.message(PadProtocol.PONG)
        assertEquals(listOf<PcMessage>(PcMessage.Pong), PadDecoder().feed(all))
        // and in small pieces
        val d = PadDecoder()
        val got = ArrayList<PcMessage>()
        all.toList().chunked(777).forEach { got += d.feed(it.toByteArray()) }
        assertEquals(listOf<PcMessage>(PcMessage.Pong), got)
    }

    @Test fun rejectsOver16MB() {
        val d = PadDecoder()
        assertEquals(1, d.feed(hex("85 00 00 00 00")).size)   // fine before
        try { d.feed(hex("83 01 00 00 01")); fail("over 16 MB must throw") } catch (e: PadProtocolException) {}
        try { d.feed(hex("85 00 00 00 00")); fail("stays broken") } catch (e: PadProtocolException) {}
        // exactly 16 MB is allowed (an unknown type here, so nothing is kept)
        assertEquals(0, PadDecoder().feed(hex("99 01 00 00 00")).size)
        try { PadDecoder().feed(hex("99 FF FF FF FF")); fail("4 GB must throw") } catch (e: PadProtocolException) {}
    }

    @Test fun badJsonIsDroppedNotFatal() {
        val all = PadProtocol.message(PadProtocol.STATE, "{not json".toByteArray()) + PadProtocol.message(PadProtocol.PONG)
        assertEquals(listOf<PcMessage>(PcMessage.Pong), PadDecoder().feed(all))
    }

    @Test fun json() {
        assertEquals(mapOf("a" to "x\"y\n\u00e9", "b" to listOf(1.0, true, null), "c" to mapOf<String, Any?>()),
            Json.parse("""{ "a" : "x\"y\n\u00e9", "b":[1, true ,null], "c":{} }"""))
        assertNull(Json.parse("{\"a\":1"))
        assertNull(Json.parse("{\"a\":1} x"))
        assertNull(Json.parse("[".repeat(100000)))
        assertNull(Json.parse("{\"a\":\"\\u12\"}"))
        val s = Json.obj("code" to "1\"2\\", "n" to 3, "ok" to false)
        assertEquals(mapOf("code" to "1\"2\\", "n" to 3.0, "ok" to false), Json.parse(s))
    }

    @Test fun addresses() {
        assertEquals("192.168.1.20" to 47820, PadProtocol.parseAddress("192.168.1.20"))
        assertEquals("192.168.1.20" to 5000, PadProtocol.parseAddress(" 192.168.1.20:5000 "))
        assertEquals("fe80::1" to 47820, PadProtocol.parseAddress("fe80::1"))
        assertEquals("fe80::1" to 9, PadProtocol.parseAddress("[fe80::1]:9"))
        assertNull(PadProtocol.parseAddress(""))
        assertNull(PadProtocol.parseAddress("1.2.3.4:"))
        assertNull(PadProtocol.parseAddress("1.2.3.4:70000"))
        assertNull(PadProtocol.parseAddress("a b"))
        assertTrue(PadProtocol.validCode("012345"))
        assertTrue(!PadProtocol.validCode("12345") && !PadProtocol.validCode("12345a"))
    }
}
