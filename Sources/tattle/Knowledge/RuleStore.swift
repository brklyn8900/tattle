import Foundation
import GRDB
import os

/// The knowledge base: the shipped rules, in memory, and the model's answers, in the file.
/// Any process of the user can write the file, so of its rule table only a model's answers
/// are read, each for the exact item: a row there that claims a shipped source or the user's,
/// or that holds a pattern, is not a rule (ADR-0005).
struct RuleStore: Sendable {
    let database: AppDatabase
    /// The shipped rules, where no other process writes: a database in memory, made by the
    /// file's own migrations, so its rule table has the file's columns at every version.
    private let shipped: DatabaseQueue

    init(database: AppDatabase) throws {
        self.database = database
        shipped = try DatabaseQueue()
        try AppDatabase.migrator.migrate(shipped)
    }

    /// Counts the writes through this store and its copies, so a reader that remembers
    /// answers derived from rules can tell when they may be stale.
    private let writes = OSAllocatedUnfairLock(initialState: 0)

    var revision: Int { writes.withLock { $0 } }

    private func wrote() { writes.withLock { $0 += 1 } }

    /// Keeps a model's answer in the file, replacing an existing one with the same kind, match,
    /// pattern, source and identity. Returns the stored rule with its id. A rule of another
    /// source, or a pattern, is stored and never read. An unconfirmed rule never replaces a
    /// confirmed one of the same key: the upsert would reset the confirmation and the
    /// creation date, and a confirmed rule is the user's own.
    @discardableResult
    func save(_ rule: Rule) throws -> Rule {
        defer { wrote() }
        return try database.writer.write { db in
            if rule.confirmed == nil, let kept = try Self.confirmed(rule, in: db) {
                throw RuleStoreError.alreadyConfirmed(kept.id!)
            }
            var rule = rule
            try rule.upsert(db)
            return rule
        }
    }

    func confirmedRule(replacedBy rule: Rule) throws -> Rule? {
        try database.writer.read { try Self.confirmed(rule, in: $0) }
    }

    private static func confirmed(_ rule: Rule, in db: Database) throws -> Rule? {
        try Rule
            .filter(Column("kind") == rule.kind.rawValue && Column("match") == rule.match.rawValue
                    && Column("pattern") == rule.pattern && Column("source") == rule.source.rawValue
                    && Column("identity") == rule.identity && Column("confirmed") != nil)
            .fetchOne(db)
    }

    /// The rule that explains `key`, or nil. Ties are broken by precedence rank, then
    /// exact over glob, then the longer (more specific) pattern, then the newest rule.
    /// Expired LLM rules are ignored even before they are pruned.
    func lookup(kind: Rule.Kind, key: String, now: Date = Date()) throws -> Rule? {
        try candidates(kind: kind, key: key, now: now).first
    }

    /// Every rule matching `key`, best first.
    func candidates(kind: Rule.Kind, key: String, now: Date = Date()) throws -> [Rule] {
        let key = Rule.normalize(key, for: kind)
        let answers = try database.writer.read { db in
            try Rule.fetchAll(
                db,
                sql: "SELECT * FROM rule WHERE kind = :kind AND match = 'exact' AND pattern = :key AND source = 'llm'",
                arguments: ["kind": kind.rawValue, "key": key])
        }
        return Self.bestFirst(try shipped(kind: kind, key: key) + answers.filter { !$0.isExpired(at: now) })
    }

    /// The shipped rules matching `key`, best first. Reads nothing from the file, so nothing
    /// written there, readable or not, changes the answer.
    func shippedCandidates(kind: Rule.Kind, key: String) throws -> [Rule] {
        Self.bestFirst(try shipped(kind: kind, key: Rule.normalize(key, for: kind)))
    }

    private func shipped(kind: Rule.Kind, key: String) throws -> [Rule] {
        try shipped.read { db in
            try Rule.fetchAll(
                db,
                sql: """
                    SELECT * FROM rule
                    WHERE kind = :kind
                      AND ((match = 'exact' AND pattern = :key)
                        OR (match = 'glob' AND :key GLOB pattern))
                    """,
                arguments: ["kind": kind.rawValue, "key": key])
        }
    }

    private static func bestFirst(_ rules: [Rule]) -> [Rule] {
        rules.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.match != b.match { return a.match == .exact }
            if a.pattern.count != b.pattern.count { return a.pattern.count > b.pattern.count }
            return a.created > b.created
        }
    }

    /// Replaces the shipped rules of `source` with `rules`, in memory.
    func replaceShipped(source: Rule.Source, with rules: [Rule]) throws {
        defer { wrote() }
        try shipped.write { db in
            try Rule.filter(Column("source") == source.rawValue).deleteAll(db)
            for var rule in rules {
                rule.id = nil
                rule.source = source
                try rule.upsert(db)
            }
        }
    }

    /// Marks a rule confirmed. The source is kept so provenance is never lost; the rule
    /// ranks with user rules from now on.
    func confirm(id: Int64, at date: Date = Date()) throws {
        defer { wrote() }
        try database.writer.write { db in
            guard var rule = try Rule.fetchOne(db, key: id) else {
                throw RuleStoreError.notFound(id)
            }
            rule.confirmed = date
            try rule.update(db)
        }
    }

    /// Deletes unconfirmed LLM rules older than their lifetime. Returns how many went.
    @discardableResult
    func pruneExpired(now: Date = Date()) throws -> Int {
        defer { wrote() }
        let cutoff = now.addingTimeInterval(-Rule.unconfirmedLLMLifetime)
        return try database.writer.write { db in
            try Rule
                .filter(Column("source") == Rule.Source.llm.rawValue)
                .filter(Column("confirmed") == nil)
                .filter(Column("created") < cutoff)
                .deleteAll(db)
        }
    }

    /// Every rule a lookup reads: the shipped ones and the model's answers.
    func rules(kind: Rule.Kind? = nil) throws -> [Rule] {
        var request = Rule.all()
        if let kind { request = request.filter(Column("kind") == kind.rawValue) }
        let rules = try shipped.read { try request.fetchAll($0) }
        let answers = try database.writer.read { db in
            try request
                .filter(Column("source") == Rule.Source.llm.rawValue && Column("match") == Rule.Match.exact.rawValue)
                .fetchAll(db)
        }
        return (rules + answers).sorted { ($0.kind.rawValue, $0.pattern) < ($1.kind.rawValue, $1.pattern) }
    }
}

enum RuleStoreError: Error, Equatable {
    case notFound(Int64)
    case alreadyConfirmed(Int64)
}
