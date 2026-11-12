import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The Mac's own key for the tablet link (the one behind its PC check), kept in a file:
/// `~/Library/Application Support/Contrast Ink/pad-key`, the raw 32 bytes of the P-256 private key, readable only by
/// this user (the file 0600, its folder 0700). Not the Keychain: the app is signed ad hoc, so macOS ties a Keychain
/// item's access list to one build, and after an update the item can't be read (tablets would then warn "not the PC
/// you paired with"). No CryptoKit here, so it is tested anywhere.
public enum PadKeyFile {
    public enum Loaded: Equatable {
        /// The key's raw bytes.
        case key(Data)
        /// No file yet (the first run, or one before the key moved here from the Keychain).
        case missing
        /// The file is there but can't be used: never replaced by a new key without the presenter knowing.
        case unreadable(String)
    }

    public static let keyLength = 32

    /// `~/Library/Application Support/Contrast Ink/pad-key`.
    public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Contrast Ink/pad-key")
    }

    public static func load(_ url: URL) -> Loaded {
        let path = url.path
        var st = stat()
        if lstat(path, &st) != 0 {
            return errno == ENOENT ? .missing : .unreadable(String(cString: strerror(errno)))
        }
        guard st.st_mode & S_IFMT == S_IFREG else { return .unreadable("not a plain file") }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return .unreadable(String(cString: strerror(errno))) }
        defer { _ = close(fd) }
        var buf = [UInt8](repeating: 0, count: keyLength + 1)
        var got = 0
        while got < buf.count {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, $0.count - got) }
            if n < 0 { return .unreadable(String(cString: strerror(errno))) }
            if n == 0 { break }
            got += n
        }
        guard got == keyLength else { return .unreadable("\(got) bytes, not \(keyLength)") }
        return .key(Data(buf[0..<keyLength]))
    }

    /// Writes the key (creating the folder, 0700): to a new file made 0600 from the start, then moved into place.
    /// Nil when it was kept, else why not.
    public static func save(_ key: Data, to url: URL) -> String? {
        guard key.count == keyLength else { return "a key of \(key.count) bytes" }
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            do { try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { return "can't make \(dir.path): \(error)" }
            _ = chmod(dir.path, 0o700)
        }
        let temp = dir.appendingPathComponent(".pad-key-\(getpid())-\(UInt32.random(in: 0...UInt32.max))").path
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return "can't write \(temp): \(String(cString: strerror(errno)))" }
        _ = fchmod(fd, 0o600)
        var ok = true
        key.withUnsafeBytes { raw in
            var at = 0
            while at < raw.count {
                let n = write(fd, raw.baseAddress! + at, raw.count - at)
                if n <= 0 { ok = false; return }
                at += n
            }
        }
        if ok && fsync(fd) != 0 { ok = false }
        _ = close(fd)
        guard ok, rename(temp, url.path) == 0 else {
            let why = String(cString: strerror(errno))
            _ = unlink(temp)
            return "can't write \(url.path): \(why)"
        }
        return nil
    }
}
