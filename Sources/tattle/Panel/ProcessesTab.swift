import SwiftUI

struct ProcessesTab: View {
    let state: AppState
    @State private var sort = ProcessSnapshot.Sort.memory

    var body: some View {
        Group {
            if let snapshot = state.processes.snapshot {
                VStack(alignment: .leading, spacing: 0) {
                    // A reading that failed leaves the last one on screen.
                    if let error = state.processes.error {
                        Text("The processes could not be read, so this list is from \(snapshot.takenAt.formatted(date: .omitted, time: .standard)). \(error)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    ProcessesList(snapshot: snapshot, sort: $sort, state: state)
                }
            } else if let error = state.processes.error {
                Text(error).foregroundStyle(.secondary)
            } else {
                ProgressView("Reading processes")
            }
        }
        .task(id: state.panelIsShowing) {
            guard state.panelIsShowing else { return }
            state.processes.beginReadings()
            // Memory moves and CPU is a difference between readings, so the list is
            // kept current while it is on screen. The first reading has no CPU, so the
            // next one follows after a second rather than a whole cycle.
            await state.processes.refresh()
            try? await Task.sleep(for: .seconds(1))
            while !Task.isCancelled {
                await state.processes.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

private struct ProcessesList: View {
    let snapshot: ProcessSnapshot
    @Binding var sort: ProcessSnapshot.Sort
    let state: AppState

    var body: some View {
        List {
            Section {
                ForEach(snapshot.groups(sortedBy: sort)) { group in
                    NavigationLink(value: group) { GroupRow(group: group) }
                }
            } header: {
                // The sort control sits in the header: a bottom strip would cover the
                // rows scrolling under it.
                HStack(alignment: .top) {
                    GroupHeader(
                        title: "\(snapshot.groups.count) apps and programs, \(snapshot.items.count) processes",
                        description: "Each app with its helpers, each program with what it started. Everything that is part of macOS is one row.")
                    Picker("Sort by", selection: $sort) {
                        ForEach(ProcessSnapshot.Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 130)
                }
            }
        }
        .navigationDestination(for: ProcessGroup.self) { group in
            if group.members.count == 1, let only = group.members.first {
                ProcessDetail(item: only, state: state)
            } else {
                GroupDetail(group: group, state: state)
            }
        }
        .navigationDestination(for: ProcessItem.self) { item in
            ProcessDetail(item: item, state: state)
        }
    }
}

/// Name on the left, memory and CPU in fixed columns on the right.
private struct UsageColumns: View {
    let memoryBytes: UInt64
    let cpu: Double?

    var body: some View {
        HStack(spacing: 8) {
            Text(ProcessItem.memoryText(memoryBytes))
                .frame(width: 72, alignment: .trailing)
            Text(cpu.map(ProcessItem.cpuText) ?? "\u{2013}")
                .frame(width: 48, alignment: .trailing)
        }
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

private struct GroupRow: View {
    let group: ProcessGroup

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
            UsageColumns(memoryBytes: group.memoryBytes, cpu: group.cpu)
        }
    }

    private var subtitle: String {
        var parts = [group.members.count == 1 ? "1 process" : "\(group.members.count) processes"]
        if group.kind == .process, let leader = group.leader, let text = leader.signerText { parts.append(text) }
        else if let signature = group.signature { parts.append(signature.summary) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

private struct ProcessRow: View {
    let item: ProcessItem
    var depth = 0
    var showsDirectory = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                Text("pid \(String(item.pid))" + (item.signerText.map { " \u{00B7} \($0)" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if showsDirectory, let directory = item.workingDirectoryText {
                    // The end of the path is the part that tells copies apart.
                    Text(directory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .padding(.leading, CGFloat(min(depth, 6)) * 14)
            Spacer()
            UsageColumns(memoryBytes: item.memoryBytes, cpu: item.cpu)
        }
    }
}

private struct GroupDetail: View {
    let group: ProcessGroup
    let state: AppState
    @State private var actionError: String?

    /// The group as it is now; the one opened stays readable once it is gone.
    private var current: ProcessGroup? { state.processes.snapshot?.group(id: group.id) }

    var body: some View {
        let group = current ?? self.group
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(group.name).font(.headline)
                if current == nil {
                    Text("No longer running.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                FactsGrid(facts: group.facts)
                if let key = group.explainKey {
                    Divider()
                    ExplainSection(request: ExplainRequest(kind: .process, key: key, facts: group.facts, isApplesProgram: group.isApplesProgram, identity: group.identity), whyHere: group.whyHere(gone: current == nil), state: state)
                }
                Divider()
                HStack {
                    if let path = group.path {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    }
                    Spacer()
                    if current != nil, let leader = group.leader {
                        QuitControls(item: leader, name: group.name, state: state, error: $actionError)
                    }
                }
                .controlSize(.small)
                if let actionError {
                    Text(actionError).font(.caption).foregroundStyle(.red)
                }
                Divider()
                Text(group.kind == .system ? "What macOS is running" : "Processes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(group.tree, id: \.item.pid) { entry in
                        NavigationLink(value: entry.item) {
                            ProcessRow(item: entry.item, depth: entry.depth, showsDirectory: entry.showsDirectory).padding(.vertical, 4)
                        }
                            .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            .padding(12)
        }
        .navigationTitle(group.name)
    }
}

private struct ProcessDetail: View {
    let item: ProcessItem
    let state: AppState
    @State private var actionError: String?

    /// The process as it is now, so memory and CPU move; a pid reused by a new process
    /// counts as gone.
    private var current: ProcessItem? {
        guard let now = state.processes.snapshot?.item(pid: item.pid),
              abs(now.started.timeIntervalSince(item.started)) < 1 else { return nil }
        return now
    }

    var body: some View {
        let item = current ?? self.item
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(item.name).font(.headline)
                if current == nil {
                    Text("No longer running.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                FactsGrid(facts: item.facts)
                Divider()
                ExplainSection(request: ExplainRequest(kind: .process, key: item.explainKey, facts: item.facts, isApplesProgram: item.isApplesProgram, identity: item.identity), whyHere: item.whyHere(gone: current == nil), state: state)
                Divider()
                HStack {
                    if let path = item.path {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    }
                    Spacer()
                    if current != nil {
                        QuitControls(item: item, name: item.name, state: state, error: $actionError)
                    }
                }
                .controlSize(.small)
                if let actionError {
                    Text(actionError).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(12)
        }
        .navigationTitle(item.name)
    }
}

/// Quit, and Force Quit behind a second click, for the user's own processes.
private struct QuitControls: View {
    let item: ProcessItem
    let name: String
    let state: AppState
    @Binding var error: String?
    @State private var armed = false

    var body: some View {
        if !ProcessControl.canQuit(uid: item.uid) {
            Text(ProcessControl.whyNoQuit(uid: item.uid)).font(.caption).foregroundStyle(.secondary)
        } else if armed {
            Text("Unsaved work is lost.").font(.caption).foregroundStyle(.secondary)
            Button("Cancel") { armed = false }
            Button("Force Quit \(name)", role: .destructive) {
                armed = false
                perform { try ProcessControl.forceQuit(pid: item.pid, uid: item.uid) }
            }
        } else {
            Button("Quit \(name)") { perform { try ProcessControl.quit(pid: item.pid, uid: item.uid) } }
            Button("Force Quit...") { armed = true }
        }
    }

    private func perform(_ action: @MainActor () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = String(describing: error)
            return
        }
        // Show the result sooner than the three-second cycle would.
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            await state.processes.refresh()
        }
    }
}

extension ProcessGroup: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension ProcessItem: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(pid) }
}
