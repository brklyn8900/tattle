import Foundation
import GRDB

/// The app's SQLite database under Application Support: one file and the write-ahead log
/// and its index beside it (`-wal`, `-shm`), opened through GRDB with versioned migrations.
/// Tests open an in-memory instance.
struct AppDatabase: Sendable {
    let writer: any DatabaseWriter

    init(at url: URL) throws {
        // A previous instance may still be exiting with the file open; wait rather than
        // fail the write at once.
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try Self.migrator.migrate(queue)
        Self.writeAhead(queue)
        writer = queue
    }

    /// The size the log is cut back to once a checkpoint has folded it into the file, so a
    /// large transaction (the flow index's build, a big prune) does not leave it that large.
    static let logSizeLimit = 32768

    /// History writes a few rows per poll. A rollback journal wrote over 100 KB, synced, per
    /// row; the write-ahead log appends a few pages and syncs at checkpoints. Synchronous
    /// NORMAL syncs nothing between checkpoints, so a power cut or kernel panic loses whatever
    /// was written since the last checkpoint and not yet written back by the OS; it does not
    /// corrupt the file. The switch is not a condition for starting: where it fails (another
    /// process writing the file, a full or read-only disk) the run keeps the rollback journal,
    /// and a later launch switches.
    private static func writeAhead(_ queue: DatabaseQueue) {
        do {
            try queue.writeWithoutTransaction { db in
                let mode = try String.fetchOne(db, sql: "PRAGMA journal_mode = WAL")
                guard mode == "wal" else {
                    throw DatabaseError(message: "the journal mode stayed \(mode ?? "unknown")")
                }
                try db.execute(sql: "PRAGMA synchronous = NORMAL")
                try db.execute(sql: "PRAGMA journal_size_limit = \(logSizeLimit)")
            }
        } catch {
            Log.app.error("history keeps the rollback journal this run: switching to the write-ahead log failed: \(error, privacy: .public)")
        }
    }

    /// An in-memory database for tests.
    static func inMemory() throws -> AppDatabase {
        let queue = try DatabaseQueue()
        try migrator.migrate(queue)
        return AppDatabase(writer: queue)
    }

    /// The default location: ~/Library/Application Support/<bundle name>/tattle.sqlite, so
    /// the release app uses Tattle/ and the dev build (make run) Tattle Dev/.
    /// The folder is marked so Spotlight does not index connection history (PRD,
    /// Privacy and retention); Time Machine is left to the user.
    static func openDefault() throws -> AppDatabase {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Tattle"
        let folder = support.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let noIndex = folder.appending(path: ".metadata_never_index")
        if !FileManager.default.fileExists(atPath: noIndex.path) {
            FileManager.default.createFile(atPath: noIndex.path, contents: nil)
        }
        return try AppDatabase(at: folder.appending(path: "tattle.sqlite"))
    }

    private init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-rules") { db in
            try db.create(table: "rule") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("match", .text).notNull()
                t.column("pattern", .text).notNull()
                t.column("owner", .text)
                t.column("purpose", .text).notNull()
                t.column("category", .text)
                t.column("risk", .text)
                t.column("confidence", .text)
                t.column("source", .text).notNull()
                t.column("confirmed", .datetime)
                t.column("created", .datetime).notNull()
                // One rule per (kind, match, pattern, source): a re-explained item or a
                // reloaded seed replaces the earlier row instead of piling up duplicates.
                t.uniqueKey(["kind", "match", "pattern", "source"])
            }
        }
        migrator.registerMigration("v2-settings") { db in
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        migrator.registerMigration("v3-connections") { db in
            try db.create(table: "connection") { t in
                t.autoIncrementedPrimaryKey("id")
                // The tracker's key; the same socket reused is a new row each time.
                t.column("key", .text).notNull()
                t.column("proto", .text).notNull()
                t.column("pid", .integer).notNull()
                t.column("uid", .integer).notNull()
                t.column("processName", .text).notNull()
                t.column("appName", .text)
                t.column("appPath", .text)
                t.column("signer", .text)
                t.column("localPort", .integer).notNull()
                t.column("remoteAddress", .text).notNull()
                t.column("remotePort", .integer).notNull()
                t.column("isIPv6", .boolean).notNull()
                t.column("scope", .text).notNull()
                t.column("firstSeen", .datetime).notNull()
                t.column("lastSeen", .datetime).notNull()
                t.column("ended", .datetime)
                t.column("preExisting", .boolean).notNull()
                // Filled by the sniffer; nil until then.
                t.column("name", .text)
                t.column("nameSource", .text)
            }
            try db.create(index: "connection_remote", on: "connection", columns: ["remoteAddress"])
            try db.create(index: "connection_firstSeen", on: "connection", columns: ["firstSeen"])
            try db.create(index: "connection_open", on: "connection", columns: ["key"], condition: Column("ended") == nil)
        }
        migrator.registerMigration("v4-connection-app-signer") { db in
            try db.alter(table: "connection") { $0.add(column: "appSigner", .text) }
            // A row under an app held the app's signer; the process's own was never read.
            try db.execute(sql: "UPDATE connection SET appSigner = signer, signer = NULL WHERE appPath IS NOT NULL")
        }
        migrator.registerMigration("v5-rule-identity") { db in
            // SQLite cannot change a table's unique key, so the table is rebuilt. Empty, not
            // null: SQLite treats nulls as distinct, so a key with one would never conflict.
            try db.create(table: "rule_new") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("match", .text).notNull()
                t.column("pattern", .text).notNull()
                t.column("owner", .text)
                t.column("purpose", .text).notNull()
                t.column("category", .text)
                t.column("risk", .text)
                t.column("confidence", .text)
                t.column("source", .text).notNull()
                t.column("identity", .text).notNull().defaults(to: "")
                t.column("confirmed", .datetime)
                t.column("created", .datetime).notNull()
                // One rule per item and per program: an answer about one program with a name
                // must not replace another's.
                t.uniqueKey(["kind", "match", "pattern", "source", "identity"])
            }
            try db.execute(sql: """
                INSERT INTO rule_new (id, kind, match, pattern, owner, purpose, category, risk, confidence, source, confirmed, created)
                SELECT id, kind, match, pattern, owner, purpose, category, risk, confidence, source, confirmed, created FROM rule
                """)
            try db.drop(table: "rule")
            try db.rename(table: "rule_new", to: "rule")
        }
        migrator.registerMigration("v6-claude-preset-flags") { db in
            // A preset is saved as its text, so one saved earlier would keep its old flags. This
            // runs once: the same text typed later is the user's own.
            try db.execute(
                sql: "UPDATE setting SET value = ? WHERE key = 'provider.command' AND value = ?",
                arguments: [
                    #"claude -p --setting-sources project,local --no-session-persistence --strict-mcp-config --system-prompt "" --tools "" --permission-prompts none --output-format json --json-schema {schema}"#,
                    #"claude -p --setting-sources project,local --tools "" --permission-prompts none --output-format json --json-schema {schema}"#,
                ])
        }
        migrator.registerMigration("v7-connection-direction") { db in
            // Rows from before this were recorded as this Mac reaching out, and first contact
            // is measured against them.
            try db.alter(table: "connection") { $0.add(column: "direction", .text).notNull().defaults(to: Connection.Direction.outbound.rawValue) }
        }
        migrator.registerMigration("v8-connection-flow-index") { db in
            // Naming a flow, on the main actor, found its rows by address and read each one,
            // tens of thousands for a client that talks to one address all day. The address
            // index stays: knownAddresses scans it at launch, and scans this wider one slower.
            // No `id` column: every index entry already ends in the row id, so listing it
            // would store it twice.
            try db.create(index: "connection_flow", on: "connection",
                          columns: ["remoteAddress", "localPort", "remotePort", "proto"])
        }
        return migrator
    }
}
