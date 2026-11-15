import Darwin
import Foundation
import Security

/// The code a process runs, against the file at its path. A signature is read from that file
/// (`CodeSignature.reading`), and the file can change under a running process: a program can
/// rename a publisher's signed binary over its own path, and an update replaces the file of an
/// app that is still open. Either way the file's signer did not sign what runs.
enum RunningCode {
    /// What the kernel holds of a process's code: the file it names for it, the hash of the
    /// code directory it loaded, and its code-signing status, which says among other things
    /// whether the code is still as it was signed. The hash and the status are nil for a
    /// process the kernel will not describe, the hash also for unsigned code.
    struct State: Equatable, Sendable {
        var path: String?
        var hash: Data?
        var status: UInt32?

        /// The kernel describes the process and holds no signature for its code. Told by the
        /// status and not by a missing hash, which the kernel may withhold for another reason.
        var isUnsigned: Bool { status.map { $0 & RunningCode.signedStatus == 0 } ?? false }
    }

    /// Nil once the process has ended, is a zombie, or is on its way out, when it runs
    /// nothing: the kernel still lists a process that is exiting, and says of its code that
    /// there is no such process. It can say so of the hash after it has given the status.
    static func state(of pid: Int32) -> State? {
        guard ProcessTable.commandName(pid) != nil else { return nil }
        let path = ProcessTable.pidPath(pid)
        // Without the call nothing tells a process on its way out from one whose file is gone.
        guard let csops else { return State(path: path) }
        var status: UInt32 = 0
        let hasStatus = csops(pid, statusOperation, &status, MemoryLayout<UInt32>.size) == 0
        guard hasStatus || errno != ESRCH else { return nil }
        var hash = [UInt8](repeating: 0, count: hashLength)
        let hasHash = csops(pid, hashOperation, &hash, hash.count) == 0
        guard hasHash || errno != ESRCH else { return nil }
        return State(path: path, hash: hasHash ? Data(hash) : nil, status: hasStatus ? status : nil)
    }

    /// Whether the file at the process's path is the code it runs: macOS finds the running
    /// code by pid and checks it against that file, at the slice the process loaded, and that
    /// the kernel still holds the code valid. A failure of either step is a no, whatever its
    /// code: a file renamed over the path fails the check as changed, over an unsigned
    /// program as invalid, and a file of another layout fails the lookup.
    static func matchesFile(_ pid: Int32) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], nil) == errSecSuccess
    }

    /// `csops`, the system call the kernel answers about a process's code signature with. It
    /// is in libSystem and in no SDK header, so it is resolved at run time: where it is
    /// missing no hash is read, and a check is made at every reading instead of being kept.
    private typealias Csops = @convention(c) (pid_t, UInt32, UnsafeMutableRawPointer?, Int) -> Int32
    private static let csops: Csops? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops").map { unsafeBitCast($0, to: Csops.self) }
    /// `CS_OPS_STATUS`, `CS_OPS_CDHASH` and `CS_CDHASH_LEN` in the kernel's `sys/codesign.h`.
    private static let statusOperation: UInt32 = 0
    private static let hashOperation: UInt32 = 5
    private static let hashLength = 20
    /// `CS_SIGNED` in the kernel's `kern/cs_blobs.h`: the process has a signature.
    static let signedStatus: UInt32 = 0x2000_0000
}
