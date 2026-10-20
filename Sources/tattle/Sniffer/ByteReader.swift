import Foundation

extension ByteReader {
    enum ParseError: Error {
        case short
    }
}

// Bounds-checked cursor over a byte array. Every read throws instead of trapping, so a
// malformed packet is dropped rather than crashing the capture loop.
struct ByteReader {
    let bytes: [UInt8]
    var pos: Int
    var end: Int

    init(_ bytes: [UInt8], from: Int = 0, to: Int? = nil) {
        self.bytes = bytes
        self.pos = from
        self.end = min(to ?? bytes.count, bytes.count)
    }

    var remaining: Int { end - pos }

    mutating func u8() throws -> UInt8 {
        guard pos < end else { throw ParseError.short }
        defer { pos += 1 }
        return bytes[pos]
    }

    mutating func u16() throws -> UInt16 {
        guard pos + 2 <= end else { throw ParseError.short }
        defer { pos += 2 }
        return UInt16(bytes[pos]) << 8 | UInt16(bytes[pos + 1])
    }

    mutating func u24() throws -> UInt32 {
        guard pos + 3 <= end else { throw ParseError.short }
        defer { pos += 3 }
        return UInt32(bytes[pos]) << 16 | UInt32(bytes[pos + 1]) << 8 | UInt32(bytes[pos + 2])
    }

    mutating func u32() throws -> UInt32 {
        guard pos + 4 <= end else { throw ParseError.short }
        defer { pos += 4 }
        return UInt32(bytes[pos]) << 24 | UInt32(bytes[pos + 1]) << 16
            | UInt32(bytes[pos + 2]) << 8 | UInt32(bytes[pos + 3])
    }

    mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, pos + n <= end else { throw ParseError.short }
        defer { pos += n }
        return bytes[pos..<(pos + n)]
    }

    mutating func skip(_ n: Int) throws {
        guard n >= 0, pos + n <= end else { throw ParseError.short }
        pos += n
    }

    var rest: ArraySlice<UInt8> { bytes[pos..<end] }

    // QUIC variable-length integer (RFC 9000 section 16): the top two bits give the length.
    mutating func varint() throws -> UInt64 {
        let first = try u8()
        let length = 1 << Int(first >> 6)
        var value = UInt64(first & 0x3f)
        for _ in 1..<length {
            value = value << 8 | UInt64(try u8())
        }
        return value
    }
}
