import XCTest
@testable import tattle

final class NetworkSnapshotTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(_ pid: Int32, _ ppid: Int32, _ path: String) -> ProcessEntry {
        ProcessEntry(pid: pid, parentPid: ppid, uid: 501, name: URL(fileURLWithPath: path).lastPathComponent, path: path, started: t0)
    }

    private func connection(_ pid: Int32, _ remote: String, port: UInt16 = 443, at: TimeInterval = 0, scope: Connection.Scope = .remote, preExisting: Bool = false) -> Connection {
        Connection(id: "\(pid):tcp/5\(Int(at))>\(remote):\(port)", proto: .tcp, pid: pid, uid: 501, localPort: 50000,
                   remoteAddress: remote, remotePort: port, isIPv6: false, scope: scope, tcpState: 4,
                   firstSeen: t0 + at, lastSeen: t0 + at, ended: nil, preExisting: preExisting)
    }

    private let processes: [Int32: ProcessEntry] = {
        let list = [
            ProcessEntry(pid: 1, parentPid: 0, uid: 0, name: "launchd", path: "/sbin/launchd", started: .distantPast),
            ProcessEntry(pid: 100, parentPid: 1, uid: 501, name: "Slack", path: "/Applications/Slack.app/Contents/MacOS/Slack", started: .distantPast),
            ProcessEntry(pid: 101, parentPid: 100, uid: 501, name: "Slack Helper", path: "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper", started: .distantPast),
            ProcessEntry(pid: 300, parentPid: 1, uid: 0, name: "trustd", path: "/usr/libexec/trustd", started: .distantPast),
            ProcessEntry(pid: 400, parentPid: 1, uid: 501, name: "com.apple.WebKit.Networking",
                         path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking", started: .distantPast),
            ProcessEntry(pid: 500, parentPid: 1, uid: 501, name: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari", started: .distantPast),
        ]
        return Dictionary(list.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
    }()

    /// What the panel shows differs from what a prompt carries: a development certificate is
    /// named after the developer, and the user's account after their login.
    private func assertPromptValuesDiffer(_ facts: [Fact], runsAs: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let signed = facts.first { $0.name == "Signed by" }
        XCTAssertEqual(signed?.value, "Username Doe", file: file, line: line)
        XCTAssertEqual(signed?.promptValue, "Apple Development", file: file, line: line)
        guard runsAs else { return }
        let login = String(cString: getpwuid(getuid()).pointee.pw_name)
        let account = facts.first { $0.name == "Runs as" }
        XCTAssertEqual(account?.value, "you (\(login))", file: file, line: line)
        XCTAssertEqual(account?.promptValue, "you", file: file, line: line)
    }

    func testProcessGroupFactsKeepTheCertificateNameOutOfTheirPromptValue() throws {
        let owner = ConnectionOwner(processName: "Mine", signature: CodeSignature(signer: .development(name: "Username Doe"), teamIdentifier: "ABCDE12345"))
        let snapshot = NetworkSnapshot(connections: [
            LiveConnection(connection: connection(100, "52.1.1.1"), owner: owner, isNew: false),
        ], takenAt: t0)
        assertPromptValuesDiffer(try XCTUnwrap(snapshot.groups.first).facts(gone: false), runsAs: false)
    }

    func testConnectionFactsKeepTheLoginOutOfTheirPromptValue() throws {
        var mine = connection(100, "52.1.1.1")
        mine.uid = getuid()
        let owner = ConnectionOwner(processName: "Mine", signature: CodeSignature(signer: .development(name: "Username Doe"), teamIdentifier: "ABCDE12345"))
        let row = LiveConnection(connection: mine, owner: owner, isNew: false)
        assertPromptValuesDiffer(row.facts(now: t0), runsAs: true)
    }

    func testOwnerResolution() {
        var read: [String] = []
        let helper = ConnectionOwner.resolve(pid: 101, in: processes, runningApp: { _ in nil }) { path in
            read.append(path)
            return CodeSignature(signer: .developerID(name: "Slack Technologies"), teamIdentifier: "BQR82RBBHL")
        }
        XCTAssertEqual(helper.displayName, "Slack")
        XCTAssertEqual(helper.processName, "Slack Helper")
        XCTAssertEqual(helper.groupID, "/Applications/Slack.app")
        XCTAssertEqual(read, ["/Applications/Slack.app"], "the app bundle is signed, not each helper")

        let daemon = ConnectionOwner.resolve(pid: 300, in: processes, runningApp: { _ in nil }) { _ in CodeSignature(signer: .apple) }
        XCTAssertEqual(daemon.displayName, "trustd")
        XCTAssertEqual(daemon.groupID, "process:trustd")
        XCTAssertEqual(ConnectionOwner.resolve(pid: 999, in: processes, runningApp: { _ in nil }, signature: { _ in nil }).processName, "pid 999")

        // Safari's networking runs in a service launchd starts for it: not a child, but
        // macOS knows whose it is.
        let service = ConnectionOwner.resolve(pid: 400, in: processes, runningApp: { _ in nil },
                                              responsible: { $0 == 400 ? 500 : nil }, signature: { _ in nil })
        XCTAssertEqual(service.displayName, "Safari")
        XCTAssertEqual(service.processName, "com.apple.WebKit.Networking")
        XCTAssertEqual(service.groupID, "/Applications/Safari.app")
        let orphan = ConnectionOwner.resolve(pid: 400, in: processes, runningApp: { _ in nil }, responsible: { _ in nil }, signature: { _ in nil })
        XCTAssertEqual(orphan.displayName, "com.apple.WebKit.Networking", "no responsible process: the service stands alone")
        XCTAssertEqual(ConnectionOwner.resolve(pid: 400, in: processes, runningApp: { _ in nil }, responsible: { _ in 400 }, signature: { _ in nil }).displayName,
                       "com.apple.WebKit.Networking", "responsible for itself")
    }

    func testGroupsAndCounts() {
        let slack = ConnectionOwner(processName: "Slack", app: AppBundle(path: "/Applications/Slack.app"))
        let helper = ConnectionOwner(processName: "Slack Helper", app: AppBundle(path: "/Applications/Slack.app"))
        let trustd = ConnectionOwner(processName: "trustd")
        let snapshot = NetworkSnapshot(connections: [
            LiveConnection(connection: connection(100, "52.1.1.1", at: 1), owner: slack, isNew: true),
            LiveConnection(connection: connection(101, "52.1.1.2", at: 5), owner: helper, isNew: false),
            LiveConnection(connection: connection(101, "192.168.1.9", port: 9100, at: 3, scope: .local), owner: helper, isNew: true),
            LiveConnection(connection: connection(300, "17.1.1.1", at: 2, preExisting: true), owner: trustd, isNew: false),
        ], takenAt: t0 + 10)

        let groups = snapshot.groups
        XCTAssertEqual(groups.map(\.name), ["Slack", "trustd"])
        XCTAssertEqual(groups[0].id, "/Applications/Slack.app", "the app and its helper are one row")
        XCTAssertEqual(groups[0].connections.map(\.connection.remoteAddress), ["52.1.1.2", "192.168.1.9", "52.1.1.1"], "newest first")
        XCTAssertEqual(groups[0].newCount, 2)
        XCTAssertEqual(groups[0].localCount, 1)
        XCTAssertEqual(snapshot.newCount, 2)
        XCTAssertEqual(snapshot.preExistingCount, 1)

        let facts = Dictionary(snapshot.connections[3].facts(now: t0 + 10).map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(facts["Destination"], "17.1.1.1:443")
        XCTAssertEqual(facts["Protocol"], "TCP, connected")
        XCTAssertEqual(facts["Since"], "before Tattle started looking")
        XCTAssertEqual(facts["First contact"], "no, seen before")
        XCTAssertEqual(snapshot.connections[0].facts(now: t0 + 10).first { $0.name == "Since" }?.value, "9 s ago")
        XCTAssertEqual(LiveConnection.ago(t0, now: t0 + 125), "2 min ago")
    }
}
