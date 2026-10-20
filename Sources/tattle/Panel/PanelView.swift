import SwiftUI

/// The window that drops down from the menu bar item.
struct PanelView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case network = "Network"
        case processes = "Processes"
        case ports = "Ports"
        case startup = "Startup"

        var id: String { rawValue }
    }

    let state: AppState
    @State private var tab = Tab.network
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ResourcesLine(sample: state.sampler.sample)
            Picker("Tab", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            content
                .frame(maxWidth: .infinity, minHeight: 240, alignment: .center)
            Divider()
            HStack {
                Button("Settings...") {
                    // The panel is the key window while open; it must go before the
                    // settings window takes focus, or both stay on screen.
                    NSApplication.shared.keyWindow?.close()
                    openSettings()
                }
                Spacer()
                Button("Quit Tattle") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 480)
    }

    @ViewBuilder
    private var content: some View {
        Text("\(tab.rawValue): nothing to show yet.")
            .foregroundStyle(.secondary)
    }
}

/// Shown instead of the panel when the database could not be opened.
struct StartupFailureView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tattle could not start.").font(.headline)
            Text(message).font(.callout).textSelection(.enabled)
            HStack {
                Spacer()
                Button("Quit Tattle") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 480)
    }
}
