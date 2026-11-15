import XCTest
@testable import tattle

/// A signature is read from the file at a process's path, and counts for the process only
/// while that file is the code it runs.
final class RunningCodeTests: XCTestCase {
    // MARK: - On this machine

    /// A copy of one of Apple's programs, run from a folder of the test's own, with another
    /// file renamed over its path while it runs: what a program does to read as the signer of
    /// a file it is not, and what an update in place does to an app that is open.
    func testAFileRenamedOverARunningProgramDoesNotVouchForIt() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tattle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tool = folder.appending(path: "tool")
        func put(_ source: String) throws {
            let staged = folder.appending(path: "staged")
            try FileManager.default.copyItem(atPath: source, toPath: staged.path)
            XCTAssertEqual(rename(staged.path, tool.path), 0, "errno \(errno)")
        }
        try put("/bin/sleep")
        let process = Process()
        process.executableURL = tool
        process.arguments = ["600"]
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        let pid = process.processIdentifier
        let path = try XCTUnwrap(ProcessTable.pidPath(pid))
        XCTAssertFalse(ApplesProgram.isInstalled(at: path))
        let cache = SignatureCache()

        let own = try XCTUnwrap(cache.signature(of: pid, at: path))
        XCTAssertEqual(own.signer, .apple)
        XCTAssertEqual(own.identifier, "com.apple.sleep")
        XCTAssertEqual(cache.signature(of: pid, at: path), own, "and at the next reading")

        try put("/bin/cat")
        XCTAssertEqual(ProcessTable.pidPath(pid), path, "the kernel names the same path")
        XCTAssertEqual(cache.signature(at: path)?.identifier, "com.apple.cat", "the file reads as what is there now")
        XCTAssertNil(cache.signature(of: pid, at: path), "which is not what the process runs")
        XCTAssertNil(cache.signature(of: pid, at: path), "nor at the next reading")
        XCTAssertNil(SignatureCache().signature(of: pid, at: path), "nor to a reader that never saw the first file")

        try put("/bin/sleep")
        XCTAssertEqual(cache.signature(of: pid, at: path), own, "the same build back in its place")

        try put("/bin/cat")
        XCTAssertNil(cache.signature(of: pid, at: path))
        process.terminate()
        waitForExit(process)
        XCTAssertEqual(cache.signature(of: pid, at: path)?.identifier, "com.apple.cat", "a process that has ended reads as its file")
    }

    func testTheKernelSaysWhatAProcessRuns() throws {
        let own = try XCTUnwrap(RunningCode.state(of: getpid()))
        XCTAssertEqual(own.path, ProcessTable.pidPath(getpid()))
        XCTAssertEqual(own.hash?.count, 20, "the test runner is signed")
        XCTAssertEqual(own.isUnsigned, false)
        XCTAssertEqual(RunningCode.state(of: getpid()), own, "the same at the next reading")
        XCTAssertTrue(RunningCode.matchesFile(getpid()))
        let launchd = try XCTUnwrap(RunningCode.state(of: 1), "another account's process")
        XCTAssertEqual(launchd.hash?.count, 20)
        XCTAssertFalse(launchd.isUnsigned)
        XCTAssertNotEqual(launchd.hash, own.hash)
        XCTAssertNil(RunningCode.state(of: Int32.max), "no such process")
        XCTAssertFalse(RunningCode.matchesFile(Int32.max))
    }

    /// The kernel lists a process that is exiting until it is a zombie, and by then answers
    /// for neither its file nor its code: read as a running process, it would be one that runs
    /// from no path. Whether a reading lands in that window is chance, so this ends several.
    func testAProcessOnItsWayOutReadsAsEnded() throws {
        for _ in 0..<20 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["600"]
            try process.run()
            let pid = process.processIdentifier
            XCTAssertNotNil(RunningCode.state(of: pid)?.status)
            kill(pid, SIGKILL)
            while let state = RunningCode.state(of: pid) {
                XCTAssertNotNil(state.status, "listed, and described by nothing: \(state)")
                XCTAssertNotNil(state.hash, "listed, with a status and no hash for its signed code: \(state)")
            }
            process.waitUntilExit()
        }
    }

    // MARK: - When the check is made

    /// A machine with one program on it, a publisher's unless a test says otherwise, and the
    /// processes that run it.
    private final class Machine: @unchecked Sendable {
        let file = FileManager.default.temporaryDirectory.appending(path: "tattle-" + UUID().uuidString)
        var signature = CodeSignature(signer: .developerID(name: "EXAMPLE DEVELOPER"), identifier: "tool", teamIdentifier: "EXAMPLE123")
        lazy var code: RunningCode.State? = RunningCode.State(path: file.path, hash: Data([1]), status: RunningCode.signedStatus | 1)
        var ended = Set<Int32>()
        var matches = true
        var checks = 0
        var duringCheck: (() -> Void)?

        lazy var cache = SignatureCache(
            files: { _ in [] }, read: { [unowned self] _ in CodeSignature.Reading(signature: signature) },
            running: { [unowned self] pid in ended.contains(pid) ? nil : code },
            matchesFile: { [unowned self] _ in
                checks += 1
                duringCheck?()
                return matches
            })

        init() throws { try install("one") }
        deinit { try? FileManager.default.removeItem(at: file) }

        /// Puts another file at the program's path, as a rename over it does.
        func install(_ content: String) throws { try Data(content.utf8).write(to: file, options: .atomic) }

        func signer(of pid: Int32) -> CodeSignature? { cache.signature(of: pid, at: file.path) }
    }

    func testACheckIsMadeOncePerCodeAndFile() throws {
        let machine = try Machine()
        XCTAssertEqual(machine.signer(of: 7), machine.signature)
        XCTAssertEqual(machine.signer(of: 7), machine.signature)
        XCTAssertEqual(machine.checks, 1, "the same code and the same file")

        try machine.install("two")
        XCTAssertEqual(machine.signer(of: 7), machine.signature)
        XCTAssertEqual(machine.checks, 2, "another file at the path, under the same process")

        machine.code?.hash = Data([2])
        XCTAssertEqual(machine.signer(of: 7), machine.signature)
        XCTAssertEqual(machine.checks, 3, "the process started another program, or its pid went to another process")

        machine.code?.status = RunningCode.signedStatus
        XCTAssertEqual(machine.signer(of: 7), machine.signature)
        XCTAssertEqual(machine.checks, 4, "the kernel changed what it says of the code")

        XCTAssertEqual(machine.signer(of: 8), machine.signature)
        XCTAssertEqual(machine.checks, 5, "another process, running the same code")

        machine.matches = false
        try machine.install("three")
        XCTAssertNil(machine.signer(of: 7))
        XCTAssertNil(machine.signer(of: 7))
        XCTAssertEqual(machine.checks, 6, "a failure is kept as a success is")
        XCTAssertEqual(machine.cache.signature(at: machine.file.path), machine.signature, "the file still reads as its signer's")
    }

    func testWithoutTheKernelsWordEveryReadingChecks() throws {
        let machine = try Machine()
        machine.code = RunningCode.State(path: machine.file.path)
        XCTAssertEqual(machine.signer(of: 7), machine.signature)
        machine.matches = false
        XCTAssertNil(machine.signer(of: 7), "nothing says the code is the code last checked")
        XCTAssertEqual(machine.checks, 2)

        machine.code = RunningCode.State(path: machine.file.path, status: RunningCode.signedStatus | 1)
        machine.matches = true
        XCTAssertEqual(machine.signer(of: 7), machine.signature, "signed code whose hash the kernel did not give")
        XCTAssertEqual(machine.signer(of: 7), machine.signature)
        XCTAssertEqual(machine.checks, 4)
    }

    func testUnsignedRunningCodeIsNotASignedFileWithoutACheck() throws {
        let machine = try Machine()
        machine.code = RunningCode.State(path: machine.file.path, status: 1)
        XCTAssertNil(machine.signer(of: 7), "the kernel holds no signature for what runs")
        XCTAssertNil(machine.signer(of: 7))
        XCTAssertEqual(machine.checks, 0)
    }

    func testACheckThatSpansAChangeDoesNotVouch() throws {
        let machine = try Machine()
        func unsettled() -> Bool {
            let reading = machine.cache.reading(of: 7, at: machine.file.path)
            XCTAssertNil(reading.signature)
            return !reading.isSettled
        }
        machine.duringCheck = { machine.code?.hash = Data([2]) }
        XCTAssertTrue(unsettled(), "the process started another program while it was checked")
        machine.duringCheck = { try? machine.install("two") }
        XCTAssertTrue(unsettled(), "another file arrived at the path while it was checked")
        machine.duringCheck = nil
        XCTAssertEqual(machine.signer(of: 7), machine.signature, "neither was kept")
        XCTAssertEqual(machine.checks, 3)

        machine.code?.path = "/x/another"
        XCTAssertTrue(unsettled(), "the process now runs from another path than the one it was listed at")
        XCTAssertEqual(machine.checks, 3)

        machine.code?.path = machine.file.path
        machine.matches = false
        try machine.install("three")
        let differs = machine.cache.reading(of: 7, at: machine.file.path)
        XCTAssertNil(differs.signature)
        XCTAssertTrue(differs.isSettled, "a file that is not the running code is an answer, and is kept")
    }

    /// A file read while it was being replaced may read as neither the old nor the new: what
    /// keeps a process's reading is told, whether or not the process was checked against it.
    func testAFileThatChangedWhileItWasReadIsNotASettledReading() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "tattle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("one".utf8).write(to: file)
        final class Read: @unchecked Sendable {
            var signature = CodeSignature(signer: .invalid)
            var changesFile = true
        }
        let read = Read()
        let ended = Read()
        let cache = SignatureCache(
            files: { _ in [] },
            read: { path in
                if read.changesFile { try? Data("another".utf8).write(to: URL(fileURLWithPath: path), options: .atomic) }
                return CodeSignature.Reading(signature: read.signature)
            },
            running: { _ in ended.changesFile ? RunningCode.State(path: file.path, hash: Data([1]), status: 0x2000_0001) : nil },
            matchesFile: { _ in true })

        var reading = cache.reading(of: 7, at: file.path)
        XCTAssertEqual(reading.signature?.signer, .invalid, "shown, as a file's reading is")
        XCTAssertFalse(reading.isSettled, "a signature no one is checked against")

        read.signature = CodeSignature(signer: .developerID(name: "EXAMPLE DEVELOPER"), teamIdentifier: "EXAMPLE123")
        reading = cache.reading(of: 7, at: file.path)
        XCTAssertNil(reading.signature, "a signer is not shown from a reading that was not settled")
        XCTAssertFalse(reading.isSettled)

        ended.changesFile = false
        reading = cache.reading(of: 7, at: file.path)
        XCTAssertEqual(reading.signature, read.signature, "a process that has ended reads as its file")
        XCTAssertFalse(reading.isSettled)

        read.changesFile = false
        XCTAssertTrue(cache.reading(of: 7, at: file.path).isSettled)
    }

    func testAProcessThatHasEndedReadsAsItsFile() throws {
        let machine = try Machine()
        machine.matches = false
        machine.ended = [7]
        XCTAssertEqual(machine.signer(of: 7), machine.signature)
        XCTAssertEqual(machine.checks, 0)
        machine.ended = []
        machine.duringCheck = { machine.ended = [7] }
        XCTAssertEqual(machine.signer(of: 7), machine.signature, "ended while it was checked")
    }

    func testOnlyAFileThatNamesASignerOutsideMacOSIsChecked() throws {
        let machine = try Machine()
        machine.matches = false
        for signer in [CodeSignature.Signer.adHoc, .unsigned, .invalid, .notIssuedByApple] {
            machine.signature = CodeSignature(signer: signer)
            try machine.install("\(signer)")
            XCTAssertEqual(machine.signer(of: 7)?.signer, signer)
        }
        XCTAssertEqual(machine.checks, 0, "none of them names a signer for the process to borrow")

        let apple = CodeSignature(signer: .apple, identifier: "com.apple.tool")
        let installed = SignatureCache(
            files: { _ in [] }, read: { _ in CodeSignature.Reading(signature: apple) },
            running: { _ in RunningCode.State(path: "/usr/libexec/tool", hash: Data([1]), status: 1) },
            matchesFile: { _ in XCTFail("only macOS can put a file there"); return false })
        XCTAssertEqual(installed.signature(of: 7, at: "/usr/libexec/tool"), apple)

        machine.signature = apple
        try machine.install("a copy of Apple's")
        XCTAssertNil(machine.signer(of: 7), "Apple's signature on a file anyone can replace")
        XCTAssertEqual(machine.checks, 1)
    }

    func testVerdictsOfProcessesThatEndedAreDropped() throws {
        let machine = try Machine()
        let first: ClosedRange<Int32> = 1...1024
        for pid in first { _ = machine.signer(of: pid) }
        XCTAssertEqual(machine.checks, 1024)
        machine.ended = Set(first.dropLast())
        _ = machine.signer(of: 5000)
        machine.ended = []
        machine.checks = 0
        _ = machine.signer(of: 1024)
        _ = machine.signer(of: 5000)
        XCTAssertEqual(machine.checks, 0, "the processes still running are kept")
        _ = machine.signer(of: 1)
        XCTAssertEqual(machine.checks, 1, "a pid that came back is checked as new")
    }

    // MARK: - What the tabs show

    private let slack = CodeSignature(signer: .developerID(name: "Slack Technologies"), identifier: "com.tinyspeck.slackmacgap", teamIdentifier: "BQR82RBBHL")
    private let helper = CodeSignature(signer: .developerID(name: "Slack Technologies"), identifier: "com.tinyspeck.slackmacgap.helper", teamIdentifier: "BQR82RBBHL")
    private let agent = CodeSignature(signer: .developerID(name: "EXAMPLE DEVELOPER"), identifier: "agent", teamIdentifier: "EXAMPLE123")
    private let python = CodeSignature(signer: .developerID(name: "Python Software Foundation"), identifier: "org.python.python", teamIdentifier: "PYTHON1234")
    private let app = "/Applications/Slack.app"

    private var signatures: [String: CodeSignature] {
        [app: slack, "\(app)/Contents/MacOS/Slack": slack, "\(app)/Contents/Frameworks/Helper": helper,
         "/opt/agent/agent": agent, "/opt/python/bin/python3": python]
    }

    /// As the table lists them: named without their signatures.
    private var processes: [Int32: ProcessEntry] {
        func entry(_ pid: Int32, _ parent: Int32, _ path: String, arguments: [String]? = nil) -> ProcessEntry {
            ProcessEntry(pid: pid, parentPid: parent, uid: 501, name: URL(fileURLWithPath: path).lastPathComponent, path: path,
                         arguments: arguments, started: .distantPast)
        }
        let list = [
            entry(100, 1, "\(app)/Contents/MacOS/Slack"), entry(101, 100, "\(app)/Contents/Frameworks/Helper"),
            entry(300, 1, "/opt/agent/agent"), entry(400, 1, "/opt/python/bin/python3", arguments: ["python3", "/opt/job.py"]),
        ]
        return Dictionary(list.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// The app's own process, the agent and the interpreter run code that is not their file's;
    /// the app's helper runs its own.
    private func executable(_ pid: Int32, _ path: String) -> CodeSignature? {
        [100, 300, 400].contains(pid) ? nil : signatures[path]
    }

    private func value(_ name: String, in facts: [Fact]) -> String? { facts.first { $0.name == name }?.value }

    func testProcessesShowNoSignerForAProcessItsFileDoesNotVouchFor() throws {
        let entries = processes.values.map { $0.named(signature: $0.executableSignature(executable)) }.sorted { $0.pid < $1.pid }
        let snapshot = ProcessSnapshot.build(
            entries: entries, previous: nil, signature: { self.signatures[$0] }, executable: executable,
            mainExecutable: { _ in "\(self.app)/Contents/MacOS/Slack" }, responsible: { _ in nil })

        for pid: Int32 in [100, 300] {
            let item = try XCTUnwrap(snapshot.item(pid: pid))
            XCTAssertNil(item.signature, "pid \(pid)")
            XCTAssertNil(item.identity, "pid \(pid)")
            XCTAssertNil(item.signerText, "pid \(pid)")
            XCTAssertNil(value("Signed by", in: item.facts), "pid \(pid)")
            XCTAssertNil(value("Team", in: item.facts), "pid \(pid)")
        }
        XCTAssertEqual(snapshot.item(pid: 101)?.signature, helper, "a process that runs its file keeps its signer")
        XCTAssertEqual(snapshot.item(pid: 101)?.identity?.text, "team:BQR82RBBHL:com.tinyspeck.slackmacgap.helper")

        let row = try XCTUnwrap(snapshot.group(id: app))
        XCTAssertEqual(row.leaderPid, 100)
        XCTAssertNil(row.signature, "the app's row does not name the signer while its own process runs other code")
        XCTAssertNil(row.identity)
        XCTAssertNil(value("Signed by", in: row.facts))
        let alone = try XCTUnwrap(snapshot.group(id: "pid:300"))
        XCTAssertNil(alone.signature)
        XCTAssertNil(alone.identity)

        let script = try XCTUnwrap(snapshot.item(pid: 400))
        XCTAssertEqual(script.signature?.signer, .script, "what the command line says, as for any file of an interpreter's name")
        XCTAssertNil(script.interpreterSignature, "and no signer for the interpreter")
        XCTAssertNil(value("Interpreter signed by", in: script.facts))
    }

    func testNetworkShowsNoSignerForAProcessItsFileDoesNotVouchFor() {
        func owner(_ pid: Int32) -> ConnectionOwner {
            ConnectionOwner.resolve(pid: pid, in: processes, runningApp: { _ in nil }, responsible: { _ in nil },
                                    executable: executable, signature: { self.signatures[$0] })
        }
        func live(_ pid: Int32) -> LiveConnection {
            let connection = Connection(
                id: "\(pid):tcp/50000>1.1.1.1:443", proto: .tcp, pid: pid, uid: 501, localPort: 50000, remoteAddress: "1.1.1.1", remotePort: 443,
                isIPv6: false, scope: .remote, tcpState: 4, firstSeen: .distantPast, lastSeen: .distantPast, ended: nil, preExisting: false,
                direction: .outbound)
            return LiveConnection(connection: connection, owner: owner(pid), isNew: false)
        }

        let own = owner(100)
        XCTAssertNil(own.signature)
        XCTAssertNil(own.identity)
        XCTAssertTrue(own.isForeignToApp)
        XCTAssertNil(own.groupSignature)
        XCTAssertNil(own.groupIdentity)
        XCTAssertNil(value("Signed by", in: live(100).facts(now: .distantPast)))
        XCTAssertEqual(owner(101).groupSignature, slack, "the helper alone reads as the app's")

        let rows = NetworkSnapshot(connections: [live(100), live(101), live(300)], takenAt: .distantPast).groups
        let row = rows.first { $0.id == app }
        XCTAssertEqual(row?.connections.count, 2)
        XCTAssertNil(row?.signature, "the app's row, with a connection of the process that runs other code")
        XCTAssertNil(row?.identity)
        let alone = rows.first { $0.id == "process:agent" }
        XCTAssertNil(alone?.signature)
        XCTAssertNil(alone?.identity)

        let script = owner(400)
        XCTAssertEqual(script.signature?.signer, .script)
        XCTAssertNil(script.interpreterSignature)
    }

    /// Network keeps an owner for as long as its process has a connection open. One read
    /// while its file or its process was changing has no signer, and would have none for
    /// every connection after.
    @MainActor
    func testNetworkReadsAnOwnerAgainWhenItsReadingWasNotSettled() async throws {
        final class World: @unchecked Sendable {
            private let lock = NSLock()
            private var sockets: [SocketEntry] = []
            private var settled = false
            var table: [SocketEntry] {
                get { lock.withLock { sockets } }
                set { lock.withLock { sockets = newValue } }
            }
            var isSettled: Bool {
                get { lock.withLock { settled } }
                set { lock.withLock { settled = newValue } }
            }
        }
        let world = World()
        let pid: Int32 = 9_000_100
        let signed = agent
        let records = [pid: ProcessEntry(pid: pid, parentPid: 1, uid: 501, name: "agent", path: "/opt/agent/agent", started: .distantPast)]
        func socket(_ port: UInt16) -> SocketEntry {
            SocketEntry(proto: .tcp, isIPv6: false, localAddress: "192.168.1.5", localPort: port, remoteAddress: "17.1.1.1", remotePort: 443,
                        tcpState: SocketEntry.tcpEstablished, pid: pid, effectivePid: 0, uid: 501)
        }
        let database = try AppDatabase.inMemory()
        let observer = NetworkObserver(
            store: ConnectionStore(database: database), rules: try RuleStore(database: database),
            settings: try AppSettings(store: SettingsStore(database: database)),
            socketTable: { world.table },
            processRecords: {
                ProcessRecords { pids in
                    ProcessTable.lines(of: pids, in: records, parent: \.parentPid, entry: { $0 }, responsible: { _ in nil })
                }
            },
            signature: { _ in nil },
            executable: { _, _ in world.isSettled ? SignatureCache.ProcessReading(signature: signed) : SignatureCache.ProcessReading(isSettled: false) })
        func signer(_ port: UInt16) -> CodeSignature? {
            observer.snapshot?.connections.first { $0.connection.localPort == port }?.owner.signature
        }

        world.table = [socket(40000)]
        await observer.poll()
        XCTAssertEqual(observer.snapshot?.connections.count, 1)
        XCTAssertNil(signer(40000), "nothing said whether the file was the running code")

        world.isSettled = true
        world.table = [socket(40000), socket(40001)]
        await observer.poll()
        XCTAssertEqual(signer(40001), signed, "the owner is read again for the next connection")
        XCTAssertNil(signer(40000), "the first keeps the owner it opened with")

        world.isSettled = false
        world.table = [socket(40000), socket(40001), socket(40002)]
        await observer.poll()
        XCTAssertEqual(signer(40002), signed, "a settled owner is kept")
    }

    func testPortsShowNoSignerForAProcessItsFileDoesNotVouchFor() throws {
        func listener(_ pid: Int32, _ port: UInt16) -> SocketEntry {
            SocketEntry(proto: .tcp, isIPv6: false, localAddress: "0.0.0.0", localPort: port, remoteAddress: "0.0.0.0", remotePort: 0,
                        tcpState: SocketEntry.tcpListen, pid: pid, effectivePid: 0, uid: 501)
        }
        let snapshot = PortsSnapshot.build(
            entries: [listener(300, 8000), listener(101, 8001), listener(400, 8002)], services: .empty,
            processes: { self.processes[$0] }, executable: executable)
        let item = try XCTUnwrap(snapshot.items.first { $0.pid == 300 })
        XCTAssertNil(item.signature)
        XCTAssertNil(item.identity)
        XCTAssertNil(value("Signed by", in: item.facts))
        XCTAssertEqual(snapshot.items.first { $0.pid == 101 }?.signature, helper)
        let script = try XCTUnwrap(snapshot.items.first { $0.pid == 400 })
        XCTAssertEqual(script.signature?.signer, .script)
        XCTAssertNil(script.interpreterSignature)
    }
}
