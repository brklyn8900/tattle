import SwiftUI

struct StartupTab: View {
    let state: AppState

    var body: some View {
        Group {
            if let snapshot = state.startup.snapshot {
                StartupList(snapshot: snapshot, state: state)
            } else {
                ProgressView("Reading startup items")
            }
        }
        .task(id: state.panelIsShowing) {
            // Read each time the list comes on screen, like Ports and Processes; the last
            // reading stays up meanwhile. Startup items rarely change under it, so not again
            // while it is watched.
            guard state.panelIsShowing else { return }
            await state.startup.refresh()
        }
    }
}

private struct StartupList: View {
    let snapshot: StartupSnapshot
    let state: AppState

    var body: some View {
        List {
            if let error = snapshot.loginItemsError {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(error)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        if snapshot.loginItemsNeedFullDiskAccess {
                            Button("Open Full Disk Access Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
            ForEach(StartupItem.Group.allCases, id: \.self) { group in
                let items = snapshot.items(in: group)
                if !items.isEmpty {
                    Section {
                        ForEach(items) { item in
                            NavigationLink(value: item) { StartupRow(item: item) }
                        }
                    } header: {
                        GroupHeader(title: group.title, description: group.description)
                    }
                }
            }
            Section {
                HStack {
                    Text("Apple")
                    Spacer()
                    Text("\(snapshot.appleCount) system jobs")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationDestination(for: StartupItem.self) { item in
            StartupDetail(item: item, state: state)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button {
                    Task { await state.startup.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(state.startup.isLoading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
}

private struct StartupRow: View {
    let item: StartupItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(item.state.isActive ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var subtitle: String {
        var parts = [item.trigger, item.state.text]
        if let signature = item.signature { parts.append(signature.summary) }
        else if let developer = item.developer { parts.append(developer) }
        return parts.joined(separator: " · ")
    }
}

private struct StartupDetail: View {
    let item: StartupItem
    let state: AppState
    @State private var actionError: String?

    /// The row as it is after a refresh, so an action's effect shows without going back; the
    /// one opened stays readable once it is gone.
    private var current: StartupItem? {
        state.startup.snapshot?.items.first { $0.id == item.id }
    }

    var body: some View {
        let item = current ?? self.item
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(item.name).font(.headline)
                if current == nil {
                    Text("No longer installed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                FactsGrid(facts: item.facts)
                Divider()
                if item.canExplain {
                    ExplainSection(request: ExplainRequest(kind: .launchItem, key: item.explainKey, facts: item.facts, identity: item.identity), state: state)
                    Divider()
                }
                HStack {
                    if let plist = item.plistURL {
                        Button(item.isUnlistedFolder ? "Reveal Folder" : "Reveal Plist") { NSWorkspace.shared.activateFileViewerSelecting([plist]) }
                    }
                    if item.isLoginItem {
                        Button("Login Items Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    Spacer()
                    if current != nil { controls(item) }
                }
                .controlSize(.small)
                if let actionError {
                    Text(actionError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
        }
        .navigationTitle(item.name)
    }

    @ViewBuilder
    private func controls(_ item: StartupItem) -> some View {
        if let scope = item.launchdScope, let plist = item.plistURL {
            if item.isCaptureBroker {
                // Removed through the administrator dialog.
                Button("Remove") {
                    actionError = nil
                    Task {
                        if await !state.network.removeBroker() { actionError = state.network.accessError }
                        await state.startup.refresh()
                    }
                }
                .disabled(state.network.accessBusy)
            } else if !Launchctl.canControl(scope) {
                Text("Loading or unloading a daemon needs root").font(.caption).foregroundStyle(.secondary)
            } else {
                switch item.state {
                case .notLoaded:
                    Button("Load") { perform { try Launchctl.load(plist: plist, in: item.launchDomain) } }
                case .running, .idle:
                    Button("Unload") { perform { try Launchctl.unload(label: item.id, in: item.launchDomain) } }
                case .disabled, .placeholder, .enabled, .off, .unreadable, .unlisted:
                    EmptyView()
                }
            }
        }
    }

    /// Off the main thread: removing the broker waits on the administrator dialog.
    private func perform(_ action: @escaping @Sendable () throws -> Void) {
        actionError = nil
        Task {
            do {
                try await Task.detached { try action() }.value
                await state.startup.refresh()
            } catch Launchctl.ControlError.failed(_, let message) {
                actionError = message
            } catch {
                actionError = String(describing: error)
            }
        }
    }
}

extension StartupItem: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
