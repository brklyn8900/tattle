import Foundation
import GRDB

/// One knowledge-base rule: what an item (host, process, port, launch item) is and why it
/// is probably there. See the proposal, "Explanation pipeline".
struct Rule: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case host, process, port, launchItem
    }

    enum Match: String, Codable, Sendable {
        /// `pattern` is the item itself.
        case exact
        /// `pattern` is an SQLite GLOB (`*`, `?`, `[...]`), e.g. `p*-caldav.icloud.com`.
        case glob
    }

    /// Sources in precedence order. A confirmed rule ranks with `user` whatever its source.
    enum Source: String, Codable, Sendable, CaseIterable {
        case user, builtin, iap, appleList = "apple-list", trackerRadar = "tracker-radar", llm

        var rank: Int { Self.allCases.firstIndex(of: self)! }
    }

    enum Level: String, Codable, Sendable {
        case low, medium, high
    }

    /// Unconfirmed LLM answers are dropped after this long.
    static let unconfirmedLLMLifetime: TimeInterval = 45 * 24 * 60 * 60

    var id: Int64?
    var kind: Kind
    var match: Match
    var pattern: String
    var owner: String?
    var purpose: String
    var category: String?
    var risk: Level?
    var confidence: Level?
    var source: Source
    /// Set when the user has read the explanation against the facts and confirmed it.
    var confirmed: Date?
    var created: Date

    init(
        id: Int64? = nil, kind: Kind, match: Match = .exact, pattern: String,
        owner: String? = nil, purpose: String, category: String? = nil,
        risk: Level? = nil, confidence: Level? = nil, source: Source,
        confirmed: Date? = nil, created: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.match = match
        self.pattern = Self.normalize(pattern, for: kind)
        self.owner = owner
        self.purpose = purpose
        self.category = category
        self.risk = risk
        self.confidence = confidence
        self.source = source
        self.confirmed = confirmed
        self.created = created
    }

    /// Precedence rank: lower wins. Confirmation promotes any source to `user`.
    var rank: Int { confirmed == nil ? source.rank : Source.user.rank }

    /// A shipped rule about one of Apple's programs by its name, which any program can take.
    /// A port-wide rule (`*:udp/5353`) describes the port, whoever listens.
    var describesApplesProgram: Bool {
        source == .builtin && owner == "Apple" && (kind == .process || (kind == .port && !pattern.hasPrefix("*")))
    }

    /// True once an unconfirmed LLM rule has outlived its lifetime.
    func isExpired(at now: Date) -> Bool {
        source == .llm && confirmed == nil
            && now.timeIntervalSince(created) > Self.unconfirmedLLMLifetime
    }

    /// Hosts compare case-insensitively (ASCII only: Unicode folding would map the Kelvin
    /// sign onto "k" and let a look-alike name hit a rule for another host) and without a
    /// trailing dot; everything else is taken as-is (process paths and launch item labels
    /// are case-sensitive).
    static func normalize(_ key: String, for kind: Kind) -> String {
        guard kind == .host else { return key }
        var host = String(String.UnicodeScalarView(key.unicodeScalars.map { scalar in
            (0x41...0x5A).contains(scalar.value) ? Unicode.Scalar(scalar.value + 0x20)! : scalar
        }))
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }
}

extension Rule: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "rule"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
