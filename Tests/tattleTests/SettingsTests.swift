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

        settings.providerCommand = "cat"
        settings.promptInstructions = "Be terse."
        settings.retentionDays = 7
        XCTAssertFalse(settings.promptInstructionsAreDefault)

        let reloaded = try AppSettings(store: SettingsStore(database: database))
        XCTAssertEqual(reloaded.providerCommand, "cat")
        XCTAssertEqual(reloaded.promptInstructions, "Be terse.")
        XCTAssertEqual(reloaded.retentionDays, 7)

        reloaded.resetPromptInstructions()
        XCTAssertEqual(try AppSettings(store: SettingsStore(database: database)).promptInstructions, Prompt.defaultInstructions)
    }
}
