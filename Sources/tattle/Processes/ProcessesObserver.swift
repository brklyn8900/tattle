import AppKit
import Foundation
import Observation

/// Reads the process table on demand and keeps the previous snapshot for CPU shares.
@MainActor @Observable
final class ProcessesObserver {
    private(set) var snapshot: ProcessSnapshot?
    private(set) var error: String?
    private(set) var isLoading = false
    private let signatures = SignatureCache()

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let signatures = signatures
        let previous = snapshot
        let result = await Task.detached(priority: .userInitiated) { () -> Result<ProcessSnapshot, Error> in
            do {
                let entries = try ProcessTable.read()
                return .success(ProcessSnapshot.build(
                    entries: entries, previous: previous,
                    signature: signatures.signature(at:), runningApp: Self.runningAppBundle(pid:)))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let snapshot):
            self.snapshot = snapshot
            error = nil
        case .failure(let failure):
            error = String(describing: failure)
            Log.app.error("process snapshot failed: \(failure, privacy: .public)")
        }
    }

    /// The bundle Launch Services opened a pid from; nil for anything that is not an app.
    nonisolated private static func runningAppBundle(pid: Int32) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleURL?.path
    }
}
