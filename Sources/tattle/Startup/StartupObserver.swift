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
            do {
                loginItems = try LoginItemsDatabase.readCurrent().items
            } catch LoginItemsDatabase.ReadError.cannotList(let reason) {
                loginItemsError = "Login items need Full Disk Access: \(reason)"
            } catch {
                loginItemsError = "Login items could not be read: \(error)"
            }
            if let loginItemsError { Log.app.error("\(loginItemsError, privacy: .public)") }
            let state = LaunchctlState.read()
            var snapshot = StartupSnapshot.build(
                launchd: launchd, loginItems: loginItems, state: state, signature: signatures.signature(at:))
            snapshot.loginItemsError = loginItemsError
            return snapshot
        }.value
    }
}

/// Signature reads cost up to a tenth of a second per app, so each path is read once per
/// version of the file.
final class SignatureCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: (version: FileVersion?, signature: CodeSignature)] = [:]
    private let read: @Sendable (String) -> CodeSignature

    init(read: @escaping @Sendable (String) -> CodeSignature = { CodeSignature.read(path: $0) }) {
        self.read = read
    }

    func signature(at path: String) -> CodeSignature? {
        let version = FileVersion(path: path)
        if let hit = lock.withLock({ cache[path] }), hit.version == version { return hit.signature }
        let signature = read(path)
        lock.withLock { cache[path] = (version, signature) }
        return signature
    }
}
