import SwiftUI

/// The explanation for one item, as three answers: what it is, why it is probably here, and
/// whether to care. The knowledge base's answer, or a button that asks the model, and
/// confirmation of an unconfirmed answer. Shared by every tab's detail view.
struct ExplainSection: View {
    let request: ExplainRequest
    /// The app's own sentence that opens "Why it is probably here", from the facts.
    let whyHere: String?
    let state: AppState
    @State private var rule: Rule?
    /// The code `rule` was asked about, when the answer was the model's in this view.
    @State private var answered: CodeIdentity?
    /// The item on screen. A running task sees the `request` it started with, so an answer
    /// that arrives late is checked against this.
    @State private var shown: ExplainRequest.Subject?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Card {
            question("What is this", rule?.purpose)
            RowLine()
            // Before there is an answer the app's own sentence still stands, and the other
            // two say that they are waiting.
            if let rule {
                if let why = Self.why(rule, opening: whyHere) {
                    question("Why it is probably here", why)
                    RowLine()
                }
                if let care = Self.care(rule) {
                    question("Should I care", care)
                    RowLine()
                }
            } else {
                question("Why it is probably here", whyHere)
                RowLine()
                question("Should I care", nil)
                RowLine()
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(rule.map(provenance) ?? "No explanation yet.")
                        .font(PanelFont.small)
                        .foregroundStyle(PanelColor.sub)
                    Spacer(minLength: 0)
                    if busy { ProgressView().controlSize(.small) }
                    if let rule {
                        if rule.source == .llm && rule.confirmed == nil {
                            Button("Ask again") { ask() }
                                .buttonStyle(PanelButtonStyle(height: 22))
                                .disabled(busy || !providerConfigured)
                        }
                        if rule.source == .llm && rule.confirmed == nil && rule.id != nil {
                            Button("Confirm") { confirm(rule) }
                                .buttonStyle(PanelButtonStyle(kind: .primary, height: 22))
                        }
                    } else {
                        Button("Explain") { ask() }
                            .buttonStyle(PanelButtonStyle(kind: .primary, height: 22))
                            .disabled(busy || !providerConfigured)
                    }
                }
                .frame(minHeight: 22)
                if rule == nil && !providerConfigured {
                    Text("Choose a provider in Settings to ask a model.")
                        .font(PanelFont.small)
                        .foregroundStyle(PanelColor.sub)
                }
                if let error {
                    Text(error)
                        .font(PanelFont.small)
                        .foregroundStyle(PanelColor.bad)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .task(id: request) { await load() }
    }

    /// One question with its answer, or with the words that stand in for one.
    private func question(_ heading: String, _ answer: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(heading)
                .font(PanelFont.smallBold)
                .foregroundStyle(PanelColor.sub)
                .accessibilityAddTraits(.isHeader)
            Text(answer ?? "Not explained yet.")
                .foregroundStyle(answer == nil ? PanelColor.sub : PanelColor.text)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The app's sentence from the facts, then the rule's. A host's rule is asked not to say which
    /// program opened the connection: the app's sentence does.
    static func why(_ rule: Rule?, opening: String?) -> String? {
        joined([opening, rule?.why])
    }

    /// The words the app picks from the rule's risk, then the rule's reason. The app picks them
    /// so they never disagree with the risk shown under them; none when the rule has no risk or
    /// was a guess.
    static func care(_ rule: Rule) -> String? {
        joined([verdict(rule), rule.care])
    }

    static func verdict(_ rule: Rule) -> String? {
        guard let risk = rule.risk, rule.confidence != .low else { return nil }
        switch risk {
        case .low: return "Probably not."
        case .medium: return "Worth a look."
        case .high: return "Yes."
        }
    }

    private static func joined(_ parts: [String?]) -> String? {
        let parts = parts.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var providerConfigured: Bool {
        !state.settings.providerCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func load() async {
        shown = request.subject
        let unkept = Self.unkept(rule, givenFor: answered, request: request)
        let found = try? await state.explainer.lookup(request)
        guard !Task.isCancelled else { return }
        rule = found ?? unkept
    }

    /// The answer that stays when the knowledge base has none: one not kept (no id), for as
    /// long as the view holds the code it was given for.
    static func unkept(_ rule: Rule?, givenFor identity: CodeIdentity?, request: ExplainRequest) -> Rule? {
        guard let rule, rule.id == nil, rule.pattern == request.key, identity == request.identity else { return nil }
        return rule
    }

    private func ask() {
        busy = true
        error = nil
        let asked = request.subject
        Task {
            defer { busy = false }
            do {
                let answer = try await state.explainer.ask(request)
                guard shown == asked else { return }
                rule = answer
                answered = asked.identity
            } catch {
                self.error = describe(error)
            }
        }
    }

    private func confirm(_ rule: Rule) {
        guard let id = rule.id else { return }
        do {
            try state.rules.confirm(id: id)
            Task { await load() }
        } catch {
            self.error = describe(error)
        }
    }

    /// Where the answer came from, and how much the source trusted it.
    private func provenance(_ rule: Rule) -> String {
        var parts = [rule.sourceText]
        if let risk = rule.risk { parts.append("risk \(risk.rawValue)") }
        if let confidence = rule.confidence { parts.append("confidence \(confidence.rawValue)") }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case ProviderError.notConfigured: "No provider configured."
        case ProviderError.timedOut: "The provider did not answer in time."
        case ProviderError.tooMuchOutput: "The provider wrote more than an answer could hold, so it was stopped."
        case ProviderError.cannotDisclaim: "The command was not run, because this version of macOS would give it Tattle's permissions."
        case ProviderError.failed(let status, let stderr): "The provider failed (exit \(status)). \(stderr)"
        case let parse as LLMAnswer.ParseError: "The answer was not in the expected shape (\(parse))."
        default: String(describing: error)
        }
    }
}

extension Rule {
    /// Where the answer came from.
    var sourceText: String {
        switch source {
        case .llm: confirmed == nil ? "Model answer, unconfirmed" : "Model answer, confirmed by you"
        case .user: "Your rule"
        case .builtin: "Tattle's rules"
        case .iap: "Declared by the app"
        case .appleList: "Apple's host list"
        case .trackerRadar: "Tracker Radar"
        }
    }
}
