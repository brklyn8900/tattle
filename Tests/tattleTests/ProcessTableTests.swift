import XCTest
@testable import tattle

final class ProcessTableTests: XCTestCase {
    func testKernelListHasEveryoneWithNamesAndParents() throws {
        let entries = try ProcessTable.list()
        let byPid = Dictionary(entries.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byPid.count, entries.count, "one entry per pid")
        XCTAssertGreaterThan(entries.count, 100)

        let kernel = try XCTUnwrap(byPid[0])
        XCTAssertEqual(kernel.name, "kernel_task", "pid 0 has no path, so the command name is used")
        XCTAssertNil(kernel.path)
        let launchd = try XCTUnwrap(byPid[1])
        XCTAssertEqual(launchd.path, "/sbin/launchd")
        XCTAssertEqual(launchd.parentPid, 0)
        XCTAssertEqual(launchd.uid, 0)

        let me = try XCTUnwrap(byPid[getpid()])
        XCTAssertEqual(me.uid, getuid())
        XCTAssertEqual(me.parentPid, getppid())
        XCTAssertNotNil(me.path)
        XCTAssertLessThan(me.started, Date())
        XCTAssertGreaterThan(me.started, Date().addingTimeInterval(-24 * 60 * 60))
        XCTAssertTrue(entries.contains { $0.uid != getuid() }, "root processes are listed too")
    }

    func testScriptsAreNamedAfterTheScript() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appending(path: "tattle-probe-script.sh")
        try Data("#!/bin/sh\nsleep 30\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let process = Process()
        process.executableURL = script
        process.arguments = ["--flag", "/etc"]
        try process.run()
        defer { process.terminate() }

        let entries = try ProcessTable.list()
        let entry = try XCTUnwrap(entries.first { $0.pid == process.processIdentifier })
        XCTAssertEqual(entry.name, "tattle-probe-script.sh")
        XCTAssertEqual(entry.interpreter, "sh")
        XCTAssertEqual(entry.path, "/bin/sh")
        XCTAssertEqual(entry.arguments?.dropFirst().first, script.path, "the kernel passes the script as the first argument")
        XCTAssertEqual(entry.arguments?.last, "/etc")

        let me = try XCTUnwrap(entries.first { $0.pid == getpid() })
        XCTAssertNil(me.interpreter)
        XCTAssertEqual(me.arguments?.isEmpty, false)
        let launchd = try XCTUnwrap(entries.first { $0.pid == 1 })
        XCTAssertNil(launchd.arguments, "other users' command lines are not readable")
        XCTAssertEqual(launchd.name, "launchd")
    }

    func testNaming() {
        XCTAssertEqual(ProcessEntry.name(path: "/usr/bin/python3", arguments: ["python3", "-u", "/bin/ls"], command: "python3").name, "ls")
        XCTAssertEqual(ProcessEntry.name(path: "/opt/homebrew/bin/python3.14", arguments: ["python3.14", "/bin/ls"], command: "python3.14").interpreter, "python3.14")
        XCTAssertEqual(ProcessEntry.name(path: "/usr/bin/python3", arguments: ["python3", "-m", "http.server"], command: "python3").name, "python3")
        let shell = ProcessEntry.name(path: "/bin/zsh", arguments: ["-zsh"], command: "zsh")
        XCTAssertEqual(shell.name, "zsh", "a login shell with no script is itself")
        XCTAssertNil(shell.interpreter)
        XCTAssertEqual(ProcessEntry.name(path: "/Users/u/.local/share/claude/versions/2.1.304", arguments: ["claude", "--model", "x"], command: "2.1.304").name, "claude",
                       "the name it was started under beats a version-numbered file name")
        XCTAssertEqual(ProcessEntry.name(path: "/Users/u/.local/share/claude/versions/2.1.304", arguments: ["ugrep", "-G"], command: "2.1.304").name, "ugrep")
        XCTAssertEqual(ProcessEntry.name(path: nil, arguments: ["claude"], command: "2.1.206").name, "claude", "a deleted executable too")
        XCTAssertEqual(ProcessEntry.name(path: "/opt/node/bin/node", arguments: ["npm exec chrome-devtools-mcp@1.11.0", ""], command: "node").name,
                       "npm exec chrome-devtools-mcp@1.11.0", "a title node set for itself")
        XCTAssertEqual(ProcessEntry.name(path: "/usr/libexec/trustd", arguments: nil, command: "trustd").name, "trustd")
        XCTAssertEqual(ProcessEntry.name(path: nil, arguments: nil, command: "kernel_task").name, "kernel_task")

        XCTAssertEqual(ProcessEntry.scriptName("/Users/u/.npm/_npx/0a/node_modules/chrome-devtools-mcp/build/src/main.js"), "chrome-devtools-mcp")
        XCTAssertEqual(ProcessEntry.scriptName("/x/node_modules/@playwright/mcp/cli.js"), "@playwright/mcp")
        XCTAssertEqual(ProcessEntry.scriptName("/x/node_modules/.bin/tsc"), "tsc")
        XCTAssertEqual(ProcessEntry.name(path: "/opt/node/bin/node", arguments: ["npm exec @playwright/mcp@latest", ""], command: "node").name,
                       "npm exec @playwright/mcp@latest", "a title is not a path")
        XCTAssertEqual(ProcessEntry.scriptName("/Users/u/dev/app/server.js"), "server.js")
    }

    func testParseArguments() {
        var bytes: [UInt8] = [3, 0, 0, 0]
        bytes += Array("/usr/bin/node".utf8) + [0, 0, 0]
        bytes += Array("node".utf8) + [0] + Array("/tmp/server.js".utf8) + [0] + Array("--port".utf8) + [0]
        bytes += Array("HOME=/Users/u".utf8) + [0]
        XCTAssertEqual(ProcessTable.parseArguments(bytes[...]), ["node", "/tmp/server.js", "--port"])
        XCTAssertNil(ProcessTable.parseArguments([1, 0][...]))
    }

    func testOwnUsageMatchesGetrusage() {
        var spin = 0.0
        for i in 0..<5_000_000 { spin += (Double(i) * 1.0001).squareRoot() }
        XCTAssertGreaterThan(spin, 0)
        var rusage = Darwin.rusage()
        getrusage(RUSAGE_SELF, &rusage)
        let expected = Double(rusage.ru_utime.tv_sec) + Double(rusage.ru_utime.tv_usec) / 1e6
            + Double(rusage.ru_stime.tv_sec) + Double(rusage.ru_stime.tv_usec) / 1e6

        let usage = ProcessTable.ownUsage(pid: getpid())!
        XCTAssertTrue(usage.memoryIsFootprint)
        XCTAssertGreaterThan(usage.memoryBytes, 1 << 20)
        // The rusage times are Mach units, converted with the timebase; getrusage is the
        // same clock in microseconds.
        XCTAssertEqual(usage.cpuSeconds, expected, accuracy: 0.05)
        XCTAssertNil(ProcessTable.ownUsage(pid: 1), "root processes are refused")
    }

    func testFallbackParsesPsTimes() {
        let parsed = ProcessUsageFallback.parse("""
              1  32736 622:57.17
            313 103024   0:05.31
            999  1024 1-02:03:04.50
            bad line here
            """)
        XCTAssertEqual(parsed[1], ProcessUsage(memoryBytes: 32736 * 1024, cpuSeconds: 622 * 60 + 57.17, memoryIsFootprint: false))
        XCTAssertEqual(parsed[313]?.cpuSeconds, 5.31)
        XCTAssertEqual(parsed[999]?.cpuSeconds, 26 * 3600 + 3 * 60 + 4.5)
        XCTAssertEqual(parsed.count, 3)
        XCTAssertNil(ProcessUsageFallback.seconds(fromTime: "12"))
        XCTAssertNil(ProcessUsageFallback.seconds(fromTime: "a:b"))
    }

    func testReadFillsUsageForOthersThroughFallback() throws {
        var asked: [Int32] = []
        let entries = try ProcessTable.read { pids in
            asked = pids
            return Dictionary(pids.map { ($0, ProcessUsage(memoryBytes: 7, cpuSeconds: 1, memoryIsFootprint: false)) }, uniquingKeysWith: { a, _ in a })
        }
        XCTAssertTrue(asked.contains(1), "launchd is root, so ps must supply it")
        XCTAssertFalse(asked.contains(getpid()), "own processes come from libproc")
        XCTAssertEqual(entries.first { $0.pid == 1 }?.usage?.memoryBytes, 7)
        XCTAssertTrue(entries.first { $0.pid == getpid() }?.usage?.memoryIsFootprint == true)
    }

    func testRealFallbackCoversRootProcesses() throws {
        let entries = try ProcessTable.read()
        let root = entries.filter { $0.uid == 0 && $0.pid > 0 }
        let covered = root.filter { $0.usage != nil }
        // A handful can exit between the kernel list and ps.
        XCTAssertGreaterThan(Double(covered.count), Double(root.count) * 0.95, "\(covered.count) of \(root.count)")
        XCTAssertEqual(entries.first { $0.pid == 1 }?.usage?.memoryIsFootprint, false)
        XCTAssertGreaterThan(entries.first { $0.pid == 1 }?.usage?.memoryBytes ?? 0, 0)
    }
}
