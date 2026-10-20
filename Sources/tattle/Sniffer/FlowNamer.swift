import Foundation

/// Which packet named a connection, in order of preference (ADR-0001).
enum NameSource: String, Sendable, Codable {
    /// The server name in a TLS ClientHello over TCP.
    case sni
    /// The same, inside a decrypted QUIC Initial packet.
    case quic
    /// The Host header of a plaintext HTTP request.
    case http
    /// Only a DNS reply seen earlier named the address: a fallback, and ambiguous
    /// wherever one address serves many names.
    case dns

    var text: String {
        switch self {
        case .sni: "the connection's TLS handshake"
        case .quic: "the connection's QUIC handshake"
        case .http: "the HTTP request"
        case .dns: "a DNS reply for the address"
        }
    }
}

/// An outbound flow as the socket table also sees it: protocol, local port and peer.
/// The pid is the socket table's to add.
struct FlowKey: Hashable, Sendable {
    let proto: Packet.Proto
    let localPort: UInt16
    let remote: IPAddress
    let remotePort: UInt16

    /// The join key shared with `Connection.flowKey`.
    var text: String { "\(proto == .tcp ? "tcp" : "udp")/\(localPort)>\(remote.text):\(remotePort)" }
}

struct FlowEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A connection just started: the moment to read the socket table for its owner.
        case opened
        case named(String, NameSource)
    }

    var key: FlowKey
    var kind: Kind
}

/// Turns captured packets into names for connections. Keeps, per flow, only the handshake
/// bytes until a name is found or ruled out; keeps no packet contents otherwise.
struct FlowNamer: Sendable {
    /// A wire name must arrive within this long, or the DNS map is consulted.
    static let dnsFallbackAfter = 3.0
    /// A flow still unnamed after this long is given up on and its buffers freed.
    static let finalizeAfter = 20.0
    /// A flow not seen for this long is forgotten; a later packet with the same
    /// addresses is a new connection.
    static let idleAfter = 120.0
    /// How long a DNS answer is remembered.
    static let dnsRemembered = 3600.0
    /// The most handshake bytes buffered for one TCP flow.
    static let bufferLimit = 16_384

    private struct Flow {
        var start: Double
        var lastSeen: Double
        var named = false
        var dnsTried = false
        var tlsBuffer: [UInt8]? = []  // nil once the stream is known not to be TLS or HTTP
        var nextSeq: UInt32 = 0
        var quicAssembly = QUICAssembly()
        var quicDone = false

        /// Nothing more can come of this flow; packets only refresh lastSeen.
        var finished: Bool { named || (tlsBuffer == nil && quicDone) }
    }

    private var local: Set<IPAddress>
    private var dnsMap: [IPAddress: (name: String, at: Double)] = [:]
    private var flows: [FlowKey: Flow] = [:]

    init(localAddresses: Set<IPAddress>) {
        local = localAddresses
    }

    /// Addresses change with DHCP leases and network switches.
    mutating func updateLocalAddresses(_ addresses: Set<IPAddress>) {
        if !addresses.isEmpty { local = addresses }
    }

    var flowCount: Int { flows.count }
    var dnsCount: Int { dnsMap.count }

    mutating func observe(_ p: Packet, at ts: Double) -> [FlowEvent] {
        let outbound = local.contains(p.src)
        if p.proto == .udp && p.srcPort == 53 && !outbound {
            if let reply = DNS.parseReply(p.payload) {
                for address in reply.addresses { dnsMap[address] = (reply.name, ts) }
            }
            return []
        }
        guard outbound, !p.dst.isLocalScope, !local.contains(p.dst) else { return [] }

        let key = FlowKey(proto: p.proto, localPort: p.srcPort, remote: p.dst, remotePort: p.dstPort)
        switch p.proto {
        case .tcp:
            let syn = p.tcpFlags & 0x02 != 0 && p.tcpFlags & 0x10 == 0
            if syn {
                flows[key] = Flow(start: ts, lastSeen: ts, nextSeq: p.tcpSeq &+ 1, quicDone: true)
                return [FlowEvent(key: key, kind: .opened)]
            }
            guard var flow = flows[key] else { return [] }
            flow.lastSeen = ts
            defer { flows[key] = flow }
            guard !flow.finished, !p.payload.isEmpty else { return [] }
            // Only the in-order segment extends the buffer: a retransmit (seq behind) is
            // dropped, and a gap (seq ahead) ends buffering rather than risk a shifted parse.
            if p.tcpSeq == flow.nextSeq {
                flow.nextSeq = flow.nextSeq &+ UInt32(p.payload.count)
                if let (name, source) = inspectTCP(&flow, payload: p.payload) {
                    flow.named = true
                    return [FlowEvent(key: key, kind: .named(name, source))]
                }
            } else if p.tcpSeq &- flow.nextSeq < 0x8000_0000 {
                flow.tlsBuffer = nil
            }
            return []
        case .udp:
            let datagram = Array(p.payload)
            var events: [FlowEvent] = []
            if var flow = flows[key] {
                flow.lastSeen = ts
                flows[key] = flow
            } else {
                // Only a long header starts a flow: a QUIC connection whose first packet seen
                // is a short one was open before capture began and has no ClientHello left.
                guard QUIC.isLongHeader(datagram) else { return [] }
                flows[key] = Flow(start: ts, lastSeen: ts, tlsBuffer: nil)
                events.append(FlowEvent(key: key, kind: .opened))
            }
            guard var flow = flows[key], !flow.finished, QUIC.isLongHeader(datagram) else { return events }
            if let name = inspectUDP(&flow, datagram: datagram) {
                flow.named = true
                events.append(FlowEvent(key: key, kind: .named(name, .quic)))
            }
            flows[key] = flow
            return events
        }
    }

    private func inspectTCP(_ flow: inout Flow, payload: ArraySlice<UInt8>) -> (String, NameSource)? {
        guard var buffer = flow.tlsBuffer else { return nil }
        if buffer.isEmpty, payload.first != 0x16 {
            flow.tlsBuffer = nil
            return HTTP.host(payload).map { ($0, .http) }
        }
        buffer.append(contentsOf: payload)
        switch TLS.clientHelloFromRecords(buffer) {
        case .hello(let sni):
            flow.tlsBuffer = nil
            return sni.map { ($0, .sni) }
        case .notClientHello:
            flow.tlsBuffer = nil
            return nil
        case .needMore:
            flow.tlsBuffer = buffer.count < Self.bufferLimit ? buffer : nil
            return nil
        }
    }

    private func inspectUDP(_ flow: inout Flow, datagram: [UInt8]) -> String? {
        var offset = 0
        while offset < datagram.count, datagram[offset] & 0x80 != 0 {
            switch QUIC.parseInitial(datagram, at: offset) {
            case .success(let initial):
                flow.quicAssembly.add(initial.chunks)
                offset = initial.nextOffset
                if case .hello(let sni) = TLS.clientHello(flow.quicAssembly.stream) {
                    flow.quicDone = true
                    return sni
                }
            case .failure(.unsupportedVersion):
                // Not a version whose Initial can be read; nothing more will come of it.
                flow.quicDone = true
                return nil
            case .failure:
                return nil
            }
        }
        return nil
    }

    /// Time-driven work: the DNS fallback for flows nothing else named, giving up on old
    /// ones, forgetting idle ones and stale DNS answers.
    mutating func expire(now: Double) -> [FlowEvent] {
        var events: [FlowEvent] = []
        for (key, var flow) in flows {
            if !flow.named, !flow.dnsTried, now - flow.start >= Self.dnsFallbackAfter {
                flow.dnsTried = true
                if let entry = dnsMap[key.remote] {
                    flow.named = true
                    events.append(FlowEvent(key: key, kind: .named(entry.name, .dns)))
                }
            }
            if !flow.named, now - flow.start >= Self.finalizeAfter {
                flow.tlsBuffer = nil
                flow.quicDone = true
            }
            if now - flow.lastSeen >= Self.idleAfter {
                flows[key] = nil
            } else {
                flows[key] = flow
            }
        }
        dnsMap = dnsMap.filter { now - $0.value.at < Self.dnsRemembered }
        return events
    }
}
