import Foundation

/// What launchd currently says about its jobs, read through `launchctl print` for the
/// user's GUI domain and the system domain. Both work without privileges.
struct LaunchctlState: Equatable, Sendable {
    struct Service: Equatable, Sendable {
        /// Running pid, nil when not running.
        var pid: Int32?
        /// Exit status of the last run, nil if it never ran.
        var lastExitStatus: Int32?
    }

    /// Label to state, for every loaded job in both domains.
    var services: [String: Service]
    /// Labels with a launchd override, and whether it is disabled.
    var overrides: [String: Bool]

    static func read() -> LaunchctlState {
        let uid = getuid()
        var state = LaunchctlState(services: [:], overrides: [:])
        for domain in ["gui/\(uid)", "system"] {
            state.services.merge(parseServices(run(["print", domain]))) { _, new in new }
            state.overrides.merge(parseOverrides(run(["print-disabled", domain]))) { _, new in new }
        }
        return state
    }

    /// The `services = { pid status label }` block of `launchctl print <domain>`.
    static func parseServices(_ output: String) -> [String: Service] {
        var services: [String: Service] = [:]
        var inBlock = false
        for line in output.split(separator: "\n") {
            if line.hasSuffix("services = {") { inBlock = true; continue }
            guard inBlock else { continue }
            if line.trimmingCharacters(in: .whitespaces) == "}" { break }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 3 else { continue }
            let pid = Int32(fields[0]).flatMap { $0 > 0 ? $0 : nil }
            services[String(fields[2])] = Service(pid: pid, lastExitStatus: Int32(fields[1]))
        }
        return services
    }

    /// The `"label" => disabled|enabled` lines of `launchctl print-disabled <domain>`.
    static func parseOverrides(_ output: String) -> [String: Bool] {
        var overrides: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), let close = trimmed.dropFirst().firstIndex(of: "\"") else { continue }
            let label = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            if trimmed.hasSuffix("=> disabled") { overrides[label] = true }
            else if trimmed.hasSuffix("=> enabled") { overrides[label] = false }
        }
        return overrides
    }

    private static func run(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
