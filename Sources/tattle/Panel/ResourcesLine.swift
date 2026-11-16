import SwiftUI

/// CPU, memory and network at a glance, across the top of the panel.
struct ResourcesLine: View {
    let sample: ResourceSample

    var body: some View {
        if #available(macOS 26.0, *) {
            // From macOS 26 the four readings lie on the glass itself, the numerals first.
            // Four columns of one width. The numerals keep one size, so they share a baseline
            // and the two meters a line; a memory total too wide for its column ("of 128 GB" beside
            // "101.9") is written shorter ("/128 GB") and shrinks, the numeral never does.
            HStack(alignment: .top, spacing: 14) {
                stat("CPU", sample.cpu.formatted(.percent.precision(.fractionLength(0))), share: sample.cpu)
                    .help(Self.allCoresHelp)
                stat("Memory", memory.used, memory.total, shortUnit: memoryShortTotal, share: memoryShare)
                stat("In", rate(sample.bytesInPerSecond).value, rate(sample.bytesInPerSecond).unit, symbol: "arrow.down")
                stat("Out", rate(sample.bytesOutPerSecond).value, rate(sample.bytesOutPerSecond).unit, symbol: "arrow.up")
            }
            .padding(.horizontal, 10)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            flat
        }
    }

    /// The two CPU figures use different scales, as Activity Monitor's do: the Mac's is all
    /// cores together, a row's is a share of one core.
    private static let cores = ProcessInfo.processInfo.activeProcessorCount
    static let allCoresHelp = "All \(cores) cores together. 100% is every core fully used."
    static let perCoreHelp = "Share of one core. 100% is one core fully used; this Mac has \(cores)."

    /// One reading: what it is, its number, and a meter when it is a share of a whole.
    private func stat(_ label: String, _ value: String, _ unit: String = "", shortUnit: String? = nil, share: Double? = nil, symbol: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 9, weight: .bold)).accessibilityHidden(true)
                }
                Text(label)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .fixedSize()
                if !unit.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        Text(unit)
                        Text(shortUnit ?? unit).minimumScaleFactor(0.7)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            if let share {
                GeometryReader { geometry in
                    Capsule().fill(.primary.opacity(0.12))
                    Capsule().fill(.tint).frame(width: max(4, geometry.size.width * min(max(share, 0), 1)))
                }
                .frame(height: 4)
                .padding(.top, 1)
                .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // One static text, as the flat line's cells are, with the full unit: "Memory, 11.2 of 16 GB".
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)\(unit.isEmpty ? "" : " " + unit)")
    }

    /// The line before macOS 26: one bar of four cells.
    private var flat: some View {
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

    /// The total written short, "/128 GB", for a column too narrow for "of 128 GB".
    private var memoryShortTotal: String {
        let total = (Double(sample.memory.total) / 1_073_741_824.0).formatted(.number.precision(.fractionLength(0...1)))
        return "/\(total) GB"
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
