import GRDB
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
        XCTAssertEqual(signed?.value, "Apple Development (ABCDE12345)", file: file, line: line)
        XCTAssertNil(signed?.promptValue, "the panel's value carries no name, so the model gets it too", file: file, line: line)
        guard runsAs else { return }
        let login = String(cString: getpwuid(getuid()).pointee.pw_name)
        let account = facts.first { $0.name == "Runs as" }
        XCTAssertEqual(account?.value, "you (\(login))", file: file, line: line)
        XCTAssertEqual(account?.promptValue, "you", file: file, line: line)
    }

    func testProcessGroupFactsKeepTheCertificateNameOutOfTheirPromptValue() throws {
        let owner = ConnectionOwner(processName: "Mine", signature: CodeSignature(signer: .development, teamIdentifier: "ABCDE12345"))
        let snapshot = NetworkSnapshot(connections: [
            LiveConnection(connection: connection(100, "52.1.1.1"), owner: owner, isNew: false),
        ], takenAt: t0)
        assertPromptValuesDiffer(try XCTUnwrap(snapshot.groups.first).facts(gone: false), runsAs: false)
    }

    func testConnectionFactsKeepTheLoginOutOfTheirPromptValue() throws {
        var mine = connection(100, "52.1.1.1")
        mine.uid = getuid()
        let owner = ConnectionOwner(processName: "Mine", signature: CodeSignature(signer: .development, teamIdentifier: "ABCDE12345"))
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
        XCTAssertEqual(Set(read), [processes[101]!.path!, "/Applications/Slack.app"], "the helper's own file, and the app apart")

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

    /// The app a connection is filed under says nothing about the code that made it: anything
    /// run from an app's terminal, or put inside its bundle, would borrow the app's signer.
    func testAConnectionIsSignedByItsOwnProcessAndItsAppApart() throws {
        let terminal = "/Applications/iTerm.app"
        let copied = "/Users/x/Copy/Slack.app"
        let developer = CodeSignature(signer: .developerID(name: "EXAMPLE DEVELOPER"), identifier: "com.googlecode.iterm2", teamIdentifier: "EXAMPLE123")
        let slack = CodeSignature(signer: .developerID(name: "Slack Technologies"), identifier: "com.tinyspeck.slackmacgap", teamIdentifier: "BQR82RBBHL")
        let signatures: [String: CodeSignature] = [
            terminal: developer, "\(terminal)/Contents/MacOS/iTerm2": developer, "/usr/bin/curl": CodeSignature(signer: .apple, identifier: "com.apple.curl"),
            copied: slack, "\(copied)/Contents/MacOS/dropper": CodeSignature(signer: .unsigned),
        ]
        let list = [
            entry(700, 1, "\(terminal)/Contents/MacOS/iTerm2"), entry(701, 700, "/usr/bin/curl"), entry(702, 1, "\(copied)/Contents/MacOS/dropper"),
        ]
        let byPid = Dictionary(list.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        func owner(_ pid: Int32) -> ConnectionOwner {
            ConnectionOwner.resolve(pid: pid, in: byPid, runningApp: { _ in nil }, responsible: { _ in nil }, signature: { signatures[$0] })
        }

        let curl = owner(701)
        XCTAssertEqual(curl.displayName, "iTerm", "filed under the terminal, as before")
        XCTAssertEqual(curl.signature?.summary, "Apple")
        XCTAssertEqual(curl.appSignature?.summary, "EXAMPLE DEVELOPER")
        var facts = Dictionary(LiveConnection(connection: connection(701, "1.1.1.1"), owner: curl, isNew: false).facts(now: t0).map { ($0.name, $0.value) },
                               uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(facts["Signed by"], "Apple")
        XCTAssertEqual(facts["App signed by"], "EXAMPLE DEVELOPER")
        XCTAssertEqual(facts["App team"], "EXAMPLE123")
        XCTAssertNil(facts["Team"], "Apple's curl has none, and the terminal's is not its")

        let dropper = owner(702)
        XCTAssertEqual(dropper.displayName, "Slack")
        XCTAssertEqual(dropper.signature?.summary, "unsigned", "a file put in a copied bundle does not read as the bundle's")
        XCTAssertEqual(dropper.appSignature?.summary, "Slack Technologies")

        let same = owner(700)
        facts = Dictionary(LiveConnection(connection: connection(700, "1.1.1.1"), owner: same, isNew: false).facts(now: t0).map { ($0.name, $0.value) },
                           uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(facts["Signed by"], "EXAMPLE DEVELOPER")
        XCTAssertNil(facts["App signed by"], "said once when the app's signer is the process's")

        let snapshot = NetworkSnapshot(connections: [
            LiveConnection(connection: connection(701, "1.1.1.1"), owner: curl, isNew: false),
        ], takenAt: t0)
        XCTAssertEqual(snapshot.groups.first?.signature?.summary, "EXAMPLE DEVELOPER", "the row is the app's")
    }

    /// A process that took a name shares its row: the newest connection's signer alone would
    /// read as Apple's with the impostor's connections inside.
    func testARowWhoseConnectionsDifferNamesNoSigner() throws {
        func live(_ pid: Int32, _ signature: CodeSignature, at: TimeInterval) -> LiveConnection {
            LiveConnection(connection: connection(pid, "1.1.1.1", at: at), owner: ConnectionOwner(processName: "curl", signature: signature), isNew: false)
        }
        let apple = CodeSignature(signer: .apple, identifier: "com.apple.curl")
        let mixed = try XCTUnwrap(NetworkSnapshot(connections: [live(1, CodeSignature(signer: .unsigned), at: 0), live(2, apple, at: 1)], takenAt: t0).groups.first)
        XCTAssertNil(mixed.signature)
        XCTAssertFalse(mixed.facts(gone: false).contains { $0.name == "Signed by" }, "nor is the model told one")

        let same = try XCTUnwrap(NetworkSnapshot(connections: [live(1, apple, at: 0), live(2, apple, at: 1)], takenAt: t0).groups.first)
        XCTAssertEqual(same.signature?.summary, "Apple")
    }

    /// A process as Network lists it: named without its signature.
    private func listed(_ pid: Int32, _ parent: Int32, _ path: String, _ arguments: [String]) -> ProcessEntry {
        let named = ProcessEntry.name(path: path, arguments: arguments, command: "", startedByLaunchd: parent == 1)
        return ProcessEntry(pid: pid, parentPid: parent, uid: 501, name: named.name, path: path, interpreter: named.interpreter,
                            runsUnnamedCode: named.runsUnnamedCode, arguments: arguments, started: t0)
    }

    private func facts(_ owner: ConnectionOwner) -> [String: String] {
        Dictionary(LiveConnection(connection: connection(1, "1.1.1.1"), owner: owner, isNew: false).facts(now: t0).map { ($0.name, $0.value) },
                   uniquingKeysWith: { a, _ in a })
    }

    private func owner(_ pid: Int32, _ list: [ProcessEntry], signatures: [String: CodeSignature],
                       runningApp: @escaping (Int32) -> String? = { _ in nil }) -> ConnectionOwner {
        let byPid = Dictionary(list.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        return ConnectionOwner.resolve(pid: pid, in: byPid, runningApp: runningApp, responsible: { _ in nil }, signature: { signatures[$0] })
    }

    /// A copy of Apple's bash under another name is known as bash only by its signature, so
    /// the listing alone reads it as a program of Apple's.
    func testARenamedCopyOfApplesInterpreterReadsAsTheScriptItRuns() {
        let copy = "/Users/x/updater"
        let owner = owner(700, [listed(700, 1, copy, [copy, "/Users/x/job.sh"])], signatures: [copy: CodeSignature(signer: .apple, identifier: "com.apple.bash")])
        XCTAssertEqual(owner.processName, "job.sh")
        XCTAssertEqual(owner.interpreter, "updater")
        XCTAssertEqual(owner.signature?.summary, "script, not signed")
        XCTAssertEqual(owner.interpreterSignature?.summary, "Apple")
        XCTAssertFalse(owner.isApplesProgram)
        let facts = facts(owner)
        XCTAssertEqual(facts["Signed by"], "script, not signed")
        XCTAssertEqual(facts["Runs with"], "updater (\(copy))")
        XCTAssertEqual(facts["Interpreter signed by"], "Apple")
    }

    func testInlineCodeUnderApplesInterpreterIsNotApples() {
        let owner = owner(700, [listed(700, 1, "/bin/zsh", ["/bin/zsh", "-c", "curl x | sh"])], signatures: ["/bin/zsh": CodeSignature(signer: .apple, identifier: "com.apple.zsh")])
        XCTAssertEqual(owner.signature?.summary, "unnamed code")
        XCTAssertEqual(owner.interpreterSignature?.summary, "Apple")
        XCTAssertFalse(owner.isApplesProgram)
    }

    func testApplesOwnProgramStaysApples() {
        let owner = owner(300, [listed(300, 1, "/usr/libexec/trustd", ["/usr/libexec/trustd"])], signatures: ["/usr/libexec/trustd": CodeSignature(signer: .apple, identifier: "com.apple.trustd")])
        XCTAssertEqual(owner.signature?.summary, "Apple")
        XCTAssertNil(owner.interpreter)
        XCTAssertNil(owner.interpreterSignature)
        XCTAssertTrue(owner.isApplesProgram)
    }

    /// One of Apple's developer tools runs what it is told, and says nothing of whose code
    /// that is, so neither it nor what it starts is filed under the Xcode it lives in.
    func testADeveloperToolIsUnnamedCodeAndFiledWhereItWasStarted() {
        let terminal = "/Applications/iTerm.app/Contents/MacOS/iTerm2"
        let git = "/Applications/Xcode.app/Contents/Developer/usr/bin/git"
        let remote = "/Applications/Xcode.app/Contents/Developer/usr/libexec/git-core/git-remote-https"
        let developer = CodeSignature(signer: .developerID(name: "EXAMPLE DEVELOPER"), teamIdentifier: "EXAMPLE123")
        let signatures: [String: CodeSignature] = [
            terminal: developer, "/Applications/iTerm.app": developer,
            git: CodeSignature(signer: .apple, identifier: "com.apple.git"), remote: CodeSignature(signer: .apple, identifier: "com.apple.git-remote-https"),
        ]
        let list = [listed(700, 1, terminal, [terminal]), listed(701, 700, git, [git, "fetch"]), listed(702, 701, remote, [remote, "origin"])]

        let tool = owner(701, list, signatures: signatures)
        XCTAssertEqual(tool.displayName, "iTerm", "not Xcode")
        XCTAssertEqual(tool.signature?.summary, "unnamed code")
        XCTAssertEqual(tool.interpreterSignature?.summary, "Apple")
        XCTAssertEqual(owner(702, list, signatures: signatures).displayName, "iTerm", "an ancestor among the developer tools is read by its signature too")
    }

    func testAnAppAmongApplesDeveloperToolsReadsAsUnnamedCode() {
        let service = "/Applications/Xcode.app/Contents/Developer/Library/Xcode/Agents/Xcode Service.app"
        let executable = "\(service)/Contents/MacOS/Xcode Service"
        let apple = CodeSignature(signer: .apple, identifier: "com.apple.dt.mcp-server", teamIdentifier: "59GAB85EFG")
        let owner = owner(700, [listed(700, 1, executable, [executable])], signatures: [executable: apple, service: apple], runningApp: { _ in service })
        XCTAssertEqual(owner.displayName, "Xcode Service")
        XCTAssertEqual(owner.signature?.summary, "unnamed code")
        XCTAssertEqual(owner.appSignature?.summary, "unnamed code")
        XCTAssertNil(facts(owner)["App signed by"], "the same reading, said once")
        let snapshot = NetworkSnapshot(connections: [LiveConnection(connection: connection(700, "1.1.1.1"), owner: owner, isNew: false)], takenAt: t0)
        XCTAssertEqual(snapshot.groups.first?.signature?.summary, "unnamed code", "the row's subtitle")
    }

    func testHistoryKeepsTheProcesssSignerAndItsAppsApart() throws {
        let owner = ConnectionOwner(processName: "curl", path: "/usr/bin/curl", app: AppBundle(path: "/Applications/iTerm.app"),
                                    signature: CodeSignature(signer: .apple), appSignature: CodeSignature(signer: .developerID(name: "EXAMPLE DEVELOPER")))
        let store = ConnectionStore(database: try AppDatabase.inMemory())
        let live = LiveConnection(connection: connection(701, "1.1.1.1"), owner: owner, isNew: false,
                                  outcome: .named(ConnectionName(name: "example.com", source: .sni, kind: .destination)))
        let saved = try store.open(ConnectionRecord(live))
        XCTAssertEqual(saved.signer, "Apple")
        XCTAssertEqual(saved.appSigner, "EXAMPLE DEVELOPER")
        XCTAssertEqual(saved.appPath, "/Applications/iTerm.app")
        XCTAssertEqual(saved.name, "example.com")
        XCTAssertEqual(saved.nameSource, "sni")
    }

    /// Before the process's own signer was read, a row under an app held the app's.
    func testAnOldRowsSignerUnderAnAppMovesToTheAppsColumn() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v3-connections")
        try queue.write { db in
            for (key, appPath) in [("under-app", "/Applications/iTerm.app" as String?), ("alone", nil)] {
                try db.execute(sql: """
                    INSERT INTO connection (key, proto, pid, uid, processName, appPath, signer, localPort, remoteAddress, remotePort, isIPv6, scope, firstSeen, lastSeen, preExisting)
                    VALUES (?, 'tcp', 1, 501, 'curl', ?, 'EXAMPLE DEVELOPER', 1, '1.1.1.1', 443, 0, 'remote', 0, 0, 0)
                    """, arguments: [key, appPath])
            }
        }
        try AppDatabase.migrator.migrate(queue)
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT key, signer, appSigner FROM connection ORDER BY key")
            XCTAssertEqual(rows.map { $0["key"] as String }, ["alone", "under-app"])
            XCTAssertEqual(rows[0]["signer"] as String?, "EXAMPLE DEVELOPER", "no app: it was the process's own")
            XCTAssertNil(rows[0]["appSigner"] as String?)
            XCTAssertNil(rows[1]["signer"] as String?, "the process's own signer was never read")
            XCTAssertEqual(rows[1]["appSigner"] as String?, "EXAMPLE DEVELOPER")
        }
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
