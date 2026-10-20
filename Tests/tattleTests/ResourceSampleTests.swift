import XCTest
@testable import tattle

final class ResourceSampleTests: XCTestCase {
    private func snapshot(
        at seconds: TimeInterval, busy: UInt64, total: UInt64, bytesIn: UInt64, bytesOut: UInt64
    ) -> SystemSnapshot {
        SystemSnapshot(
            time: Date(timeIntervalSinceReferenceDate: seconds),
            cpu: CPUTicks(busy: busy, total: total),
            memory: MemoryUsage(used: 1, total: 2),
            network: NetworkCounters(bytesIn: bytesIn, bytesOut: bytesOut))
    }

    func testRatesBetweenSnapshots() {
        let a = snapshot(at: 0, busy: 100, total: 400, bytesIn: 1_000, bytesOut: 500)
        let b = snapshot(at: 2, busy: 150, total: 500, bytesIn: 5_000, bytesOut: 700)
        let sample = ResourceSample.between(a, b)
        XCTAssertEqual(sample.cpu, 0.5)
        XCTAssertEqual(sample.bytesInPerSecond, 2_000)
        XCTAssertEqual(sample.bytesOutPerSecond, 100)
        XCTAssertEqual(sample.memory, MemoryUsage(used: 1, total: 2))
    }

    func testNoTicksMeansZeroCPU() {
        let a = snapshot(at: 0, busy: 100, total: 400, bytesIn: 0, bytesOut: 0)
        XCTAssertEqual(ResourceSample.between(a, a).cpu, 0)
    }

    func testNetworkCounterWrap() {
        XCTAssertEqual(NetworkCounters.wrappedDelta(from: 10, to: 30), 20)
        XCTAssertEqual(NetworkCounters.wrappedDelta(from: UInt64(UInt32.max) - 9, to: 10), 20)
    }

    func testCompactRate() {
        XCTAssertEqual(ByteRate.compact(0), "0")
        XCTAssertEqual(ByteRate.compact(999), "999")
        XCTAssertEqual(ByteRate.compact(1_000), "1.0K")
        XCTAssertEqual(ByteRate.compact(12_345), "12K")
        XCTAssertEqual(ByteRate.compact(1_234_567), "1.2M")
        XCTAssertEqual(ByteRate.compact(3_400_000_000), "3.4G")
        XCTAssertEqual(ByteRate.compact(-5), "0")
    }

    func testLiveSnapshotIsSane() throws {
        let snapshot = try XCTUnwrap(SystemSnapshot.read())
        XCTAssertGreaterThan(snapshot.cpu.total, 0)
        XCTAssertLessThanOrEqual(snapshot.cpu.busy, snapshot.cpu.total)
        XCTAssertGreaterThan(snapshot.memory.total, 0)
        XCTAssertLessThanOrEqual(snapshot.memory.used, snapshot.memory.total)
    }
}
