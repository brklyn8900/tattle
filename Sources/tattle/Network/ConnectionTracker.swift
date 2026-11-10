import Foundation

/// One connection: a socket with a peer, as seen in the socket table over time.
struct Connection: Equatable, Sendable, Identifiable {
    /// Which side opened the connection, as far as anything shows it.
    enum Direction: String, Sendable, Codable {
        /// This Mac's SYN or QUIC Initial was seen leaving, or no listener claims a socket on
        /// an ephemeral local port.
        case outbound
        /// The socket sits on a listener's endpoint: it was accepted.
        case inbound
        /// None of those: nothing is claimed about which side connected.
        case unknown
    }

    enum Scope: String, Sendable {
        /// A public address: the internet.
        case remote
        /// A private, link-local or multicast address: this network.
        case local
    }

    /// Process, protocol, local port and peer: stable for the socket's life. A reused
    /// local port to the same peer from the same pid is treated as the same connection.
    var id: String
    var proto: SocketEntry.Proto
    var pid: Int32
    var uid: UInt32
    var localPort: UInt16
    var remoteAddress: String
    var remotePort: UInt16
    var isIPv6: Bool
    var scope: Scope
    var tcpState: Int32?
    var firstSeen: Date
    var lastSeen: Date
    /// Set when the socket left the table. The connection may have ended any time between
    /// the previous poll and this one.
    var ended: Date?
    /// Already in the table when Tattle started looking, so first seen is not when it began.
    var preExisting: Bool
    var direction = Direction.unknown

    var isOpen: Bool { ended == nil }

    /// TCP state in plain words (netinet/tcp_fsm.h); nil for UDP.
    var stateText: String? {
        guard let tcpState else { return nil }
        switch tcpState {
        case 2, 3: return "connecting"
        case 4: return "connected"
        case 5, 6, 7, 8, 9, 10: return "closing"
        case 0: return "closed"
        default: return "state \(tcpState)"
        }
    }

    static func key(_ entry: SocketEntry) -> String {
        "\(entry.pid):\(entry.proto.rawValue)/\(entry.localPort)>\(entry.remoteAddress):\(entry.remotePort)"
    }

    /// What the sniffer sees of this connection (`FlowKey.text`): the key without the pid.
    var flowKey: String { "\(proto.rawValue)/\(localPort)>\(wireAddress):\(remotePort)" }

    /// The peer's address as the wire shows it. An IPv6 socket talking IPv4 shows a mapped
    /// address; the wire shows IPv4, and both are one peer.
    var wireAddress: String { Self.wireAddress(remoteAddress) }

    static func wireAddress(_ address: String) -> String {
        address.lowercased().hasPrefix("::ffff:") ? String(address.dropFirst(7)) : address
    }
}

extension SocketEntry {
    /// A socket talking to a peer somewhere other than this Mac: TCP past listening, or
    /// UDP with a peer. Loopback is left out: a process talking to another on this Mac is
    /// the Ports tab's subject.
    var connectionScope: Connection.Scope? {
        guard remotePort != 0, !isListening, tcpState != SocketEntry.tcpListen else { return nil }
        guard !Self.isLoopback(remoteAddress), !Self.isUnspecified(remoteAddress) else { return nil }
        return Self.isLocalScope(remoteAddress) ? .local : .remote
    }

    static func isLoopback(_ address: String) -> Bool {
        address.hasPrefix("127.") || address == "::1" || address.lowercased().hasPrefix("::ffff:127.")
    }

    static func isUnspecified(_ address: String) -> Bool { address == "0.0.0.0" || address == "::" }

    /// RFC 1918, RFC 6598's shared space (Tailscale's, and carrier NAT's), link-local,
    /// multicast, and their IPv6 equivalents. The sniffer's own test leaves shared space
    /// out, so a Tailscale peer can still be named (`IPAddress.isLocalScope`).
    static func isLocalScope(_ address: String) -> Bool {
        let lower = address.lowercased()
        if lower.contains(":") {
            if lower.hasPrefix("fe8") || lower.hasPrefix("fe9") || lower.hasPrefix("fea") || lower.hasPrefix("feb") { return true }
            if lower.hasPrefix("fc") || lower.hasPrefix("fd") || lower.hasPrefix("ff") { return true }
            if lower.hasPrefix("::ffff:") { return isLocalScope(String(lower.dropFirst(7))) }
            return false
        }
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        switch octets[0] {
        case 10, 0: return true
        case 100: return (64...127).contains(octets[1])
        case 172: return (16...31).contains(octets[1])
        case 192: return octets[1] == 168
        case 169: return octets[1] == 254
        case 224...239: return true
        case 255: return true
        default: return false
        }
    }
}

/// The TCP endpoints sockets are listening on. An accepted socket keeps its listener's local
/// address and port, the only sign of one in the socket table; the pid can differ, since
/// launchd holds the listener of a job it starts on demand.
private struct TCPListeners {
    /// Ports listening on every address, by family. A family's ephemeral ports are allocated
    /// without regard to listeners that take only the other family, so a socket of one family
    /// on such a listener's port was not accepted by it.
    private var everyIPv4 = Set<UInt16>()
    private var everyIPv6 = Set<UInt16>()
    /// Listeners bound to one address.
    private var bound = Set<String>()

    init(_ entries: [SocketEntry]) {
        for entry in entries where entry.proto == .tcp && entry.isListening {
            guard entry.isBoundToAllInterfaces else { bound.insert(Self.endpoint(entry)); continue }
            if entry.acceptsIPv4 { everyIPv4.insert(entry.localPort) }
            if entry.acceptsIPv6 { everyIPv6.insert(entry.localPort) }
        }
    }

    func accepted(_ entry: SocketEntry) -> Bool {
        guard entry.proto == .tcp else { return false }
        let isIPv4 = !entry.isIPv6 || entry.localAddress.lowercased().hasPrefix("::ffff:")
        return (isIPv4 ? everyIPv4 : everyIPv6).contains(entry.localPort) || bound.contains(Self.endpoint(entry))
    }

    /// An IPv6 socket talking IPv4 shows a mapped address where its listener may show IPv4.
    private static func endpoint(_ entry: SocketEntry) -> String {
        let address = entry.localAddress.lowercased()
        return "\(address.hasPrefix("::ffff:") ? String(address.dropFirst(7)) : address)/\(entry.localPort)"
    }
}

/// Follows connections across polls of the socket table: which opened, which are still
/// there, which went away.
struct ConnectionTracker: Sendable {
    struct Changes: Equatable, Sendable {
        var opened: [Connection] = []
        var closed: [Connection] = []
    }

    private(set) var live: [String: Connection] = [:]
    private(set) var hasPolled = false

    var open: [Connection] { live.values.sorted { $0.firstSeen > $1.firstSeen } }

    private func connection(_ entry: SocketEntry) -> (key: String, scope: Connection.Scope, opens: Bool)? {
        guard let scope = entry.connectionScope else { return nil }
        let key = Connection.key(entry)
        return (key, scope, live[key] == nil)
    }

    func openingPids(_ entries: [SocketEntry]) -> Set<Int32> {
        Set(entries.compactMap { entry in connection(entry)?.opens == true ? entry.pid : nil })
    }

    /// Folds one reading of the table in. On the first reading every connection is
    /// pre-existing: it was there before Tattle looked. `outboundSeen` says whether this Mac
    /// was just seen opening a flow, which settles a new connection's direction over any
    /// listener on its port.
    mutating func update(entries: [SocketEntry], at now: Date = Date(), outboundSeen: (String) -> Bool = { _ in false }) -> Changes {
        var changes = Changes()
        var seen = Set<String>()
        let listeners = TCPListeners(entries)
        for entry in entries {
            guard let found = connection(entry), seen.insert(found.key).inserted else { continue }
            let key = found.key
            if !found.opens, var existing = live[key] {
                existing.lastSeen = now
                existing.tcpState = entry.tcpState
                live[key] = existing
            } else {
                var connection = Connection(
                    id: key, proto: entry.proto, pid: entry.pid, uid: entry.uid,
                    localPort: entry.localPort, remoteAddress: entry.remoteAddress, remotePort: entry.remotePort,
                    isIPv6: entry.isIPv6, scope: found.scope, tcpState: entry.tcpState,
                    firstSeen: now, lastSeen: now, ended: nil, preExisting: !hasPolled)
                // macOS gives a connecting socket a port from the ephemeral range, so with no
                // listener on it the port stands in for a SYN Tattle did not see. An accepted
                // socket whose listener on such a port has closed reads wrongly here.
                connection.direction = outboundSeen(connection.flowKey) ? .outbound
                    : listeners.accepted(entry) ? .inbound
                    : entry.localPort >= PortItem.ephemeralStart ? .outbound
                    : .unknown
                live[key] = connection
                changes.opened.append(connection)
            }
        }
        for (key, var connection) in live where !seen.contains(key) {
            connection.ended = now
            live[key] = nil
            changes.closed.append(connection)
        }
        hasPolled = true
        return changes
    }

    /// Settles as outbound the live connection a seen opening belongs to, whatever a listener
    /// on its port said: the event can arrive after the poll that first showed the socket.
    /// Returns the connections it changed.
    mutating func confirmOutbound(flow: FlowKey, openedAt: Date) -> [Connection] {
        var changed: [Connection] = []
        for (key, var connection) in live where connection.flowKey == flow.text && connection.direction != .outbound
            && ConnectionStore.isConnection(of: flow, firstSeen: connection.firstSeen, isOpen: connection.isOpen, openedAt: openedAt) {
            connection.direction = .outbound
            live[key] = connection
            changed.append(connection)
        }
        return changed
    }
}
