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
/// version of the files its reading rests on: the path, and the files the reading names.
final class SignatureCache: @unchecked Sendable {
    private struct Entry {
        var files: [String]
        var versions: [FileVersion?]
        var signature: CodeSignature
    }

    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    private let read: @Sendable (String) -> CodeSignature.Reading

    init(read: @escaping @Sendable (String) -> CodeSignature.Reading = { CodeSignature.reading(path: $0) }) {
        self.read = read
    }

    func signature(at path: String) -> CodeSignature? {
        let own = FileVersion(path: path)
        if let hit = lock.withLock({ cache[path] }), hit.versions == [own] + hit.files.map({ FileVersion(path: $0) }) { return hit.signature }
        let started = Self.now()
        let reading = read(path)
        let files = reading.files.filter { $0 != path }
        let versions = files.map { FileVersion(path: $0) }
        let finished = Self.now()
        // The path's version was taken before the read, so a change to it during the read is
        // read again. The other files are known only from the read: one that is gone, or that
        // changed while the read ran, may not be what was read, so that reading is not kept.
        let isSettled = versions.allSatisfy { $0?.changed(from: started, to: finished) == false }
        lock.withLock { cache[path] = isSettled ? Entry(files: files, versions: [own] + versions, signature: reading.signature) : nil }
        return reading.signature
    }

    private static func now() -> timespec {
        var time = timespec()
        clock_gettime(CLOCK_REALTIME, &time)
        return time
    }
}
