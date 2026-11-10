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

    /// The table names the process that used a socket last. A child that writes to its
    /// parent's socket does not close one connection and open another.
    func testASocketAnotherProcessUsedLastIsTheSameConnection() {
        var tracker = ConnectionTracker()
        _ = tracker.update(entries: [], at: t0)
        let opened = tracker.update(entries: [tcp(100, 50000, "17.253.144.10")], at: t0 + 1).opened
        XCTAssertEqual(opened.map(\.pid), [100])
        XCTAssertEqual(tracker.update(entries: [tcp(101, 50000, "17.253.144.10")], at: t0 + 2), ConnectionTracker.Changes())
        XCTAssertEqual(tracker.open.map(\.id), opened.map(\.id))
        XCTAssertEqual(tracker.open.first?.pid, 100)
        XCTAssertEqual(tracker.open.first?.lastSeen, t0 + 2)
        XCTAssertEqual(tracker.update(entries: [tcp(100, 50000, "17.253.144.10")], at: t0 + 3), ConnectionTracker.Changes())

        // Two sockets on one flow at once (two local addresses) are two connections.
        let both = tracker.update(entries: [tcp(100, 50000, "17.253.144.10"), tcp(101, 50000, "17.253.144.10", localAddress: "10.0.0.2")], at: t0 + 4)
        XCTAssertEqual(both.opened.map(\.pid), [101])
        XCTAssertEqual(both.closed, [])
    }

    func testThePidsAReadingWouldOpenAreTheOnesItOpens() {
        var tracker = ConnectionTracker()
        _ = tracker.update(entries: [tcp(1, 50000, "17.1.1.1")], at: t0)
        let entries = [tcp(1, 50000, "17.1.1.1"), tcp(2, 50001, "17.1.1.2"), tcp(2, 50001, "17.1.1.2"), tcp(3, 50002, "127.0.0.1"),
                       tcp(4, 443, "0.0.0.0", 0, state: SocketEntry.tcpListen), udp(5, 5353, "224.0.0.251", 5353)]
        let opening = tracker.openingPids(entries)
        XCTAssertEqual(opening, Set(tracker.update(entries: entries, at: t0.addingTimeInterval(2)).opened.map(\.pid)))
        XCTAssertEqual(opening, [2, 5])
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

    private func listener(_ pid: Int32, _ port: UInt16, on address: String = "0.0.0.0", v6: Bool = false, dual: Bool = false) -> SocketEntry {
        SocketEntry(proto: .tcp, isIPv6: v6, localAddress: address, localPort: port, remoteAddress: v6 ? "::" : "0.0.0.0", remotePort: 0,
                    tcpState: SocketEntry.tcpListen, pid: pid, effectivePid: 0, uid: 0, isDualStack: dual)
    }

    /// An accepted socket keeps its listener's local address and port. launchd holds the
    /// listener of a job it starts on demand, so the pids need not match.
    func testASocketOnAListeningEndpointWasAccepted() throws {
        var tracker = ConnectionTracker()
        _ = tracker.update(entries: [
            listener(1, 22), listener(1, 8080, on: "127.0.0.1"), listener(1, 9000, on: "192.168.1.5"),
            listener(1, 7000, on: "::", v6: true, dual: true), listener(1, 9100, on: "192.168.1.5"),
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
            try XCTUnwrap(tracker.live[key], file: file, line: line).direction == .inbound
        }
        XCTAssertTrue(try inbound("500:tcp/22>203.0.113.5:51514"), "on a port listening on every interface")
        XCTAssertFalse(try inbound("600:tcp/50000>17.1.1.1:443"))
        XCTAssertFalse(try inbound("700:tcp/8080>17.1.1.2:443"), "the listener is on another address")
        XCTAssertTrue(try inbound("800:tcp/9000>203.0.113.6:51515"), "on the listener's own address")
        XCTAssertTrue(try inbound("900:tcp/7000>::ffff:203.0.113.7:51516"), "a dual-stack listener's IPv4 peer")
        XCTAssertTrue(try inbound("901:tcp/9100>::ffff:203.0.113.8:51517"), "a mapped address is its IPv4 address")
        XCTAssertFalse(try inbound("1000:udp/5353>224.0.0.251:5353"), "UDP accepts nothing")
    }

    /// The IPv6 allocator does not see an IPv4-only listener, and the IPv4 one no IPv6-only
    /// listener: an ephemeral port of the other family can land on the listener's.
    func testAListenerAnswersOnlyForItsFamily() throws {
        var tracker = ConnectionTracker()
        _ = tracker.update(entries: [
            listener(1, 22), listener(1, 23, on: "::", v6: true), listener(1, 24, on: "::", v6: true, dual: true),
            tcp(500, 22, "2606:4700::1", 443, v6: true),
            tcp(501, 23, "17.1.1.1"),
            tcp(502, 24, "17.1.1.2"),
            tcp(503, 24, "2606:4700::2", 443, v6: true),
            tcp(504, 23, "2606:4700::3", 443, v6: true),
        ], at: t0)
        func inbound(_ key: String, file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
            try XCTUnwrap(tracker.live[key], file: file, line: line).direction == .inbound
        }
        XCTAssertFalse(try inbound("500:tcp/22>2606:4700::1:443"), "an IPv6 socket on an IPv4-only listener's port")
        XCTAssertFalse(try inbound("501:tcp/23>17.1.1.1:443"), "an IPv4 socket on an IPv6-only listener's port")
        XCTAssertTrue(try inbound("502:tcp/24>17.1.1.2:443"), "a dual-stack listener takes both")
        XCTAssertTrue(try inbound("503:tcp/24>2606:4700::2:443"))
        XCTAssertTrue(try inbound("504:tcp/23>2606:4700::3:443"), "its own family")
    }

    func testAnAcceptedSocketStaysInboundAfterItsListenerCloses() throws {
        var tracker = ConnectionTracker()
        _ = tracker.update(entries: [listener(1, 22), tcp(500, 22, "203.0.113.5", 51514)], at: t0)
        _ = tracker.update(entries: [tcp(500, 22, "203.0.113.5", 51514)], at: t0 + 2)
        XCTAssertEqual(try XCTUnwrap(tracker.live["500:tcp/22>203.0.113.5:51514"]).direction, .inbound)
    }

    /// Below the ephemeral range, with no listener and no seen opening, nothing says which
    /// side called.
    func testASocketNothingProvesClaimsNoDirection() {
        var tracker = ConnectionTracker()
        _ = tracker.update(entries: [tcp(1, 49151, "17.1.1.1"), udp(2, 41641, "8.8.8.8", 53), tcp(3, 22, "17.1.1.2")], at: t0)
        XCTAssertEqual(tracker.open.map(\.direction), [.unknown, .unknown, .unknown])
    }

    /// Connections already open at launch have no seen opening: the local port is all there is.
    func testAnEphemeralLocalPortReadsAsThisMacConnecting() throws {
        var tracker = ConnectionTracker()
        let opened = tracker.update(entries: [tcp(1, 49152, "17.1.1.1"), udp(2, 60000, "8.8.8.8", 53)], at: t0).opened
        XCTAssertEqual(opened.map(\.direction), [.outbound, .outbound])
        var known = Set<String>()
        XCTAssertTrue(LiveConnection.isFirstContact(try XCTUnwrap(opened.first), known: &known), "first contact needs no packet access")
    }

    func testAListenerOutranksAnEphemeralLocalPort() {
        var tracker = ConnectionTracker()
        _ = tracker.update(entries: [listener(1, 49701), tcp(500, 49701, "192.168.1.20", 54553)], at: t0)
        XCTAssertEqual(tracker.live["500:tcp/49701>192.168.1.20:54553"]?.direction, .inbound)
    }

    func testASeenOpeningMakesAConnectionOutboundOverAListener() {
        var tracker = ConnectionTracker()
        _ = tracker.update(entries: [listener(1, 22), tcp(500, 22, "17.1.1.1")], at: t0, outboundSeen: { $0 == "tcp/22>17.1.1.1:443" })
        XCTAssertEqual(tracker.live["500:tcp/22>17.1.1.1:443"]?.direction, .outbound)
    }

    /// The SYN's event can arrive after the poll that first showed the socket.
    func testASeenOpeningSettlesARowAlreadyShown() {
        var tracker = ConnectionTracker()
        let entries = [listener(1, 22), tcp(500, 22, "17.1.1.1"), tcp(600, 40000, "17.1.1.2")]
        _ = tracker.update(entries: entries, at: t0)
        func flow(_ port: UInt16, _ last: UInt8) -> FlowKey { FlowKey(proto: .tcp, localPort: port, remote: IPAddress(bytes: [17, 1, 1, last]), remotePort: 443) }
        XCTAssertEqual(tracker.confirmOutbound(flow: flow(22, 1), openedAt: t0 + 1).map(\.id), ["500:tcp/22>17.1.1.1:443"])
        XCTAssertEqual(tracker.live["500:tcp/22>17.1.1.1:443"]?.direction, .outbound)
        XCTAssertTrue(tracker.confirmOutbound(flow: flow(22, 1), openedAt: t0 + 1).isEmpty, "already settled")
        XCTAssertTrue(tracker.confirmOutbound(flow: flow(40000, 2), openedAt: t0 + 60).isEmpty, "an older connection on the four-tuple")
        _ = tracker.update(entries: entries, at: t0 + 2)
        XCTAssertEqual(tracker.live["500:tcp/22>17.1.1.1:443"]?.direction, .outbound, "a later reading keeps it")
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
