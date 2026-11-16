import Security
import XCTest
@testable import tattle

/// The root install and remove scripts, run as the user against a scratch layout: directories
/// under a temporary root, this account as owner, and a stand-in launchctl that logs its calls
/// and can be told to fail, to never let the job stop, or to run a hook at bootout.
final class CaptureBrokerScriptTests: XCTestCase {
    private var root: URL!
    private var layout: CaptureBroker.Layout!
    /// A signed app bundle like Tattle's: a main executable and the real broker beside it.
    private var bundle: URL!
    private var identity: CaptureBroker.BuildIdentity!

    private var bundledHelper: URL { bundle.appending(path: "Contents/MacOS/tattle-capture-broker") }
    private var log: URL { root.appending(path: "launchctl.log") }
    private var products: URL { Bundle(for: Self.self).bundleURL.deletingLastPathComponent() }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "broker-script-\(getpid())-\(UUID().uuidString.prefix(8))")
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root!) }
        for directory in ["helpers", "daemons"] { try fm.createDirectory(at: root.appending(path: directory), withIntermediateDirectories: true) }
        let launchctl = root.appending(path: "launchctl")
        try """
            #!/bin/sh
            root=\(CaptureBroker.shell(root.path))
            echo "$*" >> "$root/launchctl.log"
            case "$1" in
            print) [ -e "$root/never-stops" ] && exit 0; exit 113 ;;
            bootout) [ -e "$root/on-bootout" ] && /bin/sh "$root/on-bootout"; exit 0 ;;
            bootstrap) [ -e "$root/fail-bootstrap" ] && exit 5; exit 0 ;;
            esac
            exit 0

            """.write(to: launchctl, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchctl.path)
        layout = CaptureBroker.Layout(helperDirectory: root.appending(path: "helpers").path, daemonsDirectory: root.appending(path: "daemons").path,
                                      service: CaptureBroker.Service(name: BrokerAgent.uniqueLabel(), privileged: false),
                                      owner: "\(getuid()):\(getgid())", launchctl: launchctl.path)
        (bundle, identity) = try makeBundle(named: "It's Tattle.app")
    }

    // MARK: Fixtures

    private func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.standardError = FileHandle.nullDevice
        try process.run()
        if waitForExit(process) { XCTAssertEqual(process.terminationStatus, 0, "\(arguments)") }
    }

    /// Builds and signs, ad hoc with the hardened runtime, a bundle holding a copy of the probe as
    /// its main executable and the built broker as its helper. A quote and a space in the name
    /// exercise the script's quoting. `universal` puts another architecture's slice beside each.
    private func makeBundle(named name: String, helperRequirement: String? = nil, universal: Bool = false) throws -> (URL, CaptureBroker.BuildIdentity) {
        let fm = FileManager.default
        let app = root.appending(path: name)
        let macOS = app.appending(path: "Contents/MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.copyItem(at: products.appending(path: "tattle-broker-probe"), to: macOS.appending(path: "tattle"))
        try fm.copyItem(at: products.appending(path: "tattle-capture-broker"), to: macOS.appending(path: "tattle-capture-broker"))
        if universal {
            for executable in ["tattle", "tattle-capture-broker"] {
                try join([macOS.appending(path: executable), try otherSlice()], at: macOS.appending(path: executable))
            }
        }
        let info: [String: Any] = ["CFBundleExecutable": "tattle", "CFBundleIdentifier": "io.github.eladefrati.tattle.fixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appending(path: "Contents/Info.plist"))
        let helperOptions = helperRequirement.map { ["--identifier", "tattle-capture-broker", "-r=\($0)"] } ?? []
        try run(["/usr/bin/codesign", "--force", "--options", "runtime", "--sign", "-"] + helperOptions + [macOS.appending(path: "tattle-capture-broker").path])
        try run(["/usr/bin/codesign", "--force", "--options", "runtime", "--sign", "-", app.path])
        return (app, try XCTUnwrap(CaptureBroker.BuildIdentity(cdhash: try cdhash(app), identifier: "io.github.eladefrati.tattle.fixture", team: nil)))
    }

    #if arch(x86_64)
    private static let nativeArchitecture = "x86_64"
    /// Apple's programs carry x86_64 and arm64e.
    private static let otherArchitecture = "arm64e"
    #else
    private static let nativeArchitecture = "arm64"
    private static let otherArchitecture = "x86_64"
    #endif

    /// The other architecture's slice of one of Apple's programs: what a universal build carries
    /// beside the slice that runs here. It is only signed and checked, never run.
    private func otherSlice(of program: String = "/usr/bin/true") throws -> URL {
        try slice(Self.otherArchitecture, of: URL(filePath: program))
    }

    private func slice(_ architecture: String, of url: URL) throws -> URL {
        let out = root.appending(path: "slice-\(UUID().uuidString)")
        try run(["/usr/bin/lipo", "-thin", architecture, url.path, "-output", out.path])
        return out
    }

    /// Joins thin files into one universal file at `url`, replacing what is there.
    private func join(_ slices: [URL], at url: URL) throws {
        let joined = root.appending(path: "joined-\(UUID().uuidString)")
        try run(["/usr/bin/lipo", "-create"] + slices.map(\.path) + ["-output", joined.path])
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: joined, to: url)
    }

    private func signAdHoc(_ url: URL, identifier: String? = nil) throws {
        try run(["/usr/bin/codesign", "--force", "--options", "runtime", "--sign", "-"] + (identifier.map { ["--identifier", $0] } ?? []) + [url.path])
    }

    /// The identifier `url` is signed with: the linker signs with one of its own, which a later
    /// ad-hoc signing keeps.
    private func identifier(_ url: URL) throws -> String {
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(url as CFURL, [], &code), errSecSuccess)
        var info: CFDictionary?
        XCTAssertEqual(SecCodeCopySigningInformation(try XCTUnwrap(code), [], &info), errSecSuccess)
        return try XCTUnwrap((info as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String)
    }

    /// The code hash of the slice that runs here.
    private func cdhash(_ url: URL) throws -> Data {
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(url as CFURL, [], &code), errSecSuccess)
        var info: CFDictionary?
        XCTAssertEqual(SecCodeCopySigningInformation(try XCTUnwrap(code), [], &info), errSecSuccess)
        return try XCTUnwrap((info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data)
    }

    /// What the administrator dialog would do, as this user: /bin/sh -c, osascript's error
    /// when the script fails.
    private func runAsUser(_ script: String) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script]
        let err = Pipe()
        process.standardError = err
        try process.run()
        let exited = waitForExit(process)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard exited, process.terminationStatus == 0 else { throw CaptureBroker.InstallError.failed(stderr) }
    }

    @discardableResult
    private func install(before: (String) throws -> Void = { _ in }) throws -> String {
        try CaptureBroker.install(bundle: bundle, identity: { self.identity }, uid: getuid(), layout: layout) { script in
            try before(script)
            try runAsUser(script)
        }
    }

    private func remove() throws {
        try CaptureBroker.remove(layout: layout) { try runAsUser($0) }
    }

    private var expectedPlist: String { CaptureBroker.plist(requirement: identity.callerRequirement, uid: getuid(), layout: layout) }

    private func contents(_ path: String) -> Data? { FileManager.default.contents(atPath: path) }

    private var launchctlCalls: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map { String($0.split(separator: " ").first ?? "") }
    }

    private var leftoverStages: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: layout.helperDirectory)) ?? []).filter { $0.hasPrefix(".") }
    }

    private func assertNothingInstalled(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(contents(layout.helperPath), "helper: \(message)", file: file, line: line)
        XCTAssertNil(contents(layout.plistPath), "plist: \(message)", file: file, line: line)
        XCTAssertEqual(launchctlCalls.filter { $0 == "bootstrap" }, [], "no bootstrap: \(message)", file: file, line: line)
    }

    /// A file a hook script can put in place of the bundled helper: another validly signed program.
    private func signedImpostor() throws -> URL {
        let impostor = root.appending(path: "impostor")
        try FileManager.default.copyItem(at: products.appending(path: "tattle-broker-probe"), to: impostor)
        try run(["/usr/bin/codesign", "--force", "--options", "runtime", "--sign", "-", "--identifier", "tattle-capture-broker", impostor.path])
        return impostor
    }

    // MARK: Install

    func testInstallsTheVerifiedHelperAndThePlistShown() throws {
        let shown = try install()
        XCTAssertEqual(shown, expectedPlist)
        XCTAssertEqual(contents(layout.helperPath), contents(bundledHelper.path))
        XCTAssertEqual(contents(layout.plistPath), Data(expectedPlist.utf8))
        XCTAssertEqual(launchctlCalls.last, "bootstrap")
        XCTAssertEqual(leftoverStages, [])
    }

    /// The bundle is the user's: during the dialog any process of theirs can replace the helper
    /// root is about to install and run.
    func testRootRefusesAHelperReplacedWithAnotherSignedProgram() throws {
        let impostor = try signedImpostor()
        XCTAssertThrowsError(try install { _ in
            try FileManager.default.removeItem(at: self.bundledHelper)
            try FileManager.default.copyItem(at: impostor, to: self.bundledHelper)
        })
        assertNothingInstalled("a re-signed helper")
    }

    func testRootRefusesAHelperWithChangedBytes() throws {
        XCTAssertThrowsError(try install { _ in
            let handle = try FileHandle(forWritingTo: self.bundledHelper)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0]))
            try handle.close()
        })
        assertNothingInstalled("appended bytes")
    }

    /// A link inside the bundle, copied as a link, would let root verify the user's file and
    /// then install it after the user swapped it.
    func testRootRefusesALinkInsideTheBundle() throws {
        let elsewhere = root.appending(path: "helper-elsewhere")
        try FileManager.default.copyItem(at: bundledHelper, to: elsewhere)
        XCTAssertThrowsError(try install { _ in
            try FileManager.default.removeItem(at: self.bundledHelper)
            try FileManager.default.createSymbolicLink(at: self.bundledHelper, withDestinationURL: elsewhere)
        })
        assertNothingInstalled("a linked helper")
    }

    /// A bundle reached through a link is copied, not linked, so root still uses its own copy.
    func testRootCopiesABundleReachedThroughALink() throws {
        let genuine = contents(bundledHelper.path)
        let link = root.appending(path: "Linked.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundle)
        bundle = link
        try install()
        XCTAssertEqual(contents(layout.helperPath), genuine)
    }

    func testASwapAfterVerificationDoesNotReachRoot() throws {
        let impostor = try signedImpostor()
        try "/bin/cp \(CaptureBroker.shell(impostor.path)) \(CaptureBroker.shell(bundledHelper.path))\n"
            .write(to: root.appending(path: "on-bootout"), atomically: true, encoding: .utf8)
        let genuine = contents(bundledHelper.path)
        try install()
        XCTAssertEqual(contents(layout.helperPath), genuine)
    }

    /// Replacing the program under a running daemon, then booting it out, can leave launchd
    /// starting the new program with the old plist.
    func testRootStopsTheOldBrokerBeforeReplacingIt() throws {
        try Data("old helper".utf8).write(to: URL(filePath: layout.helperPath))
        try Data("old plist".utf8).write(to: URL(filePath: layout.plistPath))
        try "/bin/cp \(CaptureBroker.shell(layout.helperPath)) \(CaptureBroker.shell(root.appending(path: "at-bootout").path))\n"
            .write(to: root.appending(path: "on-bootout"), atomically: true, encoding: .utf8)
        try install()
        XCTAssertEqual(contents(root.appending(path: "at-bootout").path), Data("old helper".utf8), "the old helper was still in place when it was stopped")
        XCTAssertEqual(contents(layout.helperPath), contents(bundledHelper.path))
    }

    func testRootLeavesTheOldBrokerWhenItWillNotStop() throws {
        try Data("old helper".utf8).write(to: URL(filePath: layout.helperPath))
        try Data("old plist".utf8).write(to: URL(filePath: layout.plistPath))
        FileManager.default.createFile(atPath: root.appending(path: "never-stops").path, contents: nil)
        XCTAssertThrowsError(try install())
        XCTAssertEqual(contents(layout.helperPath), Data("old helper".utf8))
        XCTAssertEqual(contents(layout.plistPath), Data("old plist".utf8))
        XCTAssertFalse(launchctlCalls.contains("bootstrap"))
        XCTAssertEqual(leftoverStages, [])
    }

    /// A partial install read as installed; a failed one now leaves nothing.
    func testAFailedInstallLeavesNothingHalfInstalled() throws {
        FileManager.default.createFile(atPath: root.appending(path: "fail-bootstrap").path, contents: nil)
        XCTAssertThrowsError(try install())
        XCTAssertNil(contents(layout.helperPath))
        XCTAssertNil(contents(layout.plistPath))
        XCTAssertEqual(leftoverStages, [])
    }

    func testInstallAndRemoveCanRunTwice() throws {
        try FileManager.default.createDirectory(atPath: "\(layout.helperDirectory)/.\(CaptureBroker.label).crashed", withIntermediateDirectories: true)
        try install()
        try install()
        XCTAssertEqual(contents(layout.helperPath), contents(bundledHelper.path))
        XCTAssertEqual(contents(layout.plistPath), Data(expectedPlist.utf8))
        XCTAssertEqual(leftoverStages, [], "a stage left by a crashed install is swept")
        try remove()
        try remove()
        XCTAssertNil(contents(layout.helperPath))
        XCTAssertNil(contents(layout.plistPath))
    }

    /// With an Apple identity the bundled broker's designated requirement names the team and an
    /// identifier, not a hash, and `codesign --deep` checks nested code only against the
    /// requirement the seal records beside it: another broker meeting it passed. Ad hoc with such
    /// a requirement shows the same.
    func testRootRefusesAHelperThatOnlyMeetsTheSealedRequirement() throws {
        (bundle, identity) = try makeBundle(named: "Team.app", helperRequirement: #"designated => identifier "tattle-capture-broker""#)
        let impostor = try signedImpostor()
        XCTAssertThrowsError(try install { _ in
            try FileManager.default.removeItem(at: self.bundledHelper)
            try FileManager.default.copyItem(at: impostor, to: self.bundledHelper)
        })
        assertNothingInstalled("a helper meeting the sealed requirement but not the sealed hash")
    }

    func testAHelperWhoseRequirementNamesNoHashStillInstalls() throws {
        (bundle, identity) = try makeBundle(named: "Team.app", helperRequirement: #"designated => identifier "tattle-capture-broker""#)
        try install()
        XCTAssertEqual(contents(layout.helperPath), contents(bundledHelper.path))
    }

    // MARK: Universal builds

    /// codesign checks every slice unless told one, and each slice has its own code hash: the
    /// install asked every slice for the running one's hash and refused every universal build.
    func testAUniversalAdHocBuildInstalls() throws {
        (bundle, identity) = try makeBundle(named: "Universal.app", universal: true)
        let shown = try install()
        XCTAssertEqual(shown, expectedPlist)
        XCTAssertEqual(contents(layout.helperPath), contents(bundledHelper.path))
        XCTAssertEqual(contents(layout.plistPath), Data(expectedPlist.utf8))
        XCTAssertEqual(leftoverStages, [])
    }

    /// Root runs whichever slice suits the Mac, so one slice that matches proves nothing about
    /// the other: every slice of the broker must be one the seal names. `--deep` with `-a`
    /// checks the broker at the running slice only, so a foreign running slice is refused there
    /// and a foreign other slice by the check of every slice.
    func testRootRefusesAUniversalBrokerWithAForeignSlice() throws {
        (bundle, identity) = try makeBundle(named: "Universal.app", universal: true)
        let signedAs = try identifier(bundledHelper)
        let nativeKept = root.appending(path: "native-kept")
        try join([try slice(Self.nativeArchitecture, of: bundledHelper), try otherSlice(of: "/usr/bin/false")], at: nativeKept)
        try signAdHoc(nativeKept, identifier: signedAs)
        XCTAssertEqual(try cdhash(nativeKept), try cdhash(bundledHelper), "the slice that runs here is the sealed one")
        let otherKept = root.appending(path: "other-kept")
        try join([products.appending(path: "tattle-broker-probe"), try slice(Self.otherArchitecture, of: bundledHelper)], at: otherKept)
        try signAdHoc(otherKept, identifier: signedAs)
        for (impostor, sentence) in [(nativeKept, Self.brokerNotSealed), (otherKept, Self.appNotRunning)] {
            assertRefused(sentence, impostor.lastPathComponent) {
                try FileManager.default.removeItem(at: self.bundledHelper)
                try FileManager.default.copyItem(at: impostor, to: self.bundledHelper)
            }
        }
    }

    private static let appNotRunning = "Tattle on disk is not the Tattle that is running."
    private static let brokerNotSealed = "The broker inside Tattle is not the one this build of Tattle was sealed with."

    /// Install refuses with `sentence`, after `during` ran in the dialog, and leaves nothing.
    private func assertRefused(_ sentence: String, _ message: String, file: StaticString = #filePath, line: UInt = #line,
                               during: @escaping () throws -> Void = {}) {
        XCTAssertThrowsError(try install { _ in try during() }, message, file: file, line: line) { error in
            guard case .failed(let text) = error as? CaptureBroker.InstallError else { return XCTFail("\(error)", file: file, line: line) }
            XCTAssertTrue(text.hasPrefix(sentence), "\(message): \(text)", file: file, line: line)
        }
        assertNothingInstalled(message, file: file, line: line)
    }

    /// The main executable is checked at the slice that is running, which pins the seal.
    func testRootRefusesAUniversalBuildWhoseRunningSliceOrSealChanged() throws {
        (bundle, identity) = try makeBundle(named: "Universal.app", universal: true)
        let main = bundle.appending(path: "Contents/MacOS/tattle")
        assertRefused(Self.appNotRunning, "another running slice") {
            try self.join([try self.slice(Self.nativeArchitecture, of: self.bundledHelper), try self.slice(Self.otherArchitecture, of: main)], at: main)
            try self.signAdHoc(self.bundle)
        }

        (bundle, identity) = try makeBundle(named: "Universal Info.app", universal: true)
        assertRefused(Self.appNotRunning, "a changed sealed file") {
            let info: [String: Any] = ["CFBundleExecutable": "tattle", "CFBundleIdentifier": "io.github.eladefrati.tattle.fixture",
                                       "CFBundlePackageType": "APPL", "CFBundleName": "Changed"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: self.bundle.appending(path: "Contents/Info.plist"))
        }
    }

    /// Accepted: root never runs the main executable, and the plist names only the running
    /// slice's hash, so a foreign slice beside it gains nothing.
    func testAForeignSliceBesideTheRunningOneInTheAppStillInstalls() throws {
        (bundle, identity) = try makeBundle(named: "Universal.app", universal: true)
        let main = bundle.appending(path: "Contents/MacOS/tattle")
        try join([try slice(Self.nativeArchitecture, of: main), try otherSlice(of: "/usr/bin/false")], at: main)
        try signAdHoc(bundle)
        XCTAssertEqual(try cdhash(bundle), identity.cdhash, "the running slice is unchanged")
        try install()
        XCTAssertEqual(contents(layout.plistPath), Data(expectedPlist.utf8))
    }

    /// Accepted: a broker cut down to one of its sealed slices is still this build's own code.
    func testABrokerCutToOneOfItsSealedSlicesInstalls() throws {
        (bundle, identity) = try makeBundle(named: "Universal.app", universal: true)
        let thin = try slice(Self.nativeArchitecture, of: bundledHelper)
        try install { _ in
            try FileManager.default.removeItem(at: self.bundledHelper)
            try FileManager.default.copyItem(at: thin, to: self.bundledHelper)
        }
        XCTAssertEqual(contents(layout.helperPath), contents(thin.path))
    }

    /// With a team the seal's requirement names no hash, and its one hash pins one slice only,
    /// so a team-signed universal broker would let any slice the team signed run as root.
    func testRootRefusesAUniversalBrokerWhoseRequirementNamesNoHash() throws {
        (bundle, identity) = try makeBundle(named: "Team Universal.app", helperRequirement: #"designated => identifier "tattle-capture-broker""#, universal: true)
        assertRefused(Self.brokerNotSealed, "a universal broker sealed with a requirement that names no hash")
    }

    /// A recorded requirement that leaves out the sealed hash is not used, so the sealed hash
    /// alone refuses the other slice.
    func testRootRefusesAUniversalBrokerWhoseRequirementLeavesOutItsSealedHash() throws {
        let hash = String(repeating: "ab", count: 20)
        (bundle, identity) = try makeBundle(named: "Clause.app", helperRequirement: #"designated => cdhash H"\#(hash)" or identifier "tattle-capture-broker""#,
                                            universal: true)
        assertRefused(Self.brokerNotSealed, "a sealed requirement that leaves out the sealed hash")
    }

    /// The step that chooses the broker's requirement, run on its own. No signed fixture can
    /// reach its hash-clauses-only guard: the seal takes the hash and the requirement from one
    /// slice, and a requirement that names its own slice's hash is circular, since the hash
    /// covers the requirement.
    func testTheBrokerRequirementIsTheRecordedHashesAloneOrElseTheSealedHash() throws {
        let sealed = String(repeating: "ab", count: 20), other = String(repeating: "cd", count: 20)
        let alone = "cdhash H\"\(sealed)\""
        let cases: [(name: String, recorded: String, used: String)] = [
            ("the sealed hash", alone, alone),
            ("every slice's hash", "\(alone) or cdhash H\"\(other)\"", "\(alone) or cdhash H\"\(other)\""),
            ("a clause besides the hashes", "\(alone) or identifier \"tattle-capture-broker\"", alone),
            ("a clause before the hashes", "identifier \"tattle-capture-broker\" or \(alone)", alone),
            ("a clause on a second line", "\(alone)\nor identifier \"tattle-capture-broker\"", alone),
            ("a command after the hashes", "\(alone); /usr/bin/true", alone),
            ("hashes that leave out the sealed one", "cdhash H\"\(other)\"", alone),
            ("no hash, as with a team", "identifier \"tattle-capture-broker\" and anchor apple generic", alone),
            ("upper-case hex", "cdhash H\"\(sealed.uppercased())\"", alone),
            ("an upper-case hash beside the sealed one", "\(alone) or cdhash H\"\(other.uppercased())\"", alone),
            ("a short hash beside the sealed one", "\(alone) or cdhash H\"cd\"", alone),
            ("a long hash beside the sealed one", "\(alone) or cdhash H\"\(other)cd\"", alone),
            ("nothing recorded", "", alone),
        ]
        for test in cases {
            XCTAssertEqual(try brokerRequirement(sealed: sealed, recorded: test.recorded), test.used, test.name)
        }
    }

    /// Runs the install script's requirement step as the root shell would, with its arguments
    /// passed as the script passes them.
    private func brokerRequirement(sealed: String, recorded: String) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", CaptureBroker.brokerRequirementFunction + "\nbroker_requirement \"$1\" \"$2\"\n", "sh", sealed, recorded]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        XCTAssertTrue(waitForExit(process))
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    func testStatusReadsAUniversalBrokerItInstalledAsThisBuilds() throws {
        (bundle, identity) = try makeBundle(named: "Universal.app", universal: true)
        try install()
        _ = try BrokerAgent(self, label: layout.service.name, arguments: ["/usr/bin/true"])
        XCTAssertEqual(status().installation, .current)
    }

    // MARK: Status

    private func status() -> CaptureBroker.Status {
        CaptureBroker.status(bundle: bundle, identity: { self.identity }, uid: getuid(), layout: layout)
    }

    /// isInstalled meant "the plist exists", so an install or removal cut short read as installed.
    func testAPartialInstallIsNotInstalled() throws {
        XCTAssertEqual(status().installation, .absent)
        try Data(expectedPlist.utf8).write(to: URL(filePath: layout.plistPath))
        XCTAssertEqual(status().installation, .stale(.incomplete), "only the plist")
        try FileManager.default.removeItem(atPath: layout.plistPath)
        try FileManager.default.copyItem(at: bundledHelper, to: URL(filePath: layout.helperPath))
        XCTAssertEqual(status().installation, .stale(.incomplete), "only the broker")
    }

    func testStatusSaysWhenTheInstalledBrokerIsNotThisBuilds() throws {
        let shown = status()
        XCTAssertEqual(shown.proposed, .success(expectedPlist), "Packet access shows what install writes")
        try install()
        XCTAssertEqual(status().installation, .stale(.notLoaded), "launchd holds no job for it")
        _ = try BrokerAgent(self, label: layout.service.name, arguments: ["/usr/bin/true"])
        XCTAssertEqual(status().installation, .current)
        XCTAssertNil(status().installed, "nothing different to show")

        let mine = expectedPlist
        try Data(CaptureBroker.plist(requirement: identity.callerRequirement, uid: getuid() + 1, layout: layout).utf8).write(to: URL(filePath: layout.plistPath))
        XCTAssertEqual(status().installation, .stale(.otherUser(getuid() + 1)))

        let other = try XCTUnwrap(CaptureBroker.BuildIdentity(cdhash: Data(repeating: 1, count: 20), identifier: "x", team: nil))
        try Data(CaptureBroker.plist(requirement: other.callerRequirement, uid: getuid(), layout: layout).utf8).write(to: URL(filePath: layout.plistPath))
        XCTAssertEqual(status().installation, .stale(.otherBuild), "another build's requirement")
        XCTAssertNotNil(status().installed, "the installed plist is shown beside this build's")

        let withoutUser = mine.replacingOccurrences(of: "<string>--uid</string>\n        <string>\(getuid())</string>\n", with: "")
        XCTAssertNotEqual(withoutUser, mine)
        try Data(withoutUser.utf8).write(to: URL(filePath: layout.plistPath))
        XCTAssertEqual(status().installation, .stale(.otherBuild), "a plist from before the installing user was recorded")

        try Data(mine.utf8).write(to: URL(filePath: layout.plistPath))
        try FileManager.default.removeItem(atPath: layout.helperPath)
        try FileManager.default.copyItem(at: try signedImpostor(), to: URL(filePath: layout.helperPath))
        XCTAssertEqual(status().installation, .stale(.otherBuild), "another build's broker")
    }

    func testStatusSaysWhyThisBuildCannotInstall() {
        let status = CaptureBroker.status(bundle: bundle, identity: { throw CaptureBroker.InstallError.changedOnDisk }, uid: getuid(), layout: layout)
        XCTAssertEqual(status.proposed, .failure(.changedOnDisk))
        XCTAssertEqual(status.installation, .absent)
    }

    // MARK: Remove

    func testRemoveLeavesTheBrokerWhenItWillNotStop() throws {
        try install()
        FileManager.default.createFile(atPath: root.appending(path: "never-stops").path, contents: nil)
        XCTAssertThrowsError(try remove())
        XCTAssertNotNil(contents(layout.plistPath), "a running broker keeps the file that says it is installed")
    }

    // MARK: Locked files

    private func setLocked(_ locked: Bool, _ url: URL) throws {
        try FileManager.default.setAttributes([.immutable: locked], ofItemAtPath: url.path)
    }

    /// Unlocks everything under the scratch root so teardown can delete it.
    private func unlockAllAtTeardown() {
        addTeardownBlock { [root] in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/chflags")
            process.arguments = ["-R", "nouchg", root!.path]
            guard (try? process.run()) != nil else { return }
            // Bounded like waitForExit, which a teardown block cannot call.
            let deadline = Date().addingTimeInterval(60)
            while process.isRunning && Date() < deadline { usleep(20_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// A file locked in Finder (uchg) is copied locked, and rm cannot delete it: the failed
    /// install left its stage, and every later install stopped at the sweep of old stages.
    /// As root the install stopped at `chown -R root:wheel` on the locked copy with chown's own
    /// line; the script now refuses the locked copy before it, in a sentence of its own.
    func testALockedFileFailsOneInstallAndWedgesNone() throws {
        unlockAllAtTeardown()
        let plist = bundle.appending(path: "Contents/Info.plist")
        try setLocked(true, plist)
        XCTAssertThrowsError(try install()) { error in
            XCTAssertEqual(error as? CaptureBroker.InstallError, .failed(
                "A file inside this copy of Tattle is locked in the Finder, so it cannot be checked. Download or build Tattle again. Nothing was installed.\n"))
        }
        assertNothingInstalled("a locked file")
        XCTAssertEqual(leftoverStages, [], "the stage of the failed copy is gone")
        try setLocked(false, plist)
        try install()
        XCTAssertEqual(contents(layout.helperPath), contents(bundledHelper.path))
    }

    /// A locked plist stands for any file rm cannot delete.
    func testRemoveFailsWhenTheBrokersPlistStays() throws {
        unlockAllAtTeardown()
        try install()
        try setLocked(true, URL(filePath: layout.plistPath))
        XCTAssertThrowsError(try remove())
        XCTAssertNotNil(contents(layout.plistPath))
        XCTAssertNil(contents(layout.helperPath), "what can be removed still is")
    }

    func testRemoveSweepsAStageHoldingALockedFile() throws {
        unlockAllAtTeardown()
        let stage = URL(filePath: layout.helperDirectory).appending(path: ".\(CaptureBroker.label).crashed")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let file = stage.appending(path: "locked")
        try Data().write(to: file)
        try setLocked(true, file)
        try remove()
        XCTAssertEqual(leftoverStages, [])
    }
}
