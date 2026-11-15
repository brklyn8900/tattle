import GRDB
import XCTest
@testable import tattle

/// The database is a file any process of the user can write (ADR-0005). These put rows into
/// the rule table as such a process would, with SQL and not through the store, and ask what
/// the app then says of an item.
@MainActor
final class PlantedRuleTests: XCTestCase {
    private var database: AppDatabase!
    private var store: RuleStore!
    private var explainer: Explainer!

    private let repoSeeds = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Resources/knowledge")

    /// The planting process's own identity, which it can work out for its own file.
    private let own: CodeIdentity = "ad-hoc:ab:/Users/username/Library/.hidden/updater"

    override func setUpWithError() throws {
        database = try AppDatabase.inMemory()
        store = try RuleStore(database: database)
        explainer = Explainer(store: store, settings: try AppSettings(store: SettingsStore(database: database)))
    }

    /// Dated a day ahead, as a planter would, so the row is the newest of its rank.
    private func plant(
        kind: String = "process", match: String = "exact", pattern: String, owner: String? = nil,
        purpose: String = "A harmless helper.", category: String? = nil, risk: String = "low",
        source: String, identity: String = "", confirmed: Bool = false
    ) throws {
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO rule (kind, match, pattern, owner, purpose, category, risk, source, identity, confirmed, created)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, CASE WHEN ? THEN datetime('now') END, datetime('now', '+1 day'))
                """, arguments: [kind, match, pattern, owner, purpose, category, risk, source, identity, confirmed])
        }
    }

    private func said(_ rule: Rule?) -> String {
        rule.map { "reads \"\($0.purpose)\" \u{00B7} \($0.sourceText) \u{00B7} risk \($0.risk?.rawValue ?? "none")" } ?? "no answer"
    }

    /// The review's row as written: no identity. Since every rule about a program needs one,
    /// it answers for nothing.
    func testAPlantedProgramRowWithNoIdentityAnswersForNothing() async throws {
        try plant(pattern: "updater", source: "builtin")
        try plant(pattern: "updater", source: "user")
        var found = try await explainer.lookup(ExplainRequest(kind: .process, key: "updater", identity: own))
        XCTAssertNil(found, said(found))
        found = try await explainer.lookup(ExplainRequest(kind: .process, key: "updater"))
        XCTAssertNil(found, said(found))
    }

    /// The same row with the planter's own identity in it.
    func testAPlantedProgramRowWithTheProcesssOwnIdentityIsNotTattlesRule() async throws {
        try plant(pattern: "updater", source: "builtin", identity: own.text)
        let found = try await explainer.lookup(ExplainRequest(kind: .process, key: "updater", identity: own))
        XCTAssertNil(found, said(found))
    }

    func testAPlantedProgramRowWithTheProcesssOwnIdentityIsNotTheUsersRule() async throws {
        try plant(pattern: "updater", source: "user", identity: own.text)
        let found = try await explainer.lookup(ExplainRequest(kind: .process, key: "updater", identity: own))
        XCTAssertNil(found, said(found))
    }

    /// What stays open (ADR-0005): a planted row can read as a model's answer, confirmed or
    /// not, and as nothing more.
    func testAPlantedModelRowReadsAsAModelsAnswer() async throws {
        try plant(pattern: "updater", source: "llm", identity: own.text, confirmed: true)
        let found = try await explainer.lookup(ExplainRequest(kind: .process, key: "updater", identity: own))
        XCTAssertEqual(found?.sourceText, "Model answer, confirmed by you")
    }

    /// A port-wide rule is about no one program, so it needs no identity: one row answers for
    /// every listener.
    func testAPlantedPortWideRowIsNotTattlesRule() async throws {
        try plant(kind: "port", match: "glob", pattern: "*:*", source: "builtin")
        let found = try await explainer.lookup(ExplainRequest(kind: .port, key: "updater:tcp/7000"))
        XCTAssertNil(found, said(found))
    }

    /// A model's answer is kept for the exact item, so a pattern in the file is no one's
    /// answer: a single row would speak for every host or every listener.
    func testAPlantedPatternAnswersForNothing() async throws {
        try plant(kind: "host", match: "glob", pattern: "*", source: "llm", confirmed: true)
        try plant(kind: "port", match: "glob", pattern: "*:*", source: "llm", confirmed: true)
        var found = try await explainer.lookup(ExplainRequest(kind: .host, key: "anything.example"))
        XCTAssertNil(found, said(found))
        found = try await explainer.lookup(ExplainRequest(kind: .port, key: "updater:tcp/7000"))
        XCTAssertNil(found, said(found))
        XCTAssertEqual(try store.rules(), [])
    }

    /// A host is its own name, so its row needs no identity either, and a relay category
    /// changes what the Network row says of the connection.
    func testAPlantedHostRowDoesNotMakeADestinationReadRelayed() async throws {
        try plant(kind: "host", pattern: "c2.example", category: "relay", source: "user")
        try plant(kind: "host", pattern: "cover.example", category: "ech-cover", source: "builtin")
        let observer = NetworkObserver(store: ConnectionStore(database: database), rules: store,
                                       settings: try AppSettings(store: SettingsStore(database: database)))
        XCTAssertEqual(observer.kind(of: "c2.example", source: .sni), .destination)
        XCTAssertEqual(observer.kind(of: "cover.example", source: .sni), .destination)
        let found = try await explainer.lookup(ExplainRequest(kind: .host, key: "c2.example"))
        XCTAssertNil(found, said(found))
    }

    /// A row the app cannot read fails the file's lookup for its name. What a name is comes
    /// from the shipped rules alone, so the row cannot make a relay read as a destination.
    func testAPlantedRowThatCannotBeReadDoesNotUnmakeARelay() throws {
        SeedLoader(rules: store).load(from: repoSeeds)
        let observer = NetworkObserver(store: ConnectionStore(database: database), rules: store,
                                       settings: try AppSettings(store: SettingsStore(database: database)))
        try plant(kind: "host", pattern: "mask.icloud.com", risk: "no such level", source: "llm")
        try plant(kind: "host", pattern: "cloudflare-ech.com", risk: "no such level", source: "llm")
        XCTAssertThrowsError(try store.candidates(kind: .host, key: "mask.icloud.com"), "the row is one the app cannot read")
        XCTAssertEqual(observer.kind(of: "mask.icloud.com", source: .sni), .relay)
        XCTAssertEqual(observer.kind(of: "cloudflare-ech.com", source: .sni), .hidden)
    }

    /// The shipped rule does not depend on the file, so a row there that the app cannot read
    /// does not take it off the item's detail.
    func testAPlantedRowThatCannotBeReadDoesNotHideTheShippedRule() async throws {
        SeedLoader(rules: store).load(from: repoSeeds)
        let shipped = try XCTUnwrap(try store.rules(kind: .process).first { $0.describesApplesProgram })
        try plant(pattern: shipped.pattern, risk: "no such level", source: "llm")
        try plant(kind: "host", pattern: "mask.icloud.com", risk: "no such level", source: "llm")
        XCTAssertThrowsError(try store.candidates(kind: .process, key: shipped.pattern), "the row is one the app cannot read")
        var found = try await explainer.lookup(ExplainRequest(kind: .process, key: shipped.pattern, isApplesProgram: true))
        XCTAssertEqual(found?.purpose, shipped.purpose, said(found))
        XCTAssertEqual(found?.source, .builtin, said(found))
        found = try await explainer.lookup(ExplainRequest(kind: .host, key: "mask.icloud.com"))
        XCTAssertEqual(found?.source, .builtin, said(found))
    }

    /// Nor does a rule table that is gone: every shipped rule still answers.
    func testADroppedRuleTableDoesNotHideTheShippedRules() async throws {
        SeedLoader(rules: store).load(from: repoSeeds)
        let shipped = try XCTUnwrap(try store.rules(kind: .process).first { $0.describesApplesProgram })
        try await database.writer.write { try $0.execute(sql: "DROP TABLE rule") }
        XCTAssertThrowsError(try store.candidates(kind: .process, key: shipped.pattern))
        var found = try await explainer.lookup(ExplainRequest(kind: .process, key: shipped.pattern, isApplesProgram: true))
        XCTAssertEqual(found?.purpose, shipped.purpose, said(found))
        found = try await explainer.lookup(ExplainRequest(kind: .host, key: "mask.icloud.com"))
        XCTAssertEqual(found?.category, "relay", said(found))
        found = try await explainer.lookup(ExplainRequest(kind: .host, key: "unknown.example"))
        XCTAssertNil(found, said(found))
    }

    /// Loading the seed files, at this launch or the next, does not make a planted row a rule.
    func testAPlantedRowIsNoRuleBesideTheShippedOnes() async throws {
        let loader = SeedLoader(rules: store)
        XCTAssertEqual(loader.load(from: repoSeeds).count, 3)
        try plant(pattern: "updater", source: "builtin", identity: own.text)
        XCTAssertEqual(loader.load(from: repoSeeds).count, 3)
        let found = try await explainer.lookup(ExplainRequest(kind: .process, key: "updater", identity: own))
        XCTAssertNil(found, said(found))
    }

    /// A row can also speak for one of Apple's programs, over the shipped rule.
    func testAPlantedRowDoesNotReplaceTheShippedRuleAboutApplesProgram() async throws {
        SeedLoader(rules: store).load(from: repoSeeds)
        let shipped = try XCTUnwrap(try store.rules(kind: .process).first { $0.describesApplesProgram })
        try plant(pattern: shipped.pattern, owner: "Apple", purpose: "Malware. Delete it.", source: "builtin", identity: "x")
        let found = try await explainer.lookup(ExplainRequest(kind: .process, key: shipped.pattern, isApplesProgram: true))
        XCTAssertEqual(found?.purpose, shipped.purpose, said(found))
    }
}
