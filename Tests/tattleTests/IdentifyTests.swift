import XCTest
@testable import tattle

final class CodeIdentityTests: XCTestCase {
    /// No publisher says which version this is: a signature's own hash does, else the file.
    func testCodeWithNoTeamIsPinnedToOneVersion() {
        XCTAssertEqual(CodeIdentity.of(CodeSignature(signer: .unsigned), path: "/x/tool"), CodeIdentity(text: "unsigned:/x/tool", contentFile: "/x/tool"))
        XCTAssertEqual(CodeIdentity.of(CodeSignature(signer: .invalid), path: "/x/tool"), CodeIdentity(text: "invalid:/x/tool", contentFile: "/x/tool"))
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
        let cache = SignatureCache(files: { _ in [] }, read: { _ in
            reads.count += 1
            return CodeSignature.Reading(signature: CodeSignature(signer: .adHoc, codeHash: String(reads.count)))
        })

        try write("one")
        XCTAssertEqual(cache.signature(at: file.path)?.codeHash, "1")
        XCTAssertEqual(cache.signature(at: file.path)?.codeHash, "1", "the same version is read once")
        try write("two")
        XCTAssertEqual(cache.signature(at: file.path)?.codeHash, "2")
    }

    /// A bundle's signature is read from files inside it, and writing over one of them leaves
    /// the folder's own dates as they were. The reading says which files they are.
    func testASignatureIsReadAgainWhenAFileItsReadingRestsOnChanges() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tattle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appending(path: "Tool.app")
        let contents = app.appending(path: "Contents")
        let executable = contents.appending(path: "MacOS/Tool")
        let seal = contents.appending(path: "_CodeSignature/CodeResources")
        let info = contents.appending(path: "Info.plist")
        for file in [executable, seal, info] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("one".utf8).write(to: file)
        }
        final class Reads: @unchecked Sendable {
            var count = 0
            var during: (() -> Void)?
        }
        let reads = Reads()
        let files = [executable.path, info.path, seal.path]
        let cache = SignatureCache(files: { _ in files }, read: { _ in
            reads.count += 1
            reads.during?()
            return CodeSignature.Reading(signature: CodeSignature(signer: .adHoc, codeHash: String(reads.count)), files: files)
        })
        func hash(_ path: URL) -> String? { cache.signature(at: path.path)?.codeHash }

        XCTAssertEqual(hash(app), "1")
        XCTAssertEqual(hash(app), "1", "the same version is read once")
        let before = try XCTUnwrap(FileVersion(path: app.path))
        try Data("another program".utf8).write(to: executable)
        XCTAssertEqual(FileVersion(path: app.path), before, "the folder itself says nothing of it")
        XCTAssertEqual(hash(app), "2", "the executable written over in place")
        try Data("a third".utf8).write(to: executable, options: .atomic)
        XCTAssertEqual(hash(app), "3", "the executable replaced by another file")
        try Data("another".utf8).write(to: info)
        XCTAssertEqual(hash(app), "4", "the Info.plist, which names the executable")
        try Data("another".utf8).write(to: seal)
        XCTAssertEqual(hash(app), "5", "the seal over the resources")
        try Data("a log".utf8).write(to: contents.appending(path: "MacOS/tool.log"))
        XCTAssertEqual(hash(app), "5", "a file the reading does not rest on")

        // The executable is read as its bundle, so it rests on the same files.
        XCTAssertEqual(hash(executable), "6")
        try Data("a third".utf8).write(to: info)
        XCTAssertEqual(hash(executable), "7", "the Info.plist written over under the executable's own reading")
        XCTAssertEqual(hash(executable), "7")
        XCTAssertEqual(hash(app), "8")

        // What changes while it is read may not be what was read.
        try Data("yet another".utf8).write(to: seal)
        reads.during = { try? Data("written during the read".utf8).write(to: executable) }
        XCTAssertEqual(hash(app), "9")
        reads.during = nil
        XCTAssertEqual(hash(app), "10", "a reading made while a file changed is not kept")
        XCTAssertEqual(hash(app), "10")
    }

    /// The same, with signed apps and the real reading.
    func testAnAppWhoseFilesAreWrittenOverIsNotReadAsBefore() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tattle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        func app(_ name: String) throws -> (bundle: URL, executable: URL, info: URL) {
            let bundle = folder.appending(path: "\(name).app")
            let executable = bundle.appending(path: "Contents/MacOS/Tool")
            let info = bundle.appending(path: "Contents/Info.plist")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: "/bin/ls", toPath: executable.path)
            try plist(identifier: "com.example.\(name.lowercased())").write(to: info)
            try codesign(["--force", "--sign", "-", bundle.path])
            return (bundle, executable, info)
        }
        let other = folder.appending(path: "other")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/cat", toPath: other.path)
        try codesign(["--force", "--sign", "-", other.path])
        final class Reads: @unchecked Sendable { var count = 0 }
        let reads = Reads()
        let cache = SignatureCache(read: {
            reads.count += 1
            return CodeSignature.reading(path: $0)
        })

        let one = try app("One")
        let first = try XCTUnwrap(cache.signature(at: one.bundle.path))
        XCTAssertEqual(first.signer, .adHoc)
        XCTAssertNotNil(first.codeHash)
        XCTAssertEqual(cache.signature(at: one.bundle.path), first)
        XCTAssertEqual(reads.count, 1, "reading it changes none of its files, so it is read once")
        try Data(contentsOf: other).write(to: one.executable)
        XCTAssertNotEqual(cache.signature(at: one.bundle.path), first, "the executable written over")

        let two = try app("Two")
        XCTAssertEqual(cache.signature(at: two.bundle.path)?.signer, .adHoc)
        XCTAssertEqual(cache.signature(at: two.executable.path)?.signer, .adHoc)
        try plist(identifier: "com.example.another").write(to: two.info)
        XCTAssertEqual(cache.signature(at: two.bundle.path)?.signer, .invalid, "the Info.plist written over")
        XCTAssertEqual(cache.signature(at: two.executable.path)?.signer, .invalid, "the executable is read as its bundle")
    }

    /// A folder renamed into an app brings its files with the dates they had, so no file's own
    /// date says that it arrived while the signature was read.
    func testAnAppWhoseFolderIsSwappedWhileItIsReadIsReadAgain() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tattle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appending(path: "Tool.app")
        let programs = app.appending(path: "Contents/MacOS"), prepared = folder.appending(path: "prepared"), aside = folder.appending(path: "aside")
        try FileManager.default.createDirectory(at: programs, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: programs.appending(path: "Tool").path)
        try plist(identifier: "com.example.tool").write(to: app.appending(path: "Contents/Info.plist"))
        try codesign(["--force", "--sign", "-", app.path])
        try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/cat", toPath: prepared.appending(path: "Tool").path)
        try codesign(["--remove-signature", prepared.appending(path: "Tool").path])
        func swap() {
            try? FileManager.default.moveItem(at: programs, to: aside)
            try? FileManager.default.moveItem(at: prepared, to: programs)
        }
        func swapBack() {
            try? FileManager.default.moveItem(at: programs, to: prepared)
            try? FileManager.default.moveItem(at: aside, to: programs)
        }
        final class Reads: @unchecked Sendable {
            var count = 0
            var before: (() -> Void)?
            var after: (() -> Void)?
        }
        let reads = Reads()
        let cache = SignatureCache(read: {
            reads.count += 1
            reads.before?()
            let reading = CodeSignature.reading(path: $0)
            reads.after?()
            return reading
        })

        // The app's own executable is read, and another is in its place by the end of the read.
        reads.after = swap
        let own = try XCTUnwrap(cache.signature(at: app.path))
        XCTAssertEqual(own.signer, .adHoc)
        reads.after = nil
        XCTAssertNotEqual(cache.signature(at: app.path), own, "the reading of the executable that was swapped out is not kept")
        XCTAssertEqual(reads.count, 2)

        // The other executable is read, and the app's own is back by the end of the read.
        swapBack()
        (reads.before, reads.after) = (swap, swapBack)
        XCTAssertNotEqual(cache.signature(at: app.path), own, "read while the other executable was in place")
        (reads.before, reads.after) = (nil, nil)
        XCTAssertEqual(cache.signature(at: app.path), own, "the reading of an executable that is gone again is not kept")
        XCTAssertEqual(cache.signature(at: app.path), own)
        XCTAssertEqual(reads.count, 4, "what is settled is read once")
    }

    /// An app being put in place is a folder whose files arrive one by one, each leaving the
    /// folder's own dates as they were. What is missing at one reading is looked for at the next.
    func testAnAppReadBeforeAllOfItIsThereIsReadAgain() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tattle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appending(path: "Tool.app"), contents = app.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        final class Reads: @unchecked Sendable { var count = 0 }
        let reads = Reads()
        let cache = SignatureCache(read: {
            reads.count += 1
            return CodeSignature.reading(path: $0)
        })
        func readsAfterAsking() -> Int {
            _ = cache.signature(at: app.path)
            _ = cache.signature(at: app.path)
            return reads.count
        }

        XCTAssertEqual(cache.signature(at: app.path)?.signer, .unsigned)
        XCTAssertEqual(readsAfterAsking(), 1, "nothing arrived, so it is read once")
        let before = try XCTUnwrap(FileVersion(path: app.path))
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: contents.appending(path: "MacOS/Tool").path)
        XCTAssertEqual(FileVersion(path: app.path), before, "the folder itself says nothing of it")
        XCTAssertEqual(readsAfterAsking(), 2, "its executable arrived")
        try plist(identifier: "com.example.tool").write(to: contents.appending(path: "Info.plist"))
        XCTAssertEqual(readsAfterAsking(), 3, "its Info.plist arrived")
        try FileManager.default.createDirectory(at: contents.appending(path: "_CodeSignature"), withIntermediateDirectories: true)
        try Data("a seal".utf8).write(to: contents.appending(path: "_CodeSignature/CodeResources"))
        XCTAssertEqual(readsAfterAsking(), 4, "the seal over its resources arrived")
        try codesign(["--force", "--sign", "-", app.path])
        XCTAssertEqual(cache.signature(at: app.path)?.signer, .adHoc)
        XCTAssertEqual(readsAfterAsking(), 5)
    }

    /// The main executable, with the Info.plist, what `_CodeSignature` holds and the folders
    /// between them when it is a bundle's, however the bundle is laid out, whether or not it
    /// is signed, and whether or not each is there. Asking before the read names the same.
    func testAReadingNamesTheFilesItRestsOn() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tattle-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: folder) }
        func files(_ path: URL, file: StaticString = #filePath, line: UInt = #line) -> Set<String> {
            let read = CodeSignature.reading(path: path.path).files
            XCTAssertEqual(CodeSignature.files(readAt: path.path), read, "asked before the read", file: file, line: line)
            // By the folder each is in, which is there even when the file is not.
            return Set(read.map { URL(fileURLWithPath: $0) }.map {
                $0.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: $0.lastPathComponent).path
            })
        }
        func make(_ executable: URL, info: URL) throws {
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: "/bin/ls", toPath: executable.path)
            try codesign(["--remove-signature", executable.path])
            try plist(identifier: "com.example.tool").write(to: info)
        }
        func paths(_ folder: URL, _ names: String...) -> Set<String> { Set(names.map { folder.appending(path: $0).path }) }

        let app = folder.appending(path: "Tool.app")
        let executable = app.appending(path: "Contents/MacOS/Tool"), info = app.appending(path: "Contents/Info.plist")
        let unsigned = paths(app, "Contents/MacOS/Tool", "Contents/Info.plist", "Contents/_CodeSignature", "Contents", "Contents/MacOS").union([app.path])
        try make(executable, info: info)
        XCTAssertEqual(files(app), unsigned, "unsigned, so its seal is named though it is not there")
        XCTAssertEqual(files(executable), unsigned, "the executable is read as its bundle")
        try codesign(["--force", "--sign", "-", app.path])
        XCTAssertEqual(files(app), unsigned.union(paths(app, "Contents/_CodeSignature/CodeResources")))

        let shallow = folder.appending(path: "Shallow.app")
        try make(shallow.appending(path: "Tool"), info: shallow.appending(path: "Info.plist"))
        XCTAssertEqual(files(shallow), paths(shallow, "Tool", "Info.plist", "_CodeSignature").union([shallow.path]), "no Contents folder")

        // As an iOS app is installed on a Mac.
        let wrapper = folder.appending(path: "Wrapped.app"), inner = wrapper.appending(path: "Wrapper/Inner.app")
        try make(inner.appending(path: "Tool"), info: inner.appending(path: "Info.plist"))
        try FileManager.default.createSymbolicLink(atPath: wrapper.appending(path: "WrappedBundle").path, withDestinationPath: "Wrapper/Inner.app")
        XCTAssertEqual(files(wrapper), paths(inner, "Tool", "Info.plist", "_CodeSignature").union([inner.path]))

        // An app being put in place: a folder that cannot be read as code yet.
        let partial = folder.appending(path: "Partial.app")
        try FileManager.default.createDirectory(at: partial.appending(path: "Contents"), withIntermediateDirectories: true)
        XCTAssertEqual(files(partial), paths(partial, "Contents", "Contents/MacOS", "Contents/Info.plist"))

        XCTAssertEqual(files(URL(fileURLWithPath: "/bin/ls")), ["/bin/ls", "/bin/Info.plist"], "no bundle until an Info.plist is beside it")
        XCTAssertEqual(files(folder.appending(path: "missing")), [])
    }

    private func plist(identifier: String) throws -> Data {
        let info = ["CFBundleExecutable": "Tool", "CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"]
        return try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
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
    func testParseServices() throws {
        let output = """
            gui/501 = {
            \ttype = gui
            \tservices = {
            \t\t   76560      - \tapplication.com.ableton.live.62578060
            \t\t       0      0 \tcom.uaudio.ua-connect.ShipIt
            \t\t       0     -9 \tcom.example.crashed
            \t\t     685      - \tcom.apple.syncdefaultsd
            \t\t     711      - \tlocal.my agent
            \t\t     712      - \tlocal.tab\tagent
            \t}
            \tendpoints = {
            \t\t"com.not.a.service" => { port = 1 }
            \t}
            }
            """
        let services = try XCTUnwrap(LaunchctlState.parseServices(output))
        XCTAssertEqual(services.count, 6)
        XCTAssertEqual(services["local.my agent"], .init(pid: 711, lastExitStatus: nil), "a label holds what follows the tab")
        XCTAssertEqual(services["local.tab\tagent"], .init(pid: 712, lastExitStatus: nil))
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

    /// One `launchctl print` gives both: its other blocks hold nothing either parser takes.
    func testOnePrintOfADomainGivesItsServicesAndItsOverrides() {
        let output = """
            gui/501 = {
            \tservices = {
            \t\t     685      - \tcom.apple.syncdefaultsd
            \t}
            \tendpoints = {
            \t\t"com.not.a.service" => { port = 1 }
            \t}
            \tdisabled services = {
            \t\t"com.apple.Siri.agent" => disabled
            \t}
            }
            """
        XCTAssertEqual(LaunchctlState.parseServices(output).map { Array($0.keys) }, ["com.apple.syncdefaultsd"])
        XCTAssertEqual(LaunchctlState.parseOverrides(output), ["com.apple.Siri.agent": true])
    }

    /// The job's own `path` line, never one of a nested block's, and none when a label's line
    /// break makes a second.
    func testAJobsPathIsItsOneFirstLevelPathLine() {
        func print(_ lines: String) -> String { "gui/501/com.acme.agent = {\n\tactive count = 1\n\(lines)\tstdout path = /tmp/out\n\tendpoints = {\n\t\tpath = /nested\n\t}\n}\n" }
        XCTAssertEqual(Launchctl.jobPath(print("\tpath = /Users/username/Library/LaunchAgents/a.plist\n")), "/Users/username/Library/LaunchAgents/a.plist")
        XCTAssertEqual(Launchctl.jobPath(print("\tpath = (submitted by Acme[42])\n")), "(submitted by Acme[42])")
        XCTAssertNil(Launchctl.jobPath(print("")))
        XCTAssertNil(Launchctl.jobPath(print("\tpath = /a.plist\n\tpath = /b.plist\n")))
        XCTAssertFalse(Launchctl.isSameFile("(submitted by Acme[42])", "/a.plist"))
        XCTAssertTrue(Launchctl.isSameFile("/Library/LaunchAgents/../LaunchAgents/a.plist", "/Library/LaunchAgents/a.plist"))
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
        XCTAssertEqual(LaunchctlState.read(pathsOf: [.gui: [label]]).gui.jobPaths[label].map { Launchctl.isSameFile($0, plist.path) }, true)
        let other = FileManager.default.temporaryDirectory.appending(path: label + ".other.plist")
        XCTAssertThrowsError(try Launchctl.unload(label: label, from: other), "another plist's job is not unloaded")
        XCTAssertNotNil(LaunchctlState.read().gui.services[label])
        try Launchctl.unload(label: label, from: plist)
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
        for signer: CodeSignature.Signer in [.unsigned, .adHoc, .invalid, .notIssuedByApple] {
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
