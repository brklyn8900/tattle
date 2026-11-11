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
        guard !expected.isEmpty else { throw XCTSkip("lsof sees no TCP listener of this user") }
        for (pid, port) in expected {
            XCTAssertTrue(listeners.contains { $0.proto == .tcp && $0.localPort == port && $0.pid == pid },
                          "lsof sees pid \(pid) listening on \(port)")
        }
    }

    /// The kernel marks a dual-stack listener with both families.
    func testTheTableTellsWhichFamiliesAListenerTakes() throws {
        func listener(family: Int32, v6Only: Bool?) throws -> (fd: Int32, port: UInt16) {
            let fd = socket(family, SOCK_STREAM, 0)
            XCTAssertGreaterThanOrEqual(fd, 0)
            if let v6Only {
                var value: Int32 = v6Only ? 1 : 0
                XCTAssertEqual(setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &value, socklen_t(MemoryLayout<Int32>.size)), 0)
            }
            var storage = sockaddr_storage()
            storage.ss_family = sa_family_t(family)
            storage.ss_len = UInt8(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            var length = socklen_t(storage.ss_len)
            let bound = withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
            }
            XCTAssertEqual(bound, 0, String(cString: strerror(errno)))
            XCTAssertEqual(Darwin.listen(fd, 1), 0)
            let named = withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            XCTAssertEqual(named, 0)
            let port = family == AF_INET
                ? withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_port } }
                : withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_port } }
            return (fd, UInt16(bigEndian: port))
        }
        let v4 = try listener(family: AF_INET, v6Only: nil)
        let v6 = try listener(family: AF_INET6, v6Only: true)
        let dual = try listener(family: AF_INET6, v6Only: false)
        defer { [v4, v6, dual].forEach { close($0.fd) } }
        let table = try SocketTable.read().filter { $0.proto == .tcp && $0.isListening }
        func entry(_ port: UInt16) throws -> SocketEntry { try XCTUnwrap(table.first { $0.localPort == port }) }
        XCTAssertEqual(try [entry(v4.port).acceptsIPv4, entry(v4.port).acceptsIPv6], [true, false])
        XCTAssertEqual(try [entry(v6.port).acceptsIPv4, entry(v6.port).acceptsIPv6], [false, true])
        XCTAssertEqual(try [entry(dual.port).acceptsIPv4, entry(dual.port).acceptsIPv6], [true, true])
    }

    private func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        // A file, not a pipe: the wait below is bounded, and output larger than a pipe's
        // buffer would hold the process until it is read.
        let output = FileManager.default.temporaryDirectory.appending(path: "socket-table-\(getpid())-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: output) }
        process.standardOutput = try FileHandle(forWritingTo: output)
        process.standardError = FileHandle.nullDevice
        try process.run()
        waitForExit(process)
        return String(decoding: try Data(contentsOf: output), as: UTF8.self)
    }
}
