import XCTest

/// What scripts/source-version.sh reads for make app to record, in throwaway repositories.
final class SourceVersionTests: XCTestCase {
    private var script: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "scripts/source-version.sh")
    }

    private var directory: URL!

    // The person's own git configuration, such as commit signing, stays out of the fixtures.
    private let environment = [
        "PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "user", "GIT_AUTHOR_EMAIL": "user@example.com",
        "GIT_COMMITTER_NAME": "user", "GIT_COMMITTER_EMAIL": "user@example.com",
    ]

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "source-version-\(getpid())-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let directory = directory!
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    }

    @discardableResult
    private func run(_ arguments: [String], in folder: URL, executable: String = "/usr/bin/git") throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if waitForExit(process) { XCTAssertEqual(process.terminationStatus, 0, "\(executable) \(arguments)") }
        return text.trimmingCharacters(in: .newlines)
    }

    private func read(_ value: String, in folder: URL) throws -> String {
        try run([script.path, value], in: folder, executable: "/bin/sh")
    }

    private func commit(_ repository: URL, _ message: String) throws {
        try message.write(to: repository.appending(path: "file"), atomically: true, encoding: .utf8)
        try run(["add", "file"], in: repository)
        try run(["commit", "-q", "-m", message], in: repository)
    }

    /// A repository with releases 2026.11.16.1, .9 (annotated) and .10 behind HEAD, a tag that
    /// is not a release, a tag of N 0, and a later release on a branch HEAD does not include.
    private func repository() throws -> URL {
        let repository = directory.appending(path: "repo")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try run(["init", "-q", "-b", "main"], in: repository)
        try commit(repository, "one")
        try run(["tag", "v2026.11.16.1"], in: repository)
        try commit(repository, "two")
        try run(["tag", "-a", "-m", "release", "v2026.11.16.9"], in: repository)
        try commit(repository, "three")
        try run(["tag", "v2026.11.16.10"], in: repository)
        try run(["tag", "v9999.1"], in: repository)
        try run(["tag", "v2026.11.17.0"], in: repository)
        try run(["switch", "-q", "-c", "other"], in: repository)
        try commit(repository, "elsewhere")
        try run(["tag", "v2026.11.20.1"], in: repository)
        try run(["switch", "-q", "main"], in: repository)
        try commit(repository, "four")
        return repository
    }

    func testTheNewestReleaseHeadIncludes() throws {
        let repository = try repository()
        XCTAssertEqual(try read("version", in: repository), "2026.11.16.10")
        XCTAssertEqual(try read("commit", in: repository), try run(["rev-parse", "--short", "HEAD"], in: repository))
    }

    func testAChangedTreeIsDirty() throws {
        let repository = try repository()
        let head = try run(["rev-parse", "--short", "HEAD"], in: repository)
        try "changed".write(to: repository.appending(path: "file"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try read("commit", in: repository), "\(head)-dirty")
        XCTAssertEqual(try read("version", in: repository), "2026.11.16.10")
    }

    func testAShallowCloneWithoutTheTagHasNoVersion() throws {
        let repository = try repository()
        let clone = directory.appending(path: "shallow")
        // A plain path would be copied whole; file:// makes --depth count.
        try run(["clone", "-q", "--depth", "1", "-b", "main", "file://\(repository.path)", clone.path], in: directory)
        XCTAssertEqual(try read("version", in: clone), "")
        XCTAssertEqual(try read("commit", in: clone), try run(["rev-parse", "--short", "HEAD"], in: repository))
    }

    func testASourceArchiveHasNeither() throws {
        let repository = try repository()
        let archive = directory.appending(path: "archive.tar"), unpacked = directory.appending(path: "unpacked")
        try run(["archive", "-o", archive.path, "HEAD"], in: repository)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try run(["-xf", archive.path], in: unpacked, executable: "/usr/bin/tar")
        XCTAssertEqual(try read("version", in: unpacked), "")
        XCTAssertEqual(try read("commit", in: unpacked), "")
    }

    /// Its own commit would be another repository's.
    func testACopyInsideAnotherRepositoryHasNeither() throws {
        let repository = try repository()
        let copy = repository.appending(path: "copy")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        XCTAssertEqual(try read("version", in: copy), "")
        XCTAssertEqual(try read("commit", in: copy), "")
    }

    func testARepositoryWithoutCommitsHasNeither() throws {
        let empty = directory.appending(path: "empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try run(["init", "-q"], in: empty)
        XCTAssertEqual(try read("version", in: empty), "")
        XCTAssertEqual(try read("commit", in: empty), "")
    }
}
