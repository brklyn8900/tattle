import SwiftUI

@main
struct TattleApp: App {
    private let state: AppState?
    private let startupError: String?

    init() {
        do {
            let state = try AppState(database: try AppDatabase.openDefault())
            state.sampler.start()
            state.network.start()
            state.settings.appearance.apply()
            self.state = state
            startupError = nil
        } catch {
            Log.app.error("startup failed: \(error, privacy: .public)")
            state = nil
            startupError = String(describing: error)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            if let state {
                PanelView(state: state)
            } else {
                StartupFailureView(message: startupError ?? "Unknown error.")
            }
        } label: {
            if let state {
                MenuBarLabel(sampler: state.sampler, settings: state.settings)
            } else {
                Image(systemName: "eye.slash")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            if let state {
                SettingsView(settings: state.settings, explainer: state.explainer)
                    .onChange(of: state.settings.appearance) { _, appearance in appearance.apply() }
            }
        }
    }
}

private extension Appearance {
    /// Sets the look of every window of the app; nil follows macOS.
    @MainActor func apply() {
        NSApplication.shared.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// The menu bar item: the eye, with live throughput in and out when the setting is on.
struct MenuBarLabel: View {
    let sampler: ResourceSampler
    let settings: AppSettings

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "eye")
            if settings.showThroughputInMenuBar {
                Text(label)
                    .font(.system(size: 11).monospacedDigit())
            }
        }
    }

    private var label: String {
        let sample = sampler.sample
        return "\u{2193}\(ByteRate.compact(sample.bytesInPerSecond)) \u{2191}\(ByteRate.compact(sample.bytesOutPerSecond))"
    }
}
