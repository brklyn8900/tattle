import XCTest
@testable import tattle

final class ResourceSampleTests: XCTestCase {
    private func snapshot(
        at seconds: TimeInterval, busy: UInt64, total: UInt64, bytesIn: UInt32, bytesOut: UInt32
    ) -> SystemSnapshot {
        SystemSnapshot(
            time: Date(timeIntervalSinceReferenceDate: seconds),
            cpu: CPUTicks(busy: busy, total: total),
            memory: MemoryUsage(used: 1, total: 2),
            network: counters(["en0": (bytesIn, bytesOut)]))
    }

    private func counters(_ interfaces: [String: (UInt32, UInt32)]) -> NetworkCounters {
        NetworkCounters(interfaces: interfaces.mapValues { .init(bytesIn: $0.0, bytesOut: $0.1) })
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

    func testACounterThatWrapsCountsTheBytesAcrossTheWrap() {
        let delta = counters(["en0": (10, 30)]).delta(from: counters(["en0": (.max - 9, 10)]))
        XCTAssertEqual(delta.bytesIn, 20)
        XCTAssertEqual(delta.bytesOut, 20)
    }

    func testEachInterfaceWrapsOnItsOwn() {
        let delta = counters(["en0": (10, 0), "en1": (5, 0)])
            .delta(from: counters(["en0": (.max - 9, 0), "en1": (.max - 4, 0)]))
        XCTAssertEqual(delta.bytesIn, 30)
    }

    func testAnInterfaceThatVanishesCountsNothing() {
        let delta = counters(["en0": (1_100, 520)])
            .delta(from: counters(["en0": (1_000, 500), "en7": (2_000_000_000, 7)]))
        XCTAssertEqual(delta.bytesIn, 100)
        XCTAssertEqual(delta.bytesOut, 20)
    }

    func testAnInterfaceThatAppearsCountsFromItsSecondReading() {
        let delta = counters(["en0": (1_100, 520), "en7": (2_000_000_000, 7)])
            .delta(from: counters(["en0": (1_000, 500)]))
        XCTAssertEqual(delta.bytesIn, 100)
        XCTAssertEqual(delta.bytesOut, 20)
    }

    func testOnlyInterfacesWithTheirOwnTrafficAreCounted() {
        for name in ["utun4", "ipsec0", "gif0", "stf0", "bridge0", "bridge100", "vmenet0", "vlan0", "bond0", "feth0"] {
            XCTAssertFalse(NetworkCounters.carriesItsOwnTraffic(name), name)
        }
        for name in ["en0", "en7", "ap1", "awdl0", "llw0", "anpi0"] {
            XCTAssertTrue(NetworkCounters.carriesItsOwnTraffic(name), name)
        }
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

    func testFullRate() {
        XCTAssertEqual(ByteRate.full(0), "0 B/s")
        XCTAssertEqual(ByteRate.full(981), "981 B/s")
        XCTAssertEqual(ByteRate.full(12_345), "12 kB/s")
        XCTAssertEqual(ByteRate.full(1_234_567), "1.2 MB/s")
    }

    func testLiveSnapshotIsSane() throws {
        let snapshot = try XCTUnwrap(SystemSnapshot.read())
        XCTAssertGreaterThan(snapshot.cpu.total, 0)
        XCTAssertLessThanOrEqual(snapshot.cpu.busy, snapshot.cpu.total)
        XCTAssertGreaterThan(snapshot.memory.total, 0)
        XCTAssertLessThanOrEqual(snapshot.memory.used, snapshot.memory.total)
        XCTAssertFalse(snapshot.network.interfaces.isEmpty)
        XCTAssertNil(snapshot.network.interfaces["lo0"])
        XCTAssertTrue(snapshot.network.interfaces.keys.allSatisfy(NetworkCounters.carriesItsOwnTraffic))
    }
}
