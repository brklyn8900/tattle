import CommonCrypto
import CryptoKit
import Foundation

// Decrypts QUIC v1 Initial packets (RFC 9001 section 5) and returns their CRYPTO frames,
// which carry the TLS ClientHello. The keys derive from the destination connection id in
// the packet itself, so anyone on the path can do this; it is not a weakness, it is how
// QUIC is specified.
enum QUIC {
    enum Failure: String, Error {
        case notInitial
        case unsupportedVersion
        case malformed
        case decryptFailed
    }

    struct Chunk {
        let offset: UInt64
        let data: [UInt8]
    }

    struct Initial {
        /// The destination connection id the keys came from.
        let dcid: [UInt8]
        let chunks: [Chunk]
        let nextOffset: Int
    }

    private static let v1Salt: [UInt8] = [
        0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17,
        0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad, 0xcc, 0xbb, 0x7f, 0x0a,
    ]

    /// A client pads every datagram carrying an Initial to at least this (RFC 9000 14.1).
    static let minimumInitialDatagram = 1200

    /// Whether a client's datagram can hold an Initial: a long header with the fixed bit set
    /// (0xC0), at the size a client must pad it to. RTP (0x80) and most other UDP fail it. In
    /// version 1 the header also says the packet's type, and a 0-RTT or Handshake packet is
    /// not one; another version's types are not read.
    static func mayBeClientInitial(_ datagram: [UInt8]) -> Bool {
        guard datagram.count >= minimumInitialDatagram, datagram[0] & 0xc0 == 0xc0 else { return false }
        return datagram[1...4] != [0, 0, 0, 1] || datagram[0] & 0x30 == 0
    }

    static func parseInitial(_ datagram: [UInt8], at start: Int) -> Result<Initial, Failure> {
        var r = ByteReader(datagram, from: start)
        do {
            let first = try r.u8()
            guard first & 0x80 != 0 else { return .failure(.notInitial) }
            let version = try r.u32()
            guard version == 1 else { return .failure(.unsupportedVersion) }
            guard first & 0x30 == 0 else { return .failure(.notInitial) }
            let dcid = Array(try r.take(Int(try r.u8())))
            _ = try r.take(Int(try r.u8()))  // source connection id
            try r.skip(Int(try r.varint()))  // token
            let length = Int(try r.varint())
            let pnOffset = r.pos - start
            guard pnOffset + length <= datagram.count - start, length >= 20 else {
                return .failure(.malformed)
            }
            var packet = Array(datagram[start..<(start + pnOffset + length)])

            let keys = clientInitialKeys(dcid: dcid)

            // Header protection: the mask comes from AES-ECB of a 16-byte sample taken 4
            // bytes past the start of the packet number field (RFC 9001 section 5.4).
            let sampleStart = pnOffset + 4
            guard sampleStart + 16 <= packet.count else { return .failure(.malformed) }
            let mask = aesECB(key: keys.hp, block: Array(packet[sampleStart..<(sampleStart + 16)]))
            packet[0] ^= mask[0] & 0x0f
            let pnLength = Int(packet[0] & 0x03) + 1
            var packetNumber: UInt64 = 0
            for i in 0..<pnLength {
                packet[pnOffset + i] ^= mask[1 + i]
                packetNumber = packetNumber << 8 | UInt64(packet[pnOffset + i])
            }

            var nonce = keys.iv
            for i in 0..<8 {
                nonce[nonce.count - 1 - i] ^= UInt8((packetNumber >> (8 * UInt64(i))) & 0xff)
            }
            let header = packet[0..<(pnOffset + pnLength)]
            let body = packet[(pnOffset + pnLength)...]
            guard body.count >= 16 else { return .failure(.malformed) }
            let ciphertext = body.dropLast(16)
            let tag = body.suffix(16)
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                            ciphertext: ciphertext, tag: tag)
            let plaintext: Data
            do {
                plaintext = try AES.GCM.open(box, using: keys.key, authenticating: header)
            } catch {
                return .failure(.decryptFailed)
            }
            let chunks = try cryptoFrames(Array(plaintext))
            return .success(Initial(dcid: dcid, chunks: chunks, nextOffset: start + pnOffset + length))
        } catch {
            return .failure(.malformed)
        }
    }

    private struct Keys {
        let key: SymmetricKey
        let iv: [UInt8]
        let hp: [UInt8]
    }

    private static func clientInitialKeys(dcid: [UInt8]) -> Keys {
        let initialSecret = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: dcid), salt: v1Salt)
        let clientSecret = HKDF<SHA256>.expand(pseudoRandomKey: initialSecret,
                                               info: expandLabelInfo("client in", length: 32),
                                               outputByteCount: 32)
        let key = HKDF<SHA256>.expand(pseudoRandomKey: clientSecret,
                                      info: expandLabelInfo("quic key", length: 16), outputByteCount: 16)
        let iv = HKDF<SHA256>.expand(pseudoRandomKey: clientSecret,
                                     info: expandLabelInfo("quic iv", length: 12), outputByteCount: 12)
        let hp = HKDF<SHA256>.expand(pseudoRandomKey: clientSecret,
                                     info: expandLabelInfo("quic hp", length: 16), outputByteCount: 16)
        return Keys(key: key,
                    iv: iv.withUnsafeBytes { Array($0) },
                    hp: hp.withUnsafeBytes { Array($0) })
    }

    // HkdfLabel from RFC 8446 section 7.1 with an empty context.
    private static func expandLabelInfo(_ label: String, length: Int) -> [UInt8] {
        let full = Array("tls13 \(label)".utf8)
        return [UInt8(length >> 8), UInt8(length & 0xff), UInt8(full.count)] + full + [0]
    }

    private static func aesECB(key: [UInt8], block: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                key, key.count, nil, block, 16, &out, 16, &moved)
        return out
    }

    // Walks the frames of a decrypted Initial payload and collects CRYPTO frame data.
    private static func cryptoFrames(_ payload: [UInt8]) throws -> [Chunk] {
        var r = ByteReader(payload)
        var chunks: [Chunk] = []
        while r.remaining > 0 {
            let type = try r.varint()
            switch type {
            case 0x00, 0x01:  // PADDING, PING
                continue
            case 0x02, 0x03:  // ACK
                _ = try r.varint()
                _ = try r.varint()
                let rangeCount = try r.varint()
                _ = try r.varint()
                for _ in 0..<rangeCount {
                    _ = try r.varint()
                    _ = try r.varint()
                }
                if type == 0x03 {
                    for _ in 0..<3 { _ = try r.varint() }
                }
            case 0x06:  // CRYPTO
                let offset = try r.varint()
                let length = Int(try r.varint())
                chunks.append(Chunk(offset: offset, data: Array(try r.take(length))))
            case 0x1c, 0x1d:  // CONNECTION_CLOSE
                _ = try r.varint()
                if type == 0x1c { _ = try r.varint() }
                try r.skip(Int(try r.varint()))
            default:
                return chunks  // nothing else belongs in an Initial; stop rather than guess
            }
        }
        return chunks
    }
}

// Reassembles the CRYPTO stream of one connection until the ClientHello is complete.
// Holds at most `FlowNamer.bufferLimit` bytes, the TCP cap: a sender chooses every offset
// and length, so empty, overlapping and far-off chunks are refused rather than stored.
struct QUICAssembly {
    /// The most chunks held ahead of the stream. Each new chunk is checked against all of
    /// them; a real ClientHello spans a handful of Initials.
    static let maxAhead = 32

    /// Contiguous bytes from offset zero.
    private(set) var stream: [UInt8] = []
    /// Chunks that arrived ahead of the stream, none overlapping another or the stream.
    private var ahead: [QUIC.Chunk] = []
    /// A chunk reached past the byte cap, or one more was held ahead than `maxAhead`: the
    /// handshake is too large to name.
    private(set) var overLimit = false

    mutating func add(_ new: [QUIC.Chunk]) {
        for chunk in new where !chunk.data.isEmpty && !overLimit {
            let start = chunk.offset
            let end = start + UInt64(chunk.data.count)
            guard end <= UInt64(FlowNamer.bufferLimit) else { return giveUp() }
            guard start >= UInt64(stream.count),
                  !ahead.contains(where: { start < $0.offset + UInt64($0.data.count) && $0.offset < end }) else { continue }
            guard ahead.count < Self.maxAhead else { return giveUp() }
            ahead.append(chunk)
        }
        // Each chunk taken is nonempty, so the stream grows on every pass.
        while let index = ahead.firstIndex(where: { $0.offset == UInt64(stream.count) }) {
            stream.append(contentsOf: ahead.remove(at: index).data)
        }
    }

    private mutating func giveUp() {
        overLimit = true
        stream = []
        ahead = []
    }
}
