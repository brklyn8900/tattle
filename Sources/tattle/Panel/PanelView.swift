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
            ResourcesLine(sample: state.panelSample)
            Picker("Tab", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            NavigationStack {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 440)
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
        .background(WindowOnScreenReader { state.panelIsShowing = $0 })
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .startup:
            StartupTab(state: state)
        case .ports:
            PortsTab(state: state)
        case .processes:
            ProcessesTab(state: state)
        case .network:
            NetworkTab(state: state)
        }
    }
}

/// Reports when the window this view is in goes on or off screen. Follows occlusion rather than
/// key status: another app taking focus without a click takes key from the panel, and the panel
/// stays on screen.
private struct WindowOnScreenReader: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> ReaderView { ReaderView(onChange: onChange) }
    func updateNSView(_ view: ReaderView, context: Context) { view.onChange = onChange }

    final class ReaderView: NSView {
        var onChange: @MainActor (Bool) -> Void
        private var observers: [NSObjectProtocol] = []

        init(onChange: @escaping @MainActor (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used from a nib") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            for observer in observers { center.removeObserver(observer) }
            observers = []
            guard let window else { return }
            observers = [
                center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reportOcclusion() }
                },
                center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reportIfOnScreen() }
                },
            ]
            reportIfOnScreen()
        }

        private func reportOcclusion() {
            guard let window else { return }
            onChange(window.occlusionState.contains(.visible))
        }

        /// Recovers a change that went unreported, so the panel cannot stay frozen on screen.
        /// Only ever reports on screen: on an ordinary open the window still reads as occluded
        /// at both of these moments, and the occlusion notification follows.
        private func reportIfOnScreen() {
            if window?.occlusionState.contains(.visible) == true { onChange(true) }
        }
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
