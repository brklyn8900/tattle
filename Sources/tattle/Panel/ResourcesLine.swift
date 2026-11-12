import SwiftUI

/// CPU, memory and network at a glance, across the top of the panel.
struct ResourcesLine: View {
    let sample: ResourceSample

    var body: some View {
        HStack(spacing: 0) {
            cell("CPU", sample.cpu.formatted(.percent.precision(.fractionLength(0))), share: sample.cpu)
            line
            cell("Memory", memory.used, memory.total, share: memoryShare)
            line
            cell("In", rate(sample.bytesInPerSecond).value, rate(sample.bytesInPerSecond).unit)
            line
            cell("Out", rate(sample.bytesOutPerSecond).value, rate(sample.bytesOutPerSecond).unit)
        }
        .fixedSize(horizontal: false, vertical: true)
        .monospacedDigit()
        .background(PanelColor.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var line: some View {
        Rectangle().fill(PanelColor.line).frame(width: 1)
    }

    private var memoryShare: Double {
        sample.memory.total == 0 ? 0 : Double(sample.memory.used) / Double(sample.memory.total)
    }

    /// "11.2" and "of 16 GB": short enough for a quarter of the panel's width.
    private var memory: (used: String, total: String) {
        let gigabyte = 1_073_741_824.0
        let used = (Double(sample.memory.used) / gigabyte).formatted(.number.precision(.fractionLength(1)))
        let total = (Double(sample.memory.total) / gigabyte).formatted(.number.precision(.fractionLength(0...1)))
        return (used, "of \(total) GB")
    }

    /// The number and its unit, apart: "1.2" and "MB/s".
    private func rate(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        let text = ByteRate.full(bytesPerSecond)
        guard let space = text.lastIndex(of: " ") else { return (text, "") }
        return (String(text[..<space]), String(text[text.index(after: space)...]))
    }

    private func cell(_ label: String, _ value: String, _ unit: String = "", share: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(PanelFont.label).foregroundStyle(PanelColor.sub)
            (Text(value).fontWeight(.semibold) + Text(unit.isEmpty ? "" : " " + unit).foregroundStyle(PanelColor.sub))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let share {
                GeometryReader { geometry in
                    Capsule().fill(PanelColor.track)
                    Capsule().fill(PanelColor.meter).frame(width: geometry.size.width * min(max(share, 0), 1))
                }
                .frame(height: 3)
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}
