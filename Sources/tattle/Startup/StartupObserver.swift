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
/// modification date.
final class SignatureCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: (modified: Date?, signature: CodeSignature)] = [:]

    func signature(at path: String) -> CodeSignature? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let hit = lock.withLock({ cache[path] }), hit.modified == modified { return hit.signature }
        let signature = CodeSignature.read(path: path)
        lock.withLock { cache[path] = (modified, signature) }
        return signature
    }
}
