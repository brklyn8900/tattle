import XCTest
@testable import tattle

final class ConnectionNameTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func connection(_ remote: String, port: UInt16 = 443, v6: Bool = false, proto: SocketEntry.Proto = .tcp) -> Connection {
        Connection(id: "100:\(proto.rawValue)/50000>\(remote):\(port)", proto: proto, pid: 100, uid: 501, localPort: 50000,
                   remoteAddress: remote, remotePort: port, isIPv6: v6, scope: .remote, tcpState: proto == .tcp ? 4 : nil,
                   firstSeen: t0, lastSeen: t0, ended: nil, preExisting: false)
    }

    func testFlowKeyMatchesWhatTheSnifferSees() {
        XCTAssertEqual(connection("17.253.144.10").flowKey, "tcp/50000>17.253.144.10:443")
        XCTAssertEqual(connection("2606:4700::1111", v6: true, proto: .udp).flowKey, "udp/50000>2606:4700::1111:443")
        XCTAssertEqual(connection("::ffff:17.253.144.10", v6: true).flowKey, "tcp/50000>17.253.144.10:443", "an IPv6 socket talking IPv4 is IPv4 on the wire")
        let key = FlowKey(proto: .tcp, localPort: 50000, remote: IPAddress(bytes: [17, 253, 144, 10]), remotePort: 443)
        XCTAssertEqual(key.text, connection("17.253.144.10").flowKey)
    }

    func testKindFromRuleCategory() {
        XCTAssertEqual(ConnectionName.kind(forCategory: "relay"), .relay)
        XCTAssertEqual(ConnectionName.kind(forCategory: "ech-cover"), .hidden)
        XCTAssertEqual(ConnectionName.kind(forCategory: "cdn"), .destination)
        XCTAssertEqual(ConnectionName.kind(forCategory: nil), .destination)
    }

    func testTitleExplainKeyAndFactsByKind() {
        let owner = ConnectionOwner(processName: "Safari")
        let unnamed = LiveConnection(connection: connection("17.253.144.10"), owner: owner, isNew: false)
        XCTAssertEqual(unnamed.title, "17.253.144.10:443")
        XCTAssertEqual(unnamed.explainKey, "17.253.144.10")
        var facts = Dictionary(unnamed.facts(now: t0).map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(facts["Destination"], "17.253.144.10:443")
        XCTAssertNil(facts["Address"])
        XCTAssertNil(facts["Name from"])

        let named = LiveConnection(connection: connection("17.253.144.10"), owner: owner, isNew: false,
                                   outcome: .named(ConnectionName(name: "www.apple.com", source: .sni, kind: .destination)))
        XCTAssertEqual(named.title, "www.apple.com")
        XCTAssertEqual(named.explainKey, "www.apple.com")
        facts = Dictionary(named.facts(now: t0).map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(facts["Destination"], "www.apple.com")
        XCTAssertEqual(facts["Address"], "17.253.144.10:443")
        XCTAssertEqual(facts["Name from"], "the connection's TLS handshake")

        let relayed = LiveConnection(connection: connection("17.253.144.10"), owner: owner, isNew: false,
                                     outcome: .named(ConnectionName(name: "mask.icloud.com", source: .quic, kind: .relay)))
        XCTAssertEqual(relayed.title, "relayed", "a relay's name is never shown as the destination")
        XCTAssertEqual(relayed.explainKey, "mask.icloud.com", "but the knowledge base explains the relay")
        facts = Dictionary(relayed.facts(now: t0).map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(facts["Destination"], "hidden inside a relay")
        XCTAssertEqual(facts["Relay"], "mask.icloud.com")

        let hidden = LiveConnection(connection: connection("104.16.0.1"), owner: owner, isNew: false,
                                    outcome: .named(ConnectionName(name: "cloudflare-ech.com", source: .sni, kind: .hidden)))
        XCTAssertEqual(hidden.title, "name hidden")
        facts = Dictionary(hidden.facts(now: t0).map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(facts["Cover name"], "cloudflare-ech.com")

        let dns = LiveConnection(connection: connection("17.253.144.10"), owner: owner, isNew: false,
                                 outcome: .named(ConnectionName(name: "cdn.example.net", source: .dns, kind: .destination)))
        XCTAssertEqual(dns.facts(now: t0).first { $0.name == "Name from" }?.value, "a DNS reply for the address", "marked, because the DNS map is ambiguous")

        let snapshot = NetworkSnapshot(connections: [unnamed, named, relayed, hidden, dns], takenAt: t0)
        XCTAssertEqual(snapshot.namedCount, 2)
        XCTAssertEqual(snapshot.relayedCount, 1)
        XCTAssertEqual(snapshot.hiddenCount, 1)
    }

    func testPendingNamesKeepsNamesForOpenFlowsAndForgetsTheRest() {
        var table = PendingNames()
        let apple = NameOutcome.named(ConnectionName(name: "www.apple.com", source: .sni, kind: .destination))
        table.set(apple, for: "tcp/50000>17.1.1.1:443", at: t0)
        table.set(.unnamed(.timeout), for: "udp/50001>1.1.1.1:443", at: t0 + 100)
        XCTAssertEqual(table.outcome(for: "tcp/50000>17.1.1.1:443"), apple)
        XCTAssertEqual(table.outcome(for: "udp/50001>1.1.1.1:443"), .unnamed(.timeout), "no name is an answer too")
        XCTAssertNil(table.outcome(for: "tcp/50000>17.1.1.1:80"))

        table.prune(now: t0 + PendingNames.keepFor + 1, keeping: ["tcp/50000>17.1.1.1:443"])
        XCTAssertEqual(table.count, 2, "the open flow's name stays past its age; the other is still young")
        table.prune(now: t0 + 100 + PendingNames.keepFor + 1, keeping: [])
        XCTAssertEqual(table.count, 0)

        table.set(apple, for: "k", at: t0)
        table.set(.named(ConnectionName(name: "later.apple.com", source: .dns, kind: .destination)), for: "k", at: t0 + 1)
        XCTAssertEqual(table.outcome(for: "k")?.name?.name, "later.apple.com", "the latest outcome wins")
    }

    /// Local ports are reused: a connection that opens on the four-tuple of one that closed a
    /// minute ago is a different connection and must not show the old one's name.
    func testAnOpenedFlowStartsWithoutThePreviousConnectionsOutcome() {
        var table = PendingNames()
        let key = FlowKey(proto: .tcp, localPort: 50000, remote: IPAddress(bytes: [17, 1, 1, 1]), remotePort: 443)
        let destination: (String) -> ConnectionName.Kind = { _ in .destination }
        let attached = table.apply([FlowEvent(key: key, kind: .named("old.example.com", .sni))], at: t0, kind: destination)
        XCTAssertEqual(attached.map(\.outcome.name?.name), ["old.example.com"])

        XCTAssertTrue(table.apply([FlowEvent(key: key, kind: .opened)], at: t0 + 60, kind: destination).isEmpty)
        XCTAssertNil(table.outcome(for: key.text), "the new connection waits for its own outcome")

        _ = table.apply([FlowEvent(key: key, kind: .opened), FlowEvent(key: key, kind: .named("new.example.com", .quic))], at: t0 + 120, kind: destination)
        XCTAssertEqual(table.outcome(for: key.text)?.name?.name, "new.example.com", "an outcome in the same batch as the open is kept")
        let later = table.apply([FlowEvent(key: key, kind: .unnamed(.timeout))], at: t0 + 140, kind: destination)
        XCTAssertEqual(later.map(\.openedAt), [t0 + 120], "history is told when the flow opened, so older rows are left alone")
    }

    func testUnnamedReasonOnTheRowAndInHistoryCodes() {
        let owner = ConnectionOwner(processName: "RCMservice")
        let silent = LiveConnection(connection: connection("40.82.255.130", port: 80), owner: owner, isNew: false, outcome: .unnamed(.timeout))
        XCTAssertNil(silent.name)
        XCTAssertEqual(silent.title, "40.82.255.130:80")
        XCTAssertEqual(silent.facts(now: t0).first { $0.name == "No name" }?.value, "the connection sent nothing in its first 20 seconds")
        XCTAssertNil(LiveConnection(connection: connection("1.1.1.1"), owner: owner, isNew: false).facts(now: t0).first { $0.name == "No name" }, "nothing to say until the sniffer gives up")

        for reason in [FlowEvent.Reason.notHandshake, .gap, .noServerName, .quic(.unsupportedVersion), .quic(.decryptFailed), .timeout] {
            XCTAssertTrue(reason.code.hasPrefix("none:"), "a reason is never mistaken for a source")
            XCTAssertEqual(FlowEvent.Reason(code: reason.code), reason)
        }
        XCTAssertNil(FlowEvent.Reason(code: "sni"))
        XCTAssertNil(FlowEvent.Reason(code: "none:quic-nonsense"))
    }
}
