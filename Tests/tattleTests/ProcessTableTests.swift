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
