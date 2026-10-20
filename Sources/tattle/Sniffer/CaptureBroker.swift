import CPacketCapture
import Foundation
import Security

/// The packet-access broker (ADR-0003): a root launch daemon that opens a capture device
/// for this app and nothing else. This is what the app knows about it: where it lives,
/// how it is installed and removed through the administrator dialog, and how to ask it
/// for a descriptor.
enum CaptureBroker {
    static let label = "io.github.eladefrati.tattle.capture-broker"
    static let socketPath = "/var/run/tattle-capture-broker.sock"
    static let helperPath = "/Library/PrivilegedHelperTools/io.github.eladefrati.tattle.capture-broker"
    static let plistPath = "/Library/LaunchDaemons/io.github.eladefrati.tattle.capture-broker.plist"
    static let appIdentifier = "io.github.eladefrati.tattle"

    enum RequestError: Error, Equatable {
        /// The broker did not accept this app: a rebuilt ad-hoc app, or someone else's.
        case refused
        case badRequest
        case openFailed(errno: Int32)
        /// The broker could not be reached.
        case transport(errno: Int32)

        var text: String {
            switch self {
            case .refused: "the packet-access broker does not recognise this build of Tattle; remove and install it again"
            case .badRequest: "the packet-access broker rejected the request"
            case .openFailed(let code): "the packet-access broker could not open a capture device: \(String(cString: strerror(code)))"
            case .transport(let code): "the packet-access broker did not answer: \(String(cString: strerror(code)))"
            }
        }
    }

    enum InstallError: Error, Equatable {
        case noHelperInBundle
        case noRequirement
        /// The administrator dialog was cancelled or the script failed; the message is
        /// osascript's.
        case failed(String)
    }

    /// The broker binary beside the app's own.
    static var bundledHelper: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "tattle-capture-broker")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistPath) }
    static var isReachable: Bool { FileManager.default.fileExists(atPath: socketPath) }

    // MARK: Requirement

    /// The code requirement the broker checks callers against. With an Apple identity it
    /// is the team and the bundle identifier, which survive certificate renewal and
    /// rebuilds; ad hoc, it is the code hash, which changes with every rebuild.
    static func requirement(identifier: String?, team: String?, cdhash: Data?) -> String? {
        if let team, !team.isEmpty {
            return "anchor apple generic and identifier \"\(identifier ?? appIdentifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        }
        guard let cdhash, !cdhash.isEmpty else { return nil }
        return "cdhash H\"\(cdhash.map { String(format: "%02x", $0) }.joined())\""
    }

    /// The requirement for the running app, from its own signature.
    static func requirementForSelf() -> String? {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let code = selfCode else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let fixed = staticCode else { return nil }
        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(fixed, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else { return nil }
        return requirement(identifier: info[kSecCodeInfoIdentifier as String] as? String,
                           team: info[kSecCodeInfoTeamIdentifier as String] as? String,
                           cdhash: info[kSecCodeInfoUnique as String] as? Data)
    }

    // MARK: Install and remove

    /// The launch daemon as installed: the requirement travels in the root-owned plist,
    /// where only an administrator can change it.
    static func plist(requirement: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(helperPath)</string>
                <string>--requirement</string>
                <string>\(escapeXML(requirement))</string>
            </array>
            <key>Sockets</key>
            <dict>
                <key>Listener</key>
                <dict>
                    <key>SockPathName</key>
                    <string>\(socketPath)</string>
                    <key>SockPathMode</key>
                    <integer>438</integer>
                </dict>
            </dict>
        </dict>
        </plist>

        """
    }

    /// What the administrator dialog runs, in plain words for the person reading it.
    static let installExplanation = """
        Names for connections come from the first packets of each one, which only a root \
        process may read. Tattle installs a small daemon that opens the capture device \
        read-only and hands it to Tattle, and to nothing else: it checks the signature of \
        whoever asks. The daemon has no other function, keeps nothing, and is removed with \
        one click here or from the Startup tab. The packet devices themselves stay root-only.
        """

    static func installScript(helper: String, plistSource: String) -> String {
        """
        set -e
        mkdir -p /Library/PrivilegedHelperTools
        cp \(shell(helper)) \(shell(helperPath))
        chown root:wheel \(shell(helperPath))
        chmod 755 \(shell(helperPath))
        cp \(shell(plistSource)) \(shell(plistPath))
        chown root:wheel \(shell(plistPath))
        chmod 644 \(shell(plistPath))
        launchctl bootout system/\(label) 2>/dev/null || true
        launchctl bootstrap system \(shell(plistPath))
        """
    }

    static var removeScript: String {
        """
        launchctl bootout system/\(label) 2>/dev/null || true
        rm -f \(shell(plistPath)) \(shell(helperPath)) \(shell(socketPath))
        """
    }

    /// Writes the plist as the user, then installs it and the helper as root through the
    /// administrator dialog. Returns the plist text that was installed.
    @discardableResult
    static func install(helper: URL? = bundledHelper, requirement: String? = requirementForSelf(),
                        runPrivileged: (String) throws -> Void = runPrivileged) throws -> String {
        guard let helper, FileManager.default.fileExists(atPath: helper.path) else { throw InstallError.noHelperInBundle }
        guard let requirement else { throw InstallError.noRequirement }
        let text = plist(requirement: requirement)
        let staging = FileManager.default.temporaryDirectory.appending(path: "\(label).plist")
        try text.write(to: staging, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: staging) }
        try runPrivileged(installScript(helper: helper.path, plistSource: staging.path))
        return text
    }

    static func remove(runPrivileged: (String) throws -> Void = runPrivileged) throws {
        try runPrivileged(removeScript)
    }

    /// Runs a shell script as root after the administrator password dialog.
    static func runPrivileged(_ script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \(appleScript(script)) with administrator privileges"]
        let err = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = err
        try process.run()
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.failed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: Request

    /// Asks the installed broker for a capture descriptor bound to `interface`.
    static func request(interface: String, socket: String = socketPath) throws -> Int32 {
        var status: Int32 = -1
        var code: Int32 = 0
        let fd = tattle_broker_request(socket, interface, &status, &code)
        if fd >= 0 { return fd }
        switch status {
        case 1: throw RequestError.refused
        case 2: throw RequestError.badRequest
        case 3: throw RequestError.openFailed(errno: code)
        default: throw RequestError.transport(errno: code)
        }
    }

    // MARK: Quoting

    static func shell(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func appleScript(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
