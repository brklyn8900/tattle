import Foundation
import Observation

/// The explain step: knowledge base first, the model only when asked, and every answer
/// kept as an exact-item rule with source `llm`.
@MainActor @Observable
final class Explainer {
    let store: RuleStore
    var provider: any ExplainProvider
    var instructions: String
    var redactor: Redactor
    /// The last prompt sent, after redaction, verbatim. Shown in Settings.
    private(set) var lastPrompt: String?

    init(
        store: RuleStore, provider: any ExplainProvider,
        instructions: String = Prompt.defaultInstructions, redactor: Redactor = .current
    ) {
        self.store = store
        self.provider = provider
        self.instructions = instructions
        self.redactor = redactor
    }

    /// What the knowledge base already says, if anything. Never reaches the model.
    func lookup(_ request: ExplainRequest) throws -> Rule? {
        try store.lookup(kind: request.kind, key: request.key)
    }

    /// Asks the model and stores its answer. Called only from the explain button.
    func ask(_ request: ExplainRequest) async throws -> Rule {
        let prompt = redactor.redact(Prompt.build(instructions: instructions, request: request))
        lastPrompt = prompt
        let output = try await provider.explain(prompt)
        let answer = try LLMAnswer.parse(output)
        let rule = Rule(
            kind: request.kind, match: .exact, pattern: request.key,
            owner: answer.owner, purpose: answer.purpose, category: answer.category,
            risk: answer.risk, confidence: answer.confidence, source: .llm)
        return try store.save(rule)
    }
}
