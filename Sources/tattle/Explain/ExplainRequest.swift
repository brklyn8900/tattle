import Foundation

/// The item under the cursor and everything the engine already knows about it.
struct ExplainRequest: Equatable, Sendable {
    var kind: Rule.Kind
    var key: String
    /// Deterministic facts from the Identify step: signer, owner, category, declared
    /// intent. Sent with the item so the model explains them instead of guessing.
    var facts: [Fact]

    init(kind: Rule.Kind, key: String, facts: [Fact] = []) {
        self.kind = kind
        self.key = Rule.normalize(key, for: kind)
        self.facts = facts
    }
}

struct Fact: Equatable, Sendable {
    var name: String
    var value: String
}
