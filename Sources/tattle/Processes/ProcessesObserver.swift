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
    private var isContinuingReadings = false

    /// Starts a new run of readings, when the list comes on screen. Its first reading shows no
    /// CPU: against the last reading of the previous run it would be an average over the gap.
    func beginReadings() {
        isContinuingReadings = false
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let signatures = signatures
        let previous = snapshot
        let continuesPrevious = isContinuingReadings
        let result = await Task.detached(priority: .userInitiated) { () -> Result<ProcessSnapshot, Error> in
            do {
                let entries = try ProcessTable.read(signature: signatures.signature(of:at:))
                return .success(ProcessSnapshot.build(
                    entries: entries, previous: previous, continuesPrevious: continuesPrevious,
                    signature: signatures.signature(at:), executable: signatures.signature(of:at:),
                    runningApp: Self.runningAppBundle(pid:)))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let snapshot):
            self.snapshot = snapshot
            isContinuingReadings = true
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
