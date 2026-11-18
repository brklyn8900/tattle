import XCTest
@testable import tattle

/// Checks on how `make app` builds the bundle, read from make's dry run, so make builds nothing.
final class BuildTests: XCTestCase {
    private var repository: URL { URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    private func recipe(_ variables: [String]) throws -> [String] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/make")
        process.arguments = ["-n", "-C", repository.path, "app"] + variables
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        if waitForExit(process) { XCTAssertEqual(process.terminationStatus, 0) }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").map(String.init)
    }

    /// Without the hardened runtime, launching Tattle with DYLD_INSERT_LIBRARIES runs foreign
    /// code inside a process the broker accepts (ADR-0003), and the broker refuses such callers.
    /// The dry run prints the whole signing conditional, so this covers ad hoc and an Apple
    /// identity at once.
    func testEverySigningUsesTheHardenedRuntime() throws {
        let signing = try recipe(["SIGN_IDENTITY="]).filter { $0.contains("codesign --force") }
        XCTAssertEqual(signing.count, 4, "two signings in each branch")
        for line in signing {
            XCTAssertTrue(line.contains("--options runtime"), line)
        }
    }

    /// A bundle that records no commit is the release, so every build but make release's
    /// records one, under the key the app reads.
    func testOnlyTheReleaseRecordsNoCommit() throws {
        let recordsCommit = { (line: String) in line.contains("plutil -replace \(AppVersion.sourceCommitKey) ") }
        XCTAssertTrue(try recipe(["SIGN_IDENTITY=-"]).contains(where: recordsCommit))
        XCTAssertFalse(try recipe(["SIGN_IDENTITY=-", "RELEASE=1"]).contains(where: recordsCommit))
    }

    /// What the ad-hoc signing line actually does, not just what it says: a copy of the
    /// broker probe signed with its options, launched with DYLD_INSERT_LIBRARIES, must not
    /// run the library. A copy signed without them must, or the library would prove nothing.
    func testAdHocSigningKeepsInjectedLibrariesOut() throws {
        let line = try XCTUnwrap(try recipe(["SIGN_IDENTITY="]).first { $0.contains("codesign --force") && $0.contains("--sign -") })
        let options = Array(line.split(separator: " ").map(String.init).drop { $0 != "codesign" }.dropFirst().prefix { !$0.contains("Tattle.app") })

        // With System Integrity Protection off, macOS loads the library into a hardened
        // program too (seen on a hosted CI runner), so the Mac cannot show what the options do.
        let csrutil = Process(), status = Pipe()
        csrutil.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil")
        csrutil.arguments = ["status"]
        csrutil.standardOutput = status
        try csrutil.run()
        csrutil.waitUntilExit()
        let protection = String(decoding: status.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard protection.contains("enabled") else { throw XCTSkip("System Integrity Protection is not enabled: \(protection)") }

        let directory = FileManager.default.temporaryDirectory.appending(path: "inject-\(getpid())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "inject.c")
        try #"""
            #include <stdio.h>
            #include <stdlib.h>
            __attribute__((constructor)) static void injected(void) {
                FILE *out = fopen(getenv("INJECT_MARKER"), "w");
                if (out) fclose(out);
            }
            """#.write(to: source, atomically: true, encoding: .utf8)
        let library = directory.appending(path: "inject.dylib")
        try run("/usr/bin/clang", ["-dynamiclib", source.path, "-o", library.path])

        let probe = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "tattle-broker-probe")
        for (name, signing) in [("ad-hoc", options), ("plain", ["--force", "--sign", "-"])] {
            let copy = directory.appending(path: "probe-\(name)")
            try FileManager.default.copyItem(at: probe, to: copy)
            try run("/usr/bin/codesign", signing + [copy.path])
            let marker = directory.appending(path: "\(name).marker")
            // No arguments: the probe prints its usage and exits, after any library has loaded.
            try run(copy.path, [], environment: ["DYLD_INSERT_LIBRARIES": library.path, "INJECT_MARKER": marker.path], status: 2)
            XCTAssertEqual(FileManager.default.fileExists(atPath: marker.path), name == "plain", "\(name), signed with \(signing)")
        }
    }

    private func run(_ path: String, _ arguments: [String], environment: [String: String]? = nil, status: Int32 = 0) throws {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        if waitForExit(process) { XCTAssertEqual(process.terminationStatus, status, "\(path) \(arguments)") }
    }
}
