import SwiftUI

@main
struct TattleApp: App {
    var body: some Scene {
        MenuBarExtra("Tattle", systemImage: "eye") {
            Text("Tattle")
            Divider()
            Button("Quit Tattle") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
