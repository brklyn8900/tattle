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
        /// Nothing more can name this flow, and why: what the spike could not tell apart.
        case unnamed(Reason)
    }

    enum Reason: Equatable, Sendable {
        /// The first bytes were neither a TLS record nor an HTTP request.
        case notHandshake
        /// A segment arrived out of order before the handshake was complete.
        case gap
        /// A ClientHello or HTTP request without a valid host name, or a handshake too large
        /// to buffer.
        case noServerName
        case quic(QUIC.Failure)
        /// No handshake within the window: no payload, or one that never completed.
        case timeout

        /// Stored in history as the name source of an unnamed connection.
        static let codePrefix = "none:"

        var code: String {
            switch self {
            case .notHandshake: Self.codePrefix + "not-handshake"
            case .gap: Self.codePrefix + "gap"
            case .noServerName: Self.codePrefix + "no-server-name"
            case .quic(let failure): Self.codePrefix + "quic-" + failure.rawValue
            case .timeout: Self.codePrefix + "timeout"
            }
        }

        init?(code: String) {
            switch code {
            case Self.codePrefix + "not-handshake": self = .notHandshake
            case Self.codePrefix + "gap": self = .gap
            case Self.codePrefix + "no-server-name": self = .noServerName
            case Self.codePrefix + "timeout": self = .timeout
            default:
                guard code.hasPrefix(Self.codePrefix + "quic-"),
                      let failure = QUIC.Failure(rawValue: String(code.dropFirst(Self.codePrefix.count + 5))) else { return nil }
                self = .quic(failure)
            }
        }

        var text: String {
            switch self {
            case .notHandshake: "the connection did not start with a TLS or HTTP handshake"
            case .gap: "part of the handshake was missed"
            case .noServerName: "the handshake carried no server name"
            case .quic(.unsupportedVersion): "a QUIC version Tattle cannot read"
            case .quic: "the QUIC handshake could not be read"
            case .timeout: "the connection sent nothing in its first \(Int(FlowNamer.finalizeAfter)) seconds"
            }
        }
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
    /// The most handshake bytes buffered for one flow, TCP or QUIC.
    static let bufferLimit = 16_384

    private struct Flow {
        var start: Double
        var lastSeen: Double
        /// Named from its own packets.
        var named = false
        var dnsTried = false
        /// Named from the DNS map, a stand-in until the wire names it: a later wire name
        /// replaces it, a later failure does not.
        var dnsNamed = false
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

    /// The packet goes to a public address from one this namer does not know as ours:
    /// the address set is stale, since this Mac sees no other host's traffic. Wi-Fi
    /// reconnecting after a wake drops and re-adds the interface's address, and a refresh
    /// that lands in the gap loses it. The source is usually private (a home network),
    /// so its scope says nothing; the destination's does.
    func endpointsUnknown(_ p: Packet) -> Bool {
        !local.contains(p.src) && !local.contains(p.dst) && !p.dst.isLocalScope
    }

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
            // The stream advances by the segment's length on the wire, captured or not.
            if p.tcpSeq == flow.nextSeq {
                flow.nextSeq = flow.nextSeq &+ UInt32(p.payload.count + p.uncaptured)
                switch inspectTCP(&flow, payload: p.payload) {
                case .named(let name, let source):
                    flow.named = true
                    return [FlowEvent(key: key, kind: .named(name, source))]
                case .unnamed(let reason):
                    return flow.dnsNamed ? [] : [FlowEvent(key: key, kind: .unnamed(reason))]
                case .pending:
                    // Still incomplete, and the rest of this segment was cut by the snap
                    // length: the handshake can never complete, so say so now.
                    guard p.uncaptured > 0, flow.tlsBuffer != nil else { return [] }
                    flow.tlsBuffer = nil
                    return flow.dnsNamed ? [] : [FlowEvent(key: key, kind: .unnamed(.gap))]
                }
            } else if p.tcpSeq &- flow.nextSeq < 0x8000_0000 {
                flow.tlsBuffer = nil
                return flow.dnsNamed ? [] : [FlowEvent(key: key, kind: .unnamed(.gap))]
            }
            return []
        case .udp:
            // A DNS query can look like anything; replies are read above.
            guard p.dstPort != 53 else { return [] }
            let datagram = Array(p.payload)
            var events: [FlowEvent] = []
            if var flow = flows[key] {
                flow.lastSeen = ts
                flows[key] = flow
            } else {
                // Only a client Initial starts a flow: a QUIC connection whose first packet
                // seen is a short one was open before capture began and has no ClientHello left.
                guard QUIC.mayBeClientInitial(datagram) else { return [] }
                flows[key] = Flow(start: ts, lastSeen: ts, tlsBuffer: nil)
                events.append(FlowEvent(key: key, kind: .opened))
            }
            guard var flow = flows[key], !flow.finished, QUIC.mayBeClientInitial(datagram) else { return events }
            switch inspectUDP(&flow, datagram: datagram) {
            case .named(let name, _):
                flow.named = true
                events.append(FlowEvent(key: key, kind: .named(name, .quic)))
            case .unnamed(let reason):
                if !flow.dnsNamed { events.append(FlowEvent(key: key, kind: .unnamed(reason))) }
            case .pending:
                break
            }
            flows[key] = flow
            return events
        }
    }

    private enum Inspection {
        case named(String, NameSource)
        case unnamed(FlowEvent.Reason)
        case pending
    }

    private func inspectTCP(_ flow: inout Flow, payload: ArraySlice<UInt8>) -> Inspection {
        guard var buffer = flow.tlsBuffer else { return .pending }
        if buffer.isEmpty, payload.first != 0x16 {
            flow.tlsBuffer = nil
            guard let request = HTTP.request(payload) else { return .unnamed(.notHandshake) }
            return request.host.map { .named($0, .http) } ?? .unnamed(.noServerName)
        }
        buffer.append(contentsOf: payload)
        switch TLS.clientHelloFromRecords(buffer) {
        case .hello(let sni):
            flow.tlsBuffer = nil
            return sni.map { .named($0, .sni) } ?? .unnamed(.noServerName)
        case .notClientHello:
            flow.tlsBuffer = nil
            return .unnamed(.notHandshake)
        case .needMore:
            guard buffer.count < Self.bufferLimit else {
                flow.tlsBuffer = nil
                return .unnamed(.noServerName)
            }
            flow.tlsBuffer = buffer
            return .pending
        }
    }

    private func inspectUDP(_ flow: inout Flow, datagram: [UInt8]) -> Inspection {
        var offset = 0
        while offset < datagram.count, datagram[offset] & 0x80 != 0 {
            switch QUIC.parseInitial(datagram, at: offset) {
            case .success(let initial):
                flow.quicAssembly.add(initial.chunks)
                offset = initial.nextOffset
                if flow.quicAssembly.overLimit {
                    flow.quicDone = true
                    flow.quicAssembly = QUICAssembly()
                    return .unnamed(.noServerName)
                }
                if case .hello(let sni) = TLS.clientHello(flow.quicAssembly.stream) {
                    flow.quicDone = true
                    flow.quicAssembly = QUICAssembly()
                    return sni.map { .named($0, .quic) } ?? .unnamed(.noServerName)
                }
            case .failure(.unsupportedVersion):
                // Not a version whose Initial can be read; nothing more will come of it.
                flow.quicDone = true
                return .unnamed(.quic(.unsupportedVersion))
            case .failure:
                // A later Initial may still complete the handshake; the timeout reports
                // the failure if none does.
                return .pending
            }
        }
        return .pending
    }

    /// Time-driven work: the DNS fallback for flows nothing else named, giving up on old
    /// ones, forgetting idle ones and stale DNS answers.
    mutating func expire(now: Double) -> [FlowEvent] {
        var events: [FlowEvent] = []
        for (key, var flow) in flows {
            if !flow.named, !flow.dnsTried, now - flow.start >= Self.dnsFallbackAfter {
                flow.dnsTried = true
                if let entry = dnsMap[key.remote] {
                    flow.dnsNamed = true
                    events.append(FlowEvent(key: key, kind: .named(entry.name, .dns)))
                }
            }
            if !flow.named, !flow.finished, now - flow.start >= Self.finalizeAfter {
                flow.tlsBuffer = nil
                flow.quicDone = true
                flow.quicAssembly = QUICAssembly()
                if !flow.dnsNamed { events.append(FlowEvent(key: key, kind: .unnamed(.timeout))) }
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
