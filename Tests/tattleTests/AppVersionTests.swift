import XCTest
@testable import tattle

final class AppVersionTests: XCTestCase {
    private let version = AppVersion.versionKey, commit = AppVersion.sourceCommitKey

    func testEveryCopyShowsItsVersionAndCommit() {
        XCTAssertEqual(AppVersion.text(info: [version: "2026.11.17.1", commit: "abc1234"]), "2026.11.17.1 (abc1234)")
        XCTAssertEqual(AppVersion.text(info: [version: "2026.11.17.12", commit: "abc1234-dirty"]), "2026.11.17.12 (abc1234-dirty)")
    }

    /// A build where no release tag can be read, such as a shallow clone's.
    func testNoVersionShowsTheCommitAlone() {
        XCTAssertEqual(AppVersion.text(info: [commit: "abc1234"]), "abc1234")
        XCTAssertEqual(AppVersion.text(info: [version: "0.0.0", commit: "abc1234"]), "abc1234", "a placeholder")
        XCTAssertEqual(AppVersion.text(info: [version: "", commit: "abc1234-dirty"]), "abc1234-dirty")
    }

    func testNoCommitShowsTheVersionAlone() {
        XCTAssertEqual(AppVersion.text(info: [version: "2026.11.17.1"]), "2026.11.17.1")
        XCTAssertEqual(AppVersion.text(info: [version: "2026.11.17.1", commit: ""]), "2026.11.17.1")
    }

    /// A build from a source archive, or a bare executable, which has no Info.plist.
    func testNeitherShowsAPlainWord() {
        XCTAssertEqual(AppVersion.text(info: [:]), "Unknown")
        XCTAssertEqual(AppVersion.text(info: [version: "0.0.0"]), "Unknown", "a placeholder")
        XCTAssertEqual(AppVersion.text(info: [version: "2026.11.17.0"]), "Unknown", "N counts from 1")
        XCTAssertEqual(AppVersion.text(info: [version: "2026.11.17.1\n"]), "Unknown")
    }
}
