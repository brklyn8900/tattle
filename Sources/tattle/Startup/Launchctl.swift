import Foundation

/// What launchd currently says about its jobs, read through `launchctl print` for the
/// user's two domains and the system one. All work without privileges. A label names a job
/// within one domain, so they are kept apart.
struct LaunchctlState: Equatable, Sendable {
    struct Service: Equatable, Sendable {
        /// Running pid, nil when not running.
        var pid: Int32?
        /// Exit status of the last run, nil if it never ran.
        var lastExitStatus: Int32?
    }

    struct Domain: Equatable, Sendable {
        /// Label to state, for every job loaded in the domain.
        var services: [String: Service] = [:]
        /// Labels with a launchd override, and whether it is disabled.
        var overrides: [String: Bool] = [:]
    }

    /// `gui/<uid>`: agents of the logged-in session.
    var gui = Domain()
    /// `user/<uid>`: agents limited to the Background session.
    var user = Domain()
    var system = Domain()

    static func read() -> LaunchctlState {
        func domain(_ name: String) -> Domain {
            Domain(services: parseServices(run(["print", name])), overrides: parseOverrides(run(["print-disabled", name])))
        }
        return LaunchctlState(gui: domain(LaunchDomain.gui.name), user: domain(LaunchDomain.user.name), system: domain(LaunchDomain.system.name))
    }

    subscript(_ domain: LaunchDomain) -> Domain {
        switch domain {
        case .gui: gui
        case .user: user
        case .system: system
        }
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
        (try? Launchctl.run(arguments))?.stdout ?? ""
    }
}

/// Where launchd keeps a job.
enum LaunchDomain: Equatable, Sendable {
    case gui, user, system

    var name: String {
        switch self {
        case .gui: "gui/\(getuid())"
        case .user: "user/\(getuid())"
        case .system: "system"
        }
    }
}

/// Loading and unloading jobs in the user's domains. Daemons live in the system domain,
/// which needs root, so they are not offered.
enum Launchctl {
    enum ControlError: Error, Equatable {
        case failed(status: Int32, message: String)
    }

    static func load(plist: URL, in domain: LaunchDomain = .gui) throws {
        try check(run(["bootstrap", domain.name, plist.path]))
    }

    static func unload(label: String, in domain: LaunchDomain = .gui) throws {
        try check(run(["bootout", domain.name + "/" + label]))
    }

    static func canControl(_ scope: LaunchdItem.Scope) -> Bool {
        scope != .daemon
    }

    private static func check(_ result: (status: Int32, stdout: String, stderr: String)) throws {
        guard result.status == 0 else {
            let message = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ControlError.failed(status: result.status, message: message)
        }
    }

    static func run(_ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
    }
}
