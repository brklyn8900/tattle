import XCTest
@testable import tattle

final class SeedLoaderTests: XCTestCase {
    private var rules: RuleStore!
    private var settings: SettingsStore!
    private var loader: SeedLoader!

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
        for host in ["mask.icloud.com", "mask-api.icloud.com", "MASK-H2.icloud.com", "ohttp-relay.cloudflare.com"] {
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
        for host in ["ohttp-relay-a.cloudflare.com", "ohttp-relay.fastly-edge.com"] {
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

    /// Apple's host list (support.apple.com/101555) names what these serve, and none is Private
    /// Relay. The two for Private Cloud Compute are third parties' relays, so they read as
    /// relayed (ADR-0001); the one for Extensions is where the traffic goes.
    func testHostsAppleNamesReadAsWhatAppleSaysTheyAre() throws {
        _ = loader.load(from: repoSeeds)
        for (host, owner) in [("apple-relay.cloudflare.com", "Cloudflare"), ("apple-relay.fastly-edge.com", "Fastly")] {
            let rule = try XCTUnwrap(try rules.lookup(kind: .host, key: host), host)
            XCTAssertEqual(ConnectionName.kind(forCategory: rule.category), .relay, host)
            XCTAssertEqual(rule.owner, owner, "a third party runs Private Cloud Compute's relay")
            XCTAssertTrue(rule.purpose.contains("Private Cloud Compute"), host)
            XCTAssertFalse(rule.purpose.contains("Private Relay"), host)
            XCTAssertFalse(rule.purpose.contains("hidden"), host)
        }
        let extensions = try XCTUnwrap(try rules.lookup(kind: .host, key: "apple-relay.apple.com"))
        XCTAssertEqual(ConnectionName.kind(forCategory: extensions.category), .destination)
        XCTAssertTrue(extensions.purpose.contains("Apple Intelligence Extensions"))
        XCTAssertFalse(extensions.purpose.contains("hidden"))
    }

    /// No source says Apple runs or uses these: their domains are the operators'.
    func testOhttpRelaysClaimNothingAboutApple() throws {
        _ = loader.load(from: repoSeeds)
        for (host, owner) in [("ohttp-relay.cloudflare.com", "Cloudflare"), ("ohttp-relay.fastly-edge.com", "Fastly")] {
            let rule = try XCTUnwrap(try rules.lookup(kind: .host, key: host), host)
            XCTAssertEqual(rule.owner, owner, host)
            XCTAssertFalse(rule.purpose.contains("Apple"), host)
            XCTAssertEqual(rule.confidence, .medium, "read from its name alone: \(host)")
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
        XCTAssertEqual(loader.load(from: folder), [], "a file that does not parse and one whose source is no seed's are skipped")
        XCTAssertEqual(loader.load(from: folder.appending(path: "missing")), [])
    }

    private func seed(_ url: URL, _ hosts: [String: String]) throws {
        let entries = hosts.map { #"{"kind":"host","pattern":"\#($0.key)","purpose":"\#($0.value)"}"# }
        try Data(#"{"source":"builtin","rules":[\#(entries.joined(separator: ","))]}"#.utf8).write(to: url)
    }
}
