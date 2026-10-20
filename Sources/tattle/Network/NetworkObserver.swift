import AppKit
import Foundation
import Observation

/// Polls the socket table for the whole run, keeps history, and publishes the open
/// connections with their owners.
@MainActor @Observable
final class NetworkObserver {
    private(set) var snapshot: NetworkSnapshot?
    private(set) var error: String?

    private let store: ConnectionStore
    private let settings: AppSettings
    private let signatures = SignatureCache()
    private var tracker = ConnectionTracker()
    private var owners: [Int32: ConnectionOwner] = [:]
    private var known = Set<String>()
    private var lastTouch = Date.distantPast
    private var lastPrune = Date.distantPast
    private var task: Task<Void, Never>?

    init(store: ConnectionStore, settings: AppSettings) {
        self.store = store
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
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func poll() async {
        let now = Date()
        let entries: [SocketEntry]
        do {
            entries = try await Task.detached(priority: .utility) { try SocketTable.read() }.value
        } catch {
            self.error = String(describing: error)
            return
        }
        let changes = tracker.update(entries: entries, at: now)

        // Owners are resolved once per pid, from one process list per poll, off the main
        // thread; a pid whose connections all closed is forgotten so a reused pid is
        // resolved afresh.
        let unknown = Set(changes.opened.map(\.pid)).subtracting(owners.keys)
        if !unknown.isEmpty {
            let signatures = signatures
            let resolved = await Task.detached(priority: .utility) { () -> [Int32: ConnectionOwner] in
                guard let list = try? ProcessTable.list() else { return [:] }
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
            let isNew = !known.contains(connection.remoteAddress)
            known.insert(connection.remoteAddress)
            opened.append(LiveConnection(connection: connection, owner: owner, isNew: isNew))
        }
        record(opened: opened, closed: changes.closed, now: now)

        let openPids = Set(tracker.live.values.map(\.pid))
        owners = owners.filter { openPids.contains($0.key) }

        // Keep each live row's "new" mark from when it opened.
        let previous = Dictionary((snapshot?.connections ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let live = tracker.open.map { connection in
            LiveConnection(connection: connection,
                           owner: previous[connection.id]?.owner ?? owners[connection.pid] ?? .unknown,
                           isNew: previous[connection.id]?.isNew ?? opened.first { $0.id == connection.id }?.isNew ?? false)
        }
        snapshot = NetworkSnapshot(connections: live, takenAt: now)
    }

    private func record(opened: [LiveConnection], closed: [Connection], now: Date) {
        do {
            for live in opened {
                try store.open(ConnectionRecord(
                    live.connection, processName: live.owner.processName, appName: live.owner.app?.name,
                    appPath: live.owner.app?.path, signer: live.owner.signature?.summary))
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
