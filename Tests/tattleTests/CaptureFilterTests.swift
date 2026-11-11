import XCTest
@testable import tattle

final class CaptureFilterTests: XCTestCase {
    private let mac: [UInt8] = [0xa4, 0x83, 0xe7, 0x11, 0x22, 0x33]
    private let otherMac: [UInt8] = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55]
    private let myV4: [UInt8] = [192, 168, 1, 5]
    private let peerV4: [UInt8] = [17, 253, 144, 10]
    private let myV6: [UInt8] = [0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 11) + [1]
    private let peerV6: [UInt8] = [0x26, 0x06, 0x47, 0x00] + [UInt8](repeating: 0, count: 10) + [0x11, 0x11]

    // MARK: Packet builders

    private func tcp(flags: UInt8, payload: Int) -> [UInt8] {
        [0xd4, 0x31, 0x01, 0xbb, 0, 0, 0, 1, 0, 0, 0, 0, 0x50, flags, 0xff, 0xff, 0, 0, 0, 0]
            + [UInt8](repeating: 0x16, count: payload)
    }

    private func udp(sourcePort: UInt16, destinationPort: UInt16, payload: [UInt8]) -> [UInt8] {
        [UInt8(sourcePort >> 8), UInt8(sourcePort & 0xff), UInt8(destinationPort >> 8), UInt8(destinationPort & 0xff),
         UInt8((8 + payload.count) >> 8), UInt8((8 + payload.count) & 0xff), 0, 0] + payload
    }

    private func ipv4(from src: [UInt8], to dst: [UInt8], proto: UInt8, _ transport: [UInt8], fragmentOffset: UInt16 = 0) -> [UInt8] {
        let total = 20 + transport.count
        return [0x45, 0, UInt8(total >> 8), UInt8(total & 0xff), 0, 0, UInt8(fragmentOffset >> 8), UInt8(fragmentOffset & 0xff),
                64, proto, 0, 0] + src + dst + transport
    }

    private func ipv6(from src: [UInt8], to dst: [UInt8], proto: UInt8, _ transport: [UInt8]) -> [UInt8] {
        [0x60, 0, 0, 0, UInt8(transport.count >> 8), UInt8(transport.count & 0xff), proto, 64] + src + dst + transport
    }

    private func ethernet(from src: [UInt8], _ ip: [UInt8]) -> [UInt8] {
        let type: [UInt8] = ip[0] >> 4 == 6 ? [0x86, 0xdd] : [0x08, 0x00]
        return otherMac + src + type + ip
    }

    private func nullLink(_ ip: [UInt8]) -> [UInt8] {
        (ip[0] >> 4 == 6 ? [30, 0, 0, 0] : [2, 0, 0, 0]) + ip
    }

    // MARK: Programs

    func testProgramsAreValidForEachLinkType() throws {
        let ethernet = try XCTUnwrap(CaptureFilter.program(linkType: PacketCapture.linkEthernet, direction: .hardwareAddress(mac)))
        XCTAssertTrue(ethernet.isValid)
        let null = try XCTUnwrap(CaptureFilter.program(linkType: PacketCapture.linkNull, direction: .sourceAddresses([myV4, myV6])))
        XCTAssertTrue(null.isValid)
        let raw = try XCTUnwrap(CaptureFilter.program(linkType: PacketCapture.linkRaw, direction: .sourceAddresses([])))
        XCTAssertTrue(raw.isValid)
        XCTAssertNil(CaptureFilter.program(linkType: 9, direction: .sourceAddresses([myV4])), "unknown link layout")
        XCTAssertNil(CaptureFilter.program(linkType: PacketCapture.linkNull, direction: .hardwareAddress(mac)), "a tunnel has no hardware address")
        XCTAssertNil(CaptureFilter.program(linkType: PacketCapture.linkEthernet, direction: .hardwareAddress([1, 2, 3])))
    }

    func testValidatorRejectsBrokenPrograms() {
        XCTAssertFalse(CaptureFilter(instructions: []).isValid)
        XCTAssertFalse(CaptureFilter(instructions: [.init(code: 0x28, jt: 0, jf: 0, k: 12)]).isValid, "must end in a return")
        XCTAssertFalse(CaptureFilter(instructions: [.init(code: 0x15, jt: 5, jf: 0, k: 0), .init(code: 0x06, jt: 0, jf: 0, k: 0)]).isValid, "jump past the end")
        XCTAssertFalse(CaptureFilter(instructions: [.init(code: 0x02, jt: 0, jf: 0, k: 16), .init(code: 0x06, jt: 0, jf: 0, k: 0)]).isValid, "memory slot out of range")
    }

    /// A client Initial's first bytes, padded to the 1200 a client sends at least.
    private let initial: [UInt8] = [0xc3, 0, 0, 0, 1] + [UInt8](repeating: 0, count: 1195)

    func testEthernetFilterKeepsHandshakesAndDNSAndDropsTheRest() throws {
        let filter = try XCTUnwrap(CaptureFilter.program(linkType: PacketCapture.linkEthernet, direction: .hardwareAddress(mac)))
        func run(_ frame: [UInt8]) -> UInt32 { Interpreter.run(filter, on: frame) }
        let snap = CaptureFilter.snapLength

        // Outbound TCP: SYN kept, pure ACK dropped, ACK with payload kept, both families.
        XCTAssertEqual(run(ethernet(from: mac, ipv4(from: myV4, to: peerV4, proto: 6, tcp(flags: 0x02, payload: 0)))), snap)
        XCTAssertEqual(run(ethernet(from: mac, ipv4(from: myV4, to: peerV4, proto: 6, tcp(flags: 0x10, payload: 0)))), 0)
        XCTAssertEqual(run(ethernet(from: mac, ipv4(from: myV4, to: peerV4, proto: 6, tcp(flags: 0x18, payload: 200)))), snap)
        XCTAssertEqual(run(ethernet(from: mac, ipv6(from: myV6, to: peerV6, proto: 6, tcp(flags: 0x02, payload: 0)))), snap)
        XCTAssertEqual(run(ethernet(from: mac, ipv6(from: myV6, to: peerV6, proto: 6, tcp(flags: 0x10, payload: 0)))), 0)
        XCTAssertEqual(run(ethernet(from: mac, ipv6(from: myV6, to: peerV6, proto: 6, tcp(flags: 0x18, payload: 1)))), snap)

        // Inbound TCP, the download case: dropped whatever it carries.
        XCTAssertEqual(run(ethernet(from: otherMac, ipv4(from: peerV4, to: myV4, proto: 6, tcp(flags: 0x18, payload: 1400)))), 0)
        XCTAssertEqual(run(ethernet(from: otherMac, ipv4(from: peerV4, to: myV4, proto: 6, tcp(flags: 0x12, payload: 0)))), 0)
        XCTAssertEqual(run(ethernet(from: otherMac, ipv6(from: peerV6, to: myV6, proto: 6, tcp(flags: 0x18, payload: 1400)))), 0)

        // Outbound UDP: a client Initial kept, short header and other UDP dropped.
        XCTAssertEqual(run(ethernet(from: mac, ipv4(from: myV4, to: peerV4, proto: 17, udp(sourcePort: 50000, destinationPort: 443, payload: initial)))), snap)
        XCTAssertEqual(run(ethernet(from: mac, ipv4(from: myV4, to: peerV4, proto: 17, udp(sourcePort: 50000, destinationPort: 443, payload: [0x41, 1, 2, 3])))), 0)
        XCTAssertEqual(run(ethernet(from: mac, ipv4(from: myV4, to: peerV4, proto: 17, udp(sourcePort: 50000, destinationPort: 53, payload: [0x12, 0x34, 0x01, 0x00])))), 0, "a DNS query is not needed")
        XCTAssertEqual(run(ethernet(from: mac, ipv6(from: myV6, to: peerV6, proto: 17, udp(sourcePort: 50000, destinationPort: 443, payload: initial)))), snap)
        // Only a client Initial: long header with the fixed bit, at least 1200 bytes, not to DNS.
        var rtp = initial
        rtp[0] = 0x80
        for family in [4, 6] {
            func out(_ port: UInt16, _ payload: [UInt8]) -> UInt32 {
                let datagram = udp(sourcePort: 50000, destinationPort: port, payload: payload)
                return run(ethernet(from: mac, family == 4 ? ipv4(from: myV4, to: peerV4, proto: 17, datagram) : ipv6(from: myV6, to: peerV6, proto: 17, datagram)))
            }
            XCTAssertEqual(out(5004, rtp), 0, "RTP, IPv\(family)")
            XCTAssertEqual(out(443, Array(initial.prefix(1199))), 0, "too small for a client Initial, IPv\(family)")
            XCTAssertEqual(out(53, initial), 0, "a DNS query, IPv\(family)")
        }

        // Inbound UDP: only replies from port 53.
        XCTAssertEqual(run(ethernet(from: otherMac, ipv4(from: peerV4, to: myV4, proto: 17, udp(sourcePort: 53, destinationPort: 50000, payload: [0x12, 0x34, 0x81, 0x80])))), snap)
        XCTAssertEqual(run(ethernet(from: otherMac, ipv4(from: peerV4, to: myV4, proto: 17, udp(sourcePort: 443, destinationPort: 50000, payload: [0xc3, 0, 0, 0, 1])))), 0, "a server's QUIC Initial is not needed")
        XCTAssertEqual(run(ethernet(from: otherMac, ipv6(from: peerV6, to: myV6, proto: 17, udp(sourcePort: 53, destinationPort: 50000, payload: [0x12, 0x34, 0x81, 0x80])))), snap)

        // Not IP, or a later fragment: dropped.
        XCTAssertEqual(run(otherMac + mac + [0x08, 0x06] + [UInt8](repeating: 0, count: 28)), 0, "ARP")
        XCTAssertEqual(run(ethernet(from: mac, ipv4(from: myV4, to: peerV4, proto: 6, tcp(flags: 0x18, payload: 100), fragmentOffset: 0x0010))), 0)
        XCTAssertEqual(run(ethernet(from: mac, ipv4(from: myV4, to: peerV4, proto: 1, [8, 0, 0, 0, 0, 0, 0, 0]))), 0, "ICMP")
    }

    func testNullLinkFilterTellsDirectionFromAddresses() throws {
        let filter = try XCTUnwrap(CaptureFilter.program(linkType: PacketCapture.linkNull, direction: .sourceAddresses([myV4, myV6])))
        func run(_ frame: [UInt8]) -> UInt32 { Interpreter.run(filter, on: frame) }
        let snap = CaptureFilter.snapLength

        XCTAssertEqual(run(nullLink(ipv4(from: myV4, to: peerV4, proto: 6, tcp(flags: 0x02, payload: 0)))), snap)
        XCTAssertEqual(run(nullLink(ipv4(from: peerV4, to: myV4, proto: 6, tcp(flags: 0x18, payload: 1400)))), 0, "inbound payload dropped")
        XCTAssertEqual(run(nullLink(ipv4(from: peerV4, to: myV4, proto: 17, udp(sourcePort: 53, destinationPort: 5000, payload: [1, 2, 3, 4])))), snap)
        XCTAssertEqual(run(nullLink(ipv6(from: myV6, to: peerV6, proto: 17, udp(sourcePort: 5000, destinationPort: 443, payload: initial)))), snap)
        XCTAssertEqual(run(nullLink(ipv6(from: peerV6, to: myV6, proto: 6, tcp(flags: 0x18, payload: 1400)))), 0)
        // Another address of ours that the filter was not told about looks inbound: dropped.
        XCTAssertEqual(run(nullLink(ipv4(from: [10, 0, 0, 9], to: peerV4, proto: 6, tcp(flags: 0x02, payload: 0)))), 0)
    }

    /// A full-tunnel VPN puts the capture on a link without a hardware address, so direction
    /// comes from addresses. Too many of them push the early jumps past BPF's 255-instruction
    /// reach; that must leave the capture unfiltered, not stop the app.
    func testTooManyAddressesGiveNoFilterInsteadOfStoppingTheApp() {
        let many = (0..<40).map { [0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 11) + [UInt8($0)] }
        XCTAssertNil(CaptureFilter.program(linkType: PacketCapture.linkNull, direction: .sourceAddresses(many)))
    }

    /// The direction test gets only the capture interface's own addresses, which keeps the
    /// program short: loopback's never include another interface's.
    func testInterfaceAddressesAreThatInterfacesOnly() {
        let loopback = localAddresses(of: "lo0")
        XCTAssertTrue(loopback.contains(IPAddress(bytes: [127, 0, 0, 1])))
        XCTAssertTrue(loopback.allSatisfy { $0.bytes.count == 4 ? $0.bytes[0] == 127 : $0.isLocalScope })
        XCTAssertTrue(localAddresses(of: "lo0").isSubset(of: localAddresses()))
    }

    /// An IPv6-only network has a default route but no IPv4 one; capture must still start.
    func testPrimaryInterfaceComesFromIPv4ThenIPv6() {
        func store(_ v4: String?, _ v6: String?) -> (String) -> [String: Any]? {
            { key in
                switch key {
                case "State:/Network/Global/IPv4": v4.map { ["PrimaryInterface": $0] }
                case "State:/Network/Global/IPv6": v6.map { ["PrimaryInterface": $0] }
                default: nil
                }
            }
        }
        XCTAssertEqual(PacketCapture.primaryInterface(store: store("en0", "en0")), "en0")
        XCTAssertEqual(PacketCapture.primaryInterface(store: store(nil, "en1")), "en1", "IPv6-only")
        XCTAssertEqual(PacketCapture.primaryInterface(store: store("en0", "utun3")), "en0", "IPv4 first, as before")
        XCTAssertNil(PacketCapture.primaryInterface(store: store(nil, nil)))
    }

    func testKernelAcceptsTheProgram() throws {
        try XCTSkipUnless(access("/dev/bpf0", R_OK) == 0, "needs readable /dev/bpf*")
        let interface = try XCTUnwrap(PacketCapture.primaryInterface())
        let capture = try PacketCapture.open(interface: interface)
        let direction: CaptureFilter.Direction
        if let mac = PacketCapture.hardwareAddress(of: interface), capture.dataLinkType == PacketCapture.linkEthernet {
            direction = .hardwareAddress(mac)
        } else {
            // The interface's own, sorted, as the sniffer builds it.
            direction = .sourceAddresses(localAddresses(of: interface).map(\.bytes).sorted { $0.lexicographicallyPrecedes($1) })
        }
        let filter = try XCTUnwrap(CaptureFilter.program(linkType: capture.dataLinkType, direction: direction))
        XCTAssertNoThrow(try capture.install(filter))
        XCTAssertThrowsError(try capture.install(CaptureFilter(instructions: [.init(code: 0x15, jt: 9, jf: 9, k: 0), .init(code: 0x06, jt: 0, jf: 0, k: 0)])))
    }

    /// Runs a program over a packet the way the kernel does, for the opcodes the
    /// builder emits. Returns the accepted length.
    private enum Interpreter {
        static func run(_ filter: CaptureFilter, on packet: [UInt8]) -> UInt32 {
            var a: UInt32 = 0, x: UInt32 = 0
            var memory = [UInt32](repeating: 0, count: 16)
            var pc = 0
            func load(_ offset: UInt32, _ size: Int) -> UInt32? {
                let start = Int(offset)
                guard start >= 0, start + size <= packet.count else { return nil }
                return packet[start..<(start + size)].reduce(0) { $0 << 8 | UInt32($1) }
            }
            while pc < filter.instructions.count {
                let i = filter.instructions[pc]
                pc += 1
                let cls = i.code & 0x07
                switch cls {
                case 0x00, 0x01:  // LD, LDX
                    let size = i.code & 0x18 == 0x10 ? 1 : i.code & 0x18 == 0x08 ? 2 : 4
                    let value: UInt32?
                    switch i.code & 0xe0 {
                    case 0x20: value = load(i.k, size)
                    case 0x40: value = load(x &+ i.k, size)
                    case 0x60: value = memory[Int(i.k)]
                    case 0xa0: value = load(i.k, 1).map { ($0 & 0x0f) * 4 }
                    case 0x00: value = i.k
                    default: return 0
                    }
                    guard let value else { return 0 }
                    if cls == 0x00 { a = value } else { x = value }
                case 0x02: memory[Int(i.k)] = a
                case 0x03: memory[Int(i.k)] = x
                case 0x04:
                    let operand = i.code & 0x08 != 0 ? x : i.k
                    switch i.code & 0xf0 {
                    case 0x10: a = a &- operand
                    case 0x50: a &= operand
                    case 0x60: a <<= operand
                    case 0x70: a >>= operand
                    default: return 0
                    }
                case 0x05:
                    let operand = i.code & 0x08 != 0 ? x : i.k
                    let taken: Bool
                    switch i.code & 0xf0 {
                    case 0x00: pc += Int(i.k); continue
                    case 0x10: taken = a == operand
                    case 0x20: taken = a > operand
                    case 0x40: taken = a & operand != 0
                    default: return 0
                    }
                    pc += Int(taken ? i.jt : i.jf)
                case 0x06: return i.code & 0x10 != 0 ? a : i.k
                case 0x07: if i.code & 0x80 == 0 { x = a } else { a = x }
                default: return 0
                }
            }
            return 0
        }
    }
}
