import Security
import XCTest
@testable import tattle

/// SIGPIPEs this process received, counted by a handler a test installs.
nonisolated(unsafe) private var brokenPipes = 0

final class CaptureBrokerTests: XCTestCase {
    func testRequirementPrefersTeamOverHash() {
        XCTAssertEqual(CaptureBroker.requirement(identifier: "io.github.eladefrati.tattle", team: "ABCDE12345", cdhash: Data([1, 2])),
                       "anchor apple generic and identifier \"io.github.eladefrati.tattle\" and certificate leaf[subject.OU] = \"ABCDE12345\"")
        XCTAssertEqual(CaptureBroker.requirement(identifier: nil, team: nil, cdhash: Data([0xab, 0x01, 0xff])), "cdhash H\"ab01ff\"")
        XCTAssertNil(CaptureBroker.requirement(identifier: "x", team: "", cdhash: nil), "nothing to pin")
        XCTAssertNotNil(CaptureBroker.requirementForSelf(), "the test process is signed by Apple")
    }

    func testPlistAndScriptsQuoteWhatTheyCarry() throws {
        let plist = CaptureBroker.plist(requirement: "identifier \"a\" and anchor <apple>")
        XCTAssertTrue(plist.contains("<string>\(CaptureBroker.label)</string>"))
        XCTAssertTrue(plist.contains("<string>\(CaptureBroker.helperPath)</string>"))
        XCTAssertTrue(plist.contains("<string>identifier \"a\" and anchor &lt;apple&gt;</string>"))
        XCTAssertTrue(plist.contains("<string>\(CaptureBroker.socketPath)</string>"))
        let parsed = try PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any]
        XCTAssertEqual((parsed?["ProgramArguments"] as? [String])?.last, "identifier \"a\" and anchor <apple>")

        let script = CaptureBroker.installScript(helper: "/Applications/Tat tle.app/Contents/MacOS/it's", plistSource: "/tmp/p.plist")
        XCTAssertTrue(script.contains("cp '/Applications/Tat tle.app/Contents/MacOS/it'\\''s' '\(CaptureBroker.helperPath)'"))
        XCTAssertTrue(script.contains("launchctl bootstrap system '\(CaptureBroker.plistPath)'"))
        XCTAssertTrue(CaptureBroker.removeScript.contains("launchctl bootout system/\(CaptureBroker.label)"))
        XCTAssertEqual(CaptureBroker.appleScript("say \"hi\" \\ there"), "\"say \\\"hi\\\" \\\\ there\"")
    }

    func testInstallStagesThePlistAndHandsTheScriptToTheDialog() throws {
        let helper = FileManager.default.temporaryDirectory.appending(path: "fake-broker-\(getpid())")
        try Data().write(to: helper)
        defer { try? FileManager.default.removeItem(at: helper) }
        var ran: String?
        let text = try CaptureBroker.install(helper: helper, requirement: "cdhash H\"00\"") { script in
            ran = script
            let source = script.split(separator: "\n").first { $0.hasPrefix("cp ") && $0.contains(".plist") }
            XCTAssertNotNil(source)
            let staged = String(source!.split(separator: "'")[1])
            XCTAssertTrue(FileManager.default.fileExists(atPath: staged), "the plist is on disk while the script runs")
        }
        XCTAssertTrue(text.contains("cdhash H\"00\""))
        XCTAssertTrue(ran?.contains("cp '\(helper.path)' '\(CaptureBroker.helperPath)'") ?? false)
        XCTAssertThrowsError(try CaptureBroker.install(helper: nil, requirement: "x") { _ in }) { XCTAssertEqual($0 as? CaptureBroker.InstallError, .noHelperInBundle) }
        XCTAssertThrowsError(try CaptureBroker.install(helper: helper, requirement: nil) { _ in }) { XCTAssertEqual($0 as? CaptureBroker.InstallError, .noRequirement) }
        XCTAssertThrowsError(try CaptureBroker.remove { _ in throw CaptureBroker.InstallError.failed("User cancelled") })
    }

    // MARK: The daemon itself

    private var brokerBinary: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "tattle-capture-broker")
    }

    /// This process's own designated requirement: what the broker must accept.
    private func selfRequirement() throws -> String {
        var code: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &code), errSecSuccess)
        var staticCode: SecStaticCode?
        XCTAssertEqual(SecCodeCopyStaticCode(try XCTUnwrap(code), [], &staticCode), errSecSuccess)
        var requirement: SecRequirement?
        XCTAssertEqual(SecCodeCopyDesignatedRequirement(try XCTUnwrap(staticCode), [], &requirement), errSecSuccess)
        var text: CFString?
        XCTAssertEqual(SecRequirementCopyString(try XCTUnwrap(requirement), [], &text), errSecSuccess)
        return try XCTUnwrap(text as String?)
    }

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

    private func runBroker(requirement: String, socket: String, once: Bool = true) throws -> Process {
        let process = Process()
        process.executableURL = brokerBinary
        process.arguments = ["--requirement", requirement, "--socket", socket] + (once ? ["--once"] : [])
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
        try XCTSkipUnless(FileManager.default.fileExists(atPath: brokerBinary.path), "broker not built")
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
        try XCTSkipUnless(FileManager.default.fileExists(atPath: brokerBinary.path), "broker not built")
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
        try XCTSkipUnless(FileManager.default.fileExists(atPath: brokerBinary.path), "broker not built")
        try XCTSkipUnless(access("/dev/bpf0", R_OK) == 0, "needs readable /dev/bpf* to run the broker as the user")
        let interface = try XCTUnwrap(PacketCapture.primaryInterface())
        let socket = socketPath()
        let broker = try runBroker(requirement: try selfRequirement(), socket: socket)
        defer { broker.terminate() }

        let fd = try CaptureBroker.request(interface: interface, socket: socket)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let capture = try PacketCapture(descriptor: fd)
        XCTAssertGreaterThan(capture.bufferLength, 0, "the broker set the buffer length before binding")
        let filter = try XCTUnwrap(CaptureFilter.program(linkType: capture.dataLinkType, direction: .sourceAddresses(localAddresses().map(\.bytes))))
        XCTAssertNoThrow(try capture.install(filter), "the descriptor is ours to filter")
        expectExit(broker)
    }

    func testBrokerRefusesOtherCallersAndBadInterfaces() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: brokerBinary.path), "broker not built")
        let strangerSocket = socketPath()
        let stranger = try runBroker(requirement: nobody, socket: strangerSocket)
        defer { stranger.terminate() }
        XCTAssertThrowsError(try CaptureBroker.request(interface: "en0", socket: strangerSocket)) {
            XCTAssertEqual($0 as? CaptureBroker.RequestError, .refused)
        }
        expectExit(stranger)
        XCTAssertFalse(FileManager.default.fileExists(atPath: strangerSocket), "the broker removes its socket on exit")

        let pickySocket = socketPath()
        let picky = try runBroker(requirement: try selfRequirement(), socket: pickySocket)
        defer { picky.terminate() }
        XCTAssertThrowsError(try CaptureBroker.request(interface: "en0; rm -rf /", socket: pickySocket)) {
            XCTAssertEqual($0 as? CaptureBroker.RequestError, .badRequest)
        }
        expectExit(picky)

        try XCTSkipUnless(access("/dev/bpf0", R_OK) == 0, "needs readable /dev/bpf*")
        let missingSocket = socketPath()
        let missing = try runBroker(requirement: try selfRequirement(), socket: missingSocket)
        defer { missing.terminate() }
        XCTAssertThrowsError(try CaptureBroker.request(interface: "nosuch9", socket: missingSocket)) {
            guard case .openFailed = $0 as? CaptureBroker.RequestError else { return XCTFail("\($0)") }
        }
        expectExit(missing)

        XCTAssertThrowsError(try CaptureBroker.request(interface: "en0", socket: "/nonexistent/broker.sock")) {
            guard case .transport = $0 as? CaptureBroker.RequestError else { return XCTFail("\($0)") }
        }
    }
}
