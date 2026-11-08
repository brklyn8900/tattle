import GRDB
import XCTest
@testable import tattle

final class RuleStoreTests: XCTestCase {
    /// Before the identity was part of a rule's key.
    func testAnExistingRuleSurvivesTheMoveToIdentitiesAndTheNameCanHoldTwo() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v4-connection-app-signer")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO rule (kind, match, pattern, purpose, source, confirmed, created)
                VALUES ('process', 'exact', 'updater', 'old', 'llm', 0, 0)
                """)
        }
        try AppDatabase.migrator.migrate(queue)
        try queue.write { db in
            let rows = try Rule.fetchAll(db)
            XCTAssertEqual(rows.map(\.purpose), ["old"])
            XCTAssertEqual(rows.first?.identity, "", "whose it was was never kept")
            XCTAssertNotNil(rows.first?.confirmed)
            var a = Rule(kind: .process, pattern: "updater", purpose: "a", source: .llm, identity: "team:A:x")
            var b = Rule(kind: .process, pattern: "updater", purpose: "b", source: .llm, identity: "team:B:x")
            var again = Rule(kind: .process, pattern: "updater", purpose: "a2", source: .llm, identity: "team:A:x")
            try a.upsert(db)
            try b.upsert(db)
            try again.upsert(db)
            XCTAssertEqual(try Rule.order(Column("purpose")).fetchAll(db).map(\.purpose), ["a2", "b", "old"])
        }
    }

    private var store: RuleStore!

    override func setUpWithError() throws {
        store = RuleStore(database: try AppDatabase.inMemory())
    }

    private func rule(
        _ pattern: String, kind: Rule.Kind = .host, match: Rule.Match = .exact,
        source: Rule.Source, purpose: String = "p", confirmed: Date? = nil,
        created: Date = Date()
    ) -> Rule {
        Rule(kind: kind, match: match, pattern: pattern, purpose: purpose,
             source: source, confirmed: confirmed, created: created)
    }

    func testExactLookupAndMiss() throws {
        try store.save(rule("gateway.icloud.com", source: .builtin, purpose: "iCloud"))
        XCTAssertEqual(try store.lookup(kind: .host, key: "gateway.icloud.com")?.purpose, "iCloud")
        XCTAssertNil(try store.lookup(kind: .host, key: "example.com"))
        XCTAssertNil(try store.lookup(kind: .process, key: "gateway.icloud.com"), "kind is part of the key")
    }

    func testGlobMatches() throws {
        try store.save(rule("p*-caldav.icloud.com", match: .glob, source: .builtin, purpose: "CalDAV"))
        try store.save(rule("com.apple.*", kind: .launchItem, match: .glob, source: .builtin, purpose: "Apple"))
        XCTAssertEqual(try store.lookup(kind: .host, key: "p61-caldav.icloud.com")?.purpose, "CalDAV")
        XCTAssertNil(try store.lookup(kind: .host, key: "p61-caldav.icloud.com.evil.net"))
        XCTAssertEqual(try store.lookup(kind: .launchItem, key: "com.apple.mdworker")?.purpose, "Apple")
    }

    func testHostsNormalizeCaseAndTrailingDot() throws {
        try store.save(rule("Gateway.iCloud.com.", source: .builtin, purpose: "iCloud"))
        XCTAssertEqual(try store.lookup(kind: .host, key: "GATEWAY.ICLOUD.COM")?.purpose, "iCloud")
        try store.save(rule("/usr/bin/Foo", kind: .process, source: .builtin, purpose: "foo"))
        XCTAssertNil(try store.lookup(kind: .process, key: "/usr/bin/foo"), "process keys stay case-sensitive")
    }

    func testHostNormalizationLowercasesAsciiOnly() throws {
        // U+212A KELVIN SIGN lowercases to ASCII "k" under Unicode rules; a different
        // host must not fold onto slack.com.
        XCTAssertEqual(Rule.normalize("slac\u{212A}.COM..", for: .host), "slac\u{212A}.com")
        XCTAssertNotEqual(Rule.normalize("slac\u{212A}.com", for: .host), "slack.com")
        XCTAssertEqual(Rule.normalize("Slack.COM.", for: .host), "slack.com")
    }

    func testSourcePrecedence() throws {
        for source in Rule.Source.allCases {
            try store.save(rule("a.example", source: source, purpose: source.rawValue))
        }
        XCTAssertEqual(try store.lookup(kind: .host, key: "a.example")?.source, .user)
        XCTAssertEqual(try store.candidates(kind: .host, key: "a.example").map(\.source),
                       Rule.Source.allCases)
    }

    func testConfirmedRuleRanksWithUser() throws {
        try store.save(rule("a.example", source: .builtin, purpose: "builtin"))
        let llm = try store.save(rule("a.example", source: .llm, purpose: "llm"))
        XCTAssertEqual(try store.lookup(kind: .host, key: "a.example")?.purpose, "builtin")

        try store.confirm(id: llm.id!)
        let best = try XCTUnwrap(try store.lookup(kind: .host, key: "a.example"))
        XCTAssertEqual(best.purpose, "llm")
        XCTAssertEqual(best.source, .llm, "provenance is kept")
        XCTAssertNotNil(best.confirmed)
    }

    func testExactBeatsGlobAndLongerGlobBeatsShorter() throws {
        try store.save(rule("*.icloud.com", match: .glob, source: .builtin, purpose: "short"))
        try store.save(rule("*-caldav.icloud.com", match: .glob, source: .builtin, purpose: "long"))
        XCTAssertEqual(try store.lookup(kind: .host, key: "p61-caldav.icloud.com")?.purpose, "long")
        try store.save(rule("p61-caldav.icloud.com", source: .builtin, purpose: "exact"))
        XCTAssertEqual(try store.lookup(kind: .host, key: "p61-caldav.icloud.com")?.purpose, "exact")
    }

    func testPromotionToPatternOnlyAtConfirmation() throws {
        let llm = try store.save(rule("p61-caldav.icloud.com", source: .llm, purpose: "CalDAV"))
        XCTAssertNil(try store.lookup(kind: .host, key: "p62-caldav.icloud.com"))
        try store.confirm(id: llm.id!, promotingTo: "P*-caldav.icloud.com")
        let promoted = try XCTUnwrap(try store.lookup(kind: .host, key: "p62-caldav.icloud.com"))
        XCTAssertEqual(promoted.match, .glob)
        XCTAssertEqual(promoted.pattern, "p*-caldav.icloud.com")
        XCTAssertEqual(promoted.source, .llm)
    }

    func testUnconfirmedLLMRulesExpireAfter45Days() throws {
        let now = Date()
        let old = now.addingTimeInterval(-46 * 86_400)
        let fresh = now.addingTimeInterval(-44 * 86_400)
        try store.save(rule("old.example", source: .llm, created: old))
        try store.save(rule("fresh.example", source: .llm, created: fresh))
        try store.save(rule("kept.example", source: .llm, confirmed: now, created: old))
        try store.save(rule("builtin.example", source: .builtin, created: old))

        XCTAssertNil(try store.lookup(kind: .host, key: "old.example", now: now), "ignored before pruning")
        XCTAssertNotNil(try store.lookup(kind: .host, key: "fresh.example", now: now))

        XCTAssertEqual(try store.pruneExpired(now: now), 1)
        XCTAssertEqual(try store.rules().map(\.pattern), ["builtin.example", "fresh.example", "kept.example"])
    }

    func testSaveReplacesSameKindPatternSource() throws {
        try store.save(rule("a.example", source: .llm, purpose: "first"))
        try store.save(rule("a.example", source: .llm, purpose: "second"))
        try store.save(rule("a.example", source: .user, purpose: "user"))
        XCTAssertEqual(try store.rules().count, 2)
        XCTAssertEqual(try store.candidates(kind: .host, key: "a.example").map(\.purpose), ["user", "second"])
    }

    func testConfirmUnknownIdThrows() {
        XCTAssertThrowsError(try store.confirm(id: 999)) { error in
            XCTAssertEqual(error as? RuleStoreError, .notFound(999))
        }
    }

    func testFileDatabaseMigratesAndPersists() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "tattle.sqlite")

        try RuleStore(database: try AppDatabase(at: url)).save(rule("a.example", source: .builtin))
        let reopened = RuleStore(database: try AppDatabase(at: url))
        XCTAssertEqual(try reopened.rules().count, 1)
    }
}
