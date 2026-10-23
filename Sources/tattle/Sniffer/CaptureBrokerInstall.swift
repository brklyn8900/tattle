import CCodePolicy
import Foundation
import Security

/// Installing and removing the packet-access broker through the administrator dialog
/// (ADR-0003 decision 4), and the identity of this build that install pins.
extension CaptureBroker {
    enum InstallError: Error, Equatable {
        case noHelperInBundle
        /// The running app has no signature the broker could check callers against.
        case unsigned
        /// The app's executable on disk is not the code that is running: replaced or rebuilt
        /// since launch. Install would pin the wrong build, so it does not start.
        case changedOnDisk
        /// The broker would refuse this build (code_policy.h), so installing it gains nothing.
        case notHardened
        /// The administrator dialog was cancelled or the script failed; the message is
        /// osascript's.
        case failed(String)
    }

    /// Where the broker sits in the app bundle. Root installs it from its own verified copy of
    /// the bundle, at this same path.
    static let helperInBundle = "Contents/MacOS/tattle-capture-broker"

    // MARK: Identity

    /// This build of Tattle, as its signature names it. Every field is checked on the way in,
    /// so the requirements built from it compile and a crafted identifier or team cannot end
    /// the quoted string and add a clause.
    struct BuildIdentity: Equatable, Sendable {
        /// Code directory hash of the main executable.
        let cdhash: Data
        let identifier: String
        /// The Apple team when signed with an Apple identity; nil ad hoc.
        let team: String?

        /// Nil unless `cdhash` is 20 bytes, `identifier` is 1 to 255 of letters, digits, '.'
        /// and '-', and `team` is absent or 10 uppercase letters and digits.
        init?(cdhash: Data, identifier: String, team: String?) {
            func only(_ text: String, _ allowed: (Character) -> Bool) -> Bool { text.allSatisfy { $0.isASCII && allowed($0) } }
            guard cdhash.count == 20, (1...255).contains(identifier.count),
                  only(identifier, { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
            if let team, !(team.count == 10 && only(team, { $0.isUppercase || $0.isNumber })) { return nil }
            self.cdhash = cdhash
            self.identifier = identifier
            self.team = team
        }

        /// What the broker checks callers against (ADR-0003). With a team: the team and the
        /// identifier, which survive rebuilds and certificate renewal. Ad hoc: this build.
        var callerRequirement: String {
            if let team {
                return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
            }
            return buildRequirement
        }

        /// This exact build, in either signing mode.
        var buildRequirement: String { "cdhash H\"\(cdhash.map { String(format: "%02x", $0) }.joined())\"" }

        /// The running app, confirmed against the code the kernel loaded.
        static func running() throws -> BuildIdentity {
            var selfCode: SecCode?
            guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let code = selfCode else { throw InstallError.unsigned }
            return try confirmed(code)
        }

        /// Reads `code`'s signature from its file, then confirms it describes the code that is
        /// running and that the broker would answer that code. `running()` passes this app;
        /// tests pass another process.
        static func confirmed(_ code: SecCode) throws -> BuildIdentity {
            var staticCode: SecStaticCode?
            var infoRef: CFDictionary?
            guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let fixed = staticCode,
                  SecCodeCopySigningInformation(fixed, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef) == errSecSuccess,
                  let info = infoRef as? [String: Any],
                  let cdhash = info[kSecCodeInfoUnique as String] as? Data,
                  let identifier = info[kSecCodeInfoIdentifier as String] as? String
            else { throw InstallError.unsigned }
            let team = (info[kSecCodeInfoTeamIdentifier as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard let identity = BuildIdentity(cdhash: cdhash, identifier: identifier, team: team) else { throw InstallError.unsigned }
            // Any process of this user may have renamed another binary over the file since
            // launch, and the file is what was just read. The dynamic check compares against the
            // code directory the kernel loaded: a changed file fails it (errSecCSStaticCodeChanged),
            // and a file changed back since the read fails the hash.
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString("\(identity.callerRequirement) and \(identity.buildRequirement)" as CFString, [], &requirement) == errSecSuccess,
                  let requirement, SecCodeCheckValidity(code, [], requirement) == errSecSuccess
            else { throw InstallError.changedOnDisk }
            guard tattle_code_hardening(code) == TATTLE_HARDENING_OK else { throw InstallError.notHardened }
            return identity
        }
    }

    // MARK: Layout

    /// Where install and remove put things. `.system` is the only layout the app uses; tests
    /// render the same scripts against a temporary directory and a stand-in launchctl, which
    /// is how the root scripts are run without root.
    struct Layout: Sendable {
        let helperDirectory: String
        let daemonsDirectory: String
        let socketPath: String
        /// Who owns what is installed: "root:wheel", or a test's own account.
        let owner: String
        let launchctl: String

        var helperPath: String { "\(helperDirectory)/\(label)" }
        var plistPath: String { "\(daemonsDirectory)/\(label).plist" }

        static let system = Layout(helperDirectory: "/Library/PrivilegedHelperTools", daemonsDirectory: "/Library/LaunchDaemons",
                                   socketPath: CaptureBroker.socketPath, owner: "root:wheel", launchctl: "/bin/launchctl")
    }

    // MARK: Install and remove

    /// The launch daemon as installed: the requirement and the installing user travel in the
    /// root-owned plist, where only an administrator can change them.
    static func plist(requirement: String, uid: uid_t, layout: Layout = .system) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(layout.helperPath)</string>
                <string>--requirement</string>
                <string>\(escapeXML(requirement))</string>
                <string>--uid</string>
                <string>\(uid)</string>
            </array>
            <key>Sockets</key>
            <dict>
                <key>Listener</key>
                <dict>
                    <key>SockPathName</key>
                    <string>\(layout.socketPath)</string>
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

    /// The root half of install. Root reads the user's bundle once, to copy it where no
    /// process of the user can reach, and uses nothing but that copy and this text: it
    /// checks the copy against `identity`, which the app confirmed is the running code and
    /// whose seal fixes the bundled broker, then installs the broker from the copy and the
    /// plist from this text. Nothing on the system changes until the copy has passed, and a
    /// failure after the old broker was stopped removes what this install put in place.
    static func installScript(identity: BuildIdentity, bundle: URL, uid: uid_t, layout: Layout = .system) -> String {
        """
        set -eu
        umask 077
        launchctl=\(shell(layout.launchctl))
        helper=\(shell(layout.helperPath))
        plist=\(shell(layout.plistPath))
        /bin/mkdir -p -m 755 \(shell(layout.helperDirectory)) \(shell(layout.daemonsDirectory))
        /bin/rm -rf \(shell(layout.helperDirectory))/.\(label).*
        stage=$(/usr/bin/mktemp -d \(shell("\(layout.helperDirectory)/.\(label).XXXXXX")))
        replacing=0
        finish() {
            status=$?
            /bin/rm -rf "$stage"
            if [ "$status" -ne 0 ] && [ "$replacing" -eq 1 ]; then
                "$launchctl" bootout system/\(label) 2>/dev/null || true
                /bin/rm -f "$plist" "$helper"
            fi
            exit "$status"
        }
        trap finish EXIT
        \(stoppedFunction)
        /usr/bin/ditto --noextattr --noqtn --norsrc --noacl \(shell(bundle.path)) "$stage/Tattle.app"
        if [ -n "$(/usr/bin/find "$stage/Tattle.app" ! -type f ! -type d -print)" ]; then
            echo 'This copy of Tattle contains links or special files, so it cannot be checked. Nothing was installed.' >&2
            exit 3
        fi
        /usr/sbin/chown -R \(shell(layout.owner)) "$stage"
        if ! /usr/bin/codesign --verify --strict --deep \(shell("-R=\(identity.buildRequirement)")) "$stage/Tattle.app" 2>/dev/null; then
            echo 'Tattle on disk is not the Tattle that is running. Quit Tattle, open it again, and try again. Nothing was installed.' >&2
            exit 3
        fi
        new="$stage/Tattle.app/\(helperInBundle)"
        /bin/test -f "$new"
        /bin/chmod 755 "$new"
        /usr/bin/printf '%s' \(shell(plist(requirement: identity.callerRequirement, uid: uid, layout: layout))) > "$stage/plist"
        /usr/bin/plutil -lint -s "$stage/plist"
        /bin/chmod 644 "$stage/plist"
        "$launchctl" bootout system/\(label) 2>/dev/null || true
        if ! stopped; then
            echo 'The installed broker would not stop. Nothing was changed.' >&2
            exit 3
        fi
        replacing=1
        /bin/mv -f "$new" "$helper"
        /bin/mv -f "$stage/plist" "$plist"
        "$launchctl" bootstrap system "$plist"
        """
    }

    /// Stops the broker before anything is removed, and removes the plist first: without it
    /// the broker no longer reads as installed, whatever else a cut-short removal leaves.
    static func removeScript(layout: Layout = .system) -> String {
        """
        set -u
        launchctl=\(shell(layout.launchctl))
        \(stoppedFunction)
        "$launchctl" bootout system/\(label) 2>/dev/null || true
        if ! stopped; then
            echo 'The packet-access broker would not stop. Nothing was removed.' >&2
            exit 3
        fi
        /bin/rm -f \(shell(layout.plistPath))
        /bin/rm -f \(shell(layout.helperPath)) \(shell(layout.socketPath))
        /bin/rm -rf \(shell(layout.helperDirectory))/.\(label).*
        """
    }

    /// True once launchd no longer knows the job: bootout can return before it has exited.
    private static let stoppedFunction = """
        stopped() {
            for _ in 1 2 3 4 5 6 7 8 9 10; do
                "$launchctl" print system/\(label) >/dev/null 2>&1 || return 0
                /bin/sleep 0.2
            done
            return 1
        }
        """

    /// Installs the broker for this build and this user through the administrator dialog.
    /// Returns the plist text that was installed, which is the one Packet access showed.
    @discardableResult
    static func install(bundle: URL = Bundle.main.bundleURL, identity: () throws -> BuildIdentity = BuildIdentity.running, uid: uid_t = getuid(),
                        layout: Layout = .system, runPrivileged: (String) throws -> Void = runPrivileged) throws -> String {
        guard FileManager.default.fileExists(atPath: bundle.appending(path: helperInBundle).path) else { throw InstallError.noHelperInBundle }
        let identity = try identity()
        Log.sniffer.notice("installing the packet-access broker from \(bundle.path, privacy: .public)")
        do {
            try runPrivileged(installScript(identity: identity, bundle: bundle, uid: uid, layout: layout))
        } catch {
            Log.sniffer.error("broker install failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        Log.sniffer.notice("packet-access broker installed")
        return plist(requirement: identity.callerRequirement, uid: uid, layout: layout)
    }

    static func remove(layout: Layout = .system, runPrivileged: (String) throws -> Void = runPrivileged) throws {
        Log.sniffer.notice("removing the packet-access broker")
        do {
            try runPrivileged(removeScript(layout: layout))
        } catch {
            Log.sniffer.error("broker removal failed: \(String(describing: error), privacy: .public)")
            throw error
        }
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

    // MARK: Quoting

    static func shell(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func appleScript(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
