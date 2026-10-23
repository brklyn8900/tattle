import Security
import XCTest
@testable import tattle

/// SIGPIPEs this process received, counted by a handler a test installs.
nonisolated(unsafe) private var brokenPipes = 0

final class CaptureBrokerTests: XCTestCase {
    func testRequirementPrefersTeamOverHash() throws {
        let hash = Data(repeating: 0xab, count: 20)
        XCTAssertEqual(CaptureBroker.BuildIdentity(cdhash: hash, identifier: "io.github.eladefrati.tattle", team: "ABCDE12345")?.callerRequirement,
                       "anchor apple generic and identifier \"io.github.eladefrati.tattle\" and certificate leaf[subject.OU] = \"ABCDE12345\"")
        XCTAssertEqual(CaptureBroker.BuildIdentity(cdhash: hash, identifier: "x", team: nil)?.callerRequirement, "cdhash H\"\(String(repeating: "ab", count: 20))\"")
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
        let adHoc = CaptureBroker.BuildIdentity(cdhash: hash, identifier: "io.github.eladefrati.tattle", team: nil)
        for identity in [team, adHoc] {
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
        XCTAssertEqual((parsed?["ProgramArguments"] as? [String])?.suffix(2), ["--uid", "501"])
    }

    func testPlistAndScriptsQuoteWhatTheyCarry() throws {
        let plist = CaptureBroker.plist(requirement: "identifier \"a\" and anchor <apple>", uid: 501)
        XCTAssertTrue(plist.contains("<string>\(CaptureBroker.label)</string>"))
        XCTAssertTrue(plist.contains("<string>\(CaptureBroker.helperPath)</string>"))
        XCTAssertTrue(plist.contains("<string>identifier \"a\" and anchor &lt;apple&gt;</string>"))
        XCTAssertTrue(plist.contains("<string>\(CaptureBroker.socketPath)</string>"))
        let parsed = try PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any]
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
        codesign.waitUntilExit()
        XCTAssertEqual(codesign.terminationStatus, 0, "codesign \(arguments)")
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(url as CFURL, [], &code), errSecSuccess)
        var info: CFDictionary?
        XCTAssertEqual(SecCodeCopySigningInformation(try XCTUnwrap(code), [], &info), errSecSuccess)
        let cdhash = try XCTUnwrap((info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data)
        return Caller(url: url, requirement: "cdhash H\"\(cdhash.map { String(format: "%02x", $0) }.joined())\"")
    }

    /// Starts `caller` asking the broker at `socket` for `interface`.
    private func start(_ caller: Caller, socket: String, interface: String = "en0", delay: Int? = nil) throws -> (Process, Pipe) {
        let process = Process()
        process.executableURL = caller.url
        process.arguments = [socket, interface] + (delay.map { ["--delay", String($0)] } ?? [])
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        return (process, output)
    }

    /// What the probe printed: accepted, refused, bad-request, open-failed <errno> or transport <errno>.
    private func answer(_ started: (Process, Pipe)) -> String {
        let text = String(decoding: started.1.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        started.0.waitUntilExit()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ask(_ caller: Caller, socket: String, interface: String = "en0") throws -> String {
        answer(try start(caller, socket: socket, interface: interface))
    }

    /// An accepted caller: a descriptor where the devices are readable, otherwise the broker's
    /// own open failing with EACCES, which it reaches only after accepting the caller.
    private static let accepted: Set<String> = ["accepted", "open-failed \(EACCES)"]

    /// Waits for the broker to exit on its own, failing instead of hanging.
    private func expectExit(_ process: Process, status: Int32 = 0) {
        for _ in 0..<250 where process.isRunning { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            return XCTFail("the broker did not exit after serving")
        }
        XCTAssertEqual(process.terminationStatus, status)
    }

    private var sockets = 0

    /// A fresh socket path per broker, so a stale file never answers for a new one.
    private func socketPath() -> String {
        sockets += 1
        return FileManager.default.temporaryDirectory.appending(path: "broker-\(getpid())-\(sockets).sock").path
    }

    private func runBroker(requirement: String, uid: String = String(getuid()), socket: String, once: Bool = true) throws -> Process {
        let process = Process()
        process.executableURL = brokerBinary
        process.arguments = ["--requirement", requirement, "--uid", uid, "--socket", socket] + (once ? ["--once"] : [])
        process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: socket) { usleep(20_000) }
        return process
    }

    /// Connects to `path` and hangs up at once, before the broker can answer. Waits while the
    /// listen queue (8 deep) is full, which a unix socket reports as a refused connection.
    private func connectAndHangUp(_ path: String) {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buffer.count))) }
        }
        for _ in 0..<100 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            let error = errno
            close(fd)
            if connected == 0 { return }
            guard error == ECONNREFUSED else { return XCTFail(String(cString: strerror(error))) }
            usleep(10_000)
        }
        XCTFail("the broker stopped accepting connections")
    }

    /// A requirement no process satisfies: the broker refuses, which is its quickest answer.
    private let nobody = "cdhash H\"0000000000000000000000000000000000000000\""

    func testBrokerSurvivesAPeerThatHangsUp() throws {
        let socket = socketPath()
        let broker = try runBroker(requirement: nobody, socket: socket, once: false)
        defer { broker.terminate() }
        // Any local account can do this: the socket is world-writable.
        for _ in 0..<20 { connectAndHangUp(socket) }
        XCTAssertThrowsError(try CaptureBroker.request(interface: "en0", socket: socket)) {
            XCTAssertEqual($0 as? CaptureBroker.RequestError, .refused, "the broker still answers after peers hung up")
        }
        XCTAssertTrue(broker.isRunning, broker.isRunning ? "" : "\(broker.terminationReason == .uncaughtSignal ? "killed by signal" : "exited with") \(broker.terminationStatus)")
    }

    func testRequestSurvivesABrokerThatHangsUp() throws {
        brokenPipes = 0
        let previous = signal(SIGPIPE) { _ in brokenPipes += 1 }
        defer { signal(SIGPIPE, previous) }
        let socket = socketPath()
        let broker = try runBroker(requirement: nobody, socket: socket)
        defer { broker.terminate() }
        // Far longer than any interface name, so the request is still being written when the
        // broker refuses and hangs up.
        XCTAssertThrowsError(try CaptureBroker.request(interface: String(repeating: "a", count: 1 << 20), socket: socket))
        XCTAssertEqual(brokenPipes, 0, "a broker hanging up must cost Tattle an error, not a SIGPIPE")
        expectExit(broker)
    }

    func testBrokerHandsADescriptorToACallerItRecognises() throws {
        try XCTSkipUnless(access("/dev/bpf0", R_OK) == 0, "needs readable /dev/bpf* to run the broker as the user")
        let interface = try XCTUnwrap(PacketCapture.primaryInterface())
        let hardened = try caller(.hardened)
        let socket = socketPath()
        let broker = try runBroker(requirement: hardened.requirement, socket: socket)
        defer { broker.terminate() }
        XCTAssertEqual(try ask(hardened, socket: socket, interface: interface), "accepted", "a descriptor the caller can prepare and filter")
        expectExit(broker)
    }

    func testBrokerAcceptsAHardenedCaller() throws {
        let hardened = try caller(.hardened)
        let socket = socketPath()
        let broker = try runBroker(requirement: hardened.requirement, socket: socket)
        defer { broker.terminate() }
        XCTAssertTrue(Self.accepted.contains(try ask(hardened, socket: socket)))
        expectExit(broker)
    }

    /// Each of these callers satisfies its requirement, yet another process of the same user
    /// could put code into it or read its memory, and with it the descriptor.
    func testBrokerRefusesCallersAnotherProcessCouldSteer() throws {
        for signing in Signing.allCases where signing != .hardened {
            let steerable = try caller(signing)
            let socket = socketPath()
            let broker = try runBroker(requirement: steerable.requirement, socket: socket)
            defer { broker.terminate() }
            XCTAssertEqual(try ask(steerable, socket: socket), "refused", "\(signing)")
            expectExit(broker)
        }
    }

    /// The socket is world-writable; the plist records which account the broker serves.
    func testBrokerAnswersOnlyTheInstallingUser() throws {
        let hardened = try caller(.hardened)
        let otherSocket = socketPath()
        let other = try runBroker(requirement: hardened.requirement, uid: String(getuid() + 1), socket: otherSocket)
        defer { other.terminate() }
        XCTAssertEqual(try ask(hardened, socket: otherSocket), "refused", "a caller running as another user")
        expectExit(other)

        let ownSocket = socketPath()
        let own = try runBroker(requirement: hardened.requirement, socket: ownSocket)
        defer { own.terminate() }
        XCTAssertTrue(Self.accepted.contains(try ask(hardened, socket: ownSocket)))
        expectExit(own)
    }

    /// A plist without a usable uid, an older one for instance, must not start a broker that
    /// serves every account.
    func testBrokerRequiresTheInstallingUser() throws {
        for uid in [nil, "0", "-1", "abc", "501x", "4294967295", "4294967296"] {
            let process = Process()
            process.executableURL = brokerBinary
            process.arguments = ["--requirement", nobody, "--socket", socketPath(), "--once"] + (uid.map { ["--uid", $0] } ?? [])
            process.standardError = FileHandle.nullDevice
            try process.run()
            expectExit(process, status: 2)
        }
    }

    /// A probe that stays running long enough to be looked at, and its code as the kernel sees it.
    private func running(_ caller: Caller) throws -> (Process, SecCode) {
        let process = Process()
        process.executableURL = caller.url
        process.arguments = ["/nonexistent/broker.sock", "en0", "--delay", "30"]
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
        let socket = socketPath()
        let broker = try runBroker(requirement: genuine.requirement, socket: socket)
        defer { broker.terminate() }
        let started = try start(impostor, socket: socket, delay: 1)
        XCTAssertEqual(rename(genuine.url.path, impostor.url.path), 0)
        XCTAssertEqual(answer(started), "refused")
        expectExit(broker)
    }

    func testBrokerRefusesOtherCallersAndBadInterfaces() throws {
        let strangerSocket = socketPath()
        let stranger = try runBroker(requirement: nobody, socket: strangerSocket)
        defer { stranger.terminate() }
        XCTAssertThrowsError(try CaptureBroker.request(interface: "en0", socket: strangerSocket)) {
            XCTAssertEqual($0 as? CaptureBroker.RequestError, .refused)
        }
        expectExit(stranger)
        XCTAssertFalse(FileManager.default.fileExists(atPath: strangerSocket), "the broker removes its socket on exit")

        let hardened = try caller(.hardened)
        let pickySocket = socketPath()
        let picky = try runBroker(requirement: hardened.requirement, socket: pickySocket)
        defer { picky.terminate() }
        XCTAssertEqual(try ask(hardened, socket: pickySocket, interface: "en0;rm"), "bad-request")
        expectExit(picky)

        if access("/dev/bpf0", R_OK) == 0 {
            let missingSocket = socketPath()
            let missing = try runBroker(requirement: hardened.requirement, socket: missingSocket)
            defer { missing.terminate() }
            XCTAssertTrue(try ask(hardened, socket: missingSocket, interface: "nosuch9").hasPrefix("open-failed"))
            expectExit(missing)
        }

        XCTAssertThrowsError(try CaptureBroker.request(interface: "en0", socket: "/nonexistent/broker.sock")) {
            guard case .transport = $0 as? CaptureBroker.RequestError else { return XCTFail("\($0)") }
        }
    }
}
