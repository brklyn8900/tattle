import os
import XCTest
@testable import tattle

final class SnifferTests: XCTestCase {
    /// ADR-0003: other software can have made the devices readable, and then Tattle opens one
    /// itself, with no broker or with one that gives it nothing.
    func testTheDeviceIsOpenedWhenThereIsNoBrokerOrItGivesNoCapture() throws {
        let refused: () throws -> String = { throw CaptureBroker.RequestError.refused }
        let unreadable: () throws -> String = { throw CaptureError.open(errno: EACCES) }
        XCTAssertEqual(try PacketCapture.obtain(broker: { "broker" }, device: { "device" }), "broker")
        XCTAssertEqual(try PacketCapture.obtain(broker: nil, device: { "device" }), "device")
        XCTAssertEqual(try PacketCapture.obtain(broker: refused, device: { "device" }), "device")
        XCTAssertThrowsError(try PacketCapture.obtain(broker: refused, device: unreadable)) {
            XCTAssertEqual($0 as? CaptureError, .broker(.refused), "what the broker said, not that the device is root's")
        }
        XCTAssertThrowsError(try PacketCapture.obtain(broker: nil, device: unreadable)) {
            XCTAssertEqual($0 as? CaptureError, .open(errno: EACCES))
        }
    }

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

    /// A raw-IP capture that delivers its packets on the first read, then nothing.
    private final class OnePass: CaptureSource, @unchecked Sendable {
        let dataLinkType = PacketCapture.linkRaw
        private let packets: OSAllocatedUnfairLock<[[UInt8]]>
        init(_ packets: [[UInt8]]) { self.packets = OSAllocatedUnfairLock(initialState: packets) }
        func install(_ filter: CaptureFilter) throws {}
        func readPackets(_ handle: (Double, [UInt8]) -> Void) throws {
            for bytes in packets.withLock({ p in defer { p = [] }; return p }) { handle(Date().timeIntervalSince1970, bytes) }
            usleep(10_000)
        }
    }

    /// A run's flows end with it. One whose handshake was not read yet gets a reason when the
    /// capture stops or reopens, or its connection keeps neither a name nor a reason.
    func testFlowsPendingWhenARunEndsGetAReason() {
        let me = IPAddress(bytes: [192, 168, 1, 5])
        let remote = IPAddress(bytes: [203, 0, 113, 7])
        @Sendable func syn(from port: UInt16) -> [UInt8] {
            [0x45, 0, 0, 40, 0, 0, 0, 0, 64, 6, 0, 0] + me.bytes + remote.bytes
                + [UInt8(port >> 8), UInt8(port & 0xff), 0x01, 0xbb, 0, 0, 0, 1, 0, 0, 0, 0, 0x50, 0x02, 0xff, 0xff, 0, 0, 0, 0]
        }
        func key(_ port: UInt16) -> FlowKey { FlowKey(proto: .tcp, localPort: port, remote: remote, remotePort: 443) }
        let interface = OSAllocatedUnfairLock(initialState: "en0")
        let opens = OSAllocatedUnfairLock(initialState: 0)
        let events = OSAllocatedUnfairLock<[FlowEvent]>(initialState: [])
        let sniffer = Sniffer(open: { _ in OnePass([syn(from: opens.withLock { n in n += 1; return 50000 + UInt16(n) })]) },
                              host: Sniffer.Host(primaryInterface: { interface.withLock { $0 } }, hardwareAddress: { _ in nil },
                                                 addresses: { _ in [me] }, resolvers: { [] }, interfaceCheckEvery: 0.05),
                              onEvents: { new in events.withLock { $0 += new } }, onStatus: { _ in })
        defer { sniffer.stop() }
        sniffer.start()
        XCTAssertTrue(eventually { events.withLock { $0 } == [FlowEvent(key: key(50001), kind: .opened)] }, "the first run's flow opened")

        interface.withLock { $0 = "en1" }
        XCTAssertTrue(eventually { events.withLock { $0 }.count >= 3 })
        XCTAssertEqual(events.withLock { $0 }, [FlowEvent(key: key(50001), kind: .opened), FlowEvent(key: key(50001), kind: .unnamed(.captureEnded)),
                                                 FlowEvent(key: key(50002), kind: .opened)],
                       "the default route moved: the old run gave up on its flow before the new run opened one")

        sniffer.stop()
        XCTAssertTrue(eventually { events.withLock { $0 }.count >= 4 })
        XCTAssertEqual(events.withLock { $0 }.last, FlowEvent(key: key(50002), kind: .unnamed(.captureEnded)), "stopped")
    }

    /// An opener that does not return until the test lets it, as a broker request that is slow
    /// to answer. Counts how many opens have begun.
    private final class SlowOpen: @unchecked Sendable {
        private let gate = DispatchSemaphore(value: 0)
        private let begun = OSAllocatedUnfairLock(initialState: 0)
        var opens: Int { begun.withLock { $0 } }
        func open() throws -> any CaptureSource {
            let number = begun.withLock { n -> Int in n += 1; return n }
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
