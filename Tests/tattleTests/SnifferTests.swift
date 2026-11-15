import CPacketCapture
import os
import XCTest
@testable import tattle

final class SnifferTests: XCTestCase {
    /// A record of no length would leave the walk where it is, and the read loop would spin.
    /// A real Ethernet record has a header length of 18, below the struct's 20, and still walks.
    func testTheCaptureWalkEndsAtARecordThatWouldNotAdvance() {
        var buffer = [UInt8](repeating: 0, count: 64)
        var timestamp = 0.0, dataOffset = 0, next = 0
        var caplen: UInt32 = 0
        XCTAssertEqual(tattle_capture_next(buffer, buffer.count, 0, &timestamp, &dataOffset, &caplen, &next), 0)

        withUnsafeBytes(of: UInt32(10).littleEndian) { buffer.replaceSubrange(8..<12, with: $0) }  // bh_caplen
        withUnsafeBytes(of: UInt16(18).littleEndian) { buffer.replaceSubrange(16..<18, with: $0) }  // bh_hdrlen
        XCTAssertEqual(tattle_capture_next(buffer, buffer.count, 0, &timestamp, &dataOffset, &caplen, &next), 1)
        XCTAssertEqual(dataOffset, 18)
        XCTAssertEqual(caplen, 10)
        XCTAssertEqual(next, 28)
    }

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
        usleep(300_000)  // six more checks of the interface
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

    /// A capture that delivers what the test feeds it, and applies no filter.
    private final class Fed: CaptureSource, @unchecked Sendable {
        let dataLinkType: UInt32
        private let packets = OSAllocatedUnfairLock<[(at: Double, bytes: [UInt8])]>(initialState: [])
        init(linkType: UInt32) { dataLinkType = linkType }
        /// `secondsAgo` dates the frames' capture that long before now.
        func feed(_ frames: [[UInt8]], secondsAgo: Double = 0) {
            let at = Date().timeIntervalSince1970 - secondsAgo
            packets.withLock { $0 += frames.map { (at, $0) } }
        }
        func install(_ filter: CaptureFilter) throws {}
        func readPackets(_ handle: (Double, [UInt8]) -> Void) throws {
            for packet in packets.withLock({ p in defer { p = [] }; return p }) { handle(packet.at, packet.bytes) }
            usleep(10_000)
        }
    }

    /// The namer's set of this Mac's addresses leaves out other links' link-local ones, so a
    /// router that answers DNS from fe80::1, which loopback holds too, still names addresses.
    func testARouterAtLoopbacksLinkLocalAddressNamesAFlowByDNS() {
        let me = IPAddress(bytes: [192, 168, 1, 5])
        let mine = IPAddress(bytes: [0xfe, 0x80] + [UInt8](repeating: 0, count: 12) + [0xab, 0xcd])
        let router = IPAddress(bytes: [0xfe, 0x80] + [UInt8](repeating: 0, count: 13) + [1])
        let remote = IPAddress(bytes: [203, 0, 113, 7])
        let mac: [UInt8] = [0x2a, 0, 0, 0, 0, 1], routerMac: [UInt8] = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55]
        let answer: [UInt8] = [0x12, 0x34, 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0, 3, 0x63, 0x64, 0x6e, 7, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 3, 0x6e, 0x65, 0x74, 0, 0, 1, 0, 1,
                               0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 0x3c, 0, 4] + remote.bytes
        let datagram: [UInt8] = [0, 53, 0xea, 0x60, 0, UInt8(8 + answer.count), 0, 0] + answer
        let reply: [UInt8] = mac + routerMac + [0x86, 0xdd, 0x60, 0, 0, 0, 0, UInt8(datagram.count), 17, 64] + router.bytes + mine.bytes + datagram
        let syn: [UInt8] = routerMac + mac + [0x08, 0x00, 0x45, 0, 0, 40, 0, 0, 0, 0, 64, 6, 0, 0] + me.bytes + remote.bytes
            + [0xc3, 0x51, 0x01, 0xbb, 0, 0, 0, 1, 0, 0, 0, 0, 0x50, 0x02, 0xff, 0xff, 0, 0, 0, 0]
        let key = FlowKey(proto: .tcp, localPort: 50001, remote: remote, remotePort: 443)

        let capture = Fed(linkType: PacketCapture.linkEthernet)
        let events = OSAllocatedUnfairLock<[FlowEvent]>(initialState: [])
        let sniffer = Sniffer(open: { _ in capture },
                              host: Sniffer.Host(primaryInterface: { "en0" }, hardwareAddress: { _ in mac },
                                                 addresses: { $0 == nil ? [me, mine, router] : [me, mine] }, resolvers: { [router] }),
                              onEvents: { new in events.withLock { $0 += new } }, onStatus: { _ in })
        defer { sniffer.stop() }
        sniffer.start()
        capture.feed([reply])
        // Opened long enough ago for the DNS fallback to be due at the next pass.
        capture.feed([syn], secondsAgo: FlowNamer.dnsFallbackAfter + 1)
        XCTAssertTrue(eventually { events.withLock { $0 }.count >= 2 })
        XCTAssertEqual(events.withLock { $0 }, [FlowEvent(key: key, kind: .opened), FlowEvent(key: key, kind: .named("cdn.example.net", .dns))])
    }

    private static let me = IPAddress(bytes: [192, 168, 1, 5])
    private static let remote = IPAddress(bytes: [203, 0, 113, 7])

    /// An Ethernet frame from `source` carrying this Mac's SYN to `remote`.
    private static func syn(from source: [UInt8], port: UInt16) -> [UInt8] {
        [2, 0, 0, 0, 0, 9] + source + [0x08, 0x00, 0x45, 0, 0, 40, 0, 0, 0, 0, 64, 6, 0, 0] + me.bytes + remote.bytes
            + [UInt8(port >> 8), UInt8(port & 0xff), 0x01, 0xbb, 0, 0, 0, 1, 0, 0, 0, 0, 0x50, 0x02, 0xff, 0xff, 0, 0, 0, 0]
    }

    private static func opened(_ port: UInt16) -> FlowEvent {
        FlowEvent(key: FlowKey(proto: .tcp, localPort: port, remote: remote, remotePort: 443), kind: .opened)
    }

    /// A sniffer on an Ethernet capture the test feeds, with no kernel filter in front, whose
    /// interface is checked only as often as given. Returns the openings it reports.
    private func ethernetSniffer(_ capture: Fed, mac: OSAllocatedUnfairLock<[UInt8]>, interfaceCheckEvery: TimeInterval) -> (Sniffer, OSAllocatedUnfairLock<[FlowEvent]>) {
        let events = OSAllocatedUnfairLock<[FlowEvent]>(initialState: [])
        let sniffer = Sniffer(open: { _ in capture },
                              host: Sniffer.Host(primaryInterface: { "en0" }, hardwareAddress: { _ in mac.withLock { $0 } },
                                                 addresses: { _ in [Self.me] }, resolvers: { [] }, interfaceCheckEvery: interfaceCheckEvery),
                              onEvents: { new in events.withLock { $0 += new.filter { $0.kind == .opened } } }, onStatus: { _ in })
        return (sniffer, events)
    }

    private static let first: [UInt8] = [0x2a, 0, 0, 0, 0, 1], rotated: [UInt8] = [0x2a, 0, 0, 0, 0, 2], other: [UInt8] = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55]

    /// On Ethernet the namer is told the interface's hardware address, so a frame another host
    /// sent under this Mac's IP address opens no flow, with or without a kernel filter in
    /// front, before the address changes and after.
    func testOnEthernetOnlyFramesFromTheInterfaceOpenFlows() {
        let mac = OSAllocatedUnfairLock(initialState: Self.first)
        let capture = Fed(linkType: PacketCapture.linkEthernet)
        let (sniffer, events) = ethernetSniffer(capture, mac: mac, interfaceCheckEvery: 0.05)
        defer { sniffer.stop() }
        sniffer.start()
        capture.feed([Self.syn(from: Self.other, port: 50001), Self.syn(from: Self.first, port: 50002)])
        XCTAssertTrue(eventually { !events.withLock { $0 }.isEmpty })
        XCTAssertEqual(events.withLock { $0 }, [Self.opened(50002)], "the other host's frame opened nothing")

        // Frames from the new address are fed until the run has noticed it and one opens a flow.
        mac.withLock { $0 = Self.rotated }
        var port: UInt16 = 50100
        let deadline = Date().addingTimeInterval(10)
        while events.withLock({ $0 }).count < 2, Date() < deadline {
            port += 1
            capture.feed([Self.syn(from: Self.rotated, port: port)])
            usleep(50_000)
        }
        // Frames are read in the order fed, so once the second of these has opened its flow the
        // first has been read too.
        capture.feed([Self.syn(from: Self.first, port: 50003), Self.syn(from: Self.rotated, port: 50004)])
        XCTAssertTrue(eventually { events.withLock { $0 }.contains(Self.opened(50004)) }, "the namer follows the interface's new address")
        XCTAssertFalse(events.withLock { $0 }.contains(Self.opened(50003)), "and a frame from the old one opens nothing")
    }

    /// The interface is checked every few seconds, and its hardware address can change in
    /// between. With no kernel filter in front, the first frame sent from the new address has
    /// the address read again and is read as sent.
    func testTheFirstFrameFromANewHardwareAddressOpensItsFlow() {
        let mac = OSAllocatedUnfairLock(initialState: Self.first)
        let capture = Fed(linkType: PacketCapture.linkEthernet)
        let (sniffer, events) = ethernetSniffer(capture, mac: mac, interfaceCheckEvery: 60)
        defer { sniffer.stop() }
        sniffer.start()
        capture.feed([Self.syn(from: Self.first, port: 50002)])
        XCTAssertTrue(eventually { events.withLock { $0 } == [Self.opened(50002)] })

        mac.withLock { $0 = Self.rotated }
        capture.feed([Self.syn(from: Self.rotated, port: 50004)])
        XCTAssertTrue(eventually { events.withLock { $0 }.count >= 2 })
        XCTAssertEqual(events.withLock { $0 }, [Self.opened(50002), Self.opened(50004)])
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
