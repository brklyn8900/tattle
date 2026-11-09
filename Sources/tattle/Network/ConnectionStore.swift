import Foundation
import GRDB

/// One connection in history: the tracker's connection plus who made it, as known when
/// it opened. The name arrives from the sniffer later, if at all.
struct ConnectionRecord: Codable, Equatable, Identifiable, Sendable {
    var id: Int64?
    var key: String
    var proto: SocketEntry.Proto
    var pid: Int32
    var uid: UInt32
    var processName: String
    var appName: String?
    var appPath: String?
    /// Who signed the process.
    var signer: String?
    /// Who signed the app it is filed under.
    var appSigner: String?
    var localPort: UInt16
    var remoteAddress: String
    var remotePort: UInt16
    var isIPv6: Bool
    var scope: Connection.Scope
    var firstSeen: Date
    var lastSeen: Date
    var ended: Date?
    var preExisting: Bool
    var direction: Connection.Direction
    var name: String?
    var nameSource: String?

    init(_ connection: Connection, processName: String, appName: String? = nil, appPath: String? = nil, signer: String? = nil, appSigner: String? = nil) {
        key = connection.id
        proto = connection.proto
        pid = connection.pid
        uid = connection.uid
        self.processName = processName
        self.appName = appName
        self.appPath = appPath
        self.signer = signer
        self.appSigner = appSigner
        localPort = connection.localPort
        remoteAddress = connection.remoteAddress
        remotePort = connection.remotePort
        isIPv6 = connection.isIPv6
        scope = connection.scope
        firstSeen = connection.firstSeen
        lastSeen = connection.lastSeen
        ended = connection.ended
        preExisting = connection.preExisting
        direction = connection.direction
    }
}

extension ConnectionRecord {
    init(_ live: LiveConnection) {
        self.init(live.connection, processName: live.owner.processName, appName: live.owner.app?.name, appPath: live.owner.app?.path,
                  signer: live.owner.signature?.summary, appSigner: live.owner.appSignature?.summary)
        name = live.name?.name
        nameSource = live.name?.source.rawValue ?? live.unnamedReason?.code
    }
}

extension SocketEntry.Proto: Codable {}
extension Connection.Scope: Codable {}

extension ConnectionRecord: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "connection"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Connection history: what talked to what, kept for the retention period.
struct ConnectionStore: Sendable {
    let database: AppDatabase

    @discardableResult
    func open(_ record: ConnectionRecord) throws -> ConnectionRecord {
        try database.writer.write { db in
            var record = record
            try record.insert(db)
            return record
        }
    }

    /// Marks the open row for `key` ended. The connection may have ended any time since
    /// it was last seen, so `ended` is the poll that noticed, and `lastSeen` the one before.
    func close(key: String, lastSeen: Date, ended: Date) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE connection SET lastSeen = ?, ended = ? WHERE key = ? AND ended IS NULL",
                arguments: [lastSeen, ended, key])
        }
    }

    /// A poll already under way when a flow opened can record its connection this much
    /// earlier than the open; an older connection on the same four-tuple ended long before.
    static let openedSlack: TimeInterval = 3

    /// Whether a connection, live row or history row, is the one a flow that opened at
    /// `openedAt` belongs to. One first seen earlier is an older connection on the same
    /// four-tuple that the socket table has not yet shown closed. The exception is a UDP
    /// socket still open. A second QUIC connection on a kept port is the same socket table
    /// entry, so its outcome renames the row.
    static func isConnection(of flow: FlowKey, firstSeen: Date, isOpen: Bool, openedAt: Date) -> Bool {
        firstSeen >= openedAt.addingTimeInterval(-openedSlack) || (flow.proto == .udp && isOpen)
    }

    /// Records the sniffer's outcome on the newest row of the flow, open or not: a short
    /// connection may have closed by the time its name arrives. Only a row `isConnection`
    /// accepts is the flow's: an outcome that arrives before the poll adds the row waits in
    /// PendingNames instead of landing on an older connection's row. An unnamed outcome
    /// keeps its reason in the name source column, prefixed so it is never read as a
    /// source. An IPv6 socket talking IPv4 recorded a mapped address; the flow carries the
    /// plain one.
    func record(_ outcome: NameOutcome, flow: FlowKey, openedAt: Date) throws {
        let name: String?
        let source: String
        switch outcome {
        case .named(let found):
            name = found.name
            source = found.source.rawValue
        case .unnamed(let reason):
            name = nil
            source = reason.code
        }
        try database.writer.write { db in
            let rows = try ConnectionRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM connection
                    WHERE proto = ? AND localPort = ? AND remotePort = ?
                      AND (remoteAddress = ? OR remoteAddress = '::ffff:' || ?)
                    ORDER BY id DESC
                    """,
                arguments: [flow.proto == .tcp ? "tcp" : "udp", flow.localPort, flow.remotePort, flow.remote.text, flow.remote.text])
            guard let id = rows.first(where: {
                Self.isConnection(of: flow, firstSeen: $0.firstSeen, isOpen: $0.ended == nil, openedAt: openedAt)
            })?.id else { return }
            try db.execute(sql: "UPDATE connection SET name = ?, nameSource = ? WHERE id = ?", arguments: [name, source, id])
        }
    }

    /// Marks the open row for `key` as this Mac reaching out, once its opening is seen.
    func setOutbound(key: String) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE connection SET direction = 'outbound' WHERE key = ? AND ended IS NULL", arguments: [key])
        }
    }

    /// Refreshes last-seen for connections still open, so a long one keeps its duration
    /// if the app stops uncleanly.
    func touch(keys: [String], at date: Date) throws {
        guard !keys.isEmpty else { return }
        try database.writer.write { db in
            for key in keys {
                try db.execute(sql: "UPDATE connection SET lastSeen = ? WHERE key = ? AND ended IS NULL", arguments: [date, key])
            }
        }
    }

    /// Rows left open by a previous run end at their last-seen time. Called at startup
    /// before the first poll. Returns how many.
    @discardableResult
    func closeStale() throws -> Int {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE connection SET ended = lastSeen WHERE ended IS NULL")
            return db.changesCount
        }
    }

    /// Deletes connections that ended before `cutoff`. Returns how many went.
    @discardableResult
    func prune(endedBefore cutoff: Date) throws -> Int {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM connection WHERE COALESCE(ended, lastSeen) < ?", arguments: [cutoff])
            return db.changesCount
        }
    }

    /// Every address this Mac has reached: what "first contact" is measured against.
    func knownAddresses() throws -> Set<String> {
        try database.writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT DISTINCT remoteAddress FROM connection WHERE direction = 'outbound'"))
        }
    }

    /// Connections to one address, newest first.
    func history(remoteAddress: String, limit: Int = 200) throws -> [ConnectionRecord] {
        try database.writer.read { db in
            try ConnectionRecord
                .filter(Column("remoteAddress") == remoteAddress)
                .order(Column("firstSeen").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Connections by one process name, newest first.
    func history(processName: String, limit: Int = 200) throws -> [ConnectionRecord] {
        try database.writer.read { db in
            try ConnectionRecord
                .filter(Column("processName") == processName)
                .order(Column("firstSeen").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func count() throws -> Int {
        try database.writer.read { db in try ConnectionRecord.fetchCount(db) }
    }
}
