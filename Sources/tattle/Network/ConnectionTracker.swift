import Foundation

/// One connection: a socket with a peer, as seen in the socket table over time.
struct Connection: Equatable, Sendable, Identifiable {
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
    /// The peer connected to this Mac: the socket was accepted from a listener.
    var isInbound = false

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

    /// What the sniffer sees of this connection (`FlowKey.text`): the key without the
    /// pid. An IPv6 socket talking IPv4 shows a mapped address; the wire shows IPv4.
    var flowKey: String {
        var remote = remoteAddress
        if remote.lowercased().hasPrefix("::ffff:") { remote = String(remote.dropFirst(7)) }
        return "\(proto.rawValue)/\(localPort)>\(remote):\(remotePort)"
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

    /// RFC 1918, link-local, multicast, and their IPv6 equivalents.
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
    /// Ports listening on every interface.
    private var everywhere = Set<UInt16>()
    /// Listeners bound to one address.
    private var bound = Set<String>()

    init(_ entries: [SocketEntry]) {
        for entry in entries where entry.proto == .tcp && entry.isListening {
            if entry.isBoundToAllInterfaces { everywhere.insert(entry.localPort) } else { bound.insert(Self.endpoint(entry)) }
        }
    }

    func accepted(_ entry: SocketEntry) -> Bool {
        entry.proto == .tcp && (everywhere.contains(entry.localPort) || bound.contains(Self.endpoint(entry)))
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

    /// Connections still open, newest first.
    var open: [Connection] { live.values.sorted { $0.firstSeen > $1.firstSeen } }

    /// Folds one reading of the table in. On the first reading every connection is
    /// pre-existing: it was there before Tattle looked.
    mutating func update(entries: [SocketEntry], at now: Date = Date()) -> Changes {
        var changes = Changes()
        var seen = Set<String>()
        let listeners = TCPListeners(entries)
        for entry in entries {
            guard let scope = entry.connectionScope else { continue }
            let key = Connection.key(entry)
            guard seen.insert(key).inserted else { continue }
            if var existing = live[key] {
                existing.lastSeen = now
                existing.tcpState = entry.tcpState
                live[key] = existing
            } else {
                let connection = Connection(
                    id: key, proto: entry.proto, pid: entry.pid, uid: entry.uid,
                    localPort: entry.localPort, remoteAddress: entry.remoteAddress, remotePort: entry.remotePort,
                    isIPv6: entry.isIPv6, scope: scope, tcpState: entry.tcpState,
                    firstSeen: now, lastSeen: now, ended: nil, preExisting: !hasPolled, isInbound: listeners.accepted(entry))
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
}
