import SwiftUI

struct NetworkTab: View {
    let state: AppState

    var body: some View {
        Group {
            if let snapshot = state.network.snapshot {
                ConnectionsList(snapshot: snapshot, captureStatus: state.network.captureStatus, state: state)
            } else if let error = state.network.error {
                Text(error).foregroundStyle(.secondary)
            } else {
                ProgressView("Reading connections")
            }
        }
    }
}

private struct ConnectionsList: View {
    let snapshot: NetworkSnapshot
    let captureStatus: Sniffer.Status
    let state: AppState

    var body: some View {
        List {
            Section {
                ForEach(snapshot.groups) { group in
                    NavigationLink(value: group) { ConnectionGroupRow(group: group) }
                }
            } header: {
                GroupHeader(title: title, description: description)
            }
        }
        .navigationDestination(for: ConnectionGroup.self) { group in
            ConnectionGroupDetail(group: group, state: state)
        }
        .navigationDestination(for: LiveConnection.self) { live in
            ConnectionDetail(live: live, state: state)
        }
    }

    private var title: String {
        let groups = snapshot.groups.count
        return "\(snapshot.connections.count) open connections from \(groups) \(groups == 1 ? "app" : "apps")"
    }

    private var description: String {
        var parts: [String] = []
        if snapshot.newCount > 0 { parts.append("\(snapshot.newCount) to addresses never seen before") }
        if snapshot.preExistingCount > 0 { parts.append("\(snapshot.preExistingCount) open since before Tattle started") }
        switch captureStatus {
        case .capturing:
            var named: [String] = []
            if snapshot.namedCount > 0 { named.append("\(snapshot.namedCount) named") }
            if snapshot.relayedCount > 0 { named.append("\(snapshot.relayedCount) relayed") }
            if snapshot.hiddenCount > 0 { named.append("\(snapshot.hiddenCount) with the name hidden") }
            parts.append(named.isEmpty ? "Names appear as connections open" : named.joined(separator: ", "))
        case .unavailable, .stopped:
            parts.append("Destinations are addresses: names need packet access, which Tattle does not have yet")
        }
        return parts.joined(separator: ". ").replacingOccurrences(of: "..", with: ".")
    }
}

private struct ConnectionGroupRow: View {
    let group: ConnectionGroup

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if group.newCount > 0 {
                Text("\(group.newCount) new")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(String(group.connections.count))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if group.remoteCount > 0 { parts.append("\(group.remoteCount) to the internet") }
        if group.localCount > 0 { parts.append("\(group.localCount) on this network") }
        if let signature = group.signature { parts.append(signature.summary) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

private struct ConnectionRow: View {
    let live: LiveConnection
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(live.title).font(.body.monospacedDigit())
                    if live.isNew {
                        Text("new").font(.caption).foregroundStyle(.orange)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(live.connection.preExisting ? "already open" : LiveConnection.ago(live.connection.firstSeen, now: now))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if live.name != nil { parts.append(live.destination) }
        parts.append(live.connection.proto.rawValue.uppercased())
        if let state = live.connection.stateText { parts.append(state) }
        if live.connection.scope == .local { parts.append("this network") }
        if live.owner.app != nil, live.owner.processName != live.owner.displayName { parts.append(live.owner.processName) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

private struct ConnectionGroupDetail: View {
    let group: ConnectionGroup
    let state: AppState

    /// The group as it is now; gone once its last connection closed.
    private var current: ConnectionGroup? { state.network.snapshot?.group(id: group.id) }

    var body: some View {
        let group = current ?? self.group
        let now = state.network.snapshot?.takenAt ?? Date()
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(group.name).font(.headline)
                if current == nil {
                    Text("No open connections now.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                FactsGrid(facts: facts(group, gone: current == nil))
                Divider()
                // The same key as the Processes tab, so an explanation of the program
                // given there is shown here and the other way round.
                ExplainSection(request: ExplainRequest(kind: .process, key: group.name, facts: facts(group, gone: current == nil)), state: state)
                Divider()
                HStack {
                    if let path = group.connections.first?.owner.app?.path ?? group.connections.first?.owner.path {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    }
                    Spacer()
                }
                .controlSize(.small)
                Divider()
                Text("Connections")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(group.connections) { live in
                        NavigationLink(value: live) { ConnectionRow(live: live, now: now).padding(.vertical, 4) }
                            .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            .padding(12)
        }
        .navigationTitle(group.name)
    }

    private func facts(_ group: ConnectionGroup, gone: Bool) -> [Fact] {
        var facts = [Fact(name: gone ? "Were open" : "Open", value: String(group.connections.count))]
        if group.remoteCount > 0 { facts.append(Fact(name: "Internet", value: String(group.remoteCount))) }
        if group.localCount > 0 { facts.append(Fact(name: "This network", value: String(group.localCount))) }
        if group.newCount > 0 { facts.append(Fact(name: "First contact", value: String(group.newCount))) }
        if let signature = group.signature {
            facts.append(Fact(name: "Signed by", value: signature.summary))
            if let team = signature.teamIdentifier { facts.append(Fact(name: "Team", value: team)) }
        }
        return facts
    }
}

private struct ConnectionDetail: View {
    let live: LiveConnection
    let state: AppState

    /// The connection as it is now; the one opened stays readable once it has closed.
    private var current: LiveConnection? { state.network.snapshot?.connection(id: live.id) }

    var body: some View {
        let live = current ?? self.live
        let now = state.network.snapshot?.takenAt ?? Date()
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(live.owner.displayName) to \(live.title)").font(.headline)
                if current == nil {
                    Text("Closed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                FactsGrid(facts: live.facts(now: now))
                Divider()
                ExplainSection(request: ExplainRequest(kind: .host, key: live.explainKey, facts: live.facts(now: now)), state: state)
                Divider()
                HStack {
                    if let path = live.owner.app?.path ?? live.owner.path {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    }
                    Spacer()
                }
                .controlSize(.small)
            }
            .padding(12)
        }
        .navigationTitle(live.title)
    }
}

extension ConnectionGroup: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension LiveConnection: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
