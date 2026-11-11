import CPacketCapture
import Security
import XCTest
import XPC
@testable import tattle

final class CaptureBrokerTests: XCTestCase {
    func testRequirementPrefersTeamOverHash() throws {
        let hash = Data(repeating: 0xab, count: 20)
        let both = "anchor apple generic and (identifier \"io.github.eladefrati.tattle\" or identifier \"io.github.eladefrati.tattle.dev\")"
            + " and certificate leaf[subject.OU] = \"ABCDE12345\""
        XCTAssertEqual(CaptureBroker.BuildIdentity(cdhash: hash, identifier: "io.github.eladefrati.tattle", team: "ABCDE12345")?.callerRequirement, both)
        XCTAssertEqual(CaptureBroker.BuildIdentity(cdhash: hash, identifier: "io.github.eladefrati.tattle.dev", team: "ABCDE12345")?.callerRequirement, both,
                       "the dev copy installs what the release app would, so neither reads the other's install as stale")
        XCTAssertEqual(CaptureBroker.BuildIdentity(cdhash: hash, identifier: "x", team: nil)?.callerRequirement, "cdhash H\"\(String(repeating: "ab", count: 20))\"")
    }

    func testABuildThatIsNotHardenedHasNoIdentityToInstallFor() {
        XCTAssertThrowsError(try CaptureBroker.BuildIdentity.running(), "the test runner has get-task-allow") {
            XCTAssertEqual($0 as? CaptureBroker.InstallError, .notHardened)
        }
    }

    /// Whether the broker could compile `text`, as it does at startup.
    private func compiles(_ text: String?) -> Bool {
        guard let text else { return false }
        var requirement: SecRequirement?
        return SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess
    }

    /// The broker exits at startup on a requirement it cannot compile, and a quote in the
    /// identifier or team would end the quoted string and let the rest add a clause.
    func testRequirementsCompileAndCannotBeWidened() {
        let hash = Data(repeating: 0xab, count: 20)
        let team = CaptureBroker.BuildIdentity(cdhash: hash, identifier: "io.github.eladefrati.tattle", team: "ABCDE12345")
        let dev = CaptureBroker.BuildIdentity(cdhash: hash, identifier: "io.github.eladefrati.tattle.dev", team: "ABCDE12345")
        let adHoc = CaptureBroker.BuildIdentity(cdhash: hash, identifier: "io.github.eladefrati.tattle", team: nil)
        for identity in [team, dev, adHoc] {
            XCTAssertTrue(compiles(identity?.callerRequirement))
            XCTAssertTrue(compiles(identity?.buildRequirement))
        }
        XCTAssertNil(CaptureBroker.BuildIdentity(cdhash: Data([0xab, 0x01, 0xff]), identifier: "io.github.eladefrati.tattle", team: nil), "not a code hash")
        XCTAssertNil(CaptureBroker.BuildIdentity(cdhash: hash, identifier: "a\" or anchor apple and identifier \"x", team: "ABCDE12345"), "a widening identifier")
        XCTAssertNil(CaptureBroker.BuildIdentity(cdhash: hash, identifier: "io.github.eladefrati.tattle", team: "ABCDE12345\" or anchor apple"), "a widening team")
        XCTAssertNil(CaptureBroker.BuildIdentity(cdhash: hash, identifier: "io.github.eladefrati.tattle", team: "abc"), "not a team identifier")
        XCTAssertNil(CaptureBroker.BuildIdentity(cdhash: hash, identifier: "", team: nil), "no identifier")
    }

    func testPlistRecordsTheInstallingUser() throws {
        let plist = CaptureBroker.plist(requirement: "cdhash H\"00\"", uid: 501)
        let parsed = try PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any]
        let arguments = try XCTUnwrap(parsed?["ProgramArguments"] as? [String])
        XCTAssertEqual(arguments.firstIndex(of: "--uid").map { arguments[$0 + 1] }, "501")
    }

    private func plistDictionary(_ plist: String) -> [String: Any]? {
        try? PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any]
    }

    func testPlistAndScriptsQuoteWhatTheyCarry() throws {
        let plist = CaptureBroker.plist(requirement: "identifier \"a\" and anchor <apple>", uid: 501)
        XCTAssertTrue(plist.contains("<string>\(CaptureBroker.label)</string>"))
        XCTAssertTrue(plist.contains("<string>\(CaptureBroker.helperPath)</string>"))
        XCTAssertTrue(plist.contains("<string>identifier \"a\" and anchor &lt;apple&gt;</string>"))
        let parsed = plistDictionary(plist)
        XCTAssertEqual((parsed?["MachServices"] as? [String: Bool]), [CaptureBroker.label: true])
        XCTAssertEqual((parsed?["ProgramArguments"] as? [String])?[2], "identifier \"a\" and anchor <apple>")

        let identity = try XCTUnwrap(CaptureBroker.BuildIdentity(cdhash: Data(count: 20), identifier: "x", team: nil))
        let script = CaptureBroker.installScript(identity: identity, bundle: URL(filePath: "/Applications/Tat tle.app"), uid: 501)
        XCTAssertTrue(script.contains("/usr/bin/ditto --noextattr --noqtn --norsrc --noacl '/Applications/Tat tle.app' "))
        XCTAssertTrue(script.contains("'-R=\(identity.buildRequirement)'"))
        XCTAssertTrue(script.contains(CaptureBroker.shell(CaptureBroker.plist(requirement: identity.callerRequirement, uid: 501))), "the plist travels in the script")
        let remove = CaptureBroker.removeScript()
        XCTAssertTrue(remove.contains("launchctl='/bin/launchctl'") && remove.contains("\"$launchctl\" bootout system/\(CaptureBroker.label)"))
        XCTAssertEqual(CaptureBroker.appleScript("say \"hi\" \\ there"), "\"say \\\"hi\\\" \\\\ there\"")
    }

    /// The plist used to be written to $TMPDIR for root to copy, where any process of the user
    /// could replace it during the dialog. It now travels in the script text only.
    func testInstallHandsTheDialogAScriptThatCarriesThePlist() throws {
        let bundle = FileManager.default.temporaryDirectory.appending(path: "Fake-\(getpid()).app")
        let helper = bundle.appending(path: CaptureBroker.helperInBundle)
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: helper)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let identity = try XCTUnwrap(CaptureBroker.BuildIdentity(cdhash: Data(count: 20), identifier: "x", team: nil))
        var ran: String?
        let text = try CaptureBroker.install(bundle: bundle, identity: { identity }) { ran = $0 }
        XCTAssertEqual(text, CaptureBroker.plist(requirement: identity.callerRequirement, uid: getuid()))
        XCTAssertTrue(ran?.contains(CaptureBroker.shell(text)) ?? false)
        XCTAssertFalse(ran?.contains(FileManager.default.temporaryDirectory.appending(path: CaptureBroker.label).path) ?? true)
        XCTAssertThrowsError(try CaptureBroker.install(bundle: URL(filePath: "/nonexistent.app"), identity: { identity }) { _ in }) {
            XCTAssertEqual($0 as? CaptureBroker.InstallError, .noHelperInBundle)
        }
        XCTAssertThrowsError(try CaptureBroker.install(bundle: bundle, identity: { throw CaptureBroker.InstallError.unsigned }) { _ in }) {
            XCTAssertEqual($0 as? CaptureBroker.InstallError, .unsigned)
        }
        XCTAssertThrowsError(try CaptureBroker.remove { _ in throw CaptureBroker.InstallError.failed("User cancelled") })
    }

    /// The test runner has no broker in its bundle, so install fails before any dialog.
    @MainActor
    func testInstallFailuresReachTheUserInPlainWords() async throws {
        let database = try AppDatabase.inMemory()
        let observer = NetworkObserver(store: ConnectionStore(database: database), rules: RuleStore(database: database),
                                       settings: try AppSettings(store: SettingsStore(database: database)))
        let done = await observer.installBroker()
        XCTAssertFalse(done)
        let text = try XCTUnwrap(observer.accessError)
        XCTAssertFalse(text.contains("noHelperInBundle"), text)
        XCTAssertTrue(text.hasSuffix("."), text)
    }

    func testEveryInstallErrorReadsAsASentence() {
        let errors: [CaptureBroker.InstallError] = [.noHelperInBundle, .unsigned, .changedOnDisk, .notHardened, .failed("")]
        for error in errors {
            XCTAssertTrue(error.text.hasSuffix("."), error.text)
            XCTAssertFalse(error.text.contains(String(describing: error)), error.text)
        }
        XCTAssertEqual(CaptureBroker.InstallError.failed("the script's own sentence").text, "the script's own sentence")
    }

    /// Tattle's environment is the user's to set (launchctl setenv reaches every app launched
    /// after it), and /bin/sh runs code from SHELLOPTS, PS4 and exported functions before the
    /// script's first line. The root shell must not inherit it.
    func testAdministratorDialogGetsAFixedEnvironment() {
        let process = CaptureBroker.privilegedProcess("true")
        XCTAssertEqual(process.environment, ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        XCTAssertEqual(process.executableURL?.path, "/usr/bin/osascript")
        XCTAssertEqual(process.arguments, ["-e", "do shell script \"true\" with administrator privileges"])
    }

    // MARK: The daemon itself

    private var brokerBinary: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "tattle-capture-broker")
    }

    private var probeBinary: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "tattle-broker-probe")
    }

    /// How a test signs its copy of the probe. Only `.hardened` is a caller the broker should
    /// answer; each other case is one way another process of the user could steer the caller.
    enum Signing: CaseIterable {
        case hardened, plain, getTaskAllow, disableLibraryValidation, allowDyldEnvironment

        var options: [String] { self == .plain ? [] : ["--options", "runtime"] }
        var entitlement: String? {
            switch self {
            case .hardened, .plain: nil
            case .getTaskAllow: "com.apple.security.get-task-allow"
            case .disableLibraryValidation: "com.apple.security.cs.disable-library-validation"
            case .allowDyldEnvironment: "com.apple.security.cs.allow-dyld-environment-variables"
            }
        }
    }

    /// A signed copy of the probe and the requirement that names exactly it.
    struct Caller {
        let url: URL
        let requirement: String
    }

    private var callers = 0

    /// Copies the probe and signs the copy ad hoc as `signing` says, under its own identifier so
    /// two copies never share a code hash.
    private func caller(_ signing: Signing) throws -> Caller {
        callers += 1
        let directory = FileManager.default.temporaryDirectory.appending(path: "probe-\(getpid())-\(callers)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "tattle-broker-probe")
        try FileManager.default.copyItem(at: probeBinary, to: url)
        var arguments = ["--force", "--sign", "-", "--identifier", "probe-\(callers)"] + signing.options
        if let entitlement = signing.entitlement {
            let plist = directory.appending(path: "entitlements.plist")
            try PropertyListSerialization.data(fromPropertyList: [entitlement: true], format: .xml, options: 0).write(to: plist)
            arguments += ["--entitlements", plist.path]
        }
        let codesign = Process()
        codesign.executableURL = URL(filePath: "/usr/bin/codesign")
        codesign.arguments = arguments + [url.path]
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        if waitForExit(codesign) { XCTAssertEqual(codesign.terminationStatus, 0, "codesign \(arguments)") }
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(url as CFURL, [], &code), errSecSuccess)
        var info: CFDictionary?
        XCTAssertEqual(SecCodeCopySigningInformation(try XCTUnwrap(code), [], &info), errSecSuccess)
        let cdhash = try XCTUnwrap((info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data)
        return Caller(url: url, requirement: "cdhash H\"\(cdhash.map { String(format: "%02x", $0) }.joined())\"")
    }

    private func start(_ caller: Caller, service: CaptureBroker.Service, interface: String = "en0", delay: Int? = nil) throws -> (Process, Pipe) {
        let process = Process()
        process.executableURL = caller.url
        process.arguments = [service.name, interface] + (delay.map { ["--delay", String($0)] } ?? [])
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        return (process, output)
    }

    /// What the probe printed: accepted, refused, bad-request, open-failed <errno> or transport <errno>.
    private func answer(_ started: (Process, Pipe)) -> String {
        waitForExit(started.0)
        let text = String(decoding: started.1.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ask(_ caller: Caller, service: CaptureBroker.Service, interface: String = "en0") throws -> String {
        answer(try start(caller, service: service, interface: interface))
    }

    /// An accepted caller: a descriptor where the devices are readable, otherwise the broker's
    /// own open failing with EACCES, which it reaches only after accepting the caller.
    private static let accepted: Set<String> = ["accepted", "open-failed \(EACCES)"]

    /// Waits for a broker run outside launchd to exit on its own, failing instead of hanging.
    private func expectExit(_ process: Process, status: Int32 = 0) {
        for _ in 0..<250 where process.isRunning { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            return XCTFail("the broker did not exit")
        }
        XCTAssertEqual(process.terminationStatus, status)
    }

    /// The broker as launchd runs it, serving a service of its own.
    private func runBroker(requirement: String, uid: String = String(getuid())) throws -> BrokerAgent {
        let label = BrokerAgent.uniqueLabel()
        return try BrokerAgent(self, label: label, arguments: [brokerBinary.path, "--requirement", requirement, "--uid", uid, "--service", label])
    }

    /// A requirement no process satisfies: the broker refuses, which is its quickest answer.
    private let nobody = "cdhash H\"0000000000000000000000000000000000000000\""

    /// Callers that quit before the reply cost the broker nothing: the same process answers next.
    func testBrokerSurvivesCallersThatQuitBeforeTheReply() throws {
        let broker = try runBroker(requirement: nobody)
        XCTAssertThrowsError(try CaptureBroker.request(interface: "en0", service: broker.service))
        let pid = try XCTUnwrap(broker.pid, "launchd started the broker")
        let hardened = try caller(.hardened)
        for _ in 0..<20 {
            let (process, _) = try start(hardened, service: broker.service)
            kill(process.processIdentifier, SIGKILL)
            waitForExit(process)
        }
        XCTAssertThrowsError(try CaptureBroker.request(interface: "en0", service: broker.service)) {
            XCTAssertEqual($0 as? CaptureBroker.RequestError, .refused, "the broker still answers")
        }
        XCTAssertEqual(broker.pid, pid)
    }

    /// A job that never answers costs one bounded wait, not a hung sniffer.
    func testRequestEndsWithinItsBoundWhenNothingAnswers() throws {
        let silent = try BrokerAgent(self, arguments: ["/usr/bin/true"])
        let began = Date()
        XCTAssertThrowsError(try CaptureBroker.request(interface: "en0", service: silent.service)) {
            XCTAssertEqual($0 as? CaptureBroker.RequestError, .transport(errno: ETIMEDOUT))
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), CaptureBroker.requestTimeout + 2, "one wait, not one per attempt")
    }

    func testBrokerHandsADescriptorToACallerItRecognises() throws {
        try XCTSkipUnless(access("/dev/bpf0", R_OK) == 0, "needs readable /dev/bpf* to run the broker as the user")
        let interface = try XCTUnwrap(PacketCapture.primaryInterface())
        let hardened = try caller(.hardened)
        let broker = try runBroker(requirement: hardened.requirement)
        XCTAssertEqual(try ask(hardened, service: broker.service, interface: interface), "accepted", "a descriptor the caller can prepare and filter")
    }

    func testBrokerAcceptsAHardenedCaller() throws {
        let hardened = try caller(.hardened)
        let broker = try runBroker(requirement: hardened.requirement)
        XCTAssertTrue(Self.accepted.contains(try ask(hardened, service: broker.service)))
        XCTAssertTrue(broker.log.contains("cannot open a capture device on en0") || broker.log.contains("handed a capture device on en0"), broker.log)
    }

    /// Each of these callers satisfies its requirement, yet another process of the same user
    /// could put code into it or read its memory, and with it the descriptor.
    func testBrokerRefusesCallersAnotherProcessCouldSteer() throws {
        for signing in Signing.allCases where signing != .hardened {
            let steerable = try caller(signing)
            let broker = try runBroker(requirement: steerable.requirement)
            XCTAssertEqual(try ask(steerable, service: broker.service), "refused", "\(signing)")
        }
    }

    /// Any account can send to the service; the plist records which account the broker serves.
    func testBrokerAnswersOnlyTheInstallingUser() throws {
        let hardened = try caller(.hardened)
        let other = try runBroker(requirement: hardened.requirement, uid: String(getuid() + 1))
        XCTAssertEqual(try ask(hardened, service: other.service), "refused", "a caller running as another user")
        let own = try runBroker(requirement: hardened.requirement)
        XCTAssertTrue(Self.accepted.contains(try ask(hardened, service: own.service)))
    }

    /// A plist without a usable uid, an older one for instance, must not start a broker that
    /// serves every account. The arguments are read before anything else, outside launchd too.
    func testBrokerRequiresTheInstallingUser() throws {
        for uid in [nil, "0", "-1", "abc", "501x", "4294967295", "4294967296"] {
            let process = Process()
            process.executableURL = brokerBinary
            process.arguments = ["--requirement", nobody, "--service", BrokerAgent.uniqueLabel()] + (uid.map { ["--uid", $0] } ?? [])
            process.standardError = FileHandle.nullDevice
            try process.run()
            expectExit(process, status: 2)
        }
    }

    /// A probe that stays running long enough to be looked at, and its code as the kernel sees it.
    private func running(_ caller: Caller) throws -> (Process, SecCode) {
        let process = Process()
        process.executableURL = caller.url
        process.arguments = ["io.github.eladefrati.tattle.test.nonexistent", "en0", "--delay", "30"]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        addTeardownBlock { process.terminate() }
        return (process, try guest(process))
    }

    /// A fresh look at a running process: Security keeps the file it first read inside a SecCode.
    private func guest(_ process: Process) throws -> SecCode {
        var code: SecCode?
        XCTAssertEqual(SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: process.processIdentifier] as CFDictionary, [], &code), errSecSuccess)
        return try XCTUnwrap(code)
    }

    /// The bundle is the user's to rewrite while Tattle runs: what install pins must be the code
    /// that is running, or a process could rename its own binary over Tattle's and be admitted.
    func testIdentityIsConfirmedAgainstTheRunningCode() throws {
        let genuine = try caller(.hardened)
        let impostor = try caller(.hardened)
        let (process, code) = try running(genuine)
        let identity = try CaptureBroker.BuildIdentity.confirmed(code)
        XCTAssertEqual(identity.buildRequirement, genuine.requirement)

        XCTAssertEqual(rename(impostor.url.path, genuine.url.path), 0)
        XCTAssertThrowsError(try CaptureBroker.BuildIdentity.confirmed(try guest(process))) {
            XCTAssertEqual($0 as? CaptureBroker.InstallError, .changedOnDisk)
        }
    }

    /// Installing for a build the broker would refuse gives a broker that never answers it.
    func testIdentityRefusesABuildTheBrokerWouldRefuse() throws {
        for signing in Signing.allCases where signing != .hardened {
            let (_, code) = try running(try caller(signing))
            XCTAssertThrowsError(try CaptureBroker.BuildIdentity.confirmed(code), "\(signing)") {
                XCTAssertEqual($0 as? CaptureBroker.InstallError, .notHardened)
            }
        }
    }

    /// The file a caller was started from is replaced after launch by the code the broker
    /// accepts: the broker judges the running code, not the file.
    func testBrokerRefusesACallerReplacedOnDiskAfterLaunch() throws {
        let impostor = try caller(.hardened)
        let genuine = try caller(.hardened)
        let broker = try runBroker(requirement: genuine.requirement)
        let started = try start(impostor, service: broker.service, delay: 1)
        XCTAssertEqual(rename(genuine.url.path, impostor.url.path), 0)
        XCTAssertEqual(answer(started), "refused")
    }

    func testBrokerRefusesOtherCallersAndBadInterfaces() throws {
        let stranger = try runBroker(requirement: nobody)
        XCTAssertThrowsError(try CaptureBroker.request(interface: "en0", service: stranger.service)) {
            XCTAssertEqual($0 as? CaptureBroker.RequestError, .refused)
        }

        let hardened = try caller(.hardened)
        let picky = try runBroker(requirement: hardened.requirement)
        XCTAssertEqual(try ask(hardened, service: picky.service, interface: "en0;rm"), "bad-request")
        XCTAssertEqual(try ask(hardened, service: picky.service, interface: String(repeating: "a", count: 1 << 16)), "bad-request")
        if access("/dev/bpf0", R_OK) == 0 {
            XCTAssertTrue(try ask(hardened, service: picky.service, interface: "nosuch9").hasPrefix("open-failed"))
        }

        XCTAssertThrowsError(try CaptureBroker.request(interface: "en0", service: CaptureBroker.Service(name: BrokerAgent.uniqueLabel(), privileged: false))) {
            XCTAssertEqual($0 as? CaptureBroker.RequestError, .transport(errno: ECONNREFUSED), "no job serves the name")
        }
    }

    /// Only root registers names in the system domain; an agent of the user's with the broker's
    /// name is not what the app reaches.
    func testTheAppLooksTheBrokerUpWhereOnlyRootRegisters() throws {
        let agent = try runBroker(requirement: nobody)
        XCTAssertThrowsError(try CaptureBroker.request(interface: "en0", service: CaptureBroker.Service(name: agent.label, privileged: true))) {
            XCTAssertEqual($0 as? CaptureBroker.RequestError, .transport(errno: ECONNREFUSED))
        }
        XCTAssertTrue(CaptureBroker.isRegistered(agent.service))
    }

    /// The broker closes a connection after its first message, answered or not, so the uid it
    /// takes from the connection is that of the one request it answers.
    func testBrokerClosesAConnectionAfterItsFirstMessage() throws {
        let broker = try runBroker(requirement: nobody)
        let connection = xpc_connection_create_mach_service(broker.label, nil, 0)
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_activate(connection)
        defer { xpc_connection_cancel(connection) }
        let message = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(message, "interface", "en0")
        xpc_connection_send_message(connection, message)
        let reply = xpc_connection_send_message_with_reply_sync(connection, message)
        XCTAssertTrue(xpc_get_type(reply) == XPC_TYPE_ERROR, "a second message on the connection was answered: \(String(describing: reply))")
    }

    /// A request is judged by the process that sent it, not by what its pid runs when the
    /// broker reads it: a sender that execs a program the broker accepts is still refused. The
    /// broker is stopped until the exec is done, so one that judged the pid would accept.
    func testBrokerJudgesTheSenderNotWhatItsPidRunsByThen() throws {
        let plain = try caller(.plain)
        let hardened = try caller(.hardened)
        let broker = try runBroker(requirement: hardened.requirement)
        XCTAssertThrowsError(try CaptureBroker.request(interface: "en0", service: broker.service), "the test runner is refused")
        let pid = try XCTUnwrap(broker.pid, "launchd started the broker")
        let refusals = { broker.log.components(separatedBy: "refused a caller").count - 1 }
        let before = refusals()
        XCTAssertEqual(kill(pid, SIGSTOP), 0)
        var resumed = false
        defer { if !resumed { kill(pid, SIGCONT) } }

        let process = Process()
        process.executableURL = plain.url
        // The program it becomes stays alive while the broker judges, and asks it nothing.
        process.arguments = [broker.label, "en0", "--send-then-exec", hardened.url.path, BrokerAgent.uniqueLabel(), "en0", "--delay", "3"]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let target = hardened.url.resolvingSymlinksInPath().path
        let deadline = Date().addingTimeInterval(5)
        while executablePath(process.processIdentifier) != target && Date() < deadline { usleep(10_000) }
        XCTAssertEqual(executablePath(process.processIdentifier), target, "the sender became the accepted program")

        XCTAssertEqual(kill(pid, SIGCONT), 0)
        resumed = true
        while refusals() == before && Date() < deadline.addingTimeInterval(5) { usleep(20_000) }
        XCTAssertEqual(refusals(), before + 1, broker.log)
        XCTAssertFalse(broker.log.contains("cannot open a capture device") || broker.log.contains("handed a capture device"), broker.log)
        waitForExit(process)
    }

    private func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(filePath: String(cString: buffer)).resolvingSymlinksInPath().path
    }

    /// Whoever launches Tattle chooses the task exception ports it inherits, and a trap would
    /// hand that process Tattle's task, which the broker cannot see. A caller drops them at
    /// launch, before its own code runs, and still asks.
    func testACallerDropsTheExceptionPortsItInheritedAtLaunch() throws {
        let hardened = try caller(.hardened)
        var output = ""
        try withInheritedExceptionPort {
            output = try spawnKeepingExceptionPorts(hardened.url, [BrokerAgent.uniqueLabel(), "en0", "--exception-ports"])
        }
        let lines = output.split(separator: "\n")
        XCTAssertEqual(lines.first, "transport \(ECONNREFUSED)", "no job serves the name")
        XCTAssertEqual(Array(lines.dropFirst()), ["dropped-at-launch 1", "exception-ports 0", "corpse-ports 1"], "the corpse port is how macOS's crash reports arrive")
    }

    /// Tattle keeps the corpse port for crash reports, so a launcher can hold it. What that
    /// launcher gets is the dead process: its memory to read, and no code to run or files to
    /// reach (ADR-0003).
    func testACorpseLetsItsHolderReadMemoryAndNothingElse() throws {
        let hardened = try caller(.hardened)
        let process = Process()
        process.executableURL = hardened.url
        process.arguments = ["--hold-corpse", hardened.url.path, "--wait"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        waitForExit(process)
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(lines.prefix(4)), ["exception \(EXC_CORPSE_NOTIFY)", "read allowed", "write refused", "thread refused"])
        XCTAssertGreaterThan(count(in: lines, "descriptors-before"), 0, "the live program's files are listed")
        XCTAssertEqual(count(in: lines, "descriptors-after"), 0, "the dead program has none")
    }

    private func count(in lines: [String], _ name: String) -> Int {
        lines.first { $0.hasPrefix(name + " ") }.flatMap { Int($0.dropFirst(name.count + 1)) } ?? -1
    }

    /// The test runner loads the code in a bundle, so it keeps the ports it was started with.
    func testTheTestRunnerKeepsItsExceptionPorts() {
        XCTAssertEqual(tattle_launch_exception_ports_dropped(), -1)
    }

    /// Runs the program with `posix_spawn`, because `Process` does not pass exception ports on,
    /// and returns what it wrote to standard output.
    private func spawnKeepingExceptionPorts(_ url: URL, _ arguments: [String]) throws -> String {
        var ends: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&ends), 0)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, ends[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, ends[0])
        posix_spawn_file_actions_addclose(&actions, ends[1])
        let argv: [UnsafeMutablePointer<CChar>?] = ([url.path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid = pid_t(0)
        let spawned = posix_spawn(&pid, url.path, &actions, nil, argv, environ)
        close(ends[1])
        let reader = FileHandle(fileDescriptor: ends[0], closeOnDealloc: true)
        guard spawned == 0 else {
            XCTFail("posix_spawn failed: \(spawned)")
            return ""
        }
        let output = try XCTUnwrap(try reader.readToEnd())
        var status = Int32(0)
        waitpid(pid, &status, 0)
        return String(decoding: output, as: UTF8.self)
    }

    /// Runs `body` with a port of this process's own as its exception port for every type, which a
    /// process started inside inherits, then puts back the ports it had.
    private func withInheritedExceptionPort(_ body: () throws -> Void) throws {
        let task = mach_task_self_
        var port = mach_port_t(MACH_PORT_NULL)
        XCTAssertEqual(mach_port_allocate(task, MACH_PORT_RIGHT_RECEIVE, &port), KERN_SUCCESS)
        XCTAssertEqual(mach_port_insert_right(task, port, port, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)), KERN_SUCCESS)
        defer { mach_port_mod_refs(task, port, MACH_PORT_RIGHT_RECEIVE, -1) }
        let capacity = Int(EXC_TYPES_COUNT)
        var masks = [exception_mask_t](repeating: 0, count: capacity)
        var ports = [mach_port_t](repeating: mach_port_t(MACH_PORT_NULL), count: capacity)
        var behaviors = [exception_behavior_t](repeating: 0, count: capacity)
        var flavors = [thread_state_flavor_t](repeating: 0, count: capacity)
        var count = mach_msg_type_number_t(capacity)
        // Every exception type, numbered 1 to 13; Swift does not import EXC_MASK_ALL.
        let every = (EXC_BAD_ACCESS...EXC_CORPSE_NOTIFY).reduce(exception_mask_t(0)) { $0 | exception_mask_t(1) << $1 }
        XCTAssertEqual(task_swap_exception_ports(task, every, port, EXCEPTION_DEFAULT, THREAD_STATE_NONE,
                                                 &masks, &count, &ports, &behaviors, &flavors), KERN_SUCCESS)
        defer {
            for i in 0..<Int(count) {
                task_set_exception_ports(task, masks[i], ports[i], behaviors[i], flavors[i])
            }
        }
        try body()
    }
}
