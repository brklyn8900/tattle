import Foundation

/// What launchd currently says about its jobs, read through `launchctl print` for the
/// user's two domains and the system one. All work without privileges. A label names a job
/// within one domain, so they are kept apart.
struct LaunchctlState: Equatable, Sendable {
    struct Service: Equatable, Sendable {
        var pid: Int32?
        /// Exit status of the last run, nil if it never ran.
        var lastExitStatus: Int32?
    }

    struct Domain: Equatable, Sendable {
        /// Label to state, for every job loaded in the domain.
        var services: [String: Service] = [:]
        /// Labels with a launchd override, and whether it is disabled.
        var overrides: [String: Bool] = [:]
        /// Why the domain could not be read, nil when it was: its jobs' state is then not known.
        var unread: String? = nil
    }

    /// `gui/<uid>`: agents of the logged-in session.
    var gui = Domain()
    /// `user/<uid>`: agents limited to the Background session.
    var user = Domain()
    var system = Domain()

    static func read() -> LaunchctlState {
        // One run per domain: `print` ends with the overrides `print-disabled` lists.
        func read(_ domain: LaunchDomain) -> Domain {
            Self.domain(domain.name, printed: try? Launchctl.run(["print", domain.name]))
        }
        return LaunchctlState(gui: read(.gui), user: read(.user), system: read(.system))
    }

    /// A domain from what `launchctl print <name>` gave; `result` is nil when it could not start.
    /// A run that fails, or prints no list of jobs, leaves the domain unread rather than empty.
    static func domain(_ name: String, printed result: (status: Int32, stdout: String, stderr: String)?) -> Domain {
        guard let result else { return Domain(unread: "launchctl could not be started") }
        guard result.status == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return Domain(unread: "launchctl print \(name) failed with status \(result.status)" + (message.isEmpty ? "" : ": \(message)"))
        }
        guard let services = parseServices(result.stdout) else { return Domain(unread: "launchctl print \(name) listed no jobs") }
        return Domain(services: services, overrides: parseOverrides(result.stdout))
    }

    subscript(_ domain: LaunchDomain) -> Domain {
        switch domain {
        case .gui: gui
        case .user: user
        case .system: system
        }
    }

    /// The `services = { pid status label }` block of `launchctl print <domain>`, nil when the
    /// output has none (`disabled services` is another block). The label is everything after
    /// the tab that follows the status, spaces and tabs included.
    static func parseServices(_ output: String) -> [String: Service]? {
        var services: [String: Service]?
        for line in output.split(separator: "\n") {
            if services == nil {
                if line.trimmingCharacters(in: .whitespaces) == "services = {" { services = [:] }
                continue
            }
            if line.trimmingCharacters(in: .whitespaces) == "}" { break }
            let fields = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 3 else { continue }
            let status = fields[1]
            let rest = line[status.endIndex...].drop { $0 == " " }
            guard rest.first == "\t", rest.count > 1 else { continue }
            let pid = Int32(fields[0]).flatMap { $0 > 0 ? $0 : nil }
            services?[String(rest.dropFirst())] = Service(pid: pid, lastExitStatus: Int32(status))
        }
        return services
    }

    /// The `"label" => disabled|enabled` lines of `launchctl print <domain>`'s
    /// `disabled services` block, which are all `launchctl print-disabled <domain>` prints.
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
