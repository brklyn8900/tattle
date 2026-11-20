import AppKit
import Foundation
import Observation

/// Reads the process table on demand and keeps the previous snapshot for CPU shares.
///
/// A list is shown before every signature it names is read. Reading them all for the first
/// time takes tens of seconds; the table itself, and the signatures of macOS's own programs,
/// about one. So a reading does not wait for a signature not yet read: the process is listed
/// with its signer awaited (`SignatureCache.readingWithoutWaiting`), and the signatures are
/// then read one at a time in the order of the list, which is read again as they come in.
@MainActor @Observable
final class ProcessesObserver {
    private(set) var snapshot: ProcessSnapshot?
    private(set) var error: String?
    private(set) var isLoading = false
    /// The order the awaited signatures are read in: the list's, so its top settles first.
    var order = ProcessSnapshot.Sort.memory
    private let signatures = SignatureCache()
    private var isContinuingReadings = false
    private var reading: Task<Result<ProcessSnapshot, Error>, Never>?
    private var settling: Task<Void, Never>?
    private var settlingPriority = TaskPriority.background

    /// The shortest gap between two readings: a CPU share is not worked out over less
    /// (`ProcessSnapshot.build`), and the list would show none.
    private static let shortestGap: TimeInterval = 0.6

    /// Starts a new run of readings, when the list comes on screen. Its first reading shows no
    /// CPU: against the last reading of the previous run it would be an average over the gap.
    func beginReadings() {
        isContinuingReadings = false
    }

    /// Reads the list, and starts reading the signatures it awaits. While those are read the
    /// list is refreshed as they come in, so a call then does nothing, unless it is made at a
    /// higher priority than they are read at: the list on screen takes over from the reading
    /// made at launch.
    func refresh(priority: TaskPriority = .userInitiated) async {
        if settling != nil {
            guard priority > settlingPriority else { return }
            settling?.cancel()
            settling = nil
        }
        await read(priority: priority)
        settle(priority: priority)
    }

    /// Waits for the signatures the list awaits to be read.
    func settled() async {
        while let settling { await settling.value }
    }

    /// A caller that finds a reading under way waits for it, which lends that reading the
    /// caller's priority: the list on screen is not kept waiting by the reading made at launch.
    private func read(priority: TaskPriority) async {
        if let reading {
            _ = await reading.value
            return
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if isContinuingReadings, let last = snapshot?.takenAt {
            let wait = Self.shortestGap - Date().timeIntervalSince(last)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
        let signatures = signatures
        let previous = snapshot
        let continuesPrevious = isContinuingReadings
        let task = Task.detached(priority: priority) { () -> Result<ProcessSnapshot, Error> in
            do {
                let entries = try ProcessTable.read(signature: { signatures.readingWithoutWaiting(of: $0, at: $1).signature })
                return .success(ProcessSnapshot.build(
                    entries: entries, previous: previous, continuesPrevious: continuesPrevious,
                    signature: signatures.signatureWithoutWaiting(at:), executable: signatures.readingWithoutWaiting(of:at:),
                    awaits: signatures.awaits,
                    runningApp: Self.runningAppBundle(pid:)))
            } catch {
                return .failure(error)
            }
        }
        reading = task
        let result = await task.value
        reading = nil
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

    /// Reads the signatures the list awaits, in its order, and the list again as they come in:
    /// after a short first batch, so the rows at the top settle soon, then after longer ones,
    /// since each reading of the list costs what a refresh costs. Read for a list that is not
    /// on screen, they are read in one batch. One at a time, so the work is one core's.
    private func settle(priority: TaskPriority) {
        guard settling == nil, snapshot?.awaited(sortedBy: order).isEmpty == false else { return }
        settlingPriority = priority
        settling = Task(priority: priority) { [weak self] in
            let start = ContinuousClock.now
            var batch = priority >= .userInitiated ? Duration.milliseconds(600) : .seconds(3600)
            var read = 0
            while !Task.isCancelled, let self, let awaited = self.snapshot?.awaited(sortedBy: self.order), !awaited.isEmpty {
                let signatures = self.signatures
                let limit = batch
                let reading = Task.detached(priority: priority) { () -> Int in
                    let deadline = ContinuousClock.now + limit
                    var count = 0
                    for subject in awaited {
                        if count > 0, Task.isCancelled || ContinuousClock.now >= deadline { break }
                        if let pid = subject.pid {
                            _ = signatures.reading(of: pid, at: subject.path)
                        } else {
                            _ = signatures.signature(at: subject.path)
                        }
                        count += 1
                    }
                    return count
                }
                read += await withTaskCancellationHandler { await reading.value } onCancel: { reading.cancel() }
                if Task.isCancelled { return }
                await self.read(priority: priority)
                // A list that could not be read again awaits what it did: the next refresh tries.
                if self.snapshot?.awaited(sortedBy: self.order) == awaited { break }
                batch = min(batch * 2, .seconds(3))
            }
            guard !Task.isCancelled, let self else { return }
            self.settling = nil
            Log.app.info("read \(read) awaited signatures in \(String(describing: ContinuousClock.now - start), privacy: .public)")
        }
    }

    /// The bundle Launch Services opened a pid from; nil for anything that is not an app.
    nonisolated private static func runningAppBundle(pid: Int32) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleURL?.path
    }
}
