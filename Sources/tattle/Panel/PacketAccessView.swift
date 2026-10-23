import SwiftUI

/// Installing and removing the packet-access broker (ADR-0003): what it does, in plain
/// words, and the exact launch daemon that goes in, before the administrator dialog.
/// Pushed inside the panel; the work and its outcome live in the observer, because the
/// dialog takes focus and closes the panel.
struct PacketAccessView: View {
    /// What the Network tab pushes to get here.
    struct Destination: Hashable {}

    let state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let network = state.network
        let broker = network.broker
        let capturing = if case .capturing = network.captureStatus { true } else { false }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Packet access").font(.headline)
                Text(CaptureBroker.installExplanation)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(statusText(network.captureStatus))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let explanation = Self.explanation(broker.installation, capturing: capturing) {
                    Text(explanation)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = network.accessError {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack {
                    if let label = Self.installLabel(broker.installation) {
                        Button(label) { run(network.installBroker) }
                            .disabled((try? broker.proposed.get()) == nil)
                    }
                    if broker.installation != .absent {
                        Button("Remove") { run(network.removeBroker) }
                    }
                    if network.accessBusy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                .controlSize(.small)
                .disabled(network.accessBusy)
                Divider()
                switch broker.proposed {
                case .success(let plist):
                    caption(broker.installation == .current ? "Installed as \(CaptureBroker.plistPath):" : "What will be installed, at \(CaptureBroker.plistPath):")
                    plistText(plist)
                case .failure(let error):
                    Text(error.text).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if let installed = broker.installed {
                    caption("Installed now:")
                    plistText(installed)
                }
            }
            .padding(12)
        }
        .navigationTitle("Packet access")
        .onAppear { network.refreshBroker() }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func plistText(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusText(_ status: Sniffer.Status) -> String {
        switch status {
        case .capturing(let interface): "Capturing on \(interface)\(CaptureBroker.isReachable ? " through the broker" : "")."
        case .unavailable(let error): "Not capturing: \(error.text)."
        case .stopped: "Not capturing."
        }
    }

    /// Back to the tab when it worked; the tab's header says what changed.
    private func run(_ action: @escaping () async -> Bool) {
        Task {
            let done = await action()
            await state.startup.refresh()
            if done { dismiss() }
        }
    }

    // MARK: Words for each state

    /// The Network tab's link here.
    static func linkTitle(_ installation: CaptureBroker.Installation) -> String {
        switch installation {
        case .absent: "Allow packet access"
        case .current: "Packet access"
        case .stale: "Packet access: install again"
        }
    }

    /// The Network tab's sentence when it has no names.
    static func namesOff(_ installation: CaptureBroker.Installation) -> String {
        if case .stale = installation { return "Destinations are addresses: the packet-access broker on this Mac does not serve this copy of Tattle" }
        return "Destinations are addresses: names need packet access, which Tattle does not have yet"
    }

    /// What is wrong with the installed broker, when something is.
    static func explanation(_ installation: CaptureBroker.Installation, capturing: Bool) -> String? {
        guard case .stale(let staleness) = installation else { return nil }
        return switch staleness {
        case .otherBuild where capturing: "The installed broker is from another build of Tattle. It still serves this one; install it again to update it."
        case .otherBuild: "The installed broker is from another build of Tattle. Install it again so it recognises this one."
        case .otherUser(let uid): "The installed broker serves another account on this Mac (user ID \(uid)), so it refuses this one. Installing it here replaces theirs."
        case .incomplete: "The packet-access broker is only partly installed and cannot run. Install it again, or remove what is left."
        case .notLoaded: "The packet-access broker is installed but not running. Install it again to start it."
        }
    }

    /// The install button's label; none when this build's broker is installed and running.
    static func installLabel(_ installation: CaptureBroker.Installation) -> String? {
        switch installation {
        case .absent: "Install"
        case .current: nil
        case .stale(.otherUser): "Install for this account"
        case .stale: "Install again"
        }
    }
}
