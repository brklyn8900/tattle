import GRDB
import XCTest
@testable import tattle

final class NetworkSnapshotTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(_ pid: Int32, _ ppid: Int32, _ path: String) -> ProcessEntry {
        ProcessEntry(pid: pid, parentPid: ppid, uid: 501, name: URL(fileURLWithPath: path).lastPathComponent, path: path, started: t0)
    }

    private func connection(_ pid: Int32, _ remote: String, port: UInt16 = 443, at: TimeInterval = 0, scope: Connection.Scope = .remote, preExisting: Bool = false, direction: Connection.Direction = .outbound) -> Connection {
        Connection(id: "\(pid):tcp/5\(Int(at))>\(remote):\(port)", proto: .tcp, pid: pid, uid: 501, localPort: 50000,
                   remoteAddress: remote, remotePort: port, isIPv6: false, scope: scope, tcpState: 4,
                   firstSeen: t0 + at, lastSeen: t0 + at, ended: nil, preExisting: preExisting, direction: direction)
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

    /// A bundle's signature is read without its resources, so it says nothing of a file put
    /// in the bundle: an answer given for the app is not about that file. What the app only
    /// launches is filed under it and is not part of it.
    func testAFileInABundleItsSignerDidNotSignTakesAwayTheRowsIdentity() throws {
        let copied = "/Users/x/Copy/Slack.app"
        let slack = CodeSignature(signer: .developerID(name: "Slack Technologies"), identifier: "com.tinyspeck.slackmacgap", teamIdentifier: "BQR82RBBHL")
        let signatures: [String: CodeSignature] = [
            copied: slack, "\(copied)/Contents/MacOS/Slack": slack, "\(copied)/Contents/Frameworks/Helper": slack,
            "\(copied)/Contents/MacOS/dropper": CodeSignature(signer: .unsigned), "/usr/bin/curl": CodeSignature(signer: .apple, identifier: "com.apple.curl"),
        ]
        let list = [entry(800, 1, "\(copied)/Contents/MacOS/Slack"), entry(801, 800, "\(copied)/Contents/Frameworks/Helper"),
                    entry(802, 800, "/usr/bin/curl"), entry(803, 1, "\(copied)/Contents/MacOS/dropper")]
        let byPid = Dictionary(list.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        func row(_ pids: Int32...) -> ConnectionGroup? {
            NetworkSnapshot(connections: pids.map { pid in
                LiveConnection(connection: connection(pid, "1.1.1.1"),
                               owner: ConnectionOwner.resolve(pid: pid, in: byPid, runningApp: { _ in nil }, responsible: { _ in nil }, signature: { signatures[$0] }),
                               isNew: false)
            }, takenAt: t0).groups.first
        }
        let app: CodeIdentity = "team:BQR82RBBHL:com.tinyspeck.slackmacgap"
        XCTAssertEqual(row(800, 801)?.identity, app, "the app and its own helper")
        XCTAssertEqual(row(800, 802)?.identity, app, "what it launches")
        XCTAssertNil(row(803)?.identity)
        XCTAssertNil(row(800, 803)?.identity)

        func group(_ entries: [ProcessEntry]) -> ProcessGroup? {
            ProcessSnapshot.build(entries: entries, previous: nil, signature: { signatures[$0] }, runningApp: { _ in nil }, responsible: { _ in nil }, takenAt: t0).group(id: copied)
        }
        XCTAssertEqual(group(Array(list.dropLast()))?.identity, app)
        XCTAssertNil(group(list)?.identity, "the Processes tab's row too")
    }

    /// Code with no team has no signer to share: ad hoc, only the bundle's own code is its own.
    func testAnAdHocBundleOwnsOnlyItsOwnCode() throws {
        let bundle = "/Users/x/Tool.app"
        let own = CodeSignature(signer: .adHoc, identifier: "tool", codeHash: "aa")
        let signatures: [String: CodeSignature] = [
            bundle: own, "\(bundle)/Contents/MacOS/Tool": own,
            "\(bundle)/Contents/MacOS/dropper": CodeSignature(signer: .adHoc, identifier: "dropper", codeHash: "bb"),
        ]
        let list = [entry(810, 1, "\(bundle)/Contents/MacOS/Tool"), entry(811, 1, "\(bundle)/Contents/MacOS/dropper")]
        let byPid = Dictionary(list.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        func owner(_ pid: Int32) -> ConnectionOwner {
            ConnectionOwner.resolve(pid: pid, in: byPid, runningApp: { _ in nil }, responsible: { _ in nil }, signature: { signatures[$0] })
        }
        XCTAssertNotNil(owner(810).groupIdentity)
        XCTAssertNil(owner(811).groupIdentity)
    }

    /// A process that replaces itself with another program keeps its pid: the connections it
    /// opens next are the new program's. One whose path cannot be read is left as it is.
    func testAnOwnerIsReadAgainWhenItsPidRunsAnotherExecutable() {
        let owners: [Int32: ConnectionOwner] = [1: ConnectionOwner(processName: "a", path: "/x/a"), 2: ConnectionOwner(processName: "b", path: "/x/b"),
                                                3: ConnectionOwner(processName: "c", path: "/x/c")]
        let running: [Int32: String] = [1: "/x/new", 2: "/x/b", 4: "/x/d"]
        XCTAssertEqual(ConnectionOwner.unresolved(opened: [1, 2, 3, 4], known: owners, executable: { running[$0] }, commandName: { _ in nil }), [1, 4])
    }

    /// A program whose file is gone has no path, and neither has a tool upgraded in place or a
    /// process that has exited: the kernel's name for it tells them apart.
    func testAnOwnerIsReadAgainWhenItsPidRunsAProgramWhoseFileIsGone() {
        let owners: [Int32: ConnectionOwner] = [
            1: ConnectionOwner(processName: "job.sh", path: "/bin/bash"),
            2: ConnectionOwner(processName: "tool", path: "/x/tool"),
            3: ConnectionOwner(processName: "exited", path: "/x/exited"),
            4: ConnectionOwner(processName: "read with no path"),
            5: ConnectionOwner(processName: "long", path: "/x/a-very-long-executable-name"),
        ]
        let names: [Int32: String] = [1: "dropper", 2: "tool", 4: "dropper", 5: "a-very-long-exec"]
        XCTAssertEqual(ConnectionOwner.unresolved(opened: [1, 2, 3, 4, 5], known: owners, executable: { _ in nil }, commandName: { names[$0] }), [1])
    }

    /// A host's answer is shown on every connection to that host, so the model is told about
    /// the host: what it hears of this connection's owner it would say of theirs.
    func testAHostIsExplainedWithoutTheProgramThatConnected() throws {
        let team = CodeSignature(signer: .developerID(name: "Acme"), teamIdentifier: "ABCDE12345")
        let owner = ConnectionOwner(processName: "job.py", path: "/opt/python3", interpreter: "python3", app: AppBundle(path: "/Applications/Slack.app"),
                                    signature: team, interpreterSignature: team, appSignature: CodeSignature(signer: .developerID(name: "Slack"), teamIdentifier: "BQR82RBBHL"))
        let facts = LiveConnection(connection: connection(1, "1.1.1.1"), owner: owner, isNew: false).facts(now: t0)
        let told = Set(facts.filter(\.inPrompt).map(\.name))
        for name in ["Process", "Runs with", "App", "Signed by", "Team", "Interpreter signed by", "Interpreter team", "App signed by", "App team", "Runs as"] {
            XCTAssertTrue(facts.contains { $0.name == name }, "the panel shows \(name)")
            XCTAssertFalse(told.contains(name), "the model is not told \(name)")
        }
        XCTAssertTrue(told.isSuperset(of: ["Protocol", "Reach"]), "\(told)")
    }

    /// An answer is kept for the host and shown on connections either way: what an outbound
    /// row says of its direction stays in the panel.
    func testAnOutboundConnectionKeepsItsDirectionFromTheModel() {
        let names: [NameOutcome?] = [nil] + [ConnectionName.Kind.destination, .relay, .hidden].map {
            .named(ConnectionName(name: "example.com", source: .sni, kind: $0))
        }
        for outcome in names {
            let row = LiveConnection(connection: connection(100, "203.0.113.5"), owner: ConnectionOwner(processName: "tool"), isNew: true, outcome: outcome)
            let facts = row.facts(now: t0)
            for claim in ["Destination", "First contact"] {
                XCTAssertEqual(facts.filter { $0.name == claim }.map(\.inPrompt), [false], "\(claim) with \(String(describing: outcome))")
            }
        }
    }

    /// The peer came to this Mac: it is no destination, and no first contact of this Mac's.
    func testAnInboundConnectionReadsAsInbound() throws {
        var accepted = connection(100, "203.0.113.5", port: 51514)
        accepted.localPort = 22
        accepted.direction = .inbound
        let owner = ConnectionOwner(processName: "sshd")
        let row = LiveConnection(connection: accepted, owner: owner, isNew: false)
        XCTAssertEqual(row.headline, "sshd from 203.0.113.5:51514")
        let facts = row.facts(now: t0)
        let values = Dictionary(facts.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(values["From"], "203.0.113.5:51514")
        XCTAssertEqual(values["To port"], "22")
        XCTAssertNil(values["Destination"], "the model is not told the peer is where this Mac went")
        XCTAssertNil(values["First contact"])
        XCTAssertTrue(Set(facts.filter(\.inPrompt).map(\.name)).isDisjoint(with: ["From", "To port"]),
                      "an answer is kept for the host and shown on connections either way")

        let out = LiveConnection(connection: connection(100, "17.1.1.1"), owner: owner, isNew: false)
        XCTAssertEqual(out.headline, "sshd to 17.1.1.1:443")
        let group = ConnectionGroup(id: "sshd", name: "sshd", connections: [row, out, LiveConnection(connection: connection(100, "192.168.1.9", scope: .local), owner: owner, isNew: false)])
        XCTAssertEqual(group.reachSummary, ["1 to the internet", "1 from the internet", "1 on this network"])
    }

    /// With nothing to say which side called, a row claims neither, and is no first contact.
    func testAConnectionNothingProvesClaimsNoDirection() throws {
        let owner = ConnectionOwner(processName: "tool")
        let row = LiveConnection(connection: connection(100, "203.0.113.5", direction: .unknown), owner: owner, isNew: false)
        XCTAssertEqual(row.headline, "tool with 203.0.113.5:443")
        let facts = row.facts(now: t0)
        let values = Dictionary(facts.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(values["Peer"], "203.0.113.5:443")
        XCTAssertEqual(values["Local port"], "50000")
        for claim in ["Destination", "From", "To port", "First contact"] { XCTAssertNil(values[claim], claim) }
        XCTAssertFalse(Set(facts.filter(\.inPrompt).map(\.name)).contains("Peer"))

        let group = ConnectionGroup(id: "tool", name: "tool", connections: [
            row, LiveConnection(connection: connection(100, "17.1.1.1"), owner: owner, isNew: false),
            LiveConnection(connection: connection(100, "192.168.1.9", scope: .local, direction: .unknown), owner: owner, isNew: false),
        ])
        XCTAssertEqual(group.reachSummary, ["1 to the internet", "1 with the internet", "1 on this network"])
    }

    /// The SYN's event can arrive after the row: it settles the row and counts as first contact.
    func testASeenOpeningSettlesARowAlreadyShown() throws {
        var snapshot = NetworkSnapshot(connections: [
            LiveConnection(connection: connection(100, "203.0.113.5", direction: .unknown), owner: ConnectionOwner(processName: "tool"), isNew: false),
        ], takenAt: t0)
        let id = try XCTUnwrap(snapshot.connections.first?.id)
        XCTAssertTrue(snapshot.confirmOutbound(id: id, isNew: true))
        XCTAssertEqual(snapshot.connections.first?.connection.direction, .outbound)
        XCTAssertEqual(snapshot.connections.first?.isNew, true)
        XCTAssertFalse(snapshot.confirmOutbound(id: "other", isNew: true))
    }

    /// The processes and sockets a reading finds. A test can end processes while the reading
    /// resolves owners. Pids from 9,000,000 up are ones no process can have, so the real calls
    /// behind a reading find nothing of their own for them.
    private final class World: @unchecked Sendable {
        struct Unreadable: Error {}
        private let lock = NSLock()
        private var processes: [Int32: ProcessEntry]
        private let unreadable: Bool
        private var sockets: [SocketEntry] = []
        private var reads: [Int32] = []
        private var endingWhenTaken: [Int32: [Int32]] = [:]

        /// `unreadable`: the kernel will not report on processes.
        init(_ processes: [ProcessEntry], unreadable: Bool = false) {
            self.processes = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
            self.unreadable = unreadable
        }

        /// Ends `pids` as `pid`'s record is taken.
        func endWhenTaken(_ pid: Int32, ending pids: [Int32]) { lock.withLock { endingWhenTaken[pid] = pids } }

        var table: [SocketEntry] {
            get { lock.withLock { sockets } }
            set { lock.withLock { sockets = newValue } }
        }

        /// Every process read beyond its record, in order, repeats included.
        var readPids: [Int32] { lock.withLock { reads } }

        /// Every process's record, as the kernel lists them in one go.
        func records() throws -> [Int32: ProcessEntry] {
            try lock.withLock {
                if unreadable { throw Unreadable() }
                defer { for pid in processes.keys { endingWhenTaken[pid]?.forEach { processes[$0] = nil } } }
                return processes
            }
        }

        /// The rest of a process, read from the system now: one that has exited since its record
        /// was taken has no path.
        func entry(_ record: ProcessEntry) -> ProcessEntry? {
            lock.withLock {
                reads.append(record.pid)
                guard processes[record.pid] == nil else { return record }
                var exited = record
                exited.path = nil
                return exited
            }
        }

        func end(_ pids: [Int32]) { lock.withLock { pids.forEach { processes[$0] = nil } } }
    }

    @MainActor
    private func observer(in world: World, signature: @escaping @Sendable (String) -> CodeSignature? = { _ in nil }) throws -> NetworkObserver {
        let database = try AppDatabase.inMemory()
        return NetworkObserver(store: ConnectionStore(database: database), rules: RuleStore(database: database),
                               settings: try AppSettings(store: SettingsStore(database: database)),
                               socketTable: { world.table },
                               processLines: { ProcessTable.lines(of: $0, table: world.records, parent: \.parentPid, entry: world.entry, responsible: { _ in nil }) },
                               signature: signature)
    }

    private func socket(_ pid: Int32, localPort: UInt16) -> SocketEntry {
        SocketEntry(proto: .tcp, isIPv6: false, localAddress: "192.168.1.5", localPort: localPort, remoteAddress: "17.1.1.1", remotePort: 443,
                    tcpState: SocketEntry.tcpEstablished, pid: pid, effectivePid: 0, uid: 501)
    }

    /// Beyond the processes' records, a reading reads the owners it has not met and the lines
    /// their apps can come from, not the table, and an owner it knows that still runs the same
    /// program is not read again.
    @MainActor
    func testAReadingReadsOnlyNewOwnersAndTheirLines() async throws {
        let me = getpid()
        let world = World([
            entry(me, 9_000_002, try XCTUnwrap(ProcessTable.pidPath(me))),
            entry(9_000_002, 1, "/Applications/Slack.app/Contents/MacOS/Slack"),
            entry(9_000_003, 1, "/x/bystander"),
        ])
        let observer = try observer(in: world)
        world.table = [socket(me, localPort: 40000)]
        await observer.read()
        XCTAssertEqual(world.readPids.sorted(), [me, 9_000_002], "the owner and its line, each once")

        world.table = [socket(me, localPort: 40000), socket(me, localPort: 40001)]
        await observer.read()
        XCTAssertEqual(world.readPids.sorted(), [me, 9_000_002], "a known owner still running the same program is not read again")
    }

    /// Two owners open connections in one reading, and every process in their lines exits as
    /// soon as the first signature is read. Their lines were read with the table, so both
    /// still reach their apps.
    @MainActor
    func testOwnersKeepTheirLinesWhenTheyExitWhileTheReadingResolvesThem() async throws {
        let line = [
            entry(9_000_011, 9_000_012, "/x/helper-a"), entry(9_000_012, 1, "/Applications/Slack.app/Contents/MacOS/Slack"),
            entry(9_000_021, 9_000_022, "/x/helper-b"), entry(9_000_022, 1, "/Applications/Zoom.app/Contents/MacOS/Zoom"),
        ]
        let world = World(line)
        let observer = try observer(in: world, signature: { _ in world.end(line.map(\.pid)); return nil })
        world.table = [socket(9_000_011, localPort: 40000), socket(9_000_021, localPort: 40001)]
        await observer.read()
        let owners = Dictionary((observer.snapshot?.connections ?? []).map { ($0.connection.pid, $0.owner) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(owners[9_000_011]?.processName, "helper-a")
        XCTAssertEqual(owners[9_000_011]?.app?.name, "Slack")
        XCTAssertEqual(owners[9_000_021]?.processName, "helper-b")
        XCTAssertEqual(owners[9_000_021]?.app?.name, "Zoom")
    }

    /// A helper's parent exits as the helper is read. The parent was running when the reading
    /// began, so the helper still reaches the app above it.
    @MainActor
    func testAHelperWhoseParentExitsAsItIsReadKeepsItsApp() async throws {
        let world = World([
            entry(9_000_041, 9_000_042, "/x/helper"), entry(9_000_042, 9_000_043, "/x/launcher"),
            entry(9_000_043, 1, "/Applications/Slack.app/Contents/MacOS/Slack"),
        ])
        world.endWhenTaken(9_000_041, ending: [9_000_042])
        let observer = try observer(in: world)
        world.table = [socket(9_000_041, localPort: 40000)]
        await observer.read()
        let owner = try XCTUnwrap(observer.snapshot?.connections.first?.owner)
        XCTAssertEqual(owner.processName, "helper")
        XCTAssertEqual(owner.app?.name, "Slack")
    }

    /// A process the kernel will not report on is not taken for one that exited.
    @MainActor
    func testAnOwnerTheKernelWillNotReadIsUnknownNotExited() async throws {
        let world = World([], unreadable: true)
        let observer = try observer(in: world)
        world.table = [socket(9_000_031, localPort: 40000)]
        await observer.read()
        XCTAssertEqual(observer.snapshot?.connections.first?.owner, .unknown)
    }

    /// A reading waits off the main actor for a new pid's owner, and the SYN's event can land
    /// in that gap, before the row and its history exist.
    @MainActor
    func testAnOpeningSeenWhileAReadingResolvesOwnersReachesTheRowAndItsHistory() async throws {
        let database = try AppDatabase.inMemory()
        let store = ConnectionStore(database: database)
        let observer = NetworkObserver(store: store, rules: RuleStore(database: database),
                                       settings: try AppSettings(store: SettingsStore(database: database)))
        let now = Date()
        let socket = SocketEntry(proto: .tcp, isIPv6: false, localAddress: "192.168.1.5", localPort: 40000, remoteAddress: "17.1.1.1", remotePort: 443,
                                 tcpState: SocketEntry.tcpEstablished, pid: getpid(), effectivePid: 0, uid: 501)
        let reading = Task { await observer.fold(entries: [socket], lines: ProcessLines(), now: now) }
        await Task.yield()
        XCTAssertNil(observer.snapshot, "the reading is waiting for the owner")
        observer.confirmOutbound(FlowKey(proto: .tcp, localPort: 40000, remote: IPAddress(bytes: [17, 1, 1, 1]), remotePort: 443), openedAt: now)
        await reading.value
        let row = try XCTUnwrap(observer.snapshot?.connections.first)
        XCTAssertEqual(row.connection.direction, .outbound)
        XCTAssertTrue(row.isNew, "an address never seen is a first contact")
        XCTAssertEqual(try store.history(remoteAddress: "17.1.1.1").first?.direction, .outbound)
    }

    func testFirstContactCountsOnlyThisMacReachingOut() {
        var known = Set<String>()
        var accepted = connection(100, "203.0.113.5")
        accepted.direction = .inbound
        XCTAssertFalse(LiveConnection.isFirstContact(accepted, known: &known))
        XCTAssertFalse(LiveConnection.isFirstContact(connection(100, "203.0.113.5", direction: .unknown), known: &known))
        XCTAssertTrue(known.isEmpty, "a later connection out to the peer is still a first contact")
        XCTAssertTrue(LiveConnection.isFirstContact(connection(100, "203.0.113.5"), known: &known))
        XCTAssertFalse(LiveConnection.isFirstContact(connection(100, "203.0.113.5"), known: &known))
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
