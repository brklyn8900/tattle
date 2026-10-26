import XCTest
@testable import tattle

/// The parsers moved from the spike (ADR-0001), checked against published fixtures:
/// RFC 9001 Appendix A.2's client Initial, whose ClientHello names example.com.
final class SnifferParserTests: XCTestCase {
    /// The protected Initial packet from RFC 9001 A.2, 1200 bytes.
    static let rfcInitial: [UInt8] = hex([
        "c000000001088394c8f03e5157080000449e7b9aec34d1b1c98dd7689fb8ec11d242b123dc9bd8bab936b47d92ec356c",
        "0bab7df5976d27cd449f63300099f3991c260ec4c60d17b31f8429157bb35a1282a643a8d2262cad67500cadb8e7378c",
        "8eb7539ec4d4905fed1bee1fc8aafba17c750e2c7ace01e6005f80fcb7df621230c83711b39343fa028cea7f7fb5ff89",
        "eac2308249a02252155e2347b63d58c5457afd84d05dfffdb20392844ae812154682e9cf012f9021a6f0be17ddd0c208",
        "4dce25ff9b06cde535d0f920a2db1bf362c23e596d11a4f5a6cf3948838a3aec4e15daf8500a6ef69ec4e3feb6b1d98e",
        "610ac8b7ec3faf6ad760b7bad1db4ba3485e8a94dc250ae3fdb41ed15fb6a8e5eba0fc3dd60bc8e30c5c4287e53805db",
        "059ae0648db2f64264ed5e39be2e20d82df566da8dd5998ccabdae053060ae6c7b4378e846d29f37ed7b4ea9ec5d82e7",
        "961b7f25a9323851f681d582363aa5f89937f5a67258bf63ad6f1a0b1d96dbd4faddfcefc5266ba6611722395c906556",
        "be52afe3f565636ad1b17d508b73d8743eeb524be22b3dcbc2c7468d54119c7468449a13d8e3b95811a198f3491de3e7",
        "fe942b330407abf82a4ed7c1b311663ac69890f4157015853d91e923037c227a33cdd5ec281ca3f79c44546b9d90ca00",
        "f064c99e3dd97911d39fe9c5d0b23a229a234cb36186c4819e8b9c5927726632291d6a418211cc2962e20fe47feb3edf",
        "330f2c603a9d48c0fcb5699dbfe5896425c5bac4aee82e57a85aaf4e2513e4f05796b07ba2ee47d80506f8d2c25e50fd",
        "14de71e6c418559302f939b0e1abd576f279c4b2e0feb85c1f28ff18f58891ffef132eef2fa09346aee33c28eb130ff2",
        "8f5b766953334113211996d20011a198e3fc433f9f2541010ae17c1bf202580f6047472fb36857fe843b19f5984009dd",
        "c324044e847a4f4a0ab34f719595de37252d6235365e9b84392b061085349d73203a4a13e96f5432ec0fd4a1ee65accd",
        "d5e3904df54c1da510b0ff20dcc0c77fcb2c0e0eb605cb0504db87632cf3d8b4dae6e705769d1de354270123cb11450e",
        "fc60ac47683d7b8d0f811365565fd98c4c8eb936bcab8d069fc33bd801b03adea2e1fbc5aa463d08ca19896d2bf59a07",
        "1b851e6c239052172f296bfb5e72404790a2181014f3b94a4e97d117b438130368cc39dbb2d198065ae3986547926cd2",
        "162f40a29f0c3c8745c0f50fba3852e566d44575c29d39a03f0cda721984b6f440591f355e12d439ff150aab7613499d",
        "bd49adabc8676eef023b15b65bfc5ca06948109f23f350db82123535eb8a7433bdabcb909271a6ecbcb58b936a88cd4e",
        "8f2e6ff5800175f113253d8fa9ca8885c2f552e657dc603f252e1a8e308f76f0be79e2fb8f5d5fbbe2e30ecadd220723",
        "c8c0aea8078cdfcb3868263ff8f0940054da48781893a7e49ad5aff4af300cd804a6b6279ab3ff3afb64491c85194aab",
        "760d58a606654f9f4400e8b38591356fbf6425aca26dc85244259ff2b19c41b9f96f3ca9ec1dde434da7d2d392b905dd",
        "f3d1f9af93d1af5950bd493f5aa731b4056df31bd267b6b90a079831aaf579be0a39013137aac6d404f518cfd4684064",
        "7e78bfe706ca4cf5e9c5453e9f7cfd2b8b4c8d169a44e55c88d4a9a7f9474241e221af44860018ab0856972e194cd934",
    ].joined())

    /// The CRYPTO frame it carries: frame header, then a 241-byte ClientHello.
    static let rfcCryptoFrame: [UInt8] = hex([
        "060040f1010000ed0303ebf8fa56f12939b9584a3896472ec40bb863cfd3e86804fe3a47f06a2b69484c000004130113",
        "02010000c000000010000e00000b6578616d706c652e636f6dff01000100000a00080006001d00170018001000070005",
        "04616c706e000500050100000000003300260024001d00209370b2c9caa47fbabaf4559fedba753de171fa71f50f1ce1",
        "5d43e994ec74d748002b0003020304000d0010000e0403050306030203080408050806002d00020101001c0002400100",
        "3900320408ffffffffffffffff05048000ffff07048000ffff0801100104800075300901100f088394c8f03e51570806",
        "048000ffff",
    ].joined())

    static var rfcClientHello: [UInt8] { Array(rfcCryptoFrame.dropFirst(4)) }

    static func hex(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            out.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    // MARK: QUIC

    func testRFC9001ClientInitialDecryptsToClientHello() throws {
        XCTAssertTrue(QUIC.mayBeClientInitial(Self.rfcInitial))
        guard case .success(let initial) = QUIC.parseInitial(Self.rfcInitial, at: 0) else {
            return XCTFail("the published Initial did not decrypt")
        }
        XCTAssertEqual(initial.nextOffset, 1200, "one packet fills the datagram")
        XCTAssertEqual(initial.chunks.count, 1)
        XCTAssertEqual(initial.chunks[0].offset, 0)
        XCTAssertEqual(initial.chunks[0].data, Self.rfcClientHello)

        var assembly = QUICAssembly()
        assembly.add(initial.chunks)
        guard case .hello(let sni) = TLS.clientHello(assembly.stream) else { return XCTFail("not a ClientHello") }
        XCTAssertEqual(sni, "example.com")
    }

    func testQUICFailures() {
        var wrongVersion = Self.rfcInitial
        wrongVersion[4] = 2
        guard case .failure(.unsupportedVersion) = QUIC.parseInitial(wrongVersion, at: 0) else { return XCTFail() }

        var corrupted = Self.rfcInitial
        corrupted[600] ^= 0xff
        guard case .failure(.decryptFailed) = QUIC.parseInitial(corrupted, at: 0) else { return XCTFail("a flipped byte must fail authentication") }

        let truncated = Array(Self.rfcInitial.prefix(100))
        guard case .failure(.malformed) = QUIC.parseInitial(truncated, at: 0) else { return XCTFail() }

        var shortHeader = Self.rfcInitial
        shortHeader[0] = 0x40
        XCTAssertFalse(QUIC.mayBeClientInitial(shortHeader))
        guard case .failure(.notInitial) = QUIC.parseInitial(shortHeader, at: 0) else { return XCTFail() }
    }

    func testQUICAssemblyOrdersChunksAndIgnoresDuplicates() {
        var assembly = QUICAssembly()
        assembly.add([QUIC.Chunk(offset: 3, data: [3, 4, 5])])
        XCTAssertEqual(assembly.stream, [], "nothing contiguous from zero yet")
        assembly.add([QUIC.Chunk(offset: 0, data: [0, 1, 2]), QUIC.Chunk(offset: 0, data: [9, 9, 9])])
        XCTAssertEqual(assembly.stream, [0, 1, 2, 3, 4, 5])
    }

    // MARK: TLS over TCP

    private func record(_ handshake: ArraySlice<UInt8>) -> [UInt8] {
        [0x16, 0x03, 0x01, UInt8(handshake.count >> 8), UInt8(handshake.count & 0xff)] + handshake
    }

    func testClientHelloSplitAcrossTwoSegments() {
        let stream = record(Self.rfcClientHello[...])
        let first = Array(stream.prefix(100))
        let second = Array(stream.dropFirst(100))

        guard case .needMore = TLS.clientHelloFromRecords(first) else { return XCTFail("a partial record needs more") }
        guard case .hello(let sni) = TLS.clientHelloFromRecords(first + second) else { return XCTFail() }
        XCTAssertEqual(sni, "example.com")
    }

    func testClientHelloSplitAcrossTwoRecords() {
        // Some clients fragment the handshake message over several records.
        let hello = Self.rfcClientHello
        let stream = record(hello[..<50]) + record(hello[50...])
        guard case .hello(let sni) = TLS.clientHelloFromRecords(stream) else { return XCTFail() }
        XCTAssertEqual(sni, "example.com")
    }

    func testNotTLS() {
        guard case .notClientHello = TLS.clientHelloFromRecords(Array("GET / HTTP/1.1\r\n".utf8)) else { return XCTFail() }
        guard case .needMore = TLS.clientHelloFromRecords([]) else { return XCTFail() }
        // A ServerHello-shaped handshake message is not a ClientHello.
        guard case .notClientHello = TLS.clientHello([2, 0, 0, 0]) else { return XCTFail() }
    }

    func testHTTPHost() {
        XCTAssertEqual(HTTP.host(Array("GET /x HTTP/1.1\r\nHost: example.org\r\nAccept: */*\r\n\r\n".utf8)[...]), "example.org")
        XCTAssertEqual(HTTP.host(Array("POST / HTTP/1.1\r\nhost:  api.example.org:8080 \r\n\r\n".utf8)[...]), "api.example.org:8080")
        XCTAssertNil(HTTP.host(Array("GET / HTTP/1.1\r\n\r\nHost: late.example\r\n".utf8)[...]), "headers end at the blank line")
        XCTAssertNil(HTTP.host(Array("SSH-2.0-OpenSSH\r\n".utf8)[...]))
    }

    // MARK: DNS

    /// A reply for www.example.com: a CNAME to example.com, then its A record, with the
    /// answer names as RFC 1035 pointers back into the question.
    private static let compressedReply: [UInt8] = [
        0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00,
        3, 0x77, 0x77, 0x77, 7, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 3, 0x63, 0x6f, 0x6d, 0,
        0x00, 0x01, 0x00, 0x01,
        0xc0, 0x0c, 0x00, 0x05, 0x00, 0x01, 0x00, 0x00, 0x0e, 0x10, 0x00, 0x02, 0xc0, 0x10,
        0xc0, 0x10, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3c, 0x00, 0x04, 93, 184, 216, 34,
    ]

    func testDNSReplyWithCompression() {
        let reply = DNS.parseReply(Self.compressedReply[...])
        XCTAssertEqual(reply?.name, "www.example.com", "the name the application asked for")
        XCTAssertEqual(reply?.addresses.map(\.text), ["93.184.216.34"])
    }

    func testDNSReplyWithAAAA() {
        var bytes = Self.compressedReply
        bytes[7] = 1  // one answer
        bytes.removeSubrange(33..<47)  // drop the CNAME
        bytes[bytes.count - 13] = 28  // type AAAA
        bytes[bytes.count - 5] = 16
        bytes.removeLast(4)
        bytes += [0x26, 0x06, 0x28, 0x00, 0x02, 0x20, 0x00, 0x01, 0x02, 0x48, 0x18, 0x93, 0x25, 0xc8, 0x19, 0x46]
        XCTAssertEqual(DNS.parseReply(bytes[...])?.addresses.map(\.text), ["2606:2800:220:1:248:1893:25c8:1946"])
    }

    func testDNSIgnoresQueriesAndPointerLoops() {
        var query = Self.compressedReply
        query[2] = 0x01  // QR bit clear
        XCTAssertNil(DNS.parseReply(query[...]))

        var loop = Self.compressedReply
        loop[12] = 0xc0
        loop[13] = 0x0c  // the question name points at itself
        XCTAssertNil(DNS.parseReply(loop[...]))
    }

    // MARK: Packets

    func testParsesIPv4UDPOverEthernet() {
        let payload: [UInt8] = [0xc0, 1, 2, 3]
        let udp: [UInt8] = [0xd4, 0x31, 0x01, 0xbb, 0x00, UInt8(8 + payload.count), 0, 0] + payload
        let total = 20 + udp.count
        let ip: [UInt8] = [0x45, 0, UInt8(total >> 8), UInt8(total & 0xff), 0, 0, 0x40, 0, 64, 17, 0, 0,
                           192, 168, 1, 5, 17, 253, 144, 10] + udp
        let frame = [UInt8](repeating: 0xaa, count: 12) + [0x08, 0x00] + ip
        let packet = Packet.parse(frame, dlt: PacketCapture.linkEthernet)
        XCTAssertEqual(packet?.proto, .udp)
        XCTAssertEqual(packet?.src.text, "192.168.1.5")
        XCTAssertEqual(packet?.dst.text, "17.253.144.10")
        XCTAssertEqual(packet?.srcPort, 54321)
        XCTAssertEqual(packet?.dstPort, 443)
        XCTAssertEqual(packet.map { Array($0.payload) }, payload)
        XCTAssertNil(Packet.parse(frame, dlt: 99), "unknown link type")
    }

    /// A capture cut at the snap length keeps the header's lengths: the payload is what was
    /// captured, and the rest is counted, so a stream position stays right.
    func testCountsPayloadCutOffByTheSnapLength() {
        let tcp: [UInt8] = [0xd4, 0x31, 0x01, 0xbb, 0, 0, 0, 1, 0, 0, 0, 0, 0x50, 0x18, 0xff, 0xff, 0, 0, 0, 0]
        let captured = [UInt8](repeating: 0x16, count: 100)
        let total = 20 + tcp.count + 3000
        let ip: [UInt8] = [0x45, 0, UInt8(total >> 8), UInt8(total & 0xff), 0, 0, 0x40, 0, 64, 6, 0, 0,
                           192, 168, 1, 5, 17, 253, 144, 10] + tcp + captured
        let packet = Packet.parse([UInt8](repeating: 0xaa, count: 12) + [0x08, 0x00] + ip, dlt: PacketCapture.linkEthernet)
        XCTAssertEqual(packet?.payload.count, 100)
        XCTAssertEqual(packet?.uncaptured, 2900)

        var v6: [UInt8] = [0x60, 0, 0, 0, UInt8((tcp.count + 3000) >> 8), UInt8((tcp.count + 3000) & 0xff), 6, 64]
        v6 += [UInt8](repeating: 0x20, count: 32)
        XCTAssertEqual(Packet.parse([30, 0, 0, 0] + v6 + tcp + captured, dlt: PacketCapture.linkNull)?.uncaptured, 2900)
    }

    func testParsesIPv6TCPOverNullLink() {
        let tcp: [UInt8] = [0xd4, 0x31, 0x01, 0xbb, 0, 0, 0, 1, 0, 0, 0, 0, 0x50, 0x02, 0xff, 0xff, 0, 0, 0, 0]
        var ip: [UInt8] = [0x60, 0, 0, 0, 0, UInt8(tcp.count), 6, 64]
        ip += [0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 11) + [1]
        ip += [0x26, 0x06, 0x47, 0x00] + [UInt8](repeating: 0, count: 10) + [0x11, 0x11]
        let frame: [UInt8] = [30, 0, 0, 0] + ip + tcp
        let packet = Packet.parse(frame, dlt: PacketCapture.linkNull)
        XCTAssertEqual(packet?.proto, .tcp)
        XCTAssertEqual(packet?.src.text, "2001:db8::1")
        XCTAssertEqual(packet?.dst.text, "2606:4700::1111")
        XCTAssertEqual(packet?.tcpFlags, 0x02)
        XCTAssertEqual(packet?.tcpSeq, 1)
        XCTAssertEqual(packet?.payload.count, 0)
    }

    func testLocalScope() {
        XCTAssertTrue(IPAddress(bytes: [10, 0, 0, 1]).isLocalScope)
        XCTAssertTrue(IPAddress(bytes: [224, 0, 0, 251]).isLocalScope)
        XCTAssertFalse(IPAddress(bytes: [17, 253, 144, 10]).isLocalScope)
        XCTAssertTrue(IPAddress(bytes: [0xfe, 0x80] + [UInt8](repeating: 0, count: 13) + [1]).isLocalScope)
        XCTAssertTrue(IPAddress(bytes: [UInt8](repeating: 0, count: 15) + [1]).isLocalScope)
        XCTAssertFalse(IPAddress(bytes: [0x26, 0x06] + [UInt8](repeating: 0, count: 14)).isLocalScope)
    }
}
