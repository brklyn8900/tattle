import Foundation
import Observation

/// The explain step: knowledge base first, the model only when asked, and every answer
/// kept as an exact-item rule with source `llm`.
@MainActor @Observable
final class Explainer {
    let store: RuleStore
    let settings: AppSettings
    /// Read on every ask: the computer name and the addresses change while the app runs.
    var makeRedactor: @MainActor () -> Redactor
    /// Builds the provider for the configured command. Tests substitute a fake.
    var makeProvider: @MainActor (String) -> any ExplainProvider
    /// The last prompt sent, after redaction, verbatim. Shown in Settings.
    private(set) var lastPrompt: String?

    init(
        store: RuleStore, settings: AppSettings, makeRedactor: @escaping @MainActor () -> Redactor = { .current },
        makeProvider: @escaping @MainActor (String) -> any ExplainProvider = { ShellProvider(command: $0) }
    ) {
        self.store = store
        self.settings = settings
        self.makeRedactor = makeRedactor
        self.makeProvider = makeProvider
    }

    /// What the knowledge base already says, if anything. Never reaches the model.
    func lookup(_ request: ExplainRequest) throws -> Rule? {
        try store.candidates(kind: request.kind, key: request.key)
            .first { request.isApplesProgram || !$0.describesApplesProgram }
    }

    /// Asks the model and stores its answer. Called only from the explain button. Throws
    /// `RuleStoreError.alreadyConfirmed`, before any model call, when the user has confirmed
    /// the stored answer for the item: replacing it would need a rule editor.
    func ask(_ request: ExplainRequest) async throws -> Rule {
        let key = Rule(kind: request.kind, match: .exact, pattern: request.key, purpose: "", source: .llm)
        if let kept = try store.confirmedRule(replacedBy: key) { throw RuleStoreError.alreadyConfirmed(kept.id!) }
        let provider = makeProvider(settings.providerCommand)
        let prompt = Prompt.build(instructions: settings.promptInstructions, request: request, redactor: makeRedactor())
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
