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
        pid: Int32, in byPid: [Int32: ProcessEntry], runningApp: (Int32) -> String?, signature: (String) -> CodeSignature?
    ) -> ConnectionOwner {
        guard let entry = byPid[pid] else { return ConnectionOwner(processName: "pid \(pid)") }
        var memo: [Int32: AppBundle?] = [:]
        let app = ProcessSnapshot.app(of: pid, in: byPid, runningApp: runningApp, memo: &memo)
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

    var id: String { connection.id }

    var destination: String {
        connection.isIPv6 ? "[\(connection.remoteAddress)]:\(connection.remotePort)" : "\(connection.remoteAddress):\(connection.remotePort)"
    }

    /// Knowledge-base key: the name once the sniffer supplies one, the address until then.
    var explainKey: String { connection.remoteAddress }

    func facts(now: Date) -> [Fact] {
        var facts = [
            Fact(name: "Destination", value: destination),
            Fact(name: "Protocol", value: connection.proto.rawValue.uppercased() + (connection.stateText.map { ", \($0)" } ?? "")),
            Fact(name: "Reach", value: connection.scope == .local ? "this network" : "the internet"),
            Fact(name: "Process", value: "\(owner.processName) (pid \(connection.pid))"),
        ]
        if let app = owner.app, app.name != owner.processName { facts.append(Fact(name: "App", value: app.name)) }
        if let signature = owner.signature {
            facts.append(Fact(name: "Signed by", value: signature.summary))
            if let team = signature.teamIdentifier { facts.append(Fact(name: "Team", value: team)) }
        }
        facts.append(Fact(name: "Runs as", value: connection.uid == 0 ? "root" : "user \(connection.uid)"))
        if connection.preExisting {
            facts.append(Fact(name: "Since", value: "before Tattle started looking"))
        } else {
            facts.append(Fact(name: "Since", value: Self.ago(connection.firstSeen, now: now)))
        }
        if let ended = connection.ended { facts.append(Fact(name: "Ended", value: Self.ago(ended, now: now))) }
        facts.append(Fact(name: "First contact", value: isNew ? "yes, never seen this address before" : "no, seen before"))
        facts.append(Fact(name: "Name", value: "not known yet; names come from the sniffer"))
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

    func connection(id: String) -> LiveConnection? { connections.first { $0.id == id } }
    func group(id: String) -> ConnectionGroup? { groups.first { $0.id == id } }
}
