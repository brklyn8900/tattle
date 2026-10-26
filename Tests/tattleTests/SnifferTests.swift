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
}
