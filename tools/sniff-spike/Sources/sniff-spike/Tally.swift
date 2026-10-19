import Foundation

struct FlowKey: Hashable {
    let proto: Packet.Proto
    let src: IPAddress
    let srcPort: UInt16
    let dst: IPAddress
    let dstPort: UInt16
}

final class Flow {
    let key: FlowKey
    let start: Double
    var dnsName: String?
    var sni: String?
    var quicName: String?
    var httpHost: String?
    var quicFailure: QUIC.Failure?
    var tlsBuffer: [UInt8]? = []  // nil once the stream is known not to be TLS
    var preexisting = false  // first packet seen was mid-connection; cannot be named
    var sawPayload = false
    var nextSeq: UInt32 = 0  // TCP: sequence number the next in-order payload must carry
    var quicAssembly = QUICAssembly()

    init(key: FlowKey, start: Double, dnsName: String?) {
        self.key = key
        self.start = start
        self.dnsName = dnsName
    }

    // How the flow got its name, in order of preference.
    var method: String {
        if sni != nil { return "sni" }
        if quicName != nil { return "quic" }
        if httpHost != nil { return "http" }
        if dnsName != nil { return "dns" }
        return "none"
    }

    var name: String? { sni ?? quicName ?? httpHost ?? dnsName }
}

final class Tally {
    private var local: Set<IPAddress>
    private let log: FileHandle?
    private let debug: Bool
    private let startedAt = Date()

    private var dnsMap: [IPAddress: String] = [:]
    private var flows: [FlowKey: Flow] = [:]
    private var udpLastSeen: [FlowKey: Double] = [:]

    // Aggregates over finalized flows.
    private var byMethod: [String: Int] = [:]
    private var localCount = 0
    private var preexistingCount = 0
    private var remoteCount = 0
    private var dnsWouldName = 0
    private var quicFailures: [String: Int] = [:]
    private var unnamed: [String: Int] = [:]

    private let finalizeAfter = 20.0
    private let udpFlowGap = 120.0

    // Addresses change with DHCP leases and network switches; refreshed by the main loop.
    func updateLocalAddresses(_ addresses: Set<IPAddress>) {
        if !addresses.isEmpty { local = addresses }
    }

    init(localAddresses: Set<IPAddress>, logPath: String?, debug: Bool) {
        self.local = localAddresses
        self.debug = debug
        if let path = logPath {
            FileManager.default.createFile(atPath: path, contents: nil)
            log = FileHandle(forWritingAtPath: path)
            log?.seekToEndOfFile()
        } else {
            log = nil
        }
    }

    func observe(_ p: Packet, at ts: Double) {
        let outbound = local.contains(p.src)

        if p.proto == .udp && p.srcPort == 53 && !outbound, let reply = DNS.parseReply(p.payload) {
            for address in reply.addresses {
                dnsMap[address] = reply.name
            }
            if debug {
                fputs("dns \(p.src.text) \(reply.name) -> \(reply.addresses.map(\.text).joined(separator: " "))\n", stderr)
            }
            return
        }
        guard outbound else { return }

        let key = FlowKey(proto: p.proto, src: p.src, srcPort: p.srcPort, dst: p.dst, dstPort: p.dstPort)
        switch p.proto {
        case .tcp:
            let syn = p.tcpFlags & 0x02 != 0 && p.tcpFlags & 0x10 == 0
            if syn {
                let flow = Flow(key: key, start: ts, dnsName: dnsMap[p.dst])
                flow.nextSeq = p.tcpSeq &+ 1
                flows[key] = flow
                return
            }
            guard let flow = flows[key], !p.payload.isEmpty else { return }
            flow.sawPayload = true
            // Only the in-order segment extends the buffer: a retransmit (seq behind) is
            // dropped, and a gap (seq ahead) ends buffering rather than risk a shifted parse.
            if p.tcpSeq == flow.nextSeq {
                flow.nextSeq = flow.nextSeq &+ UInt32(p.payload.count)
                inspectTCP(flow, payload: p.payload)
            } else if p.tcpSeq &- flow.nextSeq < 0x8000_0000 {
                flow.tlsBuffer = nil
            }
        case .udp:
            let last = udpLastSeen[key]
            udpLastSeen[key] = ts
            if flows[key] == nil && (last == nil || ts - last! > udpFlowGap) {
                let flow = Flow(key: key, start: ts, dnsName: dnsMap[p.dst])
                // A QUIC connection whose first observed packet is not an Initial was open
                // before capture started; it has no ClientHello left to read.
                flow.preexisting = p.dstPort == 443 && !QUIC.isLongHeader(Array(p.payload))
                flows[key] = flow
            }
            guard let flow = flows[key], flow.quicName == nil else { return }
            flow.sawPayload = true
            inspectUDP(flow, payload: p.payload)
        }
    }

    private func inspectTCP(_ flow: Flow, payload: ArraySlice<UInt8>) {
        guard flow.sni == nil, flow.httpHost == nil, var buffer = flow.tlsBuffer else { return }
        if buffer.isEmpty, payload.first != 0x16 {
            flow.httpHost = HTTP.host(payload)
            flow.tlsBuffer = nil
            return
        }
        buffer.append(contentsOf: payload)
        switch TLS.clientHelloFromRecords(buffer) {
        case .hello(let sni):
            flow.sni = sni
            flow.tlsBuffer = nil
        case .notClientHello:
            flow.tlsBuffer = nil
        case .needMore:
            flow.tlsBuffer = buffer.count < 16_384 ? buffer : nil
        }
    }

    private func inspectUDP(_ flow: Flow, payload: ArraySlice<UInt8>) {
        let datagram = Array(payload)
        guard QUIC.isLongHeader(datagram) else { return }
        var offset = 0
        while offset < datagram.count, datagram[offset] & 0x80 != 0 {
            switch QUIC.parseInitial(datagram, at: offset) {
            case .success(let initial):
                flow.quicAssembly.add(initial.chunks)
                offset = initial.nextOffset
                if case .hello(let sni) = TLS.clientHello(flow.quicAssembly.stream) {
                    flow.quicName = sni
                    flow.quicFailure = nil
                    return
                }
            case .failure(let failure):
                if flow.quicFailure == nil { flow.quicFailure = failure }
                return
            }
        }
    }

    // Moves flows older than the window into the aggregates.
    func expire(now: Double) {
        for (key, flow) in flows where now - flow.start > finalizeAfter {
            finalize(flow)
            flows.removeValue(forKey: key)
        }
        udpLastSeen = udpLastSeen.filter { now - $0.value <= udpFlowGap }
    }

    func finishAll() {
        for flow in flows.values { finalize(flow) }
        flows.removeAll()
    }

    private func finalize(_ flow: Flow) {
        let dst = flow.key.dst
        let isLocal = dst.isLocalScope || local.contains(dst)
        if debug {
            let scope = isLocal ? "local" : flow.preexisting ? "preexisting" : "remote"
            fputs("flow \(flow.key.proto == .tcp ? "tcp" : "udp") \(dst.text):\(flow.key.dstPort) \(scope) \(flow.method) \(flow.name ?? "-")\n", stderr)
        }
        if isLocal {
            localCount += 1
        } else if flow.preexisting {
            preexistingCount += 1
        } else {
            remoteCount += 1
            byMethod[flow.method, default: 0] += 1
            if flow.dnsName != nil { dnsWouldName += 1 }
            if let failure = flow.quicFailure, flow.quicName == nil {
                quicFailures[failure.rawValue, default: 0] += 1
            }
            if flow.name == nil {
                unnamed["\(dst.text):\(flow.key.dstPort)", default: 0] += 1
            }
        }
        writeLog(flow, isLocal: isLocal)
    }

    private func writeLog(_ flow: Flow, isLocal: Bool) {
        guard let log else { return }
        var record: [String: Any] = [
            "ts": flow.start,
            "proto": flow.key.proto == .tcp ? "tcp" : "udp",
            "remote": flow.key.dst.text,
            "port": Int(flow.key.dstPort),
            "scope": isLocal ? "local" : flow.preexisting ? "preexisting" : "remote",
            "method": flow.method,
            "payload": flow.sawPayload,
        ]
        if let v = flow.dnsName { record["dns"] = v }
        if let v = flow.sni { record["sni"] = v }
        if let v = flow.quicName { record["quic"] = v }
        if let v = flow.httpHost { record["http"] = v }
        if let v = flow.quicFailure { record["quicFailure"] = v.rawValue }
        if let data = try? JSONSerialization.data(withJSONObject: record) {
            log.write(data)
            log.write(Data([0x0a]))
        }
    }

    func printSummary(final: Bool = false) {
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        let pending = flows.count
        func pct(_ n: Int) -> String {
            remoteCount == 0 ? "0%" : "\(n * 100 / remoteCount)%"
        }
        var lines: [String] = []
        lines.append("[spike] \(final ? "final" : "running") \(elapsed / 3600)h\(elapsed % 3600 / 60)m  "
                     + "remote \(remoteCount)  local \(localCount)  preexisting \(preexistingCount)  pending \(pending)  dns-map \(dnsMap.count)")
        let named = ["sni", "quic", "http", "dns"].map { "\($0) \(byMethod[$0, default: 0]) (\(pct(byMethod[$0, default: 0])))" }
        lines.append("  named by: " + named.joined(separator: "  ") + "  none \(byMethod["none", default: 0]) (\(pct(byMethod["none", default: 0])))")
        lines.append("  dns alone would name: \(dnsWouldName)/\(remoteCount) (\(pct(dnsWouldName)))")
        if !quicFailures.isEmpty {
            let parts = quicFailures.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }
            lines.append("  quic failures: " + parts.joined(separator: "  "))
        }
        let top = unnamed.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key) x\($0.value)" }
        if !top.isEmpty {
            lines.append("  unnamed top: " + top.joined(separator: ", "))
        }
        print(lines.joined(separator: "\n"))
        fflush(stdout)
    }
}
