// The PC's end of the version-2 handshake (docs/pad-protocol.md, "Version 2"), as the Windows app's PadServer does
// it: HELLO → CHALLENGE (this Mac's long-lived key, a fresh salt, its name) → PROOF opened with keys made from the
// code → everything after sealed. No sockets here, so it is tested byte for byte against the spec's vectors.
#if canImport(CryptoKit)
import ContrastInkCore
import CryptoKit
import Foundation

public struct PadAccept {
    public enum Hello: Equatable {
        /// Send this (the whole CHALLENGE message, in the clear) and wait for the PROOF.
        case challenge(Data)
        /// Send REJECT with this text, in the clear, and close.
        case reject(String)
    }

    private let pcKey: P256.KeyAgreement.PrivateKey
    private let name: String
    public let salt: Data
    private var tabletKey: Data?
    private var into: PadSeal?
    private var out: PadSeal?
    /// The tablet's name from its HELLO.
    public private(set) var device = ""

    public init(pcKey: P256.KeyAgreement.PrivateKey, name: String, salt: Data? = nil) {
        self.pcKey = pcKey
        self.name = name
        if let salt { self.salt = salt } else {
            var g = SystemRandomNumberGenerator()
            self.salt = Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &g) })
        }
    }

    /// True once the PROOF was opened: from then on everything is sealed.
    public var isOpen: Bool { out != nil }

    /// The first message. A version-1 HELLO (it has the code in it), a broken one, or a key that isn't a point on the
    /// curve: "Please update Contrast Ink on the tablet."
    public mutating func hello(type: UInt8, payload: Data) -> Hello {
        guard tabletKey == nil, type == PadProtocol.Kind.hello.rawValue, let h = PadPC.hello(payload),
              (try? P256.KeyAgreement.PublicKey(x963Representation: h.key)) != nil
        else { return .reject(PadPC.updateTablet) }
        tabletKey = h.key
        device = h.device
        return .challenge(PadPC.challenge(key: pcKey.publicKey.x963Representation, salt: salt, name: name))
    }

    /// The PROOF: a COMMAND "hello" sealed with keys made from `code` (empty over USB). True when it opens: the
    /// tablet knows the code, and the session's seals are ready. False: a wrong code (or not a PROOF at all).
    public mutating func proof(type: UInt8, payload: Data, code: String) -> Bool {
        guard !isOpen, type == PadProtocol.Kind.proof.rawValue, let tabletKey,
              let k = PadCrypto.keys(own: pcKey, other: tabletKey, salt: salt, code: code) else { return false }
        var open = PadSeal(key: k.toPC)
        guard let inner = open.open(payload), let said = PadFrames.all(inner), said.count == 1,
              said[0].type == PadProtocol.Kind.command.rawValue,
              String(decoding: said[0].payload, as: UTF8.self) == PadCrypto.proofText else { return false }
        into = open
        out = PadSeal(key: k.toTablet)
        return true
    }

    /// A SEALED payload from the tablet → the messages inside. Nil when it was altered, replayed, sealed with other
    /// keys, or isn't only whole messages: close the connection.
    public mutating func open(_ payload: Data) -> [(type: UInt8, payload: Data)]? {
        guard into != nil, let m = into!.open(payload) else { return nil }
        return PadFrames.all(m)
    }

    /// A whole message → the whole SEALED message that carries it (nil before the PROOF: nothing goes in the clear).
    public mutating func seal(_ message: Data) -> Data? {
        guard out != nil else { return nil }
        return PadPC.message(PadProtocol.Kind.sealed.rawValue, out!.seal(message))
    }
}

public enum PadIdentityCheck {
    /// The PC check shown beside the code: the first 8 bytes of SHA-256 of the 65-byte public key,
    /// "6FC6-6A90-4861-71CA". The same 16 digits as Core's PadCrypto.check (the tablet's side): PadPCTests holds them alike.
    public static func check(_ key: P256.KeyAgreement.PrivateKey) -> String { check(publicKey: key.publicKey.x963Representation) }

    public static func check(publicKey: Data) -> String { PadCheck.text(hash: Array(SHA256.hash(data: publicKey))) ?? "" }
}
#endif
