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
                          firstSeen: at, lastSeen: at, ended: nil, preExisting: preExisting)
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
