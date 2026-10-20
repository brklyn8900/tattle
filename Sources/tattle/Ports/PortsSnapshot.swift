import Foundation

/// One listening port, with its owner.
struct PortItem: Equatable, Sendable, Identifiable {
    enum Group: Int, CaseIterable, Sendable {
        case network, local, ephemeral

        var title: String {
            switch self {
            case .network: "Reachable from your network"
            case .local: "This Mac only"
            case .ephemeral: "Ephemeral UDP"
            }
        }

        var description: String {
            switch self {
            case .network: "Bound to every interface or to a network address: anything on your network can connect."
            case .local: "Bound to localhost: only programs on this Mac can connect."
            case .ephemeral: "Unconnected UDP sockets on high ports, usually a client waiting for replies rather than a service."
            }
        }
    }

    enum Binding: Equatable, Sendable {
        case allInterfaces
        case loopback
        case address(String)

        var text: String {
            switch self {
            case .allInterfaces: "all interfaces"
            case .loopback: "localhost only"
            case .address(let address): address
            }
        }
    }

    var id: String
    var proto: SocketEntry.Proto
    var port: UInt16
    var binding: Binding
    var families: String
    var pid: Int32
    var uid: UInt32
    var process: ProcessIdentity?
    var signature: CodeSignature?
    /// The IANA name from /etc/services, which is often stale for modern uses.
    var serviceName: String?

    static let ephemeralStart: UInt16 = 49152

    var group: Group {
        if case .loopback = binding { return .local }
        if proto == .udp && port >= Self.ephemeralStart { return .ephemeral }
        return .network
    }

    var processName: String { process?.name ?? "pid \(pid)" }

    /// Knowledge-base key: the process and the port, so "ControlCenter:tcp/*" can be a rule.
    var explainKey: String { "\(processName):\(proto.rawValue)/\(port)" }

    var facts: [Fact] {
        var facts = [
            Fact(name: "Port", value: "\(String(port)) \(proto.rawValue.uppercased())"),
            Fact(name: "Bound to", value: binding.text + " (\(families))"),
            Fact(name: "Process", value: processName + " (pid \(pid))"),
        ]
        if let path = process?.path { facts.append(Fact(name: "Path", value: path)) }
        if let signature {
            facts.append(Fact(name: "Signed by", value: signature.summary))
            if let team = signature.teamIdentifier { facts.append(Fact(name: "Team", value: team)) }
        }
        facts.append(Fact(name: "Runs as", value: uid == 0 ? "root" : "user \(uid)"))
        if let serviceName { facts.append(Fact(name: "IANA name", value: serviceName)) }
        return facts
    }
}

struct PortsSnapshot: Equatable, Sendable {
    var items: [PortItem]
    var takenAt: Date

    func items(in group: PortItem.Group) -> [PortItem] {
        items.filter { $0.group == group }.sorted { ($0.port, $0.proto.rawValue, $0.pid) < ($1.port, $1.proto.rawValue, $1.pid) }
    }

    /// One row per process, protocol, port and binding; the IPv4 and IPv6 sockets of a
    /// dual-stack listener are merged.
    static func build(
        entries: [SocketEntry], services: ServiceNames,
        identity: (Int32) -> ProcessIdentity?, signature: (String) -> CodeSignature?, takenAt: Date = Date()
    ) -> PortsSnapshot {
        var byKey: [String: PortItem] = [:]
        var order: [String] = []
        var identities: [Int32: ProcessIdentity?] = [:]
        for entry in entries where entry.isListening {
            let binding: PortItem.Binding = entry.isBoundToAllInterfaces ? .allInterfaces
                : entry.isLoopback ? .loopback : .address(entry.localAddress)
            let key = "\(entry.pid):\(entry.proto.rawValue)/\(entry.localPort)@\(binding.text)"
            let family = entry.isIPv6 ? "IPv6" : "IPv4"
            if var existing = byKey[key] {
                if !existing.families.contains(family) { existing.families += " and " + family }
                byKey[key] = existing
                continue
            }
            let process: ProcessIdentity?
            if let cached = identities[entry.pid] {
                process = cached
            } else {
                process = identity(entry.pid)
                identities[entry.pid] = process
            }
            byKey[key] = PortItem(
                id: key, proto: entry.proto, port: entry.localPort, binding: binding, families: family,
                pid: entry.pid, uid: entry.uid, process: process,
                signature: process?.path.flatMap(signature),
                serviceName: services.name(port: entry.localPort, proto: entry.proto))
            order.append(key)
        }
        return PortsSnapshot(items: order.compactMap { byKey[$0] }, takenAt: takenAt)
    }
}

/// Port names from /etc/services.
struct ServiceNames: Sendable {
    private var names: [String: String]

    static let empty = ServiceNames(names: [:])

    static func load(from url: URL = URL(fileURLWithPath: "/etc/services")) -> ServiceNames {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .empty }
        return parse(text)
    }

    static func parse(_ text: String) -> ServiceNames {
        var names: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let content = line.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let fields = content.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[1].contains("/") else { continue }
            // First entry for a port wins: the file lists the canonical name first.
            if names[String(fields[1])] == nil { names[String(fields[1])] = String(fields[0]) }
        }
        return ServiceNames(names: names)
    }

    func name(port: UInt16, proto: SocketEntry.Proto) -> String? {
        names["\(port)/\(proto.rawValue)"]
    }
}
