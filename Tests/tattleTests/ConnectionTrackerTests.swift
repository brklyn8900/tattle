import XCTest
@testable import tattle

final class ConnectionTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func tcp(_ pid: Int32, _ local: UInt16, _ remote: String, _ port: UInt16 = 443, state: Int32 = SocketEntry.tcpEstablished, v6: Bool = false, localAddress: String? = nil) -> SocketEntry {
        SocketEntry(proto: .tcp, isIPv6: v6, localAddress: localAddress ?? (v6 ? "2001:db8::1" : "192.168.1.5"), localPort: local,
                    remoteAddress: remote, remotePort: port, tcpState: state, pid: pid, effectivePid: 0, uid: 501)
    }

    private func udp(_ pid: Int32, _ local: UInt16, _ remote: String, _ port: UInt16) -> SocketEntry {
        SocketEntry(proto: .udp, isIPv6: false, localAddress: "192.168.1.5", localPort: local,
                    remoteAddress: remote, remotePort: port, tcpState: nil, pid: pid, effectivePid: 0, uid: 501)
    }

    func testScope() {
        XCTAssertEqual(tcp(1, 50000, "17.253.144.10").connectionScope, .remote)
        XCTAssertEqual(tcp(1, 50000, "192.168.1.20").connectionScope, .local)
        XCTAssertEqual(tcp(1, 50000, "10.0.0.1").connectionScope, .local)
        XCTAssertEqual(tcp(1, 50000, "172.20.0.1").connectionScope, .local)
        XCTAssertEqual(tcp(1, 50000, "172.32.0.1").connectionScope, .remote)
        XCTAssertEqual(tcp(1, 50000, "100.64.0.1").connectionScope, .local, "shared address space: a Tailscale peer")
        XCTAssertEqual(tcp(1, 50000, "100.127.255.254").connectionScope, .local)
        XCTAssertEqual(tcp(1, 50000, "100.63.255.255").connectionScope, .remote)
        XCTAssertEqual(tcp(1, 50000, "100.128.0.1").connectionScope, .remote)
        XCTAssertEqual(tcp(1, 50000, "::ffff:100.100.1.2", v6: true).connectionScope, .local)
        XCTAssertEqual(udp(1, 5353, "224.0.0.251", 5353).connectionScope, .local)
        XCTAssertEqual(tcp(1, 50000, "fe80::1", v6: true).connectionScope, .local)
        XCTAssertEqual(tcp(1, 50000, "fd00::5", v6: true).connectionScope, .local)
        XCTAssertEqual(tcp(1, 50000, "2606:4700::1111", v6: true).connectionScope, .remote)
        XCTAssertEqual(tcp(1, 50000, "::ffff:8.8.8.8", v6: true).connectionScope, .remote)
        XCTAssertNil(tcp(1, 50000, "127.0.0.1").connectionScope, "loopback is not a connection here")
        XCTAssertNil(tcp(1, 50000, "::1", v6: true).connectionScope)
        XCTAssertNil(tcp(1, 443, "0.0.0.0", 0, state: SocketEntry.tcpListen).connectionScope, "a listener has no peer")
        XCTAssertNil(udp(1, 5353, "0.0.0.0", 0).connectionScope, "an unconnected UDP socket has no peer")
    }

    func testOpenPersistCloseAndPreExisting() {
        var tracker = ConnectionTracker()
        let first = tracker.update(entries: [tcp(100, 50000, "17.1.1.1"), udp(200, 60000, "8.8.8.8", 53)], at: t0)
        XCTAssertEqual(first.opened.count, 2)
        XCTAssertTrue(first.opened.allSatisfy(\.preExisting), "everything in the first reading was there before")
        XCTAssertTrue(first.closed.isEmpty)

        let second = tracker.update(entries: [tcp(100, 50000, "17.1.1.1", state: 5), tcp(100, 50001, "1.1.1.1")], at: t0 + 2)
        XCTAssertEqual(second.opened.map(\.remoteAddress), ["1.1.1.1"])
        XCTAssertFalse(second.opened[0].preExisting)
        XCTAssertEqual(second.opened[0].firstSeen, t0 + 2)
        XCTAssertEqual(second.closed.map(\.remoteAddress), ["8.8.8.8"])
        XCTAssertEqual(second.closed[0].ended, t0 + 2)
        XCTAssertEqual(second.closed[0].firstSeen, t0)

        let kept = tracker.live["100:tcp/50000>17.1.1.1:443"]!
        XCTAssertEqual(kept.lastSeen, t0 + 2)
        XCTAssertEqual(kept.firstSeen, t0)
        XCTAssertEqual(kept.stateText, "closing", "the state follows the latest reading")
        XCTAssertEqual(tracker.open.map(\.remoteAddress), ["1.1.1.1", "17.1.1.1"], "newest first")

        let third = tracker.update(entries: [], at: t0 + 4)
        XCTAssertEqual(third.closed.count, 2)
        XCTAssertTrue(tracker.live.isEmpty)
        XCTAssertFalse(tracker.update(entries: [tcp(1, 1, "9.9.9.9")], at: t0 + 6).opened[0].preExisting)
    }

    private func listener(_ pid: Int32, _ port: UInt16, on address: String = "0.0.0.0", v6: Bool = false) -> SocketEntry {
        SocketEntry(proto: .tcp, isIPv6: v6, localAddress: address, localPort: port, remoteAddress: v6 ? "::" : "0.0.0.0", remotePort: 0,
                    tcpState: SocketEntry.tcpListen, pid: pid, effectivePid: 0, uid: 0)
    }

    /// An accepted socket keeps its listener's local address and port. launchd holds the
    /// listener of a job it starts on demand, so the pids need not match.
    func testASocketOnAListeningEndpointWasAccepted() throws {
        var tracker = ConnectionTracker()
        _ = tracker.update(entries: [
            listener(1, 22), listener(1, 8080, on: "127.0.0.1"), listener(1, 9000, on: "192.168.1.5"),
            listener(1, 7000, on: "::", v6: true), listener(1, 9100, on: "192.168.1.5"),
            tcp(500, 22, "203.0.113.5", 51514),
            tcp(600, 50000, "17.1.1.1"),
            tcp(700, 8080, "17.1.1.2"),
            tcp(800, 9000, "203.0.113.6", 51515),
            tcp(900, 7000, "::ffff:203.0.113.7", 51516, v6: true, localAddress: "::ffff:192.168.1.5"),
            tcp(901, 9100, "::ffff:203.0.113.8", 51517, v6: true, localAddress: "::ffff:192.168.1.5"),
            udp(1000, 5353, "224.0.0.251", 5353),
            SocketEntry(proto: .udp, isIPv6: false, localAddress: "0.0.0.0", localPort: 5353, remoteAddress: "0.0.0.0", remotePort: 0, tcpState: nil, pid: 1, effectivePid: 0, uid: 0),
        ], at: t0)
        func inbound(_ key: String, file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
            try XCTUnwrap(tracker.live[key], file: file, line: line).isInbound
        }
        XCTAssertTrue(try inbound("500:tcp/22>203.0.113.5:51514"), "on a port listening on every interface")
        XCTAssertFalse(try inbound("600:tcp/50000>17.1.1.1:443"))
        XCTAssertFalse(try inbound("700:tcp/8080>17.1.1.2:443"), "the listener is on another address")
        XCTAssertTrue(try inbound("800:tcp/9000>203.0.113.6:51515"), "on the listener's own address")
        XCTAssertTrue(try inbound("900:tcp/7000>::ffff:203.0.113.7:51516"), "a dual-stack listener's IPv4 peer")
        XCTAssertTrue(try inbound("901:tcp/9100>::ffff:203.0.113.8:51517"), "a mapped address is its IPv4 address")
        XCTAssertFalse(try inbound("1000:udp/5353>224.0.0.251:5353"), "UDP accepts nothing")
    }

    func testAnAcceptedSocketStaysInboundAfterItsListenerCloses() throws {
        var tracker = ConnectionTracker()
        _ = tracker.update(entries: [listener(1, 22), tcp(500, 22, "203.0.113.5", 51514)], at: t0)
        _ = tracker.update(entries: [tcp(500, 22, "203.0.113.5", 51514)], at: t0 + 2)
        XCTAssertTrue(try XCTUnwrap(tracker.live["500:tcp/22>203.0.113.5:51514"]).isInbound)
    }

    func testDuplicateRecordsCountOnce() {
        var tracker = ConnectionTracker()
        let entry = tcp(100, 50000, "17.1.1.1")
        XCTAssertEqual(tracker.update(entries: [entry, entry], at: t0).opened.count, 1)
    }

    func testThisMachine() throws {
        var tracker = ConnectionTracker()
        let changes = tracker.update(entries: try SocketTable.read())
        XCTAssertFalse(changes.opened.isEmpty, "something is always connected")
        XCTAssertTrue(changes.opened.allSatisfy { $0.remotePort != 0 && !$0.remoteAddress.hasPrefix("127.") })
    }
}
