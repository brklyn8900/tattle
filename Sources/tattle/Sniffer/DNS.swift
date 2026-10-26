import Foundation

enum DNS {
    struct Reply {
        let name: String  // the question name: what the application asked for
        let addresses: [IPAddress]
    }

    static func parseReply(_ payload: ArraySlice<UInt8>) -> Reply? {
        let bytes = Array(payload)
        var r = ByteReader(bytes)
        do {
            try r.skip(2)
            let flags = try r.u16()
            guard flags & 0x8000 != 0 else { return nil }  // responses only
            let questions = Int(try r.u16())
            let answers = Int(try r.u16())
            try r.skip(4)
            guard questions >= 1 else { return nil }
            guard let qname = try readName(bytes, &r) else { return nil }
            try r.skip(4)
            for _ in 1..<max(questions, 1) {
                _ = try readName(bytes, &r)
                try r.skip(4)
            }
            var addresses: [IPAddress] = []
            for _ in 0..<answers {
                _ = try readName(bytes, &r)
                let type = try r.u16()
                try r.skip(6)
                let rdlen = Int(try r.u16())
                let rdata = try r.take(rdlen)
                if (type == 1 && rdlen == 4) || (type == 28 && rdlen == 16) {
                    addresses.append(IPAddress(bytes: Array(rdata)))
                }
            }
            return Reply(name: qname.text, addresses: addresses)
        } catch {
            return nil
        }
    }

    // Reads a name with RFC 1035 compression; the reader advances past the name as it
    // appears in the sequential stream, not past any pointer target. Nil for a name that is
    // not a host name; a label holding a dot is one, since joining would hide it.
    private static func readName(_ bytes: [UInt8], _ r: inout ByteReader) throws -> HostName? {
        var labels: [ArraySlice<UInt8>] = []
        var pos = r.pos
        var jumped = false
        var hops = 0
        while true {
            guard pos < bytes.count else { throw ByteReader.ParseError.short }
            let len = Int(bytes[pos])
            if len == 0 {
                pos += 1
                if !jumped { r.pos = pos }
                break
            }
            if len & 0xc0 == 0xc0 {
                guard pos + 1 < bytes.count else { throw ByteReader.ParseError.short }
                let target = ((len & 0x3f) << 8) | Int(bytes[pos + 1])
                if !jumped { r.pos = pos + 2 }
                jumped = true
                pos = target
                hops += 1
                guard hops < 64 else { throw ByteReader.ParseError.short }
                continue
            }
            guard pos + 1 + len <= bytes.count else { throw ByteReader.ParseError.short }
            labels.append(bytes[(pos + 1)..<(pos + 1 + len)])
            pos += 1 + len
        }
        guard !labels.contains(where: { $0.contains(UInt8(ascii: ".")) }) else { return nil }
        return HostName(Array(labels.joined(separator: [UInt8(ascii: ".")])))
    }
}
