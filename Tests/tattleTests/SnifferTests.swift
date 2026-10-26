import os
import XCTest
@testable import tattle

final class SnifferTests: XCTestCase {
    /// Waits at most `seconds` for `condition`, polling.
    private func eventually(within seconds: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { usleep(20_000) }
        return condition()
    }

    private final class FakeCapture: CaptureSource, @unchecked Sendable {
        let dataLinkType: UInt32
        private let filters = OSAllocatedUnfairLock<[CaptureFilter]>(initialState: [])
        init(linkType: UInt32) { dataLinkType = linkType }
        var installed: [CaptureFilter] { filters.withLock { $0 } }
        func install(_ filter: CaptureFilter) throws { filters.withLock { $0.append(filter) } }
        func readPackets(_ handle: (Double, [UInt8]) -> Void) throws { usleep(10_000) }
    }

    /// The kernel filter tells outbound from the interface's hardware address, or on a tunnel
    /// from its addresses. When either changes under an open capture (a private Wi-Fi address
    /// rotates, a tunnel is renumbered) the old test would class every outbound packet as
    /// inbound and drop it, so the filter is rebuilt.
    func testTheFilterFollowsTheInterfacesAddresses() {
        let mac = OSAllocatedUnfairLock(initialState: [UInt8]([0x2a, 0, 0, 0, 0, 1]))
        let ethernet = FakeCapture(linkType: PacketCapture.linkEthernet)
        let wifi = Sniffer(open: { _ in ethernet },
                           host: Sniffer.Host(primaryInterface: { "en0" }, hardwareAddress: { _ in mac.withLock { $0 } },
                                              addresses: { _ in [] }, interfaceCheckEvery: 0.05),
                           onEvents: { _ in }, onStatus: { _ in })
        wifi.start()
        XCTAssertTrue(eventually { ethernet.installed.count == 1 })
        mac.withLock { $0 = [0x2a, 0, 0, 0, 0, 2] }
        XCTAssertTrue(eventually { ethernet.installed.count == 2 }, "rebuilt for the new hardware address")
        XCTAssertEqual(ethernet.installed.last, CaptureFilter.program(linkType: PacketCapture.linkEthernet, direction: .hardwareAddress([0x2a, 0, 0, 0, 0, 2])))
        wifi.stop()
        XCTAssertEqual(ethernet.installed.count, 2, "and not again while nothing changed")

        let address = OSAllocatedUnfairLock(initialState: IPAddress(bytes: [10, 8, 0, 2]))
        let tunnel = FakeCapture(linkType: PacketCapture.linkNull)
        let vpn = Sniffer(open: { _ in tunnel },
                          host: Sniffer.Host(primaryInterface: { "utun4" }, hardwareAddress: { _ in nil },
                                             addresses: { _ in [address.withLock { $0 }] }, interfaceCheckEvery: 0.05),
                          onEvents: { _ in }, onStatus: { _ in })
        defer { vpn.stop() }
        vpn.start()
        XCTAssertTrue(eventually { tunnel.installed.count == 1 })
        address.withLock { $0 = IPAddress(bytes: [10, 8, 0, 3]) }
        XCTAssertTrue(eventually { tunnel.installed.count == 2 }, "rebuilt for the tunnel's new address")
        XCTAssertEqual(tunnel.installed.last, CaptureFilter.program(linkType: PacketCapture.linkNull, direction: .sourceAddresses([[10, 8, 0, 3]])))
    }

    /// A restart (after the broker is installed or removed) must end the old run: a run left
    /// going keeps its own capture device and reports every flow a second time.
    func testRestartEndsThePreviousRunBeforeTheNextBegins() {
        let statuses = OSAllocatedUnfairLock<[Sniffer.Status]>(initialState: [])
        let sniffer = Sniffer(open: { _ in throw CaptureError.open(errno: EACCES) },
                              onEvents: { _ in },
                              onStatus: { status in statuses.withLock { $0.append(status) } })
        defer { sniffer.stop() }
        sniffer.start()
        XCTAssertTrue(eventually { !statuses.withLock { $0 }.isEmpty }, "the first run reports its failure")
        let failure = statuses.withLock { $0[0] }

        sniffer.stop()
        sniffer.start()
        XCTAssertTrue(eventually { statuses.withLock { $0 }.count >= 3 })
        XCTAssertEqual(Array(statuses.withLock { $0 }.prefix(3)), [failure, .stopped, failure],
                       "the first run stopped before the second reported")
    }

    /// An opener that does not return until the test lets it, as a broker request that is slow
    /// to answer. Counts how many opens have begun.
    private final class SlowOpen: @unchecked Sendable {
        private let gate = DispatchSemaphore(value: 0)
        private let begun = OSAllocatedUnfairLock(initialState: 0)
        var opens: Int { begun.withLock { $0 } }
        func open() throws -> any CaptureSource {
            let number = begun.withLock { n -> Int in n += 1; return n }
            // The first open is the slow one; later ones answer at once.
            if number == 1 { _ = gate.wait(timeout: .now() + 20) }
            return FakeCapture(linkType: PacketCapture.linkEthernet)
        }
        func release() { gate.signal() }
    }

    /// A restart while the run is inside open() (the broker request can take its full timeout)
    /// must not block the caller, must not start a second run beside the first, and the old
    /// run must say nothing once it has been stopped.
    func testRestartDuringOpenNeitherBlocksNorOverlaps() {
        let statuses = OSAllocatedUnfairLock<[Sniffer.Status]>(initialState: [])
        let slow = SlowOpen()
        let sniffer = Sniffer(open: { _ in try slow.open() },
                              host: Sniffer.Host(primaryInterface: { "en0" }, hardwareAddress: { _ in [2, 0, 0, 0, 0, 1] }, addresses: { _ in [] }),
                              onEvents: { _ in }, onStatus: { status in statuses.withLock { $0.append(status) } })
        defer { slow.release(); sniffer.stop() }
        sniffer.start()
        XCTAssertTrue(eventually { slow.opens == 1 }, "the first run is inside open")

        let began = Date()
        sniffer.stop()
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.5, "stop returns without waiting for the run: it is the main actor's call")
        sniffer.start()
        usleep(500_000)
        XCTAssertEqual(slow.opens, 1, "the second run waits for the first to end before it opens a device")

        slow.release()
        XCTAssertTrue(eventually { statuses.withLock { $0 }.count >= 2 })
        XCTAssertEqual(statuses.withLock { $0 }, [.stopped, .capturing(interface: "en0")],
                       "the stopped run reports only that it stopped, and before the new run reports")
    }
}
