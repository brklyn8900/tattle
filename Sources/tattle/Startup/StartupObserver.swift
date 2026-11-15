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
/// version of the files its reading rests on.
final class SignatureCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: (version: [FileVersion?], signature: CodeSignature)] = [:]
    private let read: @Sendable (String) -> CodeSignature

    init(read: @escaping @Sendable (String) -> CodeSignature = { CodeSignature.read(path: $0) }) {
        self.read = read
    }

    func signature(at path: String) -> CodeSignature? {
        guard let version = Self.version(of: path) else { return read(path) }
        if let hit = lock.withLock({ cache[path] }), hit.version == version { return hit.signature }
        let signature = read(path)
        lock.withLock { cache[path] = (version, signature) }
        return signature
    }

    /// The files a reading at `path` rests on, each at its version. A file's reading rests on
    /// the file. A bundle's is made from its main executable, its Info.plist and the seal over
    /// its resources, and writing over one of them leaves the folder's own dates as they
    /// were, so each counts beside the folder. Every file in `Contents/MacOS` does, which
    /// saves reading the Info.plist to learn which is the main executable. Nil for a folder
    /// laid out any other way: where those files are is not known, so its reading is made
    /// every time.
    private static func version(of path: String) -> [FileVersion?]? {
        let folder = FileVersion(path: path)
        guard let folder, folder.isDirectory else { return [folder] }
        let contents = path + "/Contents"
        guard let executables = try? FileManager.default.contentsOfDirectory(atPath: contents + "/MacOS") else { return nil }
        let files = [contents, contents + "/Info.plist", contents + "/_CodeSignature/CodeResources", contents + "/MacOS"]
            + executables.sorted().map { contents + "/MacOS/" + $0 }
        return [folder] + files.map { FileVersion(path: $0) }
    }
}
