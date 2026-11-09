import XCTest
@testable import tattle

final class CodeIdentityTests: XCTestCase {
    /// No publisher says which version this is: a signature's own hash does, else the file.
    func testCodeWithNoTeamIsPinnedToOneVersion() {
        XCTAssertEqual(CodeIdentity.of(CodeSignature(signer: .unsigned), path: "/x/tool"), CodeIdentity(text: "unsigned:/x/tool", contentFile: "/x/tool"))
        XCTAssertEqual(CodeIdentity.of(CodeSignature(signer: .invalid("bad")), path: "/x/tool"), CodeIdentity(text: "invalid:/x/tool", contentFile: "/x/tool"))
        XCTAssertEqual(CodeIdentity.of(CodeSignature(signer: .adHoc, codeHash: "ab"), path: "/x/tool"), CodeIdentity(text: "ad-hoc:ab:/x/tool"))
        XCTAssertEqual(CodeIdentity.of(CodeSignature(signer: .notIssuedByApple, codeHash: "ab"), path: "/x/tool"), CodeIdentity(text: "not-issued-by-apple:ab:/x/tool"))
        XCTAssertNotEqual(CodeIdentity.of(CodeSignature(signer: .adHoc, codeHash: "cd"), path: "/x/tool"), CodeIdentity.of(CodeSignature(signer: .adHoc, codeHash: "ab"), path: "/x/tool"))
    }

    func testAPublishersCodeIsKnownWithoutItsVersion() {
        let signature = CodeSignature(signer: .developerID(name: "Acme"), identifier: "com.acme.a", teamIdentifier: "ABCDE12345", codeHash: "ab")
        XCTAssertEqual(CodeIdentity.of(signature, path: "/x/tool"), CodeIdentity(text: "team:ABCDE12345:com.acme.a"))
    }

    func testAScriptIsKnownByItsFilesContent() {
        XCTAssertEqual(CodeIdentity.script(at: "/x/job.sh"), CodeIdentity(text: "script:/x/job.sh", contentFile: "/x/job.sh"))
    }

    /// A command line says what the plist runs; what is in the file it reaches is the rest.
    func testACommandLineIsPinnedToTheCodeItReaches() throws {
        let line = try XCTUnwrap(CodeIdentity.command("/x/tool --flag"))
        XCTAssertNil(line.contentFile)
        XCTAssertNotEqual(CodeIdentity.command("/x/tool --flag", codeHash: "ab"), line)
        XCTAssertNotEqual(CodeIdentity.command("/x/tool --flag", codeHash: "ab"), CodeIdentity.command("/x/tool --flag", codeHash: "cd"))
        XCTAssertNil(CodeIdentity.command("/x/tool --flag", codeHash: "ab")?.contentFile, "a signature's hash says which version")
        XCTAssertEqual(CodeIdentity.command("/x/tool --flag", file: "/x/tool")?.contentFile, "/x/tool")
        XCTAssertNil(CodeIdentity.command("/bin/sh job.sh", file: "job.sh"), "a relative script is no file to read")
    }

    func testALaunchItemsLineIsReadToTheFileItReaches() {
        let apple: (String) -> CodeSignature? = { path in
            path.hasPrefix("/x/") ? CodeSignature(signer: .unsigned) : CodeSignature(signer: .apple, identifier: "com.apple." + URL(fileURLWithPath: path).lastPathComponent)
        }
        XCTAssertEqual(CodeSignature.started(program: "/usr/bin/env", arguments: ["/x/good"], reading: apple).version, .file("/x/good"))
        XCTAssertEqual(CodeSignature.started(program: "/bin/sh", arguments: ["/x/job.sh"], reading: apple).version, .file("/x/job.sh"))
        XCTAssertEqual(CodeSignature.started(program: "/bin/sh", arguments: ["-c", "echo"], reading: apple).version, .line, "the code is in the line")
    }

    /// An inode number is unsigned and 64 bits wide, and what a mounted file system gives is its own.
    func testAFileVersionTakesAnyInodeNumber() {
        var info = stat()
        info.st_ino = .max
        let huge = FileVersion(info)
        info.st_ino = .max - 1
        XCTAssertNotEqual(FileVersion(info), huge)
    }

    /// The same version of the file reads the same, and a file is hashed whole.
    func testDigestsOfRealFiles() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "tattle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(FileDigests.sha256(of: file.path), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

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

    /// Signed code carries a hash of itself, whoever signed it.
    func testASignatureSaysWhichCodeItIsOn() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let one = dir.appending(path: "one"), other = dir.appending(path: "other"), unsigned = dir.appending(path: "unsigned")
        for (source, target) in [("/bin/ls", one), ("/bin/cat", other), ("/bin/ls", unsigned)] {
            try FileManager.default.copyItem(atPath: source, toPath: target.path)
        }
        try codesign(["--force", "--sign", "-", one.path])
        try codesign(["--force", "--sign", "-", other.path])
        try codesign(["--remove-signature", unsigned.path])

        let hash = try XCTUnwrap(CodeSignature.read(path: one.path).codeHash)
        XCTAssertEqual(CodeSignature.read(path: one.path).codeHash, hash, "the same code reads the same")
        XCTAssertNotEqual(CodeSignature.read(path: other.path).codeHash, hash)
        XCTAssertNil(CodeSignature.read(path: unsigned.path).codeHash)
    }

    /// A team is what Apple issued. A certificate's name or kind can differ within one.
    func testABundleOwnsItsTeamsCodeUnderAnyOfItsCertificates() {
        let bundle = CodeSignature(signer: .developerID(name: "Acme Inc"), teamIdentifier: "ABCDE12345")
        XCTAssertTrue(bundle.owns(CodeSignature(signer: .developerID(name: "Acme LLC"), teamIdentifier: "ABCDE12345")))
        XCTAssertTrue(bundle.owns(CodeSignature(signer: .development, teamIdentifier: "ABCDE12345")))
        XCTAssertFalse(bundle.owns(CodeSignature(signer: .developerID(name: "Acme Inc"), teamIdentifier: "FGHIJ67890")))
        XCTAssertFalse(bundle.owns(CodeSignature(signer: .adHoc)))
        XCTAssertFalse(bundle.owns(nil))
    }

    /// A signature's hash says which version of the code this is, so what decides whether to
    /// read it again cannot be a date anyone can set back.
    func testASignatureIsReadAgainForAFileReplacedUnderItsOldDate() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "tattle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func write(_ content: String) throws {
            try Data(content.utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        }
        final class Reads: @unchecked Sendable { var count = 0 }
        let reads = Reads()
        let cache = SignatureCache(read: { _ in
            reads.count += 1
            return CodeSignature(signer: .adHoc, codeHash: String(reads.count))
        })

        try write("one")
        XCTAssertEqual(cache.signature(at: file.path)?.codeHash, "1")
        XCTAssertEqual(cache.signature(at: file.path)?.codeHash, "1", "the same version is read once")
        try write("two")
        XCTAssertEqual(cache.signature(at: file.path)?.codeHash, "2")
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

    /// An ad-hoc signature has no certificate, so the team its CodeDirectory names is
    /// whoever signed it saying so.
    func testAnAdHocSignatureClaimsNoTeam() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let adHoc = dir.appending(path: "adhoc")
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: adHoc.path)
        try codesign(["--force", "--sign", "-", "--team-identifier", "ABCDE12345", adHoc.path])

        let signature = CodeSignature.read(path: adHoc.path)
        XCTAssertEqual(signature.signer, .adHoc)
        XCTAssertNil(signature.teamIdentifier)
    }

    func testClassify() {
        XCTAssertEqual(CodeSignature.classify("Developer ID Application: PACE Anti-Piracy, Inc. (TFZ8226T6X)"), .developerID(name: "PACE Anti-Piracy, Inc."))
        XCTAssertEqual(CodeSignature.classify("Apple Development: someone@example.com (ABCDE12345)"), .development)
        XCTAssertEqual(CodeSignature.classify("Apple Mac OS Application Signing"), .appStore)
        XCTAssertEqual(CodeSignature.classify("Apple Distribution: Acme (ABCDE12345)"), .other("Apple Distribution: Acme"),
                       "the team is a fact of its own")
        XCTAssertEqual(CodeSignature.classify("3rd Party Mac Developer Application: Acme (ABCDE12345)"), .other("3rd Party Mac Developer Application: Acme"))
        for subject in ["Software Signing", "macOS Software Signing"] {
            XCTAssertNotEqual(CodeSignature.classify(subject), .apple, "Apple's own code is known by its chain, not by a subject: \(subject)")
        }
    }

    /// A development certificate is named after the developer's Apple account, usually an
    /// email address: the panel shows the kind and the team, which a screenshot may carry.
    func testADevelopmentCertificateShowsItsKindAndTeamNotItsName() {
        let development = CodeSignature(signer: .development, teamIdentifier: "ABCDE12345")
        XCTAssertEqual(development.summary, "Apple Development (ABCDE12345)")
        XCTAssertEqual(CodeSignature(signer: .development).summary, "Apple Development")
    }

    func testInterpreterSignsTheScriptNotItself() {
        // Each file reads as signed by a publisher named for its path.
        let reading: (String) -> CodeSignature? = { CodeSignature(signer: .developerID(name: $0)) }
        XCTAssertEqual(CodeSignature.read(program: "/bin/ls", arguments: ["-l"], reading: reading)?.signer, .developerID(name: "/bin/ls"))
        XCTAssertEqual(CodeSignature.read(program: "/usr/bin/osascript", arguments: ["-e", "1+1"], reading: reading)?.signer, .unnamed)
        XCTAssertEqual(CodeSignature.read(program: "/bin/sh", arguments: ["-x", "/x/run.sh"], reading: reading)?.signer, .script)
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
        XCTAssertNotNil(LaunchctlState.read().gui.services[label])
        try Launchctl.unload(label: label)
        XCTAssertNil(LaunchctlState.read().gui.services[label])
        XCTAssertThrowsError(try Launchctl.unload(label: label)) { error in
            guard case Launchctl.ControlError.failed = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(Launchctl.canControl(.daemon))
        XCTAssertTrue(Launchctl.canControl(.globalAgent))
    }

    func testThisMachine() {
        let state = LaunchctlState.read()
        XCTAssertGreaterThan(state.system.services.count, 50)
        XCTAssertTrue(state.system.services.values.contains { $0.pid != nil }, "something is running")
    }

    func testIdentityOfAPublishersProgramIsItsTeamAndIdentifierWhereverItIs() {
        let signed = CodeSignature(signer: .developerID(name: "Acme"), identifier: "com.acme.tool", teamIdentifier: "ABCDE12345")
        XCTAssertEqual(CodeIdentity.of(signed, path: "/a/1.0/tool"), CodeIdentity.of(signed, path: "/b/2.0/tool"))
        XCTAssertNotEqual(CodeIdentity.of(signed, path: "/a"), CodeIdentity.of(CodeSignature(signer: .developerID(name: "Acme"), identifier: "com.acme.other", teamIdentifier: "ABCDE12345"), path: "/a"))
    }

    func testIdentityOfApplesProgramIsItsIdentifierOnlyWhereMacOSInstallsIt() {
        let apple = CodeSignature(signer: .apple, identifier: "com.apple.mail")
        XCTAssertEqual(CodeIdentity.of(apple, path: "/System/Applications/Mail.app"), CodeIdentity.of(apple, path: "/System/Applications/Mail.app/Contents/MacOS/Mail"))
        XCTAssertNotEqual(CodeIdentity.of(apple, path: "/tmp/Mail"), CodeIdentity.of(apple, path: "/usr/bin/Mail"), "a copy keeps Apple's signature")
        XCTAssertNotEqual(CodeIdentity.of(apple, path: "/tmp/a/Mail"), CodeIdentity.of(apple, path: "/tmp/b/Mail"))
    }

    func testIdentityWithoutATeamOrAHashIsTheFile() {
        for signer: CodeSignature.Signer in [.unsigned, .adHoc, .invalid("x"), .notIssuedByApple] {
            let signature = CodeSignature(signer: signer, identifier: "tool-1234")
            XCTAssertEqual(CodeIdentity.of(signature, path: "/x/tool")?.contentFile, "/x/tool", "\(signer)")
            XCTAssertNil(CodeIdentity.of(signature, path: nil), "\(signer)")
        }
    }

    func testIdentityIsNotAScriptsOrUnnamedCodesInterpreter() {
        XCTAssertNil(CodeIdentity.of(CodeSignature(signer: .script), path: "/bin/sh"))
        XCTAssertNil(CodeIdentity.of(CodeSignature(signer: .unnamed), path: "/bin/sh"))
        XCTAssertNil(CodeIdentity.of(CodeSignature(signer: .launchItem(applesProgram: "sh")), path: "/bin/sh"))
        XCTAssertNil(CodeIdentity.of(nil, path: "/bin/sh"))
    }

    func testACommandLinesIdentityKeepsNoneOfItsWords() {
        let identity = CodeIdentity.command("/x/agent --token s3cret")
        XCTAssertFalse(identity?.text.contains("s3cret") ?? true)
        XCTAssertNotEqual(identity, CodeIdentity.command("/x/agent --token other"))
    }
}
