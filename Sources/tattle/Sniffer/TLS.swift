import Foundation

enum TLS {
    enum HelloResult {
        case needMore
        case notClientHello
        case hello(sni: String?)
    }

    // Parses a handshake-message stream (no record layer) that should start with a
    // ClientHello and returns its server_name extension, if any.
    static func clientHello(_ data: [UInt8]) -> HelloResult {
        guard data.count >= 4 else { return .needMore }
        guard data[0] == 1 else { return .notClientHello }
        let length = Int(data[1]) << 16 | Int(data[2]) << 8 | Int(data[3])
        guard data.count >= 4 + length else { return .needMore }
        var r = ByteReader(data, from: 4, to: 4 + length)
        do {
            try r.skip(2 + 32)  // legacy version, random
            try r.skip(Int(try r.u8()))  // session id
            try r.skip(Int(try r.u16()))  // cipher suites
            try r.skip(Int(try r.u8()))  // compression methods
            guard r.remaining >= 2 else { return .hello(sni: nil) }
            let extensionsLength = Int(try r.u16())
            r.end = min(r.end, r.pos + extensionsLength)
            while r.remaining >= 4 {
                let type = try r.u16()
                let length = Int(try r.u16())
                if type == 0 {
                    var e = ByteReader(data, from: r.pos, to: r.pos + length)
                    try e.skip(2)  // list length
                    let nameType = try e.u8()
                    let nameLength = Int(try e.u16())
                    let name = try e.take(nameLength)
                    guard nameType == 0 else { return .hello(sni: nil) }
                    return .hello(sni: HostName(name)?.text)
                }
                try r.skip(length)
            }
            return .hello(sni: nil)
        } catch {
            return .hello(sni: nil)
        }
    }

    // Strips the TLS record layer from a TCP byte stream and hands the concatenated
    // handshake fragments to clientHello. A partial trailing record is included; the
    // handshake length check decides whether more bytes are needed.
    static func clientHelloFromRecords(_ stream: [UInt8]) -> HelloResult {
        guard !stream.isEmpty else { return .needMore }
        guard stream[0] == 0x16 else { return .notClientHello }
        var r = ByteReader(stream)
        var handshake: [UInt8] = []
        do {
            while r.remaining >= 5 {
                let type = try r.u8()
                guard type == 0x16 else { break }
                try r.skip(2)
                let length = Int(try r.u16())
                let fragment = try r.take(min(length, r.remaining))
                handshake.append(contentsOf: fragment)
            }
        } catch {
            return .needMore
        }
        return clientHello(handshake)
    }
}

enum HTTP {
    /// A plaintext HTTP/1.x request, and the name its Host header gives the destination:
    /// nil when there is no Host header or its value is not a host name.
    struct Request {
        let host: String?
    }

    static func request(_ payload: ArraySlice<UInt8>) -> Request? {
        let head = Array(payload.prefix(2048))
        let text = String(decoding: head, as: UTF8.self)
        let methods = ["GET ", "POST ", "HEAD ", "PUT ", "DELETE ", "OPTIONS ", "CONNECT ", "PATCH "]
        guard methods.contains(where: { text.hasPrefix($0) }) else { return nil }
        for line in text.split(separator: "\r\n", omittingEmptySubsequences: false).dropFirst() {
            if line.isEmpty { break }
            if line.lowercased().hasPrefix("host:") {
                let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                return Request(host: HostName(value.utf8, allowingPort: true)?.text)
            }
        }
        return Request(host: nil)
    }
}
