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
    @State private var installed = CaptureBroker.isInstalled
    /// Read once: the signature lookup is not for every redraw.
    private let plist: String

    init(state: AppState) {
        self.state = state
        plist = CaptureBroker.plist(requirement: (try? CaptureBroker.BuildIdentity.running().callerRequirement) ?? "(this build has no code signature to pin)", uid: getuid())
    }

    var body: some View {
        let network = state.network
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Packet access").font(.headline)
                Text(CaptureBroker.installExplanation)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(statusText(network.captureStatus))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let error = network.accessError {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack {
                    if installed {
                        Button("Remove") { run(network.removeBroker) }
                    } else {
                        Button("Install") { run(network.installBroker) }
                    }
                    if network.accessBusy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                .controlSize(.small)
                .disabled(network.accessBusy)
                Divider()
                Text(installed ? "Installed as \(CaptureBroker.plistPath):" : "What will be installed, at \(CaptureBroker.plistPath):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(plist)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
        }
        .navigationTitle("Packet access")
        .onAppear { installed = CaptureBroker.isInstalled }
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
            installed = CaptureBroker.isInstalled
            await state.startup.refresh()
            if done { dismiss() }
        }
    }
}
