import Foundation

/// The item under the cursor and everything the engine already knows about it.
struct ExplainRequest: Equatable, Sendable {
    var kind: Rule.Kind
    var key: String
    /// Deterministic facts from the Identify step: signer, owner, category, declared
    /// intent. Sent with the item so the model explains them instead of guessing.
    var facts: [Fact]
    /// The program is Apple's, by its signature: a rule about one of Apple's programs
    /// describes only that program, not whatever takes its name.
    var isApple: Bool

    init(kind: Rule.Kind, key: String, facts: [Fact] = [], isApple: Bool = false) {
        self.kind = kind
        self.key = Rule.normalize(key, for: kind)
        self.facts = facts
        self.isApple = isApple
    }
}

struct Fact: Equatable, Sendable {
    var name: String
    var value: String
    /// What the model is told when it must differ from what the panel shows: the panel can
    /// name the user's own account or certificate, a prompt that leaves the machine cannot.
    var promptValue: String?
    /// False for a fact only the panel shows.
    var inPrompt: Bool

    init(name: String, value: String, promptValue: String? = nil, inPrompt: Bool = true) {
        self.name = name
        self.value = value
        self.promptValue = promptValue
        self.inPrompt = inPrompt
    }

    /// Who signed it. A development certificate is named after the developer, so the model
    /// is told the kind of certificate, not the name.
    static func signedBy(_ signature: CodeSignature, as name: String = "Signed by") -> Fact {
        Fact(name: name, value: signature.summary, promptValue: signature.promptSummary)
    }

    /// The account a process runs as; the model is not told the login name.
    static func runsAs(_ uid: uid_t) -> Fact {
        Fact(name: "Runs as", value: UserName.describe(uid), promptValue: UserName.describeForModel(uid))
    }
}
