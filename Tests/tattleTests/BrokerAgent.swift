import XCTest
@testable import tattle

/// A program under launchd as this user: an agent in `user/<uid>` whose Mach service no other
/// test or run uses, started by launchd on the first message the way the installed daemon is.
/// Tests reach the real XPC path through it without root. The user domain, not `gui/<uid>`,
/// because it exists in an ssh session too. Booted out when the test ends; a run that died
/// before its teardown leaves agents the next run boots out.
struct BrokerAgent {
    static let labelPrefix = "io.github.eladefrati.tattle.test."
    nonisolated(unsafe) private static var count = 0
    nonisolated(unsafe) private static var swept = false

    let label: String
    let directory: URL
    var service: CaptureBroker.Service { CaptureBroker.Service(name: label, privileged: false) }
    /// The program's stderr, where the broker's log lines also go.
    var log: String { (try? String(contentsOf: directory.appending(path: "stderr.log"), encoding: .utf8)) ?? "" }

    static func uniqueLabel() -> String {
        count += 1
        return "\(labelPrefix)\(getpid()).\(count)"
    }

    static var domain: String { "user/\(getuid())" }

    /// Registers `arguments` (the program first) as the job serving `label`.
    init(_ test: XCTestCase, label: String = BrokerAgent.uniqueLabel(), arguments: [String]) throws {
        Self.sweepOnce()
        self.label = label
        directory = FileManager.default.temporaryDirectory.appending(path: "broker-agent-\(label.dropFirst(Self.labelPrefix.count))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments,
            "MachServices": [label: true],
            // The user domain loads only Background agents.
            "LimitLoadToSessionType": "Background",
            "StandardErrorPath": directory.appending(path: "stderr.log").path,
        ]
        let url = directory.appending(path: "agent.plist")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        let directory = directory
        test.addTeardownBlock {
            Self.launchctl(["bootout", "\(Self.domain)/\(label)"])
            try? FileManager.default.removeItem(at: directory)
        }
        XCTAssertEqual(Self.launchctl(["bootstrap", Self.domain, url.path]), 0, "bootstrap \(label)")
    }

    /// Runs launchctl, bounded at 10 s like every process the tests start. Returns its exit
    /// status, or -1 when it could not run or was killed at the bound.
    @discardableResult
    static func launchctl(_ arguments: [String]) -> Int32 {
        run(arguments).status
    }

    /// Output goes to a file, not a pipe: `print` of a whole domain fills a pipe, and launchctl
    /// would block writing it while this waits for it to exit.
    private static func run(_ arguments: [String]) -> (status: Int32, output: String) {
        let file = FileManager.default.temporaryDirectory.appending(path: "launchctl-\(getpid())-\(UUID().uuidString).out")
        guard FileManager.default.createFile(atPath: file.path, contents: nil), let handle = try? FileHandle(forWritingTo: file) else { return (-1, "") }
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: file)
        }
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, "") }
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { usleep(10_000) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            return (-1, "")
        }
        return (process.terminationStatus, (try? String(contentsOf: file, encoding: .utf8)) ?? "")
    }

    var pid: Int32? {
        LaunchctlState.parseServices(Self.run(["print", Self.domain]).output)[label]?.pid
    }

    /// Boots out agents left by runs that are gone, once per run: their label carries their pid.
    private static func sweepOnce() {
        guard !swept else { return }
        swept = true
        for label in LaunchctlState.parseServices(run(["print", domain]).output).keys where label.hasPrefix(labelPrefix) {
            guard let pid = Int32(label.dropFirst(labelPrefix.count).split(separator: ".").first ?? ""), pid != getpid(),
                  kill(pid, 0) != 0, errno == ESRCH else { continue }
            launchctl(["bootout", "\(domain)/\(label)"])
        }
    }
}
