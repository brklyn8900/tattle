import SwiftUI

@main
struct TattleApp: App {
    private let sampler = ResourceSampler()

    init() {
        sampler.start()
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(sampler: sampler)
        } label: {
            MenuBarLabel(sampler: sampler)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar item: the eye plus live throughput in and out.
struct MenuBarLabel: View {
    let sampler: ResourceSampler

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "eye")
            Text(label)
                .font(.system(size: 11).monospacedDigit())
        }
    }

    private var label: String {
        let sample = sampler.sample
        return "\u{2193}\(ByteRate.compact(sample.bytesInPerSecond)) \u{2191}\(ByteRate.compact(sample.bytesOutPerSecond))"
    }
}
