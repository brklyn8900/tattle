import Foundation

/// Who made a connection, resolved once when it opens.
struct ConnectionOwner: Equatable, Sendable {
    var processName: String
    var path: String?
    var app: AppBundle?
    var signature: CodeSignature?

    /// The app when there is one, else the process: what the row is filed under.
    var displayName: String { app?.name ?? processName }
    var groupID: String { app?.path ?? "process:\(processName)" }

    static let unknown = ConnectionOwner(processName: "unknown process")

    /// Resolves a pid against a process list, attributing helpers to their app the same
    /// way the Processes tab does. `signature` reads the app bundle, or the executable
    /// when there is no app.
    static func resolve(
        pid: Int32, in byPid: [Int32: ProcessEntry], runningApp: (Int32) -> String?,
        responsible: (Int32) -> Int32? = ResponsibleProcess.pid(for:), signature: (String) -> CodeSignature?
    ) -> ConnectionOwner {
        guard let entry = byPid[pid] else { return ConnectionOwner(processName: "pid \(pid)") }
        var memo: [Int32: AppBundle?] = [:]
        let app = ProcessSnapshot.app(of: pid, in: byPid, runningApp: runningApp, responsible: responsible, memo: &memo)
        let signed = (app?.path ?? entry.path).flatMap(signature)
        return ConnectionOwner(processName: entry.name, path: entry.path, app: app, signature: signed)
    }
}

/// A connection as the tab shows it.
struct LiveConnection: Equatable, Sendable, Identifiable {
    var connection: Connection
    var owner: ConnectionOwner
    /// First time this address appears in history.
    var isNew: Bool
    /// From the sniffer, when it saw the handshake; nil until then or without packet access.
    var name: ConnectionName? = nil
    /// Why the sniffer found no name, once it has given up.
    var unnamedReason: FlowEvent.Reason? = nil

    var outcome: NameOutcome? {
        if let name { return .named(name) }
        if let unnamedReason { return .unnamed(unnamedReason) }
        return nil
    }

    init(connection: Connection, owner: ConnectionOwner, isNew: Bool, outcome: NameOutcome? = nil) {
        self.connection = connection
        self.owner = owner
        self.isNew = isNew
        name = outcome?.name
        unnamedReason = outcome?.reason
    }

    var id: String { connection.id }

    var destination: String {
        connection.isIPv6 ? "[\(connection.remoteAddress)]:\(connection.remotePort)" : "\(connection.remoteAddress):\(connection.remotePort)"
    }

    /// What the row is headed by: the name where it is the destination, what kind of
    /// non-destination it is otherwise, the address when there is no name.
    var title: String {
        switch name?.kind {
        case .destination: name!.name
        case .relay: "relayed"
        case .hidden: "name hidden"
        case nil: destination
        }
    }

    /// Knowledge-base key: the name once the sniffer supplies one, the address until then.
    /// A relay or cover name is still the right key: the rule for it says what it is.
    var explainKey: String { name?.name ?? connection.remoteAddress }

    func facts(now: Date) -> [Fact] {
        var facts: [Fact] = []
        switch name?.kind {
        case .destination:
            facts.append(Fact(name: "Destination", value: name!.name))
            facts.append(Fact(name: "Address", value: destination))
        case .relay:
            facts.append(Fact(name: "Destination", value: "hidden inside a relay"))
            facts.append(Fact(name: "Relay", value: name!.name))
            facts.append(Fact(name: "Address", value: destination))
        case .hidden:
            facts.append(Fact(name: "Destination", value: "hidden by Encrypted Client Hello"))
            facts.append(Fact(name: "Cover name", value: name!.name))
            facts.append(Fact(name: "Address", value: destination))
        case nil:
            facts.append(Fact(name: "Destination", value: destination))
        }
        facts += [
            Fact(name: "Protocol", value: connection.proto.rawValue.uppercased() + (connection.stateText.map { ", \($0)" } ?? "")),
            Fact(name: "Reach", value: connection.scope == .local ? "this network" : "the internet"),
            Fact(name: "Process", value: "\(owner.processName) (pid \(connection.pid))"),
        ]
        if let app = owner.app, app.name != owner.processName { facts.append(Fact(name: "App", value: app.name)) }
        if let signature = owner.signature {
            facts.append(Fact(name: "Signed by", value: signature.summary))
            if let team = signature.teamIdentifier { facts.append(Fact(name: "Team", value: team)) }
        }
        facts.append(Fact(name: "Runs as", value: UserName.describe(connection.uid)))
        if connection.preExisting {
            facts.append(Fact(name: "Since", value: "before Tattle started looking"))
        } else {
            facts.append(Fact(name: "Since", value: Self.ago(connection.firstSeen, now: now)))
        }
        if let ended = connection.ended { facts.append(Fact(name: "Ended", value: Self.ago(ended, now: now))) }
        facts.append(Fact(name: "First contact", value: isNew ? "yes, never seen this address before" : "no, seen before"))
        if let name {
            facts.append(Fact(name: "Name from", value: name.source.text))
        } else if let unnamedReason {
            facts.append(Fact(name: "No name", value: unnamedReason.text))
        }
        return facts
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(now.timeIntervalSince(date), 0)
        if seconds < 60 { return "\(Int(seconds)) s ago" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) h ago" }
        return date.formatted(.relative(presentation: .named))
    }
}

/// One row of the tab: an app or program and its open connections.
struct ConnectionGroup: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var signature: CodeSignature?
    /// Newest first.
    var connections: [LiveConnection]

    var newCount: Int { connections.filter(\.isNew).count }
    var remoteCount: Int { connections.filter { $0.connection.scope == .remote }.count }
    var localCount: Int { connections.count - remoteCount }
}

struct NetworkSnapshot: Equatable, Sendable {
    var connections: [LiveConnection]
    var takenAt: Date

    /// Groups by app or program, most connections first.
    var groups: [ConnectionGroup] {
        var byID: [String: ConnectionGroup] = [:]
        var order: [String] = []
        for live in connections.sorted(by: { $0.connection.firstSeen > $1.connection.firstSeen }) {
            let id = live.owner.groupID
            if byID[id] == nil {
                byID[id] = ConnectionGroup(id: id, name: live.owner.displayName, signature: live.owner.signature, connections: [])
                order.append(id)
            }
            byID[id]!.connections.append(live)
        }
        return order.compactMap { byID[$0] }.sorted { ($0.connections.count, $1.name) > ($1.connections.count, $0.name) }
    }

    var newCount: Int { connections.filter(\.isNew).count }
    var preExistingCount: Int { connections.filter(\.connection.preExisting).count }
    var namedCount: Int { connections.filter { $0.name?.kind == .destination }.count }
    var relayedCount: Int { connections.filter { $0.name?.kind == .relay }.count }
    var hiddenCount: Int { connections.filter { $0.name?.kind == .hidden }.count }

    func connection(id: String) -> LiveConnection? { connections.first { $0.id == id } }
    func group(id: String) -> ConnectionGroup? { groups.first { $0.id == id } }
}
