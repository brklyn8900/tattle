import Foundation

/// What the sniffer found out about where a connection goes.
struct ConnectionName: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
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

/// What the sniffer concluded about a flow: a name, or why there is none.
enum NameOutcome: Equatable, Sendable {
    case named(ConnectionName)
    case unnamed(FlowEvent.Reason)

    var name: ConnectionName? {
        if case .named(let name) = self { return name }
        return nil
    }

    var reason: FlowEvent.Reason? {
        if case .unnamed(let reason) = self { return reason }
        return nil
    }
}

/// Outcomes by flow key, waiting for or already attached to a connection. One can arrive
/// before the socket table shows the connection or after; either way it is here when the
/// other side turns up, and forgotten once nothing claimed it for a while.
struct PendingNames: Equatable, Sendable {
    static let keepFor: TimeInterval = 300

    private var names: [String: (outcome: NameOutcome, at: Date)] = [:]
    /// When each flow's opened event arrived: history rows older than that are another
    /// connection's.
    private var opened: [String: Date] = [:]

    init() {}

    static func == (a: PendingNames, b: PendingNames) -> Bool {
        a.names.keys == b.names.keys && a.names.allSatisfy { b.names[$0.key]?.outcome == $0.value.outcome }
    }

    mutating func set(_ outcome: NameOutcome, for flowKey: String, at date: Date) {
        names[flowKey] = (outcome, date)
    }

    func outcome(for flowKey: String) -> NameOutcome? { names[flowKey]?.outcome }

    /// Whether this Mac was just seen opening the flow, its outbound SYN or QUIC Initial.
    /// Anything older was an earlier connection on the same four-tuple.
    func openingSeen(_ flowKey: String, at now: Date) -> Bool {
        opened[flowKey].map { now.timeIntervalSince($0) < ConnectionStore.openedSlack } ?? false
    }

    /// Takes in the sniffer's events and returns the outcomes among them, in order, with when
    /// their flow opened, for the caller to put on rows and history. `kind` says what a name
    /// from a given source is. An opened flow drops what its key held: that was an earlier
    /// connection on a reused local port.
    mutating func apply(_ events: [FlowEvent], at date: Date, kind: (String, NameSource) -> ConnectionName.Kind) -> [(flow: FlowKey, outcome: NameOutcome, openedAt: Date)] {
        var outcomes: [(flow: FlowKey, outcome: NameOutcome, openedAt: Date)] = []
        for event in events {
            let outcome: NameOutcome
            switch event.kind {
            case .opened:
                names[event.key.text] = nil
                opened[event.key.text] = date
                continue
            case .named(let text, let source):
                outcome = .named(ConnectionName(name: text, source: source, kind: kind(text, source)))
            case .unnamed(let reason):
                outcome = .unnamed(reason)
            }
            set(outcome, for: event.key.text, at: date)
            // An outcome comes at most the namer's give-up time after its flow opened.
            outcomes.append((event.key, outcome, opened[event.key.text] ?? date.addingTimeInterval(-FlowNamer.finalizeAfter)))
        }
        return outcomes
    }

    mutating func prune(now: Date, keeping open: Set<String>) {
        names = names.filter { open.contains($0.key) || now.timeIntervalSince($0.value.at) < Self.keepFor }
        opened = opened.filter { open.contains($0.key) || now.timeIntervalSince($0.value) < Self.keepFor }
    }

    var count: Int { names.count }
}
