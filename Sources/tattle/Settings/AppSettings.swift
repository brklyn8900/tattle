import Foundation
import GRDB
import Observation

/// Key-value settings in the database, so one file holds everything the user changed.
struct SettingsStore: Sendable {
    let database: AppDatabase

    func string(_ key: String) throws -> String? {
        try database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key])
        }
    }

    func set(_ key: String, _ value: String?) throws {
        try database.writer.write { db in
            if let value {
                try db.execute(
                    sql: "INSERT INTO setting (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM setting WHERE key = ?", arguments: [key])
            }
        }
    }
}

/// The user's settings, loaded once and written through on every change.
@MainActor @Observable
final class AppSettings {
    static let defaultRetentionDays = 30

    /// Shell command template for the LLM provider. Empty until the user picks one.
    var providerCommand: String { didSet { write(Key.providerCommand, providerCommand) } }
    /// Editable part of the prompt. The output contract is appended separately and is
    /// not a setting.
    var promptInstructions: String { didSet { write(Key.promptInstructions, promptInstructions) } }
    /// How long connection history is kept before pruning.
    var retentionDays: Int { didSet { write(Key.retentionDays, String(retentionDays)) } }
    /// Live in/out next to the menu bar icon, or the icon alone with the numbers in the panel.
    var showThroughputInMenuBar: Bool { didSet { write(Key.menuBarThroughput, String(showThroughputInMenuBar)) } }

    private let store: SettingsStore

    private enum Key {
        static let providerCommand = "provider.command"
        static let promptInstructions = "prompt.instructions"
        static let retentionDays = "history.retentionDays"
        static let menuBarThroughput = "menubar.throughput"
    }

    init(store: SettingsStore) throws {
        self.store = store
        providerCommand = try store.string(Key.providerCommand) ?? ""
        promptInstructions = try store.string(Key.promptInstructions) ?? Prompt.defaultInstructions
        retentionDays = try store.string(Key.retentionDays).flatMap(Int.init) ?? Self.defaultRetentionDays
        showThroughputInMenuBar = try store.string(Key.menuBarThroughput).flatMap(Bool.init) ?? true
    }

    var promptInstructionsAreDefault: Bool { promptInstructions == Prompt.defaultInstructions }

    func resetPromptInstructions() {
        promptInstructions = Prompt.defaultInstructions
    }

    private func write(_ key: String, _ value: String) {
        do {
            try store.set(key, value)
        } catch {
            Log.settings.error("could not save \(key, privacy: .public): \(error, privacy: .public)")
        }
    }
}
