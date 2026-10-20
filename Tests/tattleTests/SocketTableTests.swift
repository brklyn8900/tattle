import XCTest
@testable import tattle

final class SocketTableTests: XCTestCase {
    func testTablesParseAndMatchLsof() throws {
        let entries = try SocketTable.read()
        XCTAssertFalse(entries.isEmpty)
        let listeners = entries.filter(\.isListening)
        XCTAssertFalse(listeners.filter { $0.proto == .tcp }.isEmpty, "something always listens on TCP")
        XCTAssertFalse(listeners.filter { $0.proto == .udp }.isEmpty, "mDNS always listens on UDP")
        XCTAssertTrue(entries.allSatisfy { $0.pid >= 0 })
        for entry in listeners where entry.proto == .tcp {
            XCTAssertEqual(entry.remotePort, 0, "a TCP listener has no peer")
        }

        // Cross-check with lsof for this user's processes: every TCP listener lsof sees
        // must be in the table with the same pid.
        let lsof = try run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"])
        var pid: Int32 = 0
        var expected: [(pid: Int32, port: UInt16)] = []
        for line in lsof.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) ?? 0 }
            if line.hasPrefix("n"), let port = line.split(separator: ":").last.flatMap({ UInt16($0) }) {
                expected.append((pid, port))
            }
        }
        XCTAssertFalse(expected.isEmpty)
        for (pid, port) in expected {
            XCTAssertTrue(listeners.contains { $0.proto == .tcp && $0.localPort == port && $0.pid == pid },
                          "lsof sees pid \(pid) listening on \(port)")
        }
    }

    func testProcessIdentity() {
        let me = ProcessIdentity.read(pid: getpid())
        XCTAssertNotNil(me?.path)
        XCTAssertEqual(ProcessIdentity.read(pid: 1)?.name, "launchd", "root processes are readable too")
        XCTAssertNil(ProcessIdentity.read(pid: 0))
        XCTAssertNil(ProcessIdentity.read(pid: 999_999))
    }

    private func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
