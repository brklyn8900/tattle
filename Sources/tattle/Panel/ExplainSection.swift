import SwiftUI

/// The explanation for one item: the knowledge base's answer, or a button that asks the
/// model, and confirmation of an unconfirmed answer. Shared by every tab's detail view.
struct ExplainSection: View {
    let request: ExplainRequest
    let state: AppState
    @State private var rule: Rule?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let rule {
                Text(rule.purpose)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(provenance(rule))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if rule.source == .llm && rule.confirmed == nil && rule.id != nil {
                        Button("Confirm") { confirm(rule) }
                            .controlSize(.small)
                    }
                    Spacer()
                    if rule.source == .llm && rule.confirmed == nil {
                        Button("Ask again") { ask() }
                            .controlSize(.small)
                            .disabled(busy || !providerConfigured)
                    }
                }
            } else {
                HStack {
                    Text("No explanation yet.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Explain") { ask() }
                        .disabled(busy || !providerConfigured)
                }
                if !providerConfigured {
                    Text("Choose a provider in Settings to ask a model.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if busy { ProgressView().controlSize(.small) }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .task(id: request) { await load() }
    }

    private var providerConfigured: Bool {
        !state.settings.providerCommand.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func load() async {
        // An answer not kept (no id) stays for as long as this item's view does.
        let unkept = rule.flatMap { $0.id == nil && $0.pattern == request.key ? $0 : nil }
        let found = try? await state.explainer.lookup(request)
        guard !Task.isCancelled else { return }
        rule = found ?? unkept
    }

    private func ask() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                rule = try await state.explainer.ask(request)
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
        var parts: [String]
        switch rule.source {
        case .llm: parts = [rule.confirmed == nil ? "Model answer, unconfirmed" : "Model answer, confirmed by you"]
        case .user: parts = ["Your rule"]
        case .builtin: parts = ["Tattle's rules"]
        case .iap: parts = ["Declared by the app"]
        case .appleList: parts = ["Apple's host list"]
        case .trackerRadar: parts = ["Tracker Radar"]
        }
        if let risk = rule.risk { parts.append("risk \(risk.rawValue)") }
        if let confidence = rule.confidence { parts.append("confidence \(confidence.rawValue)") }
        return parts.joined(separator: " · ")
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case ProviderError.notConfigured: "No provider configured."
        case ProviderError.timedOut: "The provider did not answer in time."
        case ProviderError.failed(let status, let stderr): "The provider failed (exit \(status)). \(stderr)"
        case let parse as LLMAnswer.ParseError: "The answer was not in the expected shape (\(parse))."
        default: String(describing: error)
        }
    }
}
