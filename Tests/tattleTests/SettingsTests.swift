import GRDB
import XCTest
@testable import tattle

final class SettingsStoreTests: XCTestCase {
    func testRoundTripAndDelete() throws {
        let store = SettingsStore(database: try AppDatabase.inMemory())
        XCTAssertNil(try store.string("a"))
        try store.set("a", "1")
        try store.set("a", "2")
        XCTAssertEqual(try store.string("a"), "2")
        try store.set("a", nil)
        XCTAssertNil(try store.string("a"))
    }
}

@MainActor
final class AppSettingsTests: XCTestCase {
    func testDefaultsThenPersistence() throws {
        let database = try AppDatabase.inMemory()
        let settings = try AppSettings(store: SettingsStore(database: database))
        XCTAssertEqual(settings.providerCommand, "")
        XCTAssertEqual(settings.promptInstructions, Prompt.defaultInstructions)
        XCTAssertTrue(settings.promptInstructionsAreDefault)
        XCTAssertEqual(settings.retentionDays, 30)
        XCTAssertTrue(settings.showThroughputInMenuBar)

        settings.providerCommand = "cat"
        settings.promptInstructions = "Be terse."
        settings.retentionDays = 7
        settings.showThroughputInMenuBar = false
        XCTAssertFalse(settings.promptInstructionsAreDefault)

        let reloaded = try AppSettings(store: SettingsStore(database: database))
        XCTAssertEqual(reloaded.providerCommand, "cat")
        XCTAssertEqual(reloaded.promptInstructions, "Be terse.")
        XCTAssertEqual(reloaded.retentionDays, 7)
        XCTAssertFalse(reloaded.showThroughputInMenuBar)

        reloaded.resetPromptInstructions()
        XCTAssertEqual(try AppSettings(store: SettingsStore(database: database)).promptInstructions, Prompt.defaultInstructions)
    }

    private static let earlierClaudePreset = #"claude -p --setting-sources project,local --tools "" --permission-prompts none --output-format json --json-schema {schema}"#

    /// A preset is saved as its text, so one saved by an earlier version would go on running
    /// that version's flags. A migration moves it to the current command.
    func testAPresetSavedByAnEarlierVersionIsMigrated() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v5-rule-identity")
        try queue.write {
            try $0.execute(sql: "INSERT INTO setting (key, value) VALUES ('provider.command', ?)",
                           arguments: [Self.earlierClaudePreset])
        }
        try AppDatabase.migrator.migrate(queue)
        let saved = try queue.read { try String.fetchOne($0, sql: "SELECT value FROM setting WHERE key = 'provider.command'") }
        XCTAssertEqual(saved, try XCTUnwrap(ShellProvider.presets.first { $0.id == "claude" }).command)
    }

    /// Typed after the migration, the same text is the user's own edit, and stays at every
    /// later launch.
    func testTheEarlierCommandTypedLaterStaysTheUsers() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tattle-settings-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "tattle.sqlite")
        try SettingsStore(database: AppDatabase(at: url)).set("provider.command", Self.earlierClaudePreset)
        XCTAssertEqual(try AppSettings(store: SettingsStore(database: AppDatabase(at: url))).providerCommand,
                       Self.earlierClaudePreset)
    }

    func testACommandTheUserEditedStaysTheirs() throws {
        let database = try AppDatabase.inMemory()
        let edited = #"claude -p --model haiku --tools "" --output-format json --json-schema {schema}"#
        try SettingsStore(database: database).set("provider.command", edited)
        XCTAssertEqual(try AppSettings(store: SettingsStore(database: database)).providerCommand, edited)
    }
}
