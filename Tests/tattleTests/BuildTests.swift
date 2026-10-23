import XCTest

/// Checks on how `make app` builds the bundle, read from make's dry run, so nothing is built.
final class BuildTests: XCTestCase {
    private var repository: URL { URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    /// The recipe `make app` would run with the given variables.
    private func recipe(_ variables: [String]) throws -> [String] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/make")
        process.arguments = ["-n", "-C", repository.path, "app"] + variables
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
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
}
