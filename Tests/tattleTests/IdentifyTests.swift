import XCTest
@testable import tattle

final class CodeSignatureTests: XCTestCase {
    func testAppleBinary() {
        let signature = CodeSignature.read(path: "/bin/ls")
        XCTAssertEqual(signature.signer, .apple)
        XCTAssertEqual(signature.identifier, "com.apple.ls")
        XCTAssertNil(signature.teamIdentifier)
        XCTAssertEqual(signature.summary, "Apple")
    }

    func testDeveloperIDApp() throws {
        let path = "/Applications/Spotify.app"
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("Spotify not installed") }
        let signature = CodeSignature.read(path: path)
        XCTAssertEqual(signature.signer, .developerID(name: "Spotify"))
        XCTAssertEqual(signature.teamIdentifier, "2FNC3A47ZF")
        XCTAssertEqual(signature.summary, "Spotify")
    }

    func testOwnBuildIsDevelopmentSigned() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "build/Tattle.app").path
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("no bundle built") }
        let signature = CodeSignature.read(path: path)
        guard case .development = signature.signer else { return XCTFail("\(signature.signer)") }
        XCTAssertNotNil(signature.teamIdentifier)
    }

    func testUnsignedAdHocAndScript() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let unsigned = dir.appending(path: "unsigned"), adHoc = dir.appending(path: "adhoc"), script = dir.appending(path: "run.sh")
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: unsigned.path)
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: adHoc.path)
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: script)
        try codesign(["--remove-signature", unsigned.path])
        try codesign(["--force", "--sign", "-", adHoc.path])

        XCTAssertEqual(CodeSignature.read(path: unsigned.path).signer, .unsigned)
        XCTAssertEqual(CodeSignature.read(path: adHoc.path).signer, .adHoc)
        XCTAssertEqual(CodeSignature.read(path: script.path).signer, .unsigned)
        XCTAssertEqual(CodeSignature.read(path: dir.appending(path: "missing").path).signer, .unsigned)
    }

    func testACertificateNotIssuedByAppleClaimsNothing() throws {
        let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "forged-signatures", withExtension: nil))
        for name in ["forged-software-signing", "forged-developer-id"] {
            let signature = CodeSignature.read(path: fixtures.appending(path: name).path)
            XCTAssertEqual(signature.summary, "certificate not issued by Apple", name)
            XCTAssertNotEqual(signature.signer, .apple, name)
            XCTAssertNil(signature.teamIdentifier, name)
        }
    }

    func testClassify() {
        XCTAssertEqual(CodeSignature.classify("Developer ID Application: PACE Anti-Piracy, Inc. (TFZ8226T6X)"), .developerID(name: "PACE Anti-Piracy, Inc."))
        XCTAssertEqual(CodeSignature.classify("Apple Development: someone@example.com (ABCDE12345)"), .development)
        XCTAssertEqual(CodeSignature.classify("Apple Mac OS Application Signing"), .appStore)
        XCTAssertEqual(CodeSignature.classify("Apple Distribution: Acme (X)"), .other("Apple Distribution: Acme (X)"))
    }

    /// A development certificate is named after the developer's Apple account, usually an
    /// email address: the panel shows the kind and the team, which a screenshot may carry.
    func testADevelopmentCertificateShowsItsKindAndTeamNotItsName() {
        let development = CodeSignature(signer: .development, teamIdentifier: "ABCDE12345")
        XCTAssertEqual(development.summary, "Apple Development (ABCDE12345)")
        XCTAssertEqual(CodeSignature(signer: .development).summary, "Apple Development")
    }

    func testInterpreterSignsTheScriptNotItself() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appending(path: "run.sh")
        try Data("#!/bin/sh\n".utf8).write(to: script)

        var asked: [String] = []
        let reading: (String) -> CodeSignature? = { asked.append($0); return CodeSignature(signer: .apple) }
        XCTAssertEqual(CodeSignature.read(program: "/bin/ls", arguments: ["-l"], reading: reading)?.signer, .apple)
        XCTAssertEqual(CodeSignature.read(program: "/usr/bin/osascript", arguments: ["-e", "1+1"], reading: reading)?.signer, .script)
        XCTAssertEqual(CodeSignature.read(program: "/bin/sh", arguments: ["-c", script.path], reading: reading)?.signer, .apple)
        XCTAssertEqual(asked, ["/bin/ls", script.path])
    }

    private func codesign(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try process.run()
        if waitForExit(process) { XCTAssertEqual(process.terminationStatus, 0, "codesign \(arguments)") }
    }
}

final class LaunchctlStateTests: XCTestCase {
    func testParseServices() {
        let output = """
            gui/501 = {
            \ttype = gui
            \tservices = {
            \t\t   76560      - \tapplication.com.ableton.live.62578060
            \t\t       0      0 \tcom.uaudio.ua-connect.ShipIt
            \t\t       0     -9 \tcom.example.crashed
            \t\t     685      - \tcom.apple.syncdefaultsd
            \t}
            \tendpoints = {
            \t\t"com.not.a.service" => { port = 1 }
            \t}
            }
            """
        let services = LaunchctlState.parseServices(output)
        XCTAssertEqual(services.count, 4)
        XCTAssertEqual(services["application.com.ableton.live.62578060"], .init(pid: 76560, lastExitStatus: nil))
        XCTAssertEqual(services["com.uaudio.ua-connect.ShipIt"], .init(pid: nil, lastExitStatus: 0))
        XCTAssertEqual(services["com.example.crashed"], .init(pid: nil, lastExitStatus: -9))
    }

    func testParseOverrides() {
        let output = """
            disabled services = {
            \t\t"com.apple.Siri.agent" => disabled
            \t\t"com.spotify.client.startuphelper" => enabled
            \t}
            """
        XCTAssertEqual(LaunchctlState.parseOverrides(output), ["com.apple.Siri.agent": true, "com.spotify.client.startuphelper": false])
    }

    func testLoadAndUnloadInUserDomain() throws {
        let label = "io.github.eladefrati.tattle.test." + UUID().uuidString
        let plist = FileManager.default.temporaryDirectory.appending(path: label + ".plist")
        try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key><array><string>/usr/bin/true</string></array></dict></plist>
            """.utf8).write(to: plist)
        defer { try? FileManager.default.removeItem(at: plist) }

        try Launchctl.load(plist: plist)
        XCTAssertNotNil(LaunchctlState.read().services[label])
        try Launchctl.unload(label: label)
        XCTAssertNil(LaunchctlState.read().services[label])
        XCTAssertThrowsError(try Launchctl.unload(label: label)) { error in
            guard case Launchctl.ControlError.failed = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(Launchctl.canControl(.daemon))
        XCTAssertTrue(Launchctl.canControl(.globalAgent))
    }

    func testThisMachine() {
        let state = LaunchctlState.read()
        XCTAssertGreaterThan(state.services.count, 50)
        XCTAssertTrue(state.services.values.contains { $0.pid != nil }, "something is running")
    }
}
