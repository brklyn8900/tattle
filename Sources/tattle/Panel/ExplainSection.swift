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
                    if rule.source == .llm && rule.confirmed == nil {
                        Button("Confirm") { confirm(rule) }
                            .controlSize(.small)
                    }
                    Spacer()
                    if rule.source == .llm {
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
        .task(id: request) { load() }
    }

    private var providerConfigured: Bool {
        !state.settings.providerCommand.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func load() {
        rule = try? state.explainer.lookup(request)
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
            load()
        } catch {
            self.error = describe(error)
        }
    }

    private func provenance(_ rule: Rule) -> String {
        switch rule.source {
        case .llm: rule.confirmed == nil ? "Model answer, unconfirmed" : "Model answer, confirmed by you"
        case .user: "Your rule"
        case .builtin: "Tattle's rules"
        case .iap: "Declared by the app"
        case .appleList: "Apple's host list"
        case .trackerRadar: "Tracker Radar"
        }
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
