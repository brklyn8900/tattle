import Foundation
import GRDB

/// The app's SQLite database: one file under Application Support, opened through GRDB
/// with versioned migrations. Tests open an in-memory instance.
struct AppDatabase: Sendable {
    let writer: any DatabaseWriter

    /// Opens (or creates) the database at `url`, running pending migrations.
    init(at url: URL) throws {
        // A previous instance may still be exiting with the file open; wait rather than
        // fail the write at once.
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try Self.migrator.migrate(queue)
        writer = queue
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
        return migrator
    }
}
