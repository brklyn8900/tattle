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
    private let socketTable: @Sendable () throws -> [SocketEntry]
    private let signature: @Sendable (String) -> CodeSignature?
    private var tracker = ConnectionTracker()
    private var owners: [Int32: ConnectionOwner] = [:]
    private var known = Set<String>()
    private var names = PendingNames()
    /// What a name is, by the knowledge base, looked up once per name and dropped when a
    /// rule is written, or when there are `kindCapacity` of them.
    private var kinds: [String: ConnectionName.Kind] = [:]
    private var kindsRevision = 0
    /// Flow events the mailbox dropped, in all and since the log last said so.
    private(set) var eventsDropped = 0
    private var unreportedDrops = 0
    private var lastDropReport = Date.distantPast
    private var lastTouch = Date.distantPast
    private var lastPrune = Date.distantPast
    private var task: Task<Void, Never>?
    private var sniffer: Sniffer?
    private var isPolling = false
    private var pollRequested = false
    private var promptPollScheduled = false
    private let processRecords: @Sendable () -> ProcessRecords?
    private let makeSniffer: SnifferFactory

    /// Builds the sniffer from where its events and its status go; a test gives one a capture
    /// of its own.
    typealias SnifferFactory = (_ onEvents: @escaping @Sendable ([FlowEvent]) -> Void, _ onStatus: @escaping @Sendable (Sniffer.Status) -> Void) -> Sniffer

    /// The most names whose kind is remembered. Whoever sends a handshake picks its name, so
    /// names arrive without limit; past this many the memo starts again.
    static let kindCapacity = 4096

    /// The most flow events handled in one turn of the main actor, so that whatever else
    /// waits for it, the panel included, waits for no more than these.
    static let eventBatch = 64

    /// How soon after a flow opens the socket table is read for its owner.
    static let promptPollDelay: Duration = .milliseconds(20)

    init(store: ConnectionStore, rules: RuleStore, settings: AppSettings,
         socketTable: @escaping @Sendable () throws -> [SocketEntry] = { try SocketTable.read() },
         processRecords: @escaping @Sendable () -> ProcessRecords? = { ProcessTable.records() },
         signature: (@Sendable (String) -> CodeSignature?)? = nil,
         sniffer: @escaping SnifferFactory = { Sniffer(onEvents: $0, onStatus: $1) }) {
        makeSniffer = sniffer
        self.store = store
        self.rules = rules
        self.settings = settings
        self.socketTable = socketTable
        self.processRecords = processRecords
        let signatures = SignatureCache()
        self.signature = signature ?? { signatures.signature(at: $0) }
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
        let mailbox = FlowEventMailbox()
        let sniffer = makeSniffer(
            { [weak self] events in
                if mailbox.add(events) { Task { @MainActor in await self?.drain(mailbox) } }
            },
            { [weak self] status in Task { @MainActor in self?.captureStatus = status } })
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
    /// a view so that the install and its outcome do not depend on the panel being open.
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

    /// How much is held of what the sniffer reported: outcomes and openings waiting for their
    /// connections, and names whose kind is remembered.
    var held: (outcomes: Int, openings: Int, kinds: Int) { (names.count, names.openingCount, kinds.count) }

    // MARK: Sniffer events

    /// Handles what the mailbox holds, a batch a turn, until it is empty.
    private func drain(_ mailbox: FlowEventMailbox) async {
        while let next = mailbox.take(Self.eventBatch) {
            eventsDropped += next.dropped
            unreportedDrops += next.dropped
            // Once a second at most: a flood drops events at every batch.
            if Date().timeIntervalSince(lastDropReport) >= 1 { reportDrops() }
            handle(next.events)
            await Task.yield()
        }
        // The mailbox is empty, so the flood is over or has paused: say what is still unsaid.
        reportDrops()
    }

    private func reportDrops() {
        guard unreportedDrops > 0 else { return }
        Log.sniffer.notice("dropped \(self.unreportedDrops) flow events that arrived faster than they were handled; their connections go without a name")
        unreportedDrops = 0
        lastDropReport = Date()
    }

    private func handle(_ events: [FlowEvent]) {
        let now = Date()
        for (flow, outcome, openedAt) in names.apply(events, at: now, kind: { kind(of: $0, source: $1) }) {
            if let reason = outcome.reason {
                Log.sniffer.debug("no name for \(flow.text, privacy: .public): \(String(describing: reason), privacy: .public)")
            }
            attach(outcome, to: flow, openedAt: openedAt)
        }
        for event in events where event.kind == .opened { confirmOutbound(event.key, openedAt: now) }
        if events.contains(where: { $0.kind == .opened }) { schedulePromptPoll() }
    }

    /// A seen opening settles the direction of a connection the socket table already showed.
    /// One a reading has yet to publish is left to that reading, which reads the tracker.
    func confirmOutbound(_ flow: FlowKey, openedAt: Date) {
        for connection in tracker.confirmOutbound(flow: flow, openedAt: openedAt) {
            guard snapshot?.connections.contains(where: { $0.id == connection.id }) == true else { continue }
            let isNew = LiveConnection.isFirstContact(connection, known: &known)
            if var snapshot, snapshot.confirmOutbound(id: connection.id, isNew: isNew) { self.snapshot = snapshot }
            do {
                try store.setOutbound(key: connection.id)
            } catch {
                Log.app.error("connection direction write failed: \(error, privacy: .public)")
            }
        }
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
        // Only the shipped rules say what a name is, so the file is not read: a model's
        // answer is free text, and a row another process wrote there could fail the lookup.
        let candidates: [Rule]
        do {
            candidates = try rules.shippedCandidates(kind: .host, key: name)
        } catch {
            // Not remembered: a lookup that failed says nothing about the name.
            Log.app.error("rule lookup for a connection's name failed: \(error, privacy: .public)")
            return .destination
        }
        let category = candidates.first?.category
        let kind = ConnectionName.kind(forCategory: category)
        if kinds.count >= Self.kindCapacity { kinds = [:] }
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
            await poll()
        }
    }

    // MARK: Polling

    /// One reading of the socket table. Readings never overlap: a reading that would
    /// have, runs after the current one, so an older table is never folded in after a
    /// newer one and closes connections that are still there. Tests take their readings here,
    /// under the same rule.
    func poll() async {
        guard !isPolling else {
            pollRequested = true
            return
        }
        isPolling = true
        await read()
        isPolling = false
        if pollRequested {
            pollRequested = false
            await poll()
        }
    }

    /// Reads the socket table and, in the same moment, the lines of the owners to resolve: a
    /// process can exit within milliseconds of opening a connection, so its line is read before
    /// the main actor or any signature read can hold it up.
    private func read() async {
        let now = Date()
        // Readings never overlap, so the tracker and the owners are as the fold will find them.
        let (socketTable, processRecords, owners, tracker) = (socketTable, processRecords, owners, tracker)
        let reading: (entries: [SocketEntry], unresolved: Set<Int32>, lines: ProcessLines?)
        do {
            reading = try await Task.detached(priority: .utility) {
                let entries = try socketTable()
                let opened = tracker.openingPids(entries)
                guard !opened.isEmpty else { return (entries, [], ProcessLines()) }
                let records = processRecords()
                let unresolved = ConnectionOwner.unresolved(opened: opened, known: owners, executable: ProcessTable.pidPath, commandName: ProcessTable.commandName)
                return (entries, unresolved, records?.lines(unresolved))
            }.value
        } catch {
            self.error = String(describing: error)
            return
        }
        await fold(entries: reading.entries, unresolved: reading.unresolved, lines: reading.lines, now: now)
    }

    /// Takes one reading of the table into the tracker, the history and the snapshot.
    private func fold(entries: [SocketEntry], unresolved: Set<Int32>, lines: ProcessLines?, now: Date) async {
        let changes = tracker.update(entries: entries, at: now, outboundSeen: { names.openingSeen($0, at: now) })

        // Owners are resolved once per pid and executable, off the main thread, from the lines
        // read with the table. A pid whose connections all closed is forgotten so a reused pid
        // is resolved afresh.
        if !unresolved.isEmpty {
            let signature = signature
            let resolved = await Task.detached(priority: .utility) { () -> [Int32: ConnectionOwner] in
                // With no lines, none of these is known to have exited.
                guard let lines else { return Dictionary(uniqueKeysWithValues: unresolved.map { ($0, .unknown) }) }
                var result: [Int32: ConnectionOwner] = [:]
                for pid in unresolved {
                    result[pid] = ConnectionOwner.resolve(
                        pid: pid, in: lines.entries,
                        runningApp: { NSRunningApplication(processIdentifier: $0)?.bundleURL?.path },
                        responsible: { lines.responsible[$0] },
                        signature: signature)
                }
                return result
            }.value
            owners.merge(resolved) { _, new in new }
        }

        var opened: [LiveConnection] = []
        for reading in changes.opened {
            // An opening seen while the owners were resolved has settled the tracker's copy.
            let connection = tracker.live[reading.id] ?? reading
            let owner = owners[connection.pid] ?? .unknown
            let isNew = LiveConnection.isFirstContact(connection, known: &known)
            opened.append(LiveConnection(connection: connection, owner: owner, isNew: isNew, outcome: names.outcome(for: connection)))
        }
        record(opened: opened, closed: changes.closed, now: now)

        let openPids = Set(tracker.live.values.map(\.pid))
        owners = owners.filter { openPids.contains($0.key) }
        names.prune(now: now, keeping: Set(tracker.live.values.map(\.flowKey)))

        // Keep each live row's "new" mark and name from when it opened; a row with no outcome
        // yet takes the one waiting for its connection.
        let previous = Dictionary((snapshot?.connections ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let live = tracker.open.map { connection in
            let before = previous[connection.id] ?? opened.first { $0.id == connection.id }
            return LiveConnection(connection: connection,
                                  owner: before?.owner ?? owners[connection.pid] ?? .unknown,
                                  isNew: before?.isNew ?? false,
                                  outcome: before?.outcome ?? names.outcome(for: connection))
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
