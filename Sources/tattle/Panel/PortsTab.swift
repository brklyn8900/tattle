import SwiftUI

struct PortsTab: View {
    let state: AppState

    var body: some View {
        Group {
            if let snapshot = state.ports.snapshot {
                PortsList(snapshot: snapshot, state: state)
            } else if let error = state.ports.error {
                Text(error).foregroundStyle(.secondary)
            } else {
                ProgressView("Reading listening ports")
            }
        }
        .task(id: state.panelIsShowing) {
            guard state.panelIsShowing else { return }
            // Ports come and go; keep the list current while it is on screen.
            while !Task.isCancelled {
                await state.ports.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

private struct PortsList: View {
    let snapshot: PortsSnapshot
    let state: AppState

    var body: some View {
        List {
            ForEach(PortItem.Group.allCases, id: \.self) { group in
                let items = snapshot.items(in: group)
                if !items.isEmpty {
                    Section {
                        ForEach(items) { item in
                            NavigationLink(value: item) { PortRow(item: item) }
                        }
                    } header: {
                        GroupHeader(title: group.title, description: group.description)
                    }
                }
            }
        }
        .navigationDestination(for: PortItem.self) { item in
            PortDetail(item: item, state: state)
        }
    }
}

/// A section title with its one-line explanation, shared by the tabs.
struct GroupHeader: View {
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(nil)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 8)
    }
}

private struct PortRow: View {
    let item: PortItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(item.port))
                .font(.body.monospacedDigit())
                .frame(width: 52, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.processName)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var subtitle: String {
        var parts = [item.proto.rawValue.uppercased(), item.binding.text]
        if let signature = item.signature { parts.append(signature.summary) }
        return parts.joined(separator: " · ")
    }
}

private struct PortDetail: View {
    let item: PortItem
    let state: AppState
    @State private var actionError: String?

    /// Whether the port is still in the latest snapshot. The facts shown are the ones
    /// from when the row was opened; a port that closed stays readable.
    private var isGone: Bool {
        guard let snapshot = state.ports.snapshot else { return false }
        return !snapshot.items.contains { $0.id == item.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(item.processName) on \(String(item.port)) \(item.proto.rawValue.uppercased())").font(.headline)
                if isGone {
                    Text("No longer listening.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                FactsGrid(facts: item.facts)
                Divider()
                ExplainSection(request: ExplainRequest(kind: .port, key: item.explainKey, facts: item.facts, isApplesProgram: item.isApplesProgram, identity: item.identity), whyHere: item.whyHere(gone: isGone), state: state)
                Divider()
                HStack {
                    if let path = item.process?.path {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    }
                    Spacer()
                    if isGone {
                        EmptyView()
                    } else if ProcessControl.canQuit(uid: item.uid) {
                        Button("Quit \(item.processName)") { quit() }
                    } else {
                        Text(ProcessControl.whyNoQuit(uid: item.uid)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .controlSize(.small)
                if let actionError {
                    Text(actionError).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(12)
        }
        .navigationTitle(String(item.port))
    }

    private func quit() {
        do {
            try ProcessControl.quit(pid: item.pid, uid: item.uid)
            actionError = nil
        } catch {
            actionError = String(describing: error)
            return
        }
        // Show the result sooner than the five-second cycle would.
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            await state.ports.refresh()
        }
    }
}

/// Label and value rows, shared by the detail views.
struct FactsGrid: View {
    let facts: [Fact]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(facts, id: \.name) { fact in
                GridRow {
                    Text(fact.name).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(fact.value).textSelection(.enabled)
                }
            }
        }
        .font(.callout)
    }
}

extension PortItem: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
