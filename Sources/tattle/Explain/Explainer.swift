import Foundation
import Observation

/// The explain step: knowledge base first, the model only when asked, and an answer kept as
/// an exact-item rule with source `llm`, for the code it was given for (`CodeIdentity`).
@MainActor @Observable
final class Explainer {
    let store: RuleStore
    let settings: AppSettings
    var makeRedactor: @MainActor () -> Redactor
    /// Builds the provider for the configured command. Tests substitute a fake.
    var makeProvider: @MainActor (String) -> any ExplainProvider
    /// The last prompt sent, after redaction, verbatim. Shown in Settings.
    private(set) var lastPrompt: String?
    private let digests: FileDigests

    init(
        store: RuleStore, settings: AppSettings, makeRedactor: @escaping @MainActor () -> Redactor = { .current },
        makeProvider: @escaping @MainActor (String) -> any ExplainProvider = { ShellProvider(command: $0) },
        digests: FileDigests = FileDigests()
    ) {
        self.digests = digests
        self.store = store
        self.settings = settings
        self.makeRedactor = makeRedactor
        self.makeProvider = makeProvider
    }

    /// What the knowledge base already says, if anything. Never reaches the model. A file an
    /// identity rests on is read only when an answer was kept for that file.
    func lookup(_ request: ExplainRequest) async throws -> Rule? {
        let candidates = try store.candidates(kind: request.kind, key: request.key)
        var identity: String?
        if let asked = request.identity, asked.contentFile == nil || candidates.contains(where: { asked.wasStored(as: $0.identity) }) {
            identity = await stored(asked)
        }
        return candidates.first { $0.answers(request, identity: identity) }
    }

    /// The identity as kept with an answer: nil when the file it rests on cannot be read.
    private func stored(_ identity: CodeIdentity) async -> String? {
        guard let file = identity.contentFile else { return identity.text }
        return await digests.digest(of: file).map(identity.stored(digest:))
    }

    /// Asks the model and stores its answer, unless nothing could tell a later item by this
    /// key from this one: then the answer is returned with no id, for this view alone. Called
    /// only from the explain button. Throws `RuleStoreError.alreadyConfirmed`, before any model
    /// call, when the user has confirmed the stored answer for the item: replacing it would
    /// need a rule editor.
    func ask(_ request: ExplainRequest) async throws -> Rule {
        var known: String?
        if let asked = request.identity { known = await stored(asked) }
        let identity = known ?? ""
        let key = Rule(kind: request.kind, match: .exact, pattern: request.key, purpose: "", source: .llm, identity: identity)
        let isKept = !key.needsIdentity || known != nil
        if isKept, let kept = try store.confirmedRule(replacedBy: key) { throw RuleStoreError.alreadyConfirmed(kept.id!) }
        let provider = makeProvider(settings.providerCommand)
        let prompt = Prompt.build(instructions: settings.promptInstructions, request: request, redactor: makeRedactor())
        lastPrompt = prompt
        let output = try await provider.explain(prompt)
        let answer = try LLMAnswer.parse(output)
        let rule = Rule(
            kind: request.kind, match: .exact, pattern: request.key,
            owner: answer.owner, purpose: answer.purpose, category: answer.category,
            risk: answer.risk, confidence: answer.confidence, source: .llm, identity: identity)
        return isKept ? try store.save(rule) : rule
    }
}
