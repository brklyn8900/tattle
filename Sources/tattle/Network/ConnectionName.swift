import Foundation

/// What the sniffer found out about where a connection goes.
struct ConnectionName: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The name is where the connection goes.
        case destination
        /// The name is a relay's ingress; the destination is hidden inside (ADR-0001).
        case relay
        /// The name is an Encrypted Client Hello cover; the real name is encrypted.
        case hidden
    }

    var name: String
    var source: NameSource
    var kind: Kind

    /// The kind a knowledge-base rule for the name implies.
    static func kind(forCategory category: String?) -> Kind {
        switch category {
        case "relay": .relay
        case "ech-cover": .hidden
        default: .destination
        }
    }
}

/// Names by flow key, waiting for or already attached to a connection. A name can arrive
/// before the socket table shows the connection or after; either way it is here when the
/// other side turns up, and forgotten once nothing claimed it for a while.
struct PendingNames: Equatable, Sendable {
    static let keepFor: TimeInterval = 300

    private var names: [String: (name: ConnectionName, at: Date)] = [:]

    init() {}

    static func == (a: PendingNames, b: PendingNames) -> Bool {
        a.names.keys == b.names.keys && a.names.allSatisfy { b.names[$0.key]?.name == $0.value.name }
    }

    mutating func set(_ name: ConnectionName, for flowKey: String, at date: Date) {
        names[flowKey] = (name, date)
    }

    func name(for flowKey: String) -> ConnectionName? { names[flowKey]?.name }

    /// Forgets names older than `keepFor`, except those of flows still open.
    mutating func prune(now: Date, keeping open: Set<String>) {
        names = names.filter { open.contains($0.key) || now.timeIntervalSince($0.value.at) < Self.keepFor }
    }

    var count: Int { names.count }
}
