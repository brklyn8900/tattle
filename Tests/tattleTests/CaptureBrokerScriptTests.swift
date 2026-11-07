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
    /// exercise the script's quoting.
    private func makeBundle(named name: String, helperRequirement: String? = nil) throws -> (URL, CaptureBroker.BuildIdentity) {
        let fm = FileManager.default
        let app = root.appending(path: name)
        let macOS = app.appending(path: "Contents/MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.copyItem(at: products.appending(path: "tattle-broker-probe"), to: macOS.appending(path: "tattle"))
        try fm.copyItem(at: products.appending(path: "tattle-capture-broker"), to: macOS.appending(path: "tattle-capture-broker"))
        let info: [String: Any] = ["CFBundleExecutable": "tattle", "CFBundleIdentifier": "io.github.eladefrati.tattle.fixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appending(path: "Contents/Info.plist"))
        let helperOptions = helperRequirement.map { ["--identifier", "tattle-capture-broker", "-r=\($0)"] } ?? []
        try run(["/usr/bin/codesign", "--force", "--options", "runtime", "--sign", "-"] + helperOptions + [macOS.appending(path: "tattle-capture-broker").path])
        try run(["/usr/bin/codesign", "--force", "--options", "runtime", "--sign", "-", app.path])
        return (app, try XCTUnwrap(CaptureBroker.BuildIdentity(cdhash: try cdhash(app), identifier: "io.github.eladefrati.tattle.fixture", team: nil)))
    }

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

    /// The plist was a file in $TMPDIR during the dialog: any process of the user could swap in
    /// one that runs a shell as root, at every boot.
    func testRootReadsNoPlistTheUserCanWrite() throws {
        let evil = expectedPlist.replacingOccurrences(of: layout.helperPath, with: "/bin/sh")
        try install { script in
            XCTAssertFalse(script.contains(FileManager.default.temporaryDirectory.appending(path: CaptureBroker.label).path), "the script names a staged file")
            for name in (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
            where name.hasPrefix(CaptureBroker.label) {
                try evil.write(to: FileManager.default.temporaryDirectory.appending(path: name), atomically: false, encoding: .utf8)
            }
        }
        XCTAssertEqual(contents(layout.plistPath), Data(expectedPlist.utf8))
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

    /// A swap after root verified its copy changes nothing root uses.
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
            try? process.run()
            process.waitUntilExit()
        }
    }

    /// A file locked in Finder (uchg) is copied locked, and rm cannot delete it: the failed
    /// install left its stage, and every later install stopped at the sweep of old stages.
    /// As root the install fails at `chown -R root:wheel` on the locked copy; here chown changes
    /// no owner and succeeds, so the stand-in launchctl fails the install instead.
    func testALockedFileFailsOneInstallAndWedgesNone() throws {
        unlockAllAtTeardown()
        let plist = bundle.appending(path: "Contents/Info.plist")
        try setLocked(true, plist)
        // Appends: the failed install's cleanup boots out again, after the stage is gone.
        let flags = root.appending(path: "staged-flags")
        let staged = CaptureBroker.shell("\(layout.helperDirectory)/.\(CaptureBroker.label).") + "*/Tattle.app/Contents/Info.plist"
        try "/usr/bin/stat -f %Sf \(staged) >> \(CaptureBroker.shell(flags.path))\n"
            .write(to: root.appending(path: "on-bootout"), atomically: true, encoding: .utf8)
        let failBootstrap = root.appending(path: "fail-bootstrap")
        FileManager.default.createFile(atPath: failBootstrap.path, contents: nil)
        XCTAssertThrowsError(try install())
        XCTAssertTrue((try? String(contentsOf: flags, encoding: .utf8))?.contains("uchg") == true, "the stage held a locked copy when the install failed")
        XCTAssertEqual(leftoverStages, [], "the stage of the failed copy is gone")
        try FileManager.default.removeItem(at: failBootstrap)
        try setLocked(false, plist)
        try install()
        XCTAssertEqual(contents(layout.helperPath), contents(bundledHelper.path))
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
