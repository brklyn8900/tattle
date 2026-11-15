import Foundation
import Observation

/// Loads the Startup tab's snapshot off the main thread and caches signatures by path.
@MainActor @Observable
final class StartupObserver {
    private(set) var snapshot: StartupSnapshot?
    private(set) var isLoading = false
    private let signatures = SignatureCache()

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let signatures = signatures
        snapshot = await Task.detached(priority: .userInitiated) { () -> StartupSnapshot in
            let launchd = LaunchdReader().read()
            var loginItems: [LoginItem] = []
            var loginItemsError: String?
            var needsFullDiskAccess = false
            do {
                loginItems = try LoginItemsDatabase.readCurrent().items
            } catch LoginItemsDatabase.ReadError.cannotList(let reason) {
                loginItemsError = "Login items need Full Disk Access: \(reason)"
                needsFullDiskAccess = true
            } catch {
                loginItemsError = "Login items could not be read: \(error)"
            }
            if let loginItemsError { Log.app.error("\(loginItemsError, privacy: .public)") }
            let state = LaunchctlState.read()
            var snapshot = StartupSnapshot.build(
                launchd: launchd, loginItems: loginItems, state: state, signature: signatures.signature(at:))
            snapshot.loginItemsError = loginItemsError
            snapshot.loginItemsNeedFullDiskAccess = needsFullDiskAccess
            return snapshot
        }.value
    }
}

/// Signature reads cost up to a tenth of a second per app, so each path is read once per
/// version of what its reading rests on: the path, and the files and folders the reading names.
///
/// A process's signature is its file's only while the file is the code it runs
/// (`signature(of:at:)`), which is checked once per process, code and version of the file.
final class SignatureCache: @unchecked Sendable {
    private struct Entry {
        var files: [String]
        var versions: [FileVersion?]
        var signature: CodeSignature
    }

    /// Whether a process ran what its file held, for the code the kernel said it ran and the
    /// versions of the files the signature was read from.
    private struct Verdict {
        var code: RunningCode.State
        var versions: [FileVersion?]
        var matches: Bool
    }

    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    private var verdicts: [Int32: Verdict] = [:]
    /// How many verdicts are kept before those of processes that have ended are dropped.
    private var verdictLimit = 1024
    private let files: @Sendable (String) -> [String]
    private let read: @Sendable (String) -> CodeSignature.Reading
    private let running: @Sendable (Int32) -> RunningCode.State?
    private let matchesFile: @Sendable (Int32) -> Bool

    init(
        files: @escaping @Sendable (String) -> [String] = { CodeSignature.files(readAt: $0) },
        read: @escaping @Sendable (String) -> CodeSignature.Reading = { CodeSignature.reading(path: $0) },
        running: @escaping @Sendable (Int32) -> RunningCode.State? = { RunningCode.state(of: $0) },
        matchesFile: @escaping @Sendable (Int32) -> Bool = { RunningCode.matchesFile($0) }
    ) {
        self.files = files
        self.read = read
        self.running = running
        self.matchesFile = matchesFile
    }

    func signature(at path: String) -> CodeSignature? { reading(at: path).entry.signature }

    /// A process's signature as read. Not settled when the file or the process changed while
    /// they were read: the signature may not be the file's as it now is, and where nothing
    /// could say whether the file is the code the process runs there is none. The next
    /// reading may differ, so this one is not to be kept.
    struct ProcessReading: Sendable {
        var signature: CodeSignature?
        var isSettled = true
        /// The file was checked and is not the code the process runs, which is why the reading
        /// has no signature: not that none was read or that the reading did not settle.
        var differsFromFile = false
    }

    /// The signature of the process `pid`, whose executable the kernel names as `path`: the
    /// file's, or nil when the file does not vouch for the process, because it is not the code
    /// the process runs. Only a file that names a signer is checked, and only outside the
    /// folders macOS alone installs into, where no one else can change a file: anywhere else
    /// a running program can rename a signed file over its own, and would read as its signer.
    /// An app updated in place fails the same way until it is started again.
    func signature(of pid: Int32, at path: String) -> CodeSignature? { reading(of: pid, at: path).signature }

    func reading(of pid: Int32, at path: String) -> ProcessReading {
        let (entry, isSettled) = reading(at: path)
        guard entry.signature.namesSigner, !ApplesProgram.isInstalled(at: path) else {
            return ProcessReading(signature: entry.signature, isSettled: isSettled)
        }
        guard let runs = runs(pid, entry, isSettled: isSettled, at: path) else { return ProcessReading(isSettled: false) }
        // A process that has ended reads as its file whether or not the file's reading settled.
        return ProcessReading(signature: runs ? entry.signature : nil, isSettled: isSettled, differsFromFile: !runs)
    }

    /// The signature at `path`, with the files it rests on and their versions from before it
    /// was read. Not settled when they changed while it was read.
    private func reading(at path: String) -> (entry: Entry, isSettled: Bool) {
        if let hit = lock.withLock({ cache[path] }), hit.versions == Self.versions(of: path, hit.files) { return (hit, true) }
        // The versions are taken before the read and again after it, of the files named before
        // it: a reading is kept only when it names the same files and none of them changed in
        // between, since what changed while it was read may not be what was read.
        let files = files(path).filter { $0 != path }
        let versions = Self.versions(of: path, files)
        let reading = read(path)
        let entry = Entry(files: files, versions: versions, signature: reading.signature)
        let isSettled = reading.files.filter { $0 != path } == files && versions == Self.versions(of: path, files)
        lock.withLock { cache[path] = isSettled ? entry : nil }
        return (entry, isSettled)
    }

    /// Whether the process runs the code `entry` was read from, nil when the file or the
    /// process changed while they were read. The answer is about the pair,
    /// the running code and the file: after a rename over the path the pid, its start time and
    /// its code are as they were and only the file differs, and a process that starts another
    /// program keeps its pid. So it is kept for the code the kernel says the process runs
    /// together with the versions of the files, and counts only when neither changed while the
    /// check was made: what changed meanwhile may not be what was checked. A process that has
    /// ended runs nothing, and reads as its file does.
    private func runs(_ pid: Int32, _ entry: Entry, isSettled: Bool, at path: String) -> Bool? {
        guard let code = running(pid) else { return true }
        guard isSettled, code.path == path else { return nil }
        // Unsigned code is not a file that names a signer, and with no hash for it a check
        // would be made every time.
        if code.isUnsigned { return false }
        // Without the kernel's hash nothing says the code is the code last checked.
        if code.hash != nil, let kept = lock.withLock({ verdicts[pid] }), kept.code == code, kept.versions == entry.versions {
            return kept.matches
        }
        let matches = matchesFile(pid)
        guard let after = running(pid) else { return true }
        guard after == code, Self.versions(of: path, entry.files) == entry.versions else { return nil }
        if code.hash != nil { keep(Verdict(code: code, versions: entry.versions, matches: matches), for: pid) }
        return matches
    }

    private func keep(_ verdict: Verdict, for pid: Int32) {
        lock.withLock {
            verdicts[pid] = verdict
            guard verdicts.count > verdictLimit else { return }
            verdicts = verdicts.filter { running($0.key) != nil }
            verdictLimit = max(verdictLimit, 2 * verdicts.count)
        }
    }

    private static func versions(of path: String, _ files: [String]) -> [FileVersion?] {
        ([path] + files).map { FileVersion(path: $0) }
    }
}
