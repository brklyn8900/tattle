import SwiftUI

/// CPU, memory and network at a glance, across the top of the panel.
struct ResourcesLine: View {
    let sample: ResourceSample

    var body: some View {
        HStack(spacing: 16) {
            item("CPU", sample.cpu.formatted(.percent.precision(.fractionLength(0))))
            item("Memory", memory)
            item("In", ByteRate.full(sample.bytesInPerSecond))
            item("Out", ByteRate.full(sample.bytesOutPerSecond))
        }
        .font(.callout)
        .monospacedDigit()
    }

    private var memory: String {
        let used = Int64(sample.memory.used).formatted(.byteCount(style: .memory))
        let total = Int64(sample.memory.total).formatted(.byteCount(style: .memory))
        return "\(used) of \(total)"
    }

    private func item(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}
