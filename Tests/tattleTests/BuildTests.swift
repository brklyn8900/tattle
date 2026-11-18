import XCTest
@testable import tattle

/// Checks on how `make app` builds the bundle, read from make's dry run, so make builds nothing.
final class BuildTests: XCTestCase {
    private var repository: URL { URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    private func recipe(_ variables: [String], environment: [String: String] = [:], status: Int32 = 0) throws -> [String] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/make")
        process.arguments = ["-n", "-C", repository.path, "app"] + variables
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if waitForExit(process) { XCTAssertEqual(process.terminationStatus, status, "make app \(variables)") }
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

    /// make app records the version and the commit under the keys Settings reads. The version
    /// is given here, as make release gives it: a clone without tags, such as CI's, has none.
    func testEveryBuildRecordsItsVersionAndCommitWhereTheAppReadsThem() throws {
        let lines = try recipe(["SIGN_IDENTITY=-", "VERSION=2026.11.17.1"])
        // The dry run prints a command's continued lines one by one.
        let start = try XCTUnwrap(lines.firstIndex { $0.contains("version='2026.11.17.1'") })
        let end = lines[start...].firstIndex { !$0.hasSuffix("\\") } ?? lines.endIndex - 1
        let command = lines[start...end].joined(separator: "\n")
        XCTAssertTrue(command.contains("plutil -replace \(AppVersion.versionKey) "), command)
        XCTAssertTrue(command.contains("plutil -replace \(AppVersion.sourceCommitKey) "), command)
    }

    /// One exported in the environment must not stamp a build.
    func testTheVersionIsTakenFromTheCommandLineOnly() throws {
        let lines = try recipe(["SIGN_IDENTITY=-"], environment: ["VERSION": "2026.11.17.9"])
        XCTAssertFalse(lines.contains { $0.contains("2026.11.17.9") })
    }

    func testAVersionOfAnotherFormIsRefused() throws {
        for version in ["2026.11.17", "2026.11.17.0", "v2026.11.17.1", "1.0"] {
            XCTAssertEqual(try recipe(["SIGN_IDENTITY=-", "VERSION=\(version)"], status: 2), [], version)
        }
    }

    /// Nothing committed says which release the code is: the source's Info.plist holds a
    /// placeholder the app reads as no version.
    func testTheSourceCarriesNoVersion() throws {
        let data = try Data(contentsOf: repository.appending(path: "Resources/Info.plist"))
        let info = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(AppVersion.text(info: info), "Unknown")
        XCTAssertEqual(AppVersion.text(info: info.merging([AppVersion.sourceCommitKey: "abc1234"]) { $1 }), "abc1234")
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
