import Foundation

/// Formats a bytes-per-second rate.
enum ByteRate {
    /// Menu bar form, decimal units, at most four characters: 0, 512, 12K, 1.2M, 3.4G.
    static func compact(_ bytesPerSecond: Double) -> String {
        let value = max(bytesPerSecond, 0)
        if value < 1000 { return String(Int(value)) }
        let units = ["K", "M", "G", "T"]
        var scaled = value
        var unit = -1
        while scaled >= 1000 && unit < units.count - 1 {
            scaled /= 1000
            unit += 1
        }
        let digits = scaled < 10 ? 1 : 0
        return scaled.formatted(.number.precision(.fractionLength(digits))) + units[unit]
    }

    /// Panel form, decimal units: 981 B/s, 12 kB/s, 1.2 MB/s.
    static func full(_ bytesPerSecond: Double) -> String {
        let value = Int64(max(bytesPerSecond, 0))
        if value < 1000 { return "\(value) B/s" }
        return value.formatted(.byteCount(style: .decimal)) + "/s"
    }
}
