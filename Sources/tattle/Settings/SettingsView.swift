import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let explainer: Explainer
    @State private var contractShown = false

    var body: some View {
        Form {
            Section("Menu bar") {
                Toggle("Show network in and out next to the icon", isOn: $settings.showThroughputInMenuBar)
            }
            Section("Appearance") {
                Picker("Panel and Settings", selection: $settings.appearance) {
                    ForEach(Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Explain with") {
                Picker("Preset", selection: presetSelection) {
                    ForEach(ShellProvider.presets) { Text($0.name).tag($0.id) }
                    Text("Custom").tag("custom")
                }
                TextField("Command", text: $settings.providerCommand, axis: .vertical)
                    .font(.body.monospaced())
                    .lineLimit(1...4)
                Text("The prompt goes to the command's standard input; the answer is read from its standard output. {schema} is replaced with the output contract. Nothing is sent until you click Explain on an item. The command must work from a login shell, which does not read ~/.zshrc: set PATH in ~/.zprofile or in the command.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                TextEditor(text: $settings.promptInstructions)
                    .font(.body)
                    .frame(minHeight: 120)
                HStack {
                    Spacer()
                    Button("Reset to Default") { settings.resetPromptInstructions() }
                        .disabled(settings.promptInstructionsAreDefault)
                }
            } header: {
                Text("Prompt instructions")
            } footer: {
                Text("Sent before the item and its facts.")
            }
            Section("Output contract") {
                DisclosureGroup(isExpanded: $contractShown) {
                    readOnly(OutputContract.schema)
                } label: {
                    Text("Fixed JSON schema the answer must match. Appended to every request; the knowledge base depends on this shape.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Last prompt sent") {
                if let prompt = explainer.lastPrompt {
                    readOnly(prompt)
                } else {
                    Text("Nothing has been sent.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("History") {
                Stepper(value: $settings.retentionDays, in: AppSettings.retentionRange) {
                    Text("Keep connection history for \(settings.retentionDays) days")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 720)
        .onAppear {
            NSApplication.shared.activate()
            // AppKit hands focus to the first text field; nobody opens Settings to type
            // into the command straight away.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let window = NSApplication.shared.windows.first { $0.identifier?.rawValue.contains("Settings") == true }
                    ?? NSApplication.shared.keyWindow
                window?.makeFirstResponder(nil)
            }
        }
    }

    /// The preset whose command is in the field, or Custom once it is edited.
    private var presetSelection: Binding<String> {
        Binding(
            get: { ShellProvider.presets.first { $0.command == settings.providerCommand }?.id ?? "custom" },
            set: { id in
                if let preset = ShellProvider.presets.first(where: { $0.id == id }) {
                    settings.providerCommand = preset.command
                }
            })
    }

    private func readOnly(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 140)
    }
}
