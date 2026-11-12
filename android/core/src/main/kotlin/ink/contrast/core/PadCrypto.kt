package ink.contrast.core

import java.math.BigInteger
import java.security.GeneralSecurityException
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPrivateKeySpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Version 2 of the pad link (docs/pad-protocol.md, "Version 2"): a fresh P-256 key pair for every connection, keys
 * derived with the code (which never crosses the network), and every message after the hello sealed with
 * AES-256-GCM. Only the platform's own crypto (the JDK's, or Android's which offers the same names), so nothing
 * extra ships with the app; the same code runs in the JVM tests against the spec's vectors.
 */
object PadCrypto {
    const val PROOF_TEXT = "hello"

    /** The P-256 curve: y² = x³ − 3x + b (mod p). Used to refuse a "public key" that isn't a point on it. */
    private val P = BigInteger("FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF", 16)
    private val B = BigInteger("5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B", 16)

    /**
     * What goes before the 65-byte point to make an X.509 SubjectPublicKeyInfo (the form KeyFactory reads): the
     * ASN.1 for "an EC public key on secp256r1", then the BIT STRING header. Fixed for every P-256 key.
     */
    private val SPKI_PREFIX = hex("3059301306072A8648CE3D020106082A8648CE3D030107034200")

    /** A fresh key pair: its private key, and its public key as the 65 bytes sent to the other side. */
    class KeyPair(val private: PrivateKey, val point: ByteArray)

    fun newKeyPair(): KeyPair {
        val kp = generate()
        return KeyPair(kp.private, point(kp.public as ECPublicKey))
    }

    private fun generate() = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()

    /** The curve's parameters, as the platform describes them (taken from a key it made, which every platform can). */
    val curve: ECParameterSpec by lazy { (generate().public as ECPublicKey).params }

    /**
     * A private key from its 32 bytes. Only for fixed keys: the spec's test vectors and the app's test, whose
     * stand-in PC uses the vectors' PC key. A real tablet always makes a fresh pair with [newKeyPair].
     */
    fun privateKey(d: ByteArray): PrivateKey =
        KeyFactory.getInstance("EC").generatePrivate(ECPrivateKeySpec(BigInteger(1, d), curve))

    /** A public key as 65 bytes: 04, then X and Y, 32 bytes each, big-endian. */
    fun point(k: ECPublicKey): ByteArray {
        val out = ByteArray(65)
        out[0] = 4
        fixed32(k.w.affineX).copyInto(out, 1)
        fixed32(k.w.affineY).copyInto(out, 33)
        return out
    }

    /** The other side's public key from its 65 bytes; null when it isn't a point on the curve. */
    fun readPoint(point: ByteArray): ECPublicKey? {
        if (point.size != 65 || point[0].toInt() != 4) return null
        val x = BigInteger(1, point.copyOfRange(1, 33))
        val y = BigInteger(1, point.copyOfRange(33, 65))
        // checked here rather than trusting each platform's provider to: an off-curve point can leak the private key
        if (x >= P || y >= P) return null
        if (y.multiply(y).mod(P) != x.pow(3).subtract(x.multiply(BigInteger.valueOf(3))).add(B).mod(P)) return null
        return try {
            KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(SPKI_PREFIX + point)) as ECPublicKey
        } catch (e: GeneralSecurityException) { null }
    }

    /**
     * The two keys, tablet→PC and PC→tablet: HKDF-SHA256 of SHA-256(the ECDH x coordinate), with the PC's salt and
     * the code in "info". A wrong code gives other keys, so the PC can't open the PROOF. Null for a bad point.
     */
    fun keys(own: PrivateKey, otherPoint: ByteArray, salt: ByteArray, code: String): Pair<ByteArray, ByteArray>? {
        val other = readPoint(otherPoint) ?: return null
        val ka = KeyAgreement.getInstance("ECDH")
        ka.init(own)
        ka.doPhase(other, true)
        val x = ka.generateSecret()   // the shared point's x coordinate, 32 bytes big-endian
        val shared = MessageDigest.getInstance("SHA-256").digest(x)
        val keys = hkdf(shared, salt, ("contrastink pad v2 $code").toByteArray(Charsets.UTF_8), 64)
        return keys.copyOfRange(0, 32) to keys.copyOfRange(32, 64)
    }

    /** HKDF with SHA-256 (RFC 5869): extract, then expand to [length] bytes. */
    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        // an empty salt means 32 zero bytes (the RFC's rule; Java won't take an empty key)
        mac.init(SecretKeySpec(if (salt.isEmpty()) ByteArray(32) else salt, "HmacSHA256"))
        val prk = mac.doFinal(ikm)
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        val out = ByteArray(length)
        var t = ByteArray(0)
        var at = 0
        var i = 1
        while (at < length) {
            mac.update(t); mac.update(info); mac.update(i.toByte())
            t = mac.doFinal()
            val n = minOf(t.size, length - at)
            t.copyInto(out, at, 0, n)
            at += n; i++
        }
        return out
    }

    /** The PC check: the first 4 bytes of SHA-256 of the PC's public key, as XXXX-XXXX (the PC shows the same). */
    fun pcCheck(point: ByteArray): String {
        val h = MessageDigest.getInstance("SHA-256").digest(point)
        val s = (0 until 4).joinToString("") { "%02X".format(h[it].toInt() and 0xFF) }
        return s.substring(0, 4) + "-" + s.substring(4)
    }

    private fun fixed32(v: BigInteger): ByteArray {
        val b = v.toByteArray()   // may have a leading 0 (sign) or be shorter than 32
        return when {
            b.size == 32 -> b
            b.size > 32 -> b.copyOfRange(b.size - 32, b.size)
            else -> ByteArray(32 - b.size) + b
        }
    }

    internal fun hex(s: String): ByteArray = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}

/**
 * One direction's sealing or opening: AES-256-GCM, nonce = 4 zero bytes and a 64-bit big-endian counter from 1.
 * Each side seals with one key and opens with the other, so the two directions never share a nonce.
 */
class PadSeal(key: ByteArray) {
    private val key = SecretKeySpec(key, "AES")
    private val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    /** Sealing: the last counter used. Opening: the last one accepted (anything not above it is a replay). */
    var counter = 0L
        private set

    /** A whole message (header and payload) → the payload of a SEALED message. */
    fun seal(message: ByteArray): ByteArray {
        val nonce = nonce(++counter)
        cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, nonce))
        return nonce + cipher.doFinal(message)   // ciphertext with the 16-byte tag at its end
    }

    /** A SEALED payload → the message inside; null when altered, sealed with another key (a wrong code), or replayed. */
    fun open(payload: ByteArray): ByteArray? {
        if (payload.size < 12 + 16) return null
        for (i in 0 until 4) if (payload[i].toInt() != 0) return null
        var n = 0L
        for (i in 4 until 12) n = (n shl 8) or (payload[i].toLong() and 0xFF)
        // unsigned compare: a counter of 2^63 or more is still "after" (never reached in practice, but not a hole)
        if (java.lang.Long.compareUnsigned(n, counter) <= 0) return null
        val message = try {
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, payload, 0, 12))
            cipher.doFinal(payload, 12, payload.size - 12)
        } catch (e: GeneralSecurityException) { return null }
        counter = n
        return message
    }

    private fun nonce(n: Long) = ByteArray(12).also { for (i in 0 until 8) it[4 + i] = (n ushr (56 - 8 * i)).toByte() }
}
