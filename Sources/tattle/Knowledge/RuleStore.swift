import Foundation
import GRDB
import os

/// Reads and writes knowledge-base rules.
struct RuleStore: Sendable {
    let database: AppDatabase

    /// Counts the writes through this store and its copies, so a reader that remembers
    /// answers derived from rules can tell when they may be stale.
    private let writes = OSAllocatedUnfairLock(initialState: 0)

    var revision: Int { writes.withLock { $0 } }

    private func wrote() { writes.withLock { $0 += 1 } }

    /// Inserts a rule, replacing an existing one with the same kind, match, pattern and
    /// source. Returns the stored rule with its id. An unconfirmed rule never replaces a
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

    /// The confirmed rule that saving `rule` would replace, if any.
    func confirmedRule(replacedBy rule: Rule) throws -> Rule? {
        try database.writer.read { try Self.confirmed(rule, in: $0) }
    }

    private static func confirmed(_ rule: Rule, in db: Database) throws -> Rule? {
        try Rule
            .filter(Column("kind") == rule.kind.rawValue && Column("match") == rule.match.rawValue
                    && Column("pattern") == rule.pattern && Column("source") == rule.source.rawValue
                    && Column("confirmed") != nil)
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
        let rows = try database.writer.read { db in
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
        return rows
            .filter { !$0.isExpired(at: now) }
            .sorted { a, b in
                if a.rank != b.rank { return a.rank < b.rank }
                if a.match != b.match { return a.match == .exact }
                if a.pattern.count != b.pattern.count { return a.pattern.count > b.pattern.count }
                return a.created > b.created
            }
    }

    /// Replaces every rule of `source` with `rules`, in one transaction. A rule that the
    /// user had confirmed keeps its confirmation and creation date if it is still present.
    func replaceAll(source: Rule.Source, with rules: [Rule]) throws {
        defer { wrote() }
        try database.writer.write { db in
            let existing = try Rule.filter(Column("source") == source.rawValue).fetchAll(db)
            let kept = Dictionary(
                existing.map { (Key(kind: $0.kind, match: $0.match, pattern: $0.pattern), $0) },
                uniquingKeysWith: { first, _ in first })
            try Rule.filter(Column("source") == source.rawValue).deleteAll(db)
            for var rule in rules {
                rule.id = nil
                rule.source = source
                if let old = kept[Key(kind: rule.kind, match: rule.match, pattern: rule.pattern)] {
                    rule.confirmed = old.confirmed
                    rule.created = old.created
                }
                try rule.upsert(db)
            }
        }
    }

    private struct Key: Hashable {
        var kind: Rule.Kind
        var match: Rule.Match
        var pattern: String
    }

    /// Marks a rule confirmed. The source is kept so provenance is never lost; the rule
    /// ranks with user rules from now on. `pattern` promotes it to a glob rule: only the
    /// user can do that, and only here.
    func confirm(id: Int64, at date: Date = Date(), promotingTo pattern: String? = nil) throws {
        defer { wrote() }
        try database.writer.write { db in
            guard var rule = try Rule.fetchOne(db, key: id) else {
                throw RuleStoreError.notFound(id)
            }
            rule.confirmed = date
            if let pattern {
                rule.match = .glob
                rule.pattern = Rule.normalize(pattern, for: rule.kind)
            }
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

    func rules(kind: Rule.Kind? = nil) throws -> [Rule] {
        try database.writer.read { db in
            var request = Rule.order(Column("kind"), Column("pattern"))
            if let kind { request = request.filter(Column("kind") == kind.rawValue) }
            return try request.fetchAll(db)
        }
    }
}

enum RuleStoreError: Error, Equatable {
    case notFound(Int64)
    case alreadyConfirmed(Int64)
}
