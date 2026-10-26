import XCTest
@testable import tattle

final class FlowNamerTests: XCTestCase {
    private let me = IPAddress(bytes: [192, 168, 1, 5])
    private let peer = IPAddress(bytes: [17, 253, 144, 10])
    private let resolver = IPAddress(bytes: [192, 168, 1, 1])
    private let t0 = 1_700_000_000.0

    private func namer() -> FlowNamer { FlowNamer(localAddresses: [me]) }

    private func tcp(from src: IPAddress? = nil, to dst: IPAddress? = nil, port: UInt16 = 443, flags: UInt8, seq: UInt32, _ payload: [UInt8] = []) -> Packet {
        Packet(src: src ?? me, dst: dst ?? peer, srcPort: 50000, dstPort: port, proto: .tcp, tcpFlags: flags, tcpSeq: seq, payload: payload[...])
    }

    private func udp(from src: IPAddress? = nil, to dst: IPAddress? = nil, srcPort: UInt16 = 50000, dstPort: UInt16 = 443, _ payload: [UInt8]) -> Packet {
        Packet(src: src ?? me, dst: dst ?? peer, srcPort: srcPort, dstPort: dstPort, proto: .udp, tcpFlags: 0, tcpSeq: 0, payload: payload[...])
    }

    private var tcpKey: FlowKey { FlowKey(proto: .tcp, localPort: 50000, remote: peer, remotePort: 443) }
    private var udpKey: FlowKey { FlowKey(proto: .udp, localPort: 50000, remote: peer, remotePort: 443) }

    private var clientHelloRecord: [UInt8] {
        let hello = SnifferParserTests.rfcClientHello
        return [0x16, 0x03, 0x01, UInt8(hello.count >> 8), UInt8(hello.count & 0xff)] + hello
    }

    private var dnsReply: Packet {
        var bytes: [UInt8] = [0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
        bytes += [3, 0x63, 0x64, 0x6e, 7, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 3, 0x6e, 0x65, 0x74, 0, 0x00, 0x01, 0x00, 0x01]
        bytes += [0xc0, 0x0c, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3c, 0x00, 0x04] + peer.bytes
        return udp(from: resolver, to: me, srcPort: 53, dstPort: 60000, bytes)
    }

    func testTCPHandshakeOverTwoSegmentsNamesTheFlow() {
        var n = namer()
        XCTAssertEqual(n.observe(tcp(flags: 0x02, seq: 1000), at: t0), [FlowEvent(key: tcpKey, kind: .opened)])
        let record = clientHelloRecord
        let first = Array(record.prefix(90)), second = Array(record.dropFirst(90))
        XCTAssertEqual(n.observe(tcp(flags: 0x18, seq: 1001, first), at: t0 + 0.01), [])
        XCTAssertEqual(n.observe(tcp(flags: 0x18, seq: 1001, first), at: t0 + 0.02), [], "a retransmit is dropped")
        XCTAssertEqual(n.observe(tcp(flags: 0x18, seq: 1001 + UInt32(first.count), second), at: t0 + 0.03),
                       [FlowEvent(key: tcpKey, kind: .named("example.com", .sni))])
        XCTAssertEqual(n.observe(tcp(flags: 0x18, seq: 5000, [1, 2, 3]), at: t0 + 1), [], "a named flow emits nothing more")
        XCTAssertEqual(n.expire(now: t0 + 10), [], "no DNS fallback once the wire named it")
    }

    func testGapEndsBufferingAndSegmentsWithoutASYNAreIgnored() {
        var n = namer()
        XCTAssertEqual(n.observe(tcp(flags: 0x18, seq: 7, clientHelloRecord), at: t0), [], "no SYN seen: not a flow Tattle watches")
        _ = n.observe(tcp(flags: 0x02, seq: 1000), at: t0)
        let record = clientHelloRecord
        _ = n.observe(tcp(flags: 0x18, seq: 1001, Array(record.prefix(50))), at: t0)
        XCTAssertEqual(n.observe(tcp(flags: 0x18, seq: 1001 + 60, Array(record.dropFirst(60))), at: t0),
                       [FlowEvent(key: tcpKey, kind: .unnamed(.gap))], "a gap: parsing a shifted stream would be wrong")
        XCTAssertEqual(n.observe(tcp(flags: 0x18, seq: 1001 + 50, Array(record.dropFirst(50))), at: t0), [], "buffering ended, even for the missing piece")
    }

    func testNotAHandshakeAndTimeoutAreReported() {
        var n = namer()
        _ = n.observe(tcp(port: 22, flags: 0x02, seq: 1), at: t0)
        let ssh = FlowKey(proto: .tcp, localPort: 50000, remote: peer, remotePort: 22)
        XCTAssertEqual(n.observe(tcp(port: 22, flags: 0x18, seq: 2, Array("SSH-2.0-OpenSSH\r\n".utf8)), at: t0), [FlowEvent(key: ssh, kind: .unnamed(.notHandshake))])
        XCTAssertEqual(n.observe(tcp(port: 22, flags: 0x18, seq: 19, [1, 2, 3]), at: t0 + 1), [], "reported once")

        _ = n.observe(tcp(flags: 0x02, seq: 1), at: t0)
        XCTAssertEqual(n.expire(now: t0 + FlowNamer.finalizeAfter), [FlowEvent(key: tcpKey, kind: .unnamed(.timeout))], "no payload ever came")
        XCTAssertEqual(n.expire(now: t0 + FlowNamer.finalizeAfter + 1), [], "once")
    }

    func testHTTPHostNamesAPlaintextFlow() {
        var n = namer()
        _ = n.observe(tcp(port: 80, flags: 0x02, seq: 1), at: t0)
        let key = FlowKey(proto: .tcp, localPort: 50000, remote: peer, remotePort: 80)
        XCTAssertEqual(n.observe(tcp(port: 80, flags: 0x18, seq: 2, Array("GET / HTTP/1.1\r\nHost: example.org\r\n\r\n".utf8)), at: t0),
                       [FlowEvent(key: key, kind: .named("example.org", .http))])
    }

    func testQUICInitialNamesTheFlow() {
        var n = namer()
        XCTAssertEqual(n.observe(udp(SnifferParserTests.rfcInitial), at: t0),
                       [FlowEvent(key: udpKey, kind: .opened), FlowEvent(key: udpKey, kind: .named("example.com", .quic))])
        XCTAssertEqual(n.observe(udp(SnifferParserTests.rfcInitial), at: t0 + 0.1), [], "same connection, already named")
        XCTAssertEqual(n.flowCount, 1)
    }

    func testShortHeaderDoesNotStartAFlow() {
        var n = namer()
        XCTAssertEqual(n.observe(udp([0x41, 1, 2, 3]), at: t0), [], "a connection open before capture started")
        XCTAssertEqual(n.flowCount, 0)
        var otherVersion = SnifferParserTests.rfcInitial
        otherVersion[4] = 2
        XCTAssertEqual(n.observe(udp(otherVersion), at: t0),
                       [FlowEvent(key: udpKey, kind: .opened), FlowEvent(key: udpKey, kind: .unnamed(.quic(.unsupportedVersion)))], "opened, but unreadable")
    }

    /// Only what can be a client's first QUIC packet starts a flow: long header with the fixed
    /// bit (0xC0), in a datagram of at least 1200 bytes (RFC 9000 14.1), not to DNS. RTP's
    /// first byte (0x80) and a DNS query whose id has the high bit set would otherwise show as
    /// "a QUIC version Tattle cannot read".
    func testOnlyAClientInitialStartsAUDPFlow() {
        var n = namer()
        var rtp = [UInt8](repeating: 0, count: 1300)
        rtp[0] = 0x80
        XCTAssertEqual(n.observe(udp(dstPort: 5004, rtp), at: t0), [], "RTP version 2")
        XCTAssertEqual(n.observe(udp([0xc3, 0, 0, 0, 1] + [UInt8](repeating: 0, count: 95)), at: t0), [], "too small for a client Initial")
        XCTAssertEqual(n.observe(udp(dstPort: 53, SnifferParserTests.rfcInitial), at: t0), [], "a DNS query, whatever its first byte")
        XCTAssertEqual(n.flowCount, 0)
    }

    func testDNSFallbackAfterThreeSecondsOnlyWhenNothingElseNamed() {
        var n = namer()
        XCTAssertEqual(n.observe(dnsReply, at: t0), [], "a reply updates the map and says nothing")
        XCTAssertEqual(n.dnsCount, 1)
        _ = n.observe(tcp(flags: 0x02, seq: 1), at: t0 + 1)
        XCTAssertEqual(n.expire(now: t0 + 3), [], "the wire gets three seconds first")
        XCTAssertEqual(n.expire(now: t0 + 4), [FlowEvent(key: tcpKey, kind: .named("cdn.example.net", .dns))])
        XCTAssertEqual(n.expire(now: t0 + 5), [], "once")
    }

    /// The DNS fallback is a stand-in, not an answer: a handshake that comes after it (late,
    /// as after a wake) names the flow from the wire, and the give-up timeout does not
    /// replace the DNS name with "sent nothing".
    func testAWireNameAfterTheDNSFallbackReplacesIt() {
        var n = namer()
        _ = n.observe(dnsReply, at: t0)
        _ = n.observe(tcp(flags: 0x02, seq: 1000), at: t0 + 1)
        XCTAssertEqual(n.expire(now: t0 + 4.5), [FlowEvent(key: tcpKey, kind: .named("cdn.example.net", .dns))])
        XCTAssertEqual(n.observe(tcp(flags: 0x18, seq: 1001, clientHelloRecord), at: t0 + 6),
                       [FlowEvent(key: tcpKey, kind: .named("example.com", .sni))])
        XCTAssertEqual(n.expire(now: t0 + 1 + FlowNamer.finalizeAfter), [])

        var silent = namer()
        _ = silent.observe(dnsReply, at: t0)
        _ = silent.observe(tcp(flags: 0x02, seq: 1000), at: t0 + 1)
        _ = silent.expire(now: t0 + 4.5)
        XCTAssertEqual(silent.expire(now: t0 + 1 + FlowNamer.finalizeAfter), [], "the DNS name stands")

        var garbage = namer()
        _ = garbage.observe(dnsReply, at: t0)
        _ = garbage.observe(tcp(flags: 0x02, seq: 1000), at: t0 + 1)
        _ = garbage.expire(now: t0 + 4.5)
        XCTAssertEqual(garbage.observe(tcp(flags: 0x18, seq: 1001, [0x53, 0x53, 0x48]), at: t0 + 6), [], "a failure on the wire does not replace the DNS name")
    }

    func testDNSMapIsOnlyConsultedOnceAndForgotten() {
        var n = namer()
        _ = n.observe(tcp(flags: 0x02, seq: 1), at: t0)
        XCTAssertEqual(n.expire(now: t0 + 4), [], "nothing in the map")
        _ = n.observe(dnsReply, at: t0 + 5)
        XCTAssertEqual(n.expire(now: t0 + 6), [], "a reply arriving after the fallback ran does not rename")
        _ = n.expire(now: t0 + 5 + FlowNamer.dnsRemembered)
        XCTAssertEqual(n.dnsCount, 0)
    }

    func testIdleFlowsAreForgottenAndOldOnesGivenUpOn() {
        var n = namer()
        _ = n.observe(tcp(flags: 0x02, seq: 1000), at: t0)
        _ = n.expire(now: t0 + FlowNamer.finalizeAfter)
        XCTAssertEqual(n.observe(tcp(flags: 0x18, seq: 1001, clientHelloRecord), at: t0 + FlowNamer.finalizeAfter), [], "given up: the handshake came too late")
        XCTAssertEqual(n.flowCount, 1)
        _ = n.expire(now: t0 + FlowNamer.finalizeAfter + FlowNamer.idleAfter)
        XCTAssertEqual(n.flowCount, 0)
        XCTAssertEqual(n.observe(tcp(flags: 0x02, seq: 1), at: t0 + 200), [FlowEvent(key: tcpKey, kind: .opened)], "the same addresses again are a new connection")
    }

    func testDirectionAndScope() {
        var n = namer()
        XCTAssertEqual(n.observe(tcp(from: peer, to: me, flags: 0x02, seq: 1), at: t0), [], "inbound SYN: not ours")
        XCTAssertEqual(n.observe(tcp(to: IPAddress(bytes: [192, 168, 1, 20]), flags: 0x02, seq: 1), at: t0), [], "this network needs no public name")
        let newAddress = IPAddress(bytes: [10, 0, 0, 9])
        XCTAssertEqual(n.observe(tcp(from: newAddress, flags: 0x02, seq: 1), at: t0), [], "not known as ours yet")
        XCTAssertTrue(n.endpointsUnknown(tcp(from: newAddress, flags: 0x02, seq: 1)), "to the internet from an address not known as ours: the set is stale")
        XCTAssertTrue(n.endpointsUnknown(tcp(from: IPAddress(bytes: [203, 0, 113, 9]), flags: 0x02, seq: 1)))
        XCTAssertFalse(n.endpointsUnknown(tcp(from: me, flags: 0x02, seq: 1)), "ours")
        XCTAssertFalse(n.endpointsUnknown(tcp(from: peer, to: me, flags: 0x12, seq: 1)), "inbound to us")
        XCTAssertFalse(n.endpointsUnknown(tcp(from: newAddress, to: IPAddress(bytes: [192, 168, 1, 20]), flags: 0x02, seq: 1)), "this network: no public destination to judge by")
        XCTAssertFalse(n.endpointsUnknown(dnsReply))
        n.updateLocalAddresses([newAddress])
        XCTAssertEqual(n.observe(tcp(from: newAddress, flags: 0x02, seq: 1), at: t0).count, 1)
        n.updateLocalAddresses([])
        XCTAssertEqual(n.observe(tcp(from: newAddress, flags: 0x02, seq: 2), at: t0 + 200).count, 1, "an empty reading keeps the old set")
    }

    func testFlowKeyTextMatchesConnectionShape() {
        XCTAssertEqual(tcpKey.text, "tcp/50000>17.253.144.10:443")
        XCTAssertEqual(FlowKey(proto: .udp, localPort: 1, remote: IPAddress(bytes: [0x26, 0x06, 0x47, 0] + [UInt8](repeating: 0, count: 10) + [0x11, 0x11]), remotePort: 443).text,
                       "udp/1>2606:4700::1111:443")
    }
}
