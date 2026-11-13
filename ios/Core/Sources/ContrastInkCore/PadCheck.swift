import Foundation

/// How the PC check is written (docs/pad-protocol.md, "Version 2", step 1): the first 8 bytes of the SHA-256 of the
/// PC's public key as 16 hex digits, XXXX-XXXX-XXXX-XXXX. (4 bytes were too few: a matching fake key could be
/// searched for offline.) The hashing is CryptoKit's (PadCrypto.check); the writing is here, so it is tested on Linux.
public enum PadCheck {
    public static let bytes = 8

    /// `hash`: the SHA-256 of the key (32 bytes; only the first 8 are used).
    public static func format(hash: Data) -> String {
        let hex = hash.prefix(bytes).map { b -> String in
            let s = String(b, radix: 16, uppercase: true)
            return b < 16 ? "0" + s : s
        }.joined()
        var groups: [String] = []
        var rest = Substring(hex)
        while !rest.isEmpty { groups.append(String(rest.prefix(4))); rest = rest.dropFirst(4) }
        return groups.joined(separator: "-")
    }
}
