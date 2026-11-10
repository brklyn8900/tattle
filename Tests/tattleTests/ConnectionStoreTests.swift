import GRDB
import XCTest
@testable import tattle

final class ConnectionStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private var store: ConnectionStore!

    override func setUpWithError() throws {
        store = ConnectionStore(database: try AppDatabase.inMemory())
    }

    private func connection(_ pid: Int32, _ remote: String, port: UInt16 = 443, at: Date? = nil, preExisting: Bool = false) -> Connection {
        let at = at ?? t0
        return Connection(id: "\(pid):tcp/50000>\(remote):\(port)", proto: .tcp, pid: pid, uid: 501, localPort: 50000,
                          remoteAddress: remote, remotePort: port, isIPv6: false, scope: .remote, tcpState: 4,
                          firstSeen: at, lastSeen: at, ended: nil, preExisting: preExisting, direction: .outbound)
    }

    func testKnownAddressesAreOnlyWhatThisMacWasSeenReaching() throws {
        var accepted = connection(100, "203.0.113.5", at: t0)
        accepted.direction = .inbound
        var unproven = connection(300, "203.0.113.6", at: t0)
        unproven.direction = .unknown
        try store.open(ConnectionRecord(accepted, processName: "sshd"))
        try store.open(ConnectionRecord(unproven, processName: "tool"))
        try store.open(ConnectionRecord(connection(200, "17.1.1.1"), processName: "Safari"))
        XCTAssertEqual(try store.knownAddresses(), ["17.1.1.1"])
        XCTAssertEqual(try store.history(processName: "sshd").first?.direction, .inbound)
        XCTAssertEqual(try store.history(processName: "tool").first?.direction, .unknown)
        XCTAssertEqual(try store.history(processName: "Safari").first?.direction, .outbound)

        try store.setOutbound(key: unproven.id)
        XCTAssertEqual(try store.history(processName: "tool").first?.direction, .outbound)
        XCTAssertEqual(try store.knownAddresses(), ["17.1.1.1", "203.0.113.6"])
    }

    /// First contact is measured against what was recorded before directions existed.
    func testConnectionsFromBeforeDirectionsCountAsReached() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v6-claude-preset-flags")
        try queue.write {
            try $0.execute(sql: """
                INSERT INTO connection (key, proto, pid, uid, processName, localPort, remoteAddress, remotePort, isIPv6, scope, firstSeen, lastSeen, preExisting)
                VALUES ('k', 'tcp', 1, 501, 'x', 50000, '17.1.1.1', 443, 0, 'remote', ?, ?, 0)
                """, arguments: [t0, t0])
        }
        try AppDatabase.migrator.migrate(queue)
        XCTAssertEqual(try queue.read { try String.fetchOne($0, sql: "SELECT direction FROM connection") }, "outbound")
    }

    private func historyFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tattle-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appending(path: "tattle.sqlite")
    }

    func testAHistoryFromBeforeKeepsItsRowsAndIsWrittenAhead() throws {
        let url = try historyFile()
        let rows: [Row]
        let settings: [Row]
        do {
            let queue = try DatabaseQueue(path: url.path)
            try AppDatabase.migrator.migrate(queue, upTo: "v7-connection-direction")
            try queue.write { db in
                for (i, address) in ["17.1.1.1", "::ffff:17.1.1.1", "2001:db8::1", "17.1.1.1"].enumerated() {
                    try db.execute(sql: """
                        INSERT INTO connection (key, proto, pid, uid, processName, localPort, remoteAddress, remotePort, isIPv6, scope, firstSeen, lastSeen, ended, preExisting, name, nameSource, direction)
                        VALUES (?, ?, 1, 501, 'x', 50000, ?, 443, 0, 'remote', ?, ?, ?, 0, 'a.example', 'sni', 'outbound')
                        """, arguments: ["k\(i)", i == 2 ? "udp" : "tcp", address, t0 + Double(i), t0 + Double(i), i == 2 ? nil : t0 + 9])
                }
                try db.execute(sql: "INSERT INTO setting (key, value) VALUES ('provider.command', 'mine')")
            }
            rows = try queue.read { try Row.fetchAll($0, sql: "SELECT * FROM connection ORDER BY id") }
            settings = try queue.read { try Row.fetchAll($0, sql: "SELECT * FROM setting ORDER BY key") }
            XCTAssertEqual(try queue.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }, "delete")
        }

        let database = try AppDatabase(at: url)
        try database.writer.read { db in
            XCTAssertEqual(try Row.fetchAll(db, sql: "SELECT * FROM connection ORDER BY id"), rows)
            XCTAssertEqual(try Row.fetchAll(db, sql: "SELECT * FROM setting ORDER BY key"), settings)
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT name FROM pragma_index_info('connection_flow')"),
                           ["remoteAddress", "localPort", "remotePort", "proto"])
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA journal_mode"), "wal")
            XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA synchronous"), 1, "NORMAL: synced at checkpoints")
            XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA journal_size_limit"), AppDatabase.logSizeLimit)
        }
    }

    /// The switch to the log is not a condition for starting. When it fails, here because
    /// another process is writing the file, the run keeps the rollback journal and still writes
    /// history; the next launch switches.
    func testAFailedSwitchToTheLogLeavesTheFileOpenAndWritable() throws {
        let url = try historyFile()
        try AppDatabase.migrator.migrate(try DatabaseQueue(path: url.path))
        let other = try DatabaseQueue(path: url.path)
        let database = try other.inDatabase { db in
            try db.execute(sql: "BEGIN IMMEDIATE")
            defer { try? db.execute(sql: "ROLLBACK") }
            return try AppDatabase(at: url)
        }
        XCTAssertEqual(try database.writer.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }, "delete")
        let history = ConnectionStore(database: database)
        try history.open(ConnectionRecord(connection(100, "17.1.1.1"), processName: "Safari"))
        XCTAssertEqual(try history.count(), 1)

        let next = try AppDatabase(at: url)
        XCTAssertEqual(try next.writer.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }, "wal")
        XCTAssertEqual(try ConnectionStore(database: next).count(), 1)
    }

    func testOpenCloseAndHistory() throws {
        let a = try store.open(ConnectionRecord(connection(100, "17.1.1.1"), processName: "Safari", appName: "Safari", appPath: "/Applications/Safari.app", signer: "Apple"))
        XCTAssertNotNil(a.id)
        try store.open(ConnectionRecord(connection(200, "1.1.1.1", at: t0 + 1, preExisting: true), processName: "node"))
        try store.close(key: a.key, lastSeen: t0 + 8, ended: t0 + 10)

        let apple = try store.history(remoteAddress: "17.1.1.1")
        XCTAssertEqual(apple.count, 1)
        XCTAssertEqual(apple[0].ended, t0 + 10)
        XCTAssertEqual(apple[0].lastSeen, t0 + 8)
        XCTAssertEqual(apple[0].appName, "Safari")
        XCTAssertEqual(apple[0].proto, .tcp)
        XCTAssertEqual(apple[0].scope, .remote)
        XCTAssertNil(apple[0].name)
        XCTAssertEqual(try store.history(processName: "node").first?.preExisting, true)
        XCTAssertEqual(try store.knownAddresses(), ["17.1.1.1", "1.1.1.1"])

        // A new connection to the same peer is a new row; closing touches only the open one.
        try store.open(ConnectionRecord(connection(100, "17.1.1.1", at: t0 + 20), processName: "Safari"))
        try store.close(key: a.key, lastSeen: t0 + 30, ended: t0 + 32)
        let both = try store.history(remoteAddress: "17.1.1.1")
        XCTAssertEqual(both.map { $0.ended }, [t0 + 32, t0 + 10], "newest first")
    }

    func testNameGoesOnTheNewestRowOfTheFlowOpenOrClosed() throws {
        let flow = FlowKey(proto: .tcp, localPort: 50000, remote: IPAddress(bytes: [17, 1, 1, 1]), remotePort: 443)
        let first = try store.open(ConnectionRecord(connection(100, "17.1.1.1"), processName: "Safari"))
        try store.close(key: first.key, lastSeen: t0 + 1, ended: t0 + 2)
        try store.open(ConnectionRecord(connection(200, "17.1.1.1", at: t0 + 20), processName: "curl"))
        try store.record(.named(ConnectionName(name: "www.apple.com", source: .sni, kind: .destination)), flow: flow, openedAt: t0 + 20)
        let rows = try store.history(remoteAddress: "17.1.1.1")
        XCTAssertEqual(rows.map(\.name), ["www.apple.com", nil], "the reused port names the newest row only, whatever its pid")
        XCTAssertEqual(rows[0].nameSource, "sni")

        try store.close(key: rows[0].key, lastSeen: t0 + 21, ended: t0 + 22)
        try store.record(.named(ConnectionName(name: "cdn.apple.com", source: .dns, kind: .destination)), flow: flow, openedAt: t0 + 20)
        XCTAssertEqual(try store.history(remoteAddress: "17.1.1.1")[0].name, "cdn.apple.com", "a DNS fallback can land after the connection closed")

        var mapped = connection(300, "::ffff:17.1.1.1", at: t0 + 30)
        mapped.isIPv6 = true
        try store.open(ConnectionRecord(mapped, processName: "node"))
        try store.record(.named(ConnectionName(name: "v6.apple.com", source: .quic, kind: .destination)), flow: flow, openedAt: t0 + 30)
        XCTAssertEqual(try store.history(remoteAddress: "::ffff:17.1.1.1")[0].name, "v6.apple.com", "an IPv6 socket talking IPv4")
        try store.record(.named(ConnectionName(name: "nowhere", source: .sni, kind: .destination)),
                         flow: FlowKey(proto: .udp, localPort: 1, remote: IPAddress(bytes: [2, 2, 2, 2]), remotePort: 443), openedAt: t0)

        try store.record(.unnamed(.timeout), flow: flow, openedAt: t0 + 30)
        let silent = try store.history(remoteAddress: "::ffff:17.1.1.1")[0]
        XCTAssertNil(silent.name)
        XCTAssertEqual(silent.nameSource, "none:timeout", "why there is no name, where a source would be")
    }

    /// The sniffer often names a flow before the socket table shows it. Until the poll adds
    /// the new connection's row, the newest row for the four-tuple is an older connection's,
    /// and it must keep its own outcome; the new row takes the name when it is added.
    func testANameThatArrivesBeforeItsRowLeavesOlderRowsAlone() throws {
        let flow = FlowKey(proto: .tcp, localPort: 50000, remote: IPAddress(bytes: [17, 1, 1, 1]), remotePort: 443)
        var old = ConnectionRecord(connection(100, "17.1.1.1"), processName: "Safari")
        old.name = "old.example.com"
        old.nameSource = "sni"
        old = try store.open(old)
        try store.close(key: old.key, lastSeen: t0 + 1, ended: t0 + 2)

        try store.record(.named(ConnectionName(name: "new.example.com", source: .quic, kind: .destination)), flow: flow, openedAt: t0 + 60)
        let rows = try store.history(remoteAddress: "17.1.1.1")
        XCTAssertEqual(rows.map(\.name), ["old.example.com"])
        XCTAssertEqual(rows.map(\.nameSource), ["sni"])

        // A poll already under way when the flow opened records it a moment earlier.
        try store.open(ConnectionRecord(connection(200, "17.1.1.1", at: t0 + 59.5), processName: "curl"))
        try store.record(.named(ConnectionName(name: "new.example.com", source: .quic, kind: .destination)), flow: flow, openedAt: t0 + 60)
        XCTAssertEqual(try store.history(remoteAddress: "17.1.1.1").map(\.name), ["new.example.com", "old.example.com"])
    }

    func testNamingAFlowSearchesByTheWholeFlow() throws {
        final class Statements: @unchecked Sendable { var sql: [String] = [] }
        let statements = Statements()
        let database = try AppDatabase.inMemory()
        try database.writer.writeWithoutTransaction { db in
            db.trace { event in
                if case .statement(let statement) = event { statements.sql.append(statement.expandedSQL) }
            }
        }
        let flow = FlowKey(proto: .tcp, localPort: 50000, remote: IPAddress(bytes: [17, 1, 1, 1]), remotePort: 443)
        try ConnectionStore(database: database).record(.unnamed(.timeout), flow: flow, openedAt: t0)

        let select = try XCTUnwrap(statements.sql.first { $0.contains("SELECT * FROM connection") })
        let plan = try database.writer.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + select).map { $0["detail"] as String }
        }
        let search = try XCTUnwrap(plan.first { $0.hasPrefix("SEARCH connection") }, "plan: \(plan)")
        for column in ["remoteAddress=?", "localPort=?", "remotePort=?", "proto=?"] {
            XCTAssertTrue(search.contains(column), "\(column) not in \(search)")
        }
    }

    func testTouchStaleAndPrune() throws {
        let a = try store.open(ConnectionRecord(connection(100, "17.1.1.1"), processName: "a"))
        try store.open(ConnectionRecord(connection(200, "2.2.2.2", at: t0 + 5), processName: "b"))
        try store.touch(keys: [a.key], at: t0 + 60)
        XCTAssertEqual(try store.history(remoteAddress: "17.1.1.1")[0].lastSeen, t0 + 60)

        XCTAssertEqual(try store.closeStale(), 2, "a previous run left both open")
        XCTAssertEqual(try store.history(remoteAddress: "17.1.1.1")[0].ended, t0 + 60)
        XCTAssertEqual(try store.history(remoteAddress: "2.2.2.2")[0].ended, t0 + 5)
        XCTAssertEqual(try store.closeStale(), 0)

        XCTAssertEqual(try store.prune(endedBefore: t0 + 30), 1, "only the one that ended earlier")
        XCTAssertEqual(try store.count(), 1)
        XCTAssertEqual(try store.knownAddresses(), ["17.1.1.1"])
    }
}
