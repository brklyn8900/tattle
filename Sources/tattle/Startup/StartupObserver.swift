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
final class SignatureCache: @unchecked Sendable {
    private struct Entry {
        var files: [String]
        var versions: [FileVersion?]
        var signature: CodeSignature
    }

    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    private let files: @Sendable (String) -> [String]
    private let read: @Sendable (String) -> CodeSignature.Reading

    init(
        files: @escaping @Sendable (String) -> [String] = { CodeSignature.files(readAt: $0) },
        read: @escaping @Sendable (String) -> CodeSignature.Reading = { CodeSignature.reading(path: $0) }
    ) {
        self.files = files
        self.read = read
    }

    func signature(at path: String) -> CodeSignature? {
        if let hit = lock.withLock({ cache[path] }), hit.versions == Self.versions(of: path, hit.files) { return hit.signature }
        // The versions are taken before the read and again after it, of the files named before
        // it: a reading is kept only when it names the same files and none of them changed in
        // between, since what changed while it was read may not be what was read.
        let files = files(path).filter { $0 != path }
        let versions = Self.versions(of: path, files)
        let reading = read(path)
        let isSettled = reading.files.filter { $0 != path } == files && versions == Self.versions(of: path, files)
        lock.withLock { cache[path] = isSettled ? Entry(files: files, versions: versions, signature: reading.signature) : nil }
        return reading.signature
    }

    private static func versions(of path: String, _ files: [String]) -> [FileVersion?] {
        ([path] + files).map { FileVersion(path: $0) }
    }
}
