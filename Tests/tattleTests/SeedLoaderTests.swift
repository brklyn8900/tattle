import XCTest
@testable import tattle

final class SeedLoaderTests: XCTestCase {
    private var rules: RuleStore!
    private var settings: SettingsStore!
    private var loader: SeedLoader!

    /// The seed files checked into the repo.
    private let repoSeeds = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Resources/knowledge")

    override func setUpWithError() throws {
        let database = try AppDatabase.inMemory()
        rules = RuleStore(database: database)
        settings = SettingsStore(database: database)
        loader = SeedLoader(rules: rules, settings: settings)
    }

    func testRepoSeedsLoadAndRelayNamesResolve() throws {
        XCTAssertEqual(loader.load(from: repoSeeds), [.appleList, .builtin, .trackerRadar])
        for host in ["mask.icloud.com", "mask-api.icloud.com", "MASK-H2.icloud.com", "apple-relay.apple.com", "ohttp-relay.cloudflare.com"] {
            XCTAssertEqual(try rules.lookup(kind: .host, key: host)?.category, "relay", host)
        }
        XCTAssertEqual(try rules.lookup(kind: .host, key: "cloudflare-ech.com")?.category, "ech-cover")
        XCTAssertNil(try rules.lookup(kind: .host, key: "gateway.icloud.com"))
        XCTAssertTrue(try rules.rules().allSatisfy { $0.source == .builtin }, "the other seed files are empty")
    }

    /// A relay or cover rule makes a row read "relayed" or "name hidden", so a name that only
    /// starts like an operator's host must not reach it.
    func testRelayAndCoverRulesAreAnchoredToTheOperatorsDomains() throws {
        _ = loader.load(from: repoSeeds)
        for host in ["apple-relay.cloudflare.com", "apple-relay.fastly-edge.com", "ohttp-relay-a.cloudflare.com", "ohttp-relay.fastly-edge.com"] {
            XCTAssertEqual(try rules.lookup(kind: .host, key: host)?.category, "relay", host)
        }
        for host in [
            "mask.evil.example", "mask.icloud.com.evil.example", "mask.icloud.com.evil.net",
            "apple-relay.c2.example", "apple-relay.apple.com.evil.example",
            "apple-relay.cloudflare.com.evil.example", "apple-relay.fastly-edge.com.evil.example",
            "ohttp-relay.evil.example", "ohttp-relay.cloudflare.com.evil.example",
            "ohttp-relay.fastly-edge.com.evil.example", "cloudflare-ech.com.evil.example",
        ] {
            XCTAssertNil(try rules.lookup(kind: .host, key: host), host)
        }
    }

    func testUnchangedFileIsNotReapplied() throws {
        XCTAssertEqual(loader.load(from: repoSeeds).count, 3)
        XCTAssertEqual(loader.load(from: repoSeeds), [])
    }

    func testChangedFileReplacesRulesAndKeepsConfirmation() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "builtin.json")

        try seed(file, ["a.example": "first", "stale.example": "going"])
        XCTAssertEqual(loader.load(from: folder), [.builtin])
        let a = try XCTUnwrap(try rules.lookup(kind: .host, key: "a.example"))
        try rules.confirm(id: a.id!, at: Date(timeIntervalSince1970: 1_000))

        try seed(file, ["a.example": "second", "new.example": "fresh"])
        XCTAssertEqual(loader.load(from: folder), [.builtin])
        let after = try XCTUnwrap(try rules.lookup(kind: .host, key: "a.example"))
        XCTAssertEqual(after.purpose, "second")
        XCTAssertEqual(after.confirmed, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(after.created, a.created)
        XCTAssertNil(try rules.lookup(kind: .host, key: "stale.example"))
        XCTAssertNotNil(try rules.lookup(kind: .host, key: "new.example"))
    }

    func testBadFilesAreSkippedAndMissingFolderIsFine() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("not json".utf8).write(to: folder.appending(path: "builtin.json"))
        try Data(#"{"source":"llm","rules":[]}"#.utf8).write(to: folder.appending(path: "tracker-radar.json"))
        XCTAssertEqual(loader.load(from: folder), [], "unparseable and source-mismatched files are skipped")
        XCTAssertEqual(loader.load(from: folder.appending(path: "missing")), [])
    }

    private func seed(_ url: URL, _ hosts: [String: String]) throws {
        let entries = hosts.map { #"{"kind":"host","pattern":"\#($0.key)","purpose":"\#($0.value)"}"# }
        try Data(#"{"source":"builtin","rules":[\#(entries.joined(separator: ","))]}"#.utf8).write(to: url)
    }
}
