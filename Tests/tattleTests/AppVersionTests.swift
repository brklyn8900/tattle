import XCTest
@testable import tattle

final class AppVersionTests: XCTestCase {
    private let version = "CFBundleShortVersionString"

    func testTheReleaseShowsItsVersionAlone() {
        XCTAssertEqual(AppVersion.text(info: [version: "2026.11.17.1"]), "2026.11.17.1")
    }

    func testAnotherBuildShowsDevAndItsCommit() {
        XCTAssertEqual(AppVersion.text(info: [version: "2026.11.17.1", AppVersion.sourceCommitKey: "abc1234"]),
                       "2026.11.17.1 dev (abc1234)")
        XCTAssertEqual(AppVersion.text(info: [version: "2026.11.17.1", AppVersion.sourceCommitKey: "abc1234-dirty"]),
                       "2026.11.17.1 dev (abc1234-dirty)")
        XCTAssertEqual(AppVersion.text(info: [version: "2026.11.17.1", AppVersion.sourceCommitKey: "unknown"]),
                       "2026.11.17.1 dev (unknown)")
    }

    /// No version key is no release: a bare executable has no Info.plist.
    func testABundleWithoutAVersionIsNotTheRelease() {
        XCTAssertEqual(AppVersion.text(info: [:]), "unknown dev (unknown)")
        XCTAssertEqual(AppVersion.text(info: [AppVersion.sourceCommitKey: "abc1234"]), "unknown dev (abc1234)")
    }
}
