// Version 2 of the pad link (docs/pad-protocol.md, "Version 2"): a fresh P-256 key pair for every connection, keys
// made with the code (which never crosses the network), and every message after the hello sealed with AES-256-GCM.
// CryptoKit is Apple's: on Linux this file is left out, and the rest of Core still builds and tests there.
#if canImport(CryptoKit)
import CryptoKit
import Foundation

public enum PadCrypto {
    /// What goes before the code in HKDF's info: with another code the keys differ, so a PROOF can't be opened.
    public static let info = "contrastink pad v2 "
    /// What PROOF carries, sealed: a COMMAND the PC opens to see the tablet knows the code.
    public static let proofText = "hello"

    /// The PC check: the first 4 bytes of SHA-256 of the PC's 65-byte public key, as XXXX-XXXX. The PC shows it next
    /// to the code, so the presenter can see the iPad is talking to that PC and not one pretending to be it.
    public static func check(_ publicKey: Data) -> String {
        let h = Array(SHA256.hash(data: publicKey)).prefix(4).map { String(format: "%02X", $0) }.joined()
        return "\(h.prefix(4))-\(h.suffix(4))"
    }

    /// The two keys of a connection: tablet → PC, PC → tablet. The same on both sides (ECDH is symmetric).
    /// Nil when `other` isn't a point on the curve.
    public static func keys(own: P256.KeyAgreement.PrivateKey, other: Data, salt: Data, code: String)
        -> (toPC: SymmetricKey, toTablet: SymmetricKey)? {
        guard let pub = try? P256.KeyAgreement.PublicKey(x963Representation: other),
              let secret = try? own.sharedSecretFromKeyAgreement(with: pub) else { return nil }
        // SHA-256 of the x coordinate: the form Windows' DeriveKeyFromHash gives, so every side computes the same
        let x = secret.withUnsafeBytes { Data($0) }
        let ikm = SymmetricKey(data: SHA256.hash(data: x))
        let keys = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data((info + code).utf8), outputByteCount: 64)
        let bytes = keys.withUnsafeBytes { Data($0) }
        return (SymmetricKey(data: bytes.prefix(32)), SymmetricKey(data: bytes.suffix(32)))
    }
}

/// One direction's sealing or opening: AES-256-GCM, the nonce 4 zero bytes and a big-endian counter from 1.
public struct PadSeal {
    private let key: SymmetricKey
    /// Sealing: the last counter used. Opening: the last one accepted (a lower or equal one is a replay).
    public private(set) var counter: UInt64 = 0

    public init(key: SymmetricKey) { self.key = key }

    /// A whole message (its 5-byte header and payload) → the payload of a SEALED message: nonce | ciphertext | tag.
    public mutating func seal(_ message: Data) -> Data {
        counter += 1
        let nonce = Self.nonce(counter)
        // AES.GCM only throws for a bad nonce size, and this one is always 12 bytes
        guard let box = try? AES.GCM.seal(message, using: key, nonce: try AES.GCM.Nonce(data: nonce)) else { return Data() }
        return nonce + box.ciphertext + box.tag
    }

    /// A SEALED payload → the whole message inside; nil when it was altered, sealed with other keys (a wrong code),
    /// or replayed. Only an opened message moves the counter on.
    public mutating func open(_ payload: Data) -> Data? {
        let p = Data(payload)   // indices from 0
        guard p.count >= 12 + 16, p.prefix(4).allSatisfy({ $0 == 0 }) else { return nil }
        let n = p[4..<12].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard n > counter,
              let nonce = try? AES.GCM.Nonce(data: p.prefix(12)),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: p[12..<(p.count - 16)], tag: p.suffix(16)),
              let message = try? AES.GCM.open(box, using: key) else { return nil }
        counter = n
        return message
    }

    static func nonce(_ n: UInt64) -> Data {
        Data([0, 0, 0, 0]) + Data((0..<8).map { UInt8((n >> (56 - 8 * UInt64($0))) & 0xFF) })
    }
}

/// The iPad's end of one connection: its fresh key pair, then (after the CHALLENGE) the two seals.
public struct PadLink {
    private let own: P256.KeyAgreement.PrivateKey
    private var out: PadSeal?
    private var into: PadSeal?

    /// A fresh key pair (a key only for the test vectors).
    public init(privateKey: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey()) { own = privateKey }

    /// This connection's public key, 65 bytes 04|X|Y, as HELLO carries it.
    public var publicKey: Data { own.publicKey.x963Representation }
    /// True once PROOF is made: from then on everything is sealed.
    public var isKeyed: Bool { out != nil }

    public func hello(device: String) -> Data { PadProtocol.hello(device: device, key: publicKey) }

    /// The whole PROOF message for this challenge and code (a COMMAND "hello" sealed with tablet → PC counter 1).
    /// Nil when the PC's key isn't a point on the curve.
    public mutating func proof(_ challenge: PadChallenge, code: String) -> Data? {
        guard let k = PadCrypto.keys(own: own, other: challenge.key, salt: challenge.salt, code: code) else { return nil }
        out = PadSeal(key: k.toPC)
        into = PadSeal(key: k.toTablet)
        return PadProtocol.message(.proof, Array(out!.seal(PadProtocol.command(PadCrypto.proofText))))
    }

    /// A whole message → the whole SEALED message that carries it. Nil before PROOF (nothing goes in the clear).
    public mutating func seal(_ message: Data) -> Data? {
        guard out != nil else { return nil }
        return PadProtocol.message(.sealed, Array(out!.seal(message)))
    }

    /// A SEALED payload from the PC → the message inside (nil: a type the iPad doesn't know, skipped).
    /// Throws `.refused` when it was altered, replayed, sealed with other keys, or isn't one whole message: close.
    public mutating func open(_ payload: Data) throws -> PadMessage? {
        guard into != nil, let m = into!.open(payload) else { throw PadError.refused }
        return try Self.inner(m)
    }

    /// The one whole message inside a sealed one. Its length must match exactly, and it can't be another sealed
    /// message or a challenge (those only ever travel outside).
    static func inner(_ m: Data) throws -> PadMessage? {
        let b = [UInt8](m)
        guard b.count >= 5 else { throw PadError.refused }
        let len = Int(b[1]) << 24 | Int(b[2]) << 16 | Int(b[3]) << 8 | Int(b[4])
        guard len == b.count - 5, b[0] != PadProtocol.Kind.sealed.rawValue, b[0] != PadProtocol.Kind.challenge.rawValue
        else { throw PadError.refused }
        return PadMessage.read(type: b[0], payload: Data(b[5...]))
    }
}
#endif
