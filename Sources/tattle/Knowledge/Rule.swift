import Foundation
import GRDB

/// One knowledge-base rule: what an item (host, process, port, launch item) is, why it is
/// probably there, and whether its owner should care. See the PRD, "Explanation pipeline".
struct Rule: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
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

    static let unconfirmedLLMLifetime: TimeInterval = 45 * 24 * 60 * 60

    var id: Int64?
    var kind: Kind
    var match: Match
    var pattern: String
    var owner: String?
    /// What the item is. The output contract asks that no sentence of a host's model answer
    /// say which program on this Mac opened it: the rule is shown on every connection to the host.
    var purpose: String
    /// Why an item like this is probably on a Mac.
    var why: String?
    /// The reason the owner should care or not. The words that open the answer are the app's,
    /// from `risk`.
    var care: String?
    var category: String?
    var risk: Level?
    var confidence: Level?
    var source: Source
    /// What tells the code this rule was given for from another's of its name
    /// (`CodeIdentity`). Empty when the rule is about no one program.
    var identity: String
    /// Set when the user has read the explanation against the facts and confirmed it.
    var confirmed: Date?
    var created: Date

    init(
        id: Int64? = nil, kind: Kind, match: Match = .exact, pattern: String,
        owner: String? = nil, purpose: String, why: String? = nil, care: String? = nil, category: String? = nil,
        risk: Level? = nil, confidence: Level? = nil, source: Source, identity: String = "",
        confirmed: Date? = nil, created: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.match = match
        self.pattern = Self.normalize(pattern, for: kind)
        self.owner = owner
        self.purpose = purpose
        self.why = why
        self.care = care
        self.category = category
        self.risk = risk
        self.confidence = confidence
        self.source = source
        self.identity = identity
        self.confirmed = confirmed
        self.created = created
    }

    /// Precedence rank: lower wins. Confirmation promotes any source to `user`.
    var rank: Int { confirmed == nil ? source.rank : Source.user.rank }

    /// A rule about a program by its name, which any program can take. A port-wide rule
    /// (`*:udp/5353`) describes the port, whoever listens; an exact key is one program's even
    /// when that program is named `*`.
    private var describesProgram: Bool {
        kind == .process || (kind == .port && !(match == .glob && pattern.hasPrefix("*:")))
    }

    /// A shipped rule about one of Apple's programs: `ApplesProgram` says which is one.
    var describesApplesProgram: Bool { source == .builtin && owner == "Apple" && describesProgram }

    /// A rule about a program, or the launch item that runs one, is about that program's code,
    /// whatever its source: the name or label is anyone's. Apple's programs are told by
    /// `ApplesProgram` instead. A host is its own name, and a port-wide rule is about no one
    /// program.
    var needsIdentity: Bool { !describesApplesProgram && (describesProgram || kind == .launchItem) }

    /// Whether this rule may explain the item: a name alone does not make it the program the
    /// rule is about, confirmed or not.
    /// `identity` is the item's as it would be kept (`CodeIdentity`).
    func answers(_ request: ExplainRequest, identity: String?) -> Bool {
        if describesApplesProgram { return request.isApplesProgram }
        return !needsIdentity || (!self.identity.isEmpty && self.identity == identity)
    }

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
