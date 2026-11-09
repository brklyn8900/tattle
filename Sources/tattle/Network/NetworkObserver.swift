import AppKit
import Foundation
import Observation

/// Polls the socket table for the whole run, keeps history, and publishes the open
/// connections with their owners and, when the sniffer has packet access, their names.
@MainActor @Observable
final class NetworkObserver {
    private(set) var snapshot: NetworkSnapshot?
    private(set) var error: String?
    private(set) var captureStatus: Sniffer.Status = .stopped
    /// Installing or removing the broker is under way: the administrator dialog is up.
    private(set) var accessBusy = false
    /// Why the last install or removal failed, until the next attempt.
    private(set) var accessError: String?
    /// What is installed against what this build would install; read again when Packet access
    /// opens and after every install or removal.
    private(set) var broker = CaptureBroker.status()

    private let store: ConnectionStore
    private let rules: RuleStore
    private let settings: AppSettings
    private let signatures = SignatureCache()
    private var tracker = ConnectionTracker()
    private var owners: [Int32: ConnectionOwner] = [:]
    private var known = Set<String>()
    private var names = PendingNames()
    /// What a name is, by the knowledge base, looked up once per name and dropped when a
    /// rule is written.
    private var kinds: [String: ConnectionName.Kind] = [:]
    private var kindsRevision = 0
    private var lastTouch = Date.distantPast
    private var lastPrune = Date.distantPast
    private var task: Task<Void, Never>?
    private var sniffer: Sniffer?
    private var isPolling = false
    /// A reading asked for while one was running, and whether it must be eager.
    private var pollRequested: Bool?
    private var promptPollScheduled = false

    /// Rule sources whose category may decide a connection's kind.
    private static let kindSources = SeedLoader.seedSources.union([.user])

    /// How soon after a flow opens the socket table is read for its owner.
    static let promptPollDelay: Duration = .milliseconds(20)

    init(store: ConnectionStore, rules: RuleStore, settings: AppSettings) {
        self.store = store
        self.rules = rules
        self.settings = settings
    }

    func start(every interval: Duration = .seconds(2)) {
        guard task == nil else { return }
        do {
            let stale = try store.closeStale()
            if stale > 0 { Log.app.info("closed \(stale) connections left open by the previous run") }
            known = try store.knownAddresses()
        } catch {
            self.error = String(describing: error)
            Log.app.error("connection history unavailable: \(error, privacy: .public)")
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: interval)
            }
        }
        let sniffer = Sniffer(
            onEvents: { events in Task { @MainActor [weak self] in self?.handle(events) } },
            onStatus: { status in Task { @MainActor [weak self] in self?.captureStatus = status } })
        sniffer.start()
        self.sniffer = sniffer
    }

    func stop() {
        task?.cancel()
        task = nil
        sniffer?.stop()
        sniffer = nil
    }

    /// Opens the capture again now, after the broker was installed or removed, instead
    /// of at the next retry.
    func restartCapture() {
        sniffer?.stop()
        sniffer?.start()
    }

    /// Installs the broker through the administrator dialog. Held here rather than in
    /// a view because the dialog takes focus, which closes the panel and its views.
    func installBroker() async -> Bool {
        await access { try CaptureBroker.install() }
    }

    func removeBroker() async -> Bool {
        await access { try CaptureBroker.remove() }
    }

    func refreshBroker() {
        broker = CaptureBroker.status()
    }

    private func access(_ action: @escaping @Sendable () throws -> Void) async -> Bool {
        guard !accessBusy else { return false }
        accessBusy = true
        accessError = nil
        defer {
            accessBusy = false
            refreshBroker()
        }
        do {
            try await Task.detached { try action() }.value
            restartCapture()
            return true
        } catch let error as CaptureBroker.InstallError {
            accessError = error.text
        } catch {
            accessError = error.localizedDescription
        }
        return false
    }

    // MARK: Sniffer events

    private func handle(_ events: [FlowEvent]) {
        for (flow, outcome, openedAt) in names.apply(events, at: Date(), kind: { kind(of: $0, source: $1) }) {
            if let reason = outcome.reason {
                Log.sniffer.debug("no name for \(flow.text, privacy: .public): \(String(describing: reason), privacy: .public)")
            }
            attach(outcome, to: flow, openedAt: openedAt)
        }
        if events.contains(where: { $0.kind == .opened }) { schedulePromptPoll() }
    }

    /// A name from a DNS reply is only a guess about the address and is attacker-influenced,
    /// so it is never a relay or cover name, whatever the knowledge base says of it.
    func kind(of name: String, source: NameSource) -> ConnectionName.Kind {
        if source == .dns { return .destination }
        if rules.revision != kindsRevision {
            kinds = [:]
            kindsRevision = rules.revision
        }
        if let kind = kinds[name] { return kind }
        // Only Tattle's own and the user's rules say what a name is. A model's answer is free
        // text, and a confirmed one outranks the seed in a plain lookup.
        let category = (try? rules.candidates(kind: .host, key: name))?
            .first { Self.kindSources.contains($0.source) }?.category
        let kind = ConnectionName.kind(forCategory: category)
        kinds[name] = kind
        return kind
    }

    /// Puts the outcome on the live row, if the socket table has shown the connection
    /// yet, and on its history record, which may already be closed.
    private func attach(_ outcome: NameOutcome, to flow: FlowKey, openedAt: Date) {
        if var snapshot, snapshot.attach(outcome, to: flow, openedAt: openedAt) {
            self.snapshot = snapshot
        } else {
            Log.sniffer.debug("outcome for \(flow.text, privacy: .public) arrived with no live connection")
        }
        do {
            try store.record(outcome, flow: flow, openedAt: openedAt)
        } catch {
            Log.app.error("connection name write failed: \(error, privacy: .public)")
        }
    }

    /// A connection just opened on the wire: read the socket table before it can close,
    /// once for a burst of them.
    private func schedulePromptPoll() {
        guard !promptPollScheduled else { return }
        promptPollScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: Self.promptPollDelay)
            guard let self else { return }
            promptPollScheduled = false
            await poll(eager: true)
        }
    }

    // MARK: Polling

    /// One reading of the socket table. Readings never overlap: a reading that would
    /// have, runs after the current one, so an older table is never folded in after a
    /// newer one and closes connections that are still there. An eager reading takes
    /// the process list in the same moment as the socket table, for a connection whose
    /// process may be gone by the time the owner is looked up.
    private func poll(eager: Bool = false) async {
        guard !isPolling else {
            pollRequested = (pollRequested ?? false) || eager
            return
        }
        isPolling = true
        await read(eager: eager)
        isPolling = false
        if let again = pollRequested {
            pollRequested = nil
            await poll(eager: again)
        }
    }

    private func read(eager: Bool) async {
        let now = Date()
        let entries: [SocketEntry]
        var processes: [ProcessEntry]?
        do {
            (entries, processes) = try await Task.detached(priority: .utility) {
                // Processes are listed without their signatures, since reading every one would
                // hold up the first poll; each owner's are read when it is resolved, once.
                (try SocketTable.read(), eager ? try? ProcessTable.list(signature: { _ in nil }) : nil)
            }.value
        } catch {
            self.error = String(describing: error)
            return
        }
        let changes = tracker.update(entries: entries, at: now)

        // Owners are resolved once per pid and executable, from one process list per poll, off
        // the main thread; a pid whose connections all closed is forgotten so a reused pid is
        // resolved afresh.
        let unknown = ConnectionOwner.unresolved(opened: Set(changes.opened.map(\.pid)), known: owners, executable: ProcessTable.pidPath, commandName: ProcessTable.commandName)
        if !unknown.isEmpty {
            let signatures = signatures
            let resolved = await Task.detached(priority: .utility) { [processes] () -> [Int32: ConnectionOwner] in
                guard let list = processes ?? (try? ProcessTable.list(signature: { _ in nil })) else { return [:] }
                let byPid = Dictionary(list.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
                var result: [Int32: ConnectionOwner] = [:]
                for pid in unknown {
                    result[pid] = ConnectionOwner.resolve(
                        pid: pid, in: byPid,
                        runningApp: { NSRunningApplication(processIdentifier: $0)?.bundleURL?.path },
                        signature: signatures.signature(at:))
                }
                return result
            }.value
            owners.merge(resolved) { _, new in new }
        }

        var opened: [LiveConnection] = []
        for connection in changes.opened {
            let owner = owners[connection.pid] ?? .unknown
            let isNew = LiveConnection.isFirstContact(connection, known: &known)
            opened.append(LiveConnection(connection: connection, owner: owner, isNew: isNew, outcome: names.outcome(for: connection.flowKey)))
        }
        record(opened: opened, closed: changes.closed, now: now)

        let openPids = Set(tracker.live.values.map(\.pid))
        owners = owners.filter { openPids.contains($0.key) }
        names.prune(now: now, keeping: Set(tracker.live.values.map(\.flowKey)))

        // Keep each live row's "new" mark and name from when it opened.
        let previous = Dictionary((snapshot?.connections ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let live = tracker.open.map { connection in
            let before = previous[connection.id] ?? opened.first { $0.id == connection.id }
            return LiveConnection(connection: connection,
                                  owner: before?.owner ?? owners[connection.pid] ?? .unknown,
                                  isNew: before?.isNew ?? false,
                                  outcome: before?.outcome ?? names.outcome(for: connection.flowKey))
        }
        snapshot = NetworkSnapshot(connections: live, takenAt: now)
    }

    private func record(opened: [LiveConnection], closed: [Connection], now: Date) {
        do {
            for live in opened {
                try store.open(ConnectionRecord(live))
            }
            for connection in closed {
                try store.close(key: connection.id, lastSeen: connection.lastSeen, ended: connection.ended ?? now)
            }
            if now.timeIntervalSince(lastTouch) > 60 {
                try store.touch(keys: Array(tracker.live.keys), at: now)
                lastTouch = now
            }
            if now.timeIntervalSince(lastPrune) > 3600 {
                let cutoff = now.addingTimeInterval(-Double(settings.retentionDays) * 86400)
                let pruned = try store.prune(endedBefore: cutoff)
                if pruned > 0 { Log.app.info("pruned \(pruned) connections older than \(self.settings.retentionDays) days") }
                lastPrune = now
            }
            error = nil
        } catch {
            self.error = String(describing: error)
            Log.app.error("connection history write failed: \(error, privacy: .public)")
        }
    }
}
