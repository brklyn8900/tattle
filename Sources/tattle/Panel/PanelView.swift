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

    let sampler: ResourceSampler
    @State private var tab = Tab.network

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ResourcesLine(sample: sampler.sample)
            Picker("Tab", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            content
                .frame(maxWidth: .infinity, minHeight: 240, alignment: .center)
            Divider()
            HStack {
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
