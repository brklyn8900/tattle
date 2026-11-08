import CryptoKit
import Foundation

/// The SHA-256 of the files identities rest on (`CodeIdentity.contentFile`), each read once per
/// version of the file. Only the explain step asks, for an answer looked up for an open detail
/// or being stored, so a poll reads no file's content.
///
/// A read runs off the main thread and to its end even if the detail has moved on: a detail's
/// request changes at every refresh, sooner than a large file takes to read.
@MainActor
final class FileDigests {
    private var known: [String: (version: [Int], digest: Task<String?, Never>)] = [:]
    private let read: @Sendable (String) -> String?

    init(read: @escaping @Sendable (String) -> String? = FileDigests.sha256(of:)) {
        self.read = read
    }

    /// Nil for anything but a regular file that can be read.
    func digest(of path: String) async -> String? {
        guard let version = Self.version(of: path) else { return nil }
        if let known = known[path], known.version == version { return await known.digest.value }
        let read = read
        let digest = Task.detached(priority: .utility) { read(path) }
        known[path] = (version, digest)
        return await digest.value
    }

    /// What differs between two versions of a file. Anyone can set a modification date back;
    /// the change time and the inode are the system's.
    private static func version(of path: String) -> [Int]? {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return [Int(info.st_dev), Int(info.st_ino), Int(info.st_size), info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec,
                info.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec]
    }

    /// Through one buffer, so a large file costs time and no memory. Opened without blocking:
    /// the path can become a pipe after the check, and opening a pipe waits for a writer.
    nonisolated static func sha256(of path: String) -> String? {
        let file = open(path, O_RDONLY | O_NONBLOCK)
        guard file >= 0 else { return nil }
        defer { close(file) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
