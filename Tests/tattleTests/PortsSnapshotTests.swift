import XCTest
@testable import tattle

final class PortsSnapshotTests: XCTestCase {
    private func entry(_ proto: SocketEntry.Proto, _ local: String, _ port: UInt16, pid: Int32, v6: Bool = false,
                       state: Int32? = nil, remotePort: UInt16 = 0, uid: UInt32 = 501) -> SocketEntry {
        SocketEntry(proto: proto, isIPv6: v6, localAddress: local, localPort: port, remoteAddress: v6 ? "::" : "0.0.0.0",
                    remotePort: remotePort, tcpState: proto == .tcp ? (state ?? SocketEntry.tcpListen) : nil,
                    pid: pid, effectivePid: 0, uid: uid)
    }

    private let services = ServiceNames.parse("""
        # comment
        ssh              22/udp     # SSH Remote Login Protocol
        ssh              22/tcp     # SSH Remote Login Protocol
        commplex-main  5000/tcp
        afs3-fileserver 7000/tcp   bbs
        """)

    func testGroupsMergesFamiliesAndIgnoresConnections() {
        let entries = [
            entry(.tcp, "0.0.0.0", 5000, pid: 634),
            entry(.tcp, "::", 5000, pid: 634, v6: true),
            entry(.tcp, "127.0.0.1", 8021, pid: 99, uid: 0),
            entry(.tcp, "192.168.1.5", 22, pid: 7, uid: 0),
            entry(.tcp, "192.168.1.5", 61000, pid: 1, state: SocketEntry.tcpEstablished, remotePort: 443),
            entry(.udp, "0.0.0.0", 5353, pid: 300),
            entry(.udp, "0.0.0.0", 60000, pid: 300),
            entry(.udp, "0.0.0.0", 0, pid: 300),
        ]
        let snapshot = PortsSnapshot.build(entries: entries, services: services, identity: { pid in
            pid == 634 ? ProcessIdentity(pid: 634, name: "ControlCenter", path: "/System/ControlCenter") : nil
        }, signature: { _ in CodeSignature(signer: .apple) })

        XCTAssertEqual(snapshot.items.count, 5)
        let network = snapshot.items(in: .network)
        XCTAssertEqual(network.map(\.port), [22, 5000, 5353])
        XCTAssertEqual(network[1].families, "IPv4 and IPv6")
        XCTAssertEqual(network[1].processName, "ControlCenter")
        XCTAssertEqual(network[1].signature?.signer, .apple)
        XCTAssertEqual(network[1].serviceName, "commplex-main")
        XCTAssertEqual(network[1].explainKey, "ControlCenter:tcp/5000")
        XCTAssertEqual(network[0].binding, .address("192.168.1.5"))
        XCTAssertEqual(network[0].processName, "pid 7", "unknown process keeps the pid")
        XCTAssertNil(network[0].signature)
        XCTAssertEqual(network[0].facts.first { $0.name == "Runs as" }?.value, "root")

        XCTAssertEqual(snapshot.items(in: .local).map(\.port), [8021])
        XCTAssertEqual(snapshot.items(in: .local)[0].binding, .loopback)
        XCTAssertEqual(snapshot.items(in: .ephemeral).map(\.port), [60000])
    }

    /// What the panel shows differs from what a prompt carries: a development certificate is
    /// named after the developer, and the user's account after their login.
    private func assertPromptValuesDiffer(_ facts: [Fact], runsAs: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let signed = facts.first { $0.name == "Signed by" }
        XCTAssertEqual(signed?.value, "Apple Development (ABCDE12345)", file: file, line: line)
        XCTAssertNil(signed?.promptValue, "the panel's value carries no name, so the model gets it too", file: file, line: line)
        guard runsAs else { return }
        let login = String(cString: getpwuid(getuid()).pointee.pw_name)
        let account = facts.first { $0.name == "Runs as" }
        XCTAssertEqual(account?.value, "you (\(login))", file: file, line: line)
        XCTAssertEqual(account?.promptValue, "you", file: file, line: line)
    }

    func testPortFactsKeepTheLoginAndCertificateNameOutOfTheirPromptValues() throws {
        let snapshot = PortsSnapshot.build(
            entries: [entry(.tcp, "0.0.0.0", 5000, pid: 634, uid: getuid())], services: services,
            identity: { _ in ProcessIdentity(pid: 634, name: "Mine", path: "/x/Mine") },
            signature: { _ in CodeSignature(signer: .development, teamIdentifier: "ABCDE12345") })
        assertPromptValuesDiffer(try XCTUnwrap(snapshot.items.first).facts, runsAs: true)
    }

    func testServiceNames() {
        XCTAssertEqual(services.name(port: 22, proto: .tcp), "ssh")
        XCTAssertEqual(services.name(port: 7000, proto: .tcp), "afs3-fileserver")
        XCTAssertNil(services.name(port: 7000, proto: .udp))
        XCTAssertEqual(ServiceNames.load().name(port: 443, proto: .tcp), "https")
    }

    func testBuiltinPortRulesResolve() throws {
        let database = try AppDatabase.inMemory()
        let rules = RuleStore(database: database)
        let repoSeeds = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources/knowledge")
        SeedLoader(rules: rules, settings: SettingsStore(database: database)).load(from: repoSeeds)
        XCTAssertEqual(try rules.lookup(kind: .port, key: "ControlCenter:tcp/5000")?.category, "sharing")
        XCTAssertEqual(try rules.lookup(kind: .port, key: "Comet Helper:udp/5353")?.category, "system")
        XCTAssertEqual(try rules.lookup(kind: .port, key: "mDNSResponder:udp/5353")?.purpose.prefix(8), "The macO")
        XCTAssertNil(try rules.lookup(kind: .port, key: "node:tcp/11001"))
    }

    func testThisMachine() throws {
        let snapshot = PortsSnapshot.build(entries: try SocketTable.read(), services: ServiceNames.load(),
                                           identity: ProcessIdentity.read(pid:), signature: { _ in nil })
        XCTAssertFalse(snapshot.items.isEmpty)
        XCTAssertEqual(Set(snapshot.items.map(\.id)).count, snapshot.items.count)
    }
}
