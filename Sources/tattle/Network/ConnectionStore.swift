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
    var signer: String?
    var localPort: UInt16
    var remoteAddress: String
    var remotePort: UInt16
    var isIPv6: Bool
    var scope: Connection.Scope
    var firstSeen: Date
    var lastSeen: Date
    var ended: Date?
    var preExisting: Bool
    var name: String?
    var nameSource: String?

    init(_ connection: Connection, processName: String, appName: String? = nil, appPath: String? = nil, signer: String? = nil) {
        key = connection.id
        proto = connection.proto
        pid = connection.pid
        uid = connection.uid
        self.processName = processName
        self.appName = appName
        self.appPath = appPath
        self.signer = signer
        localPort = connection.localPort
        remoteAddress = connection.remoteAddress
        remotePort = connection.remotePort
        isIPv6 = connection.isIPv6
        scope = connection.scope
        firstSeen = connection.firstSeen
        lastSeen = connection.lastSeen
        ended = connection.ended
        preExisting = connection.preExisting
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

    /// Every remote address ever recorded: what "first contact" is measured against.
    func knownAddresses() throws -> Set<String> {
        try database.writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT DISTINCT remoteAddress FROM connection"))
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
