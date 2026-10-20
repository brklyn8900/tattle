import XCTest
@testable import tattle

final class LoginItemsTests: XCTestCase {
    /// A small archive in the shape of BackgroundItems-v16.btm.
    private func fixture() throws -> Data {
        let user = "CD21E3B6-0000-0000-0000-000000000001"
        let developer = BTMRecord(["name": "Acme Inc", "identifier": "Acme Inc", "developerName": "Acme Inc"], type: 0x20, disposition: 2, items: ["8.com.acme.updater"])
        let agent = BTMRecord(["name": "Acme Updater", "identifier": "8.com.acme.updater", "developerName": "Acme Inc", "teamIdentifier": "ABCDE12345", "executablePath": "/Library/Acme/updater", "container": "Acme Inc"], type: 0x10008, disposition: 9, url: "file:///Library/LaunchAgents/com.acme.updater.plist")
        let app = BTMRecord(["name": "Magnet", "identifier": "2.com.example.magnet", "bundleIdentifier": "com.example.magnet"], type: 0x2, disposition: 3, url: "file:///Applications/Magnet.app/")
        let helper = BTMRecord(["name": "magnetLauncher", "identifier": "4.com.example.magnetLauncher", "bundleIdentifier": "com.example.magnetLauncher", "container": "2.com.example.magnet"], type: 0x4, disposition: 10, url: "Contents/Library/LoginItems/magnetLauncher.app")
        let importer = BTMRecord(["name": "Foo.mdimporter", "identifier": "64.com.example.foo", "container": "2.com.example.magnet"], type: 0x40, disposition: 11)
        let unnamed = BTMRecord(["identifier": "Unknown Developer"], type: 0x20, disposition: 10)
        let systemDeveloper = BTMRecord(["name": "Acme Inc", "identifier": "Acme Inc", "developerName": "Acme Inc"], type: 0x20, disposition: 2)
        let storage = BTMStorage(itemsByUser: [
            user: [developer, agent, app, helper, importer, unnamed],
            "FFFFEEEE-DDDD-CCCC-BBBB-AAAA00000000": [systemDeveloper],
        ])
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.setClassName("Storage", for: BTMStorage.self)
        archiver.setClassName("ItemRecord", for: BTMRecord.self)
        archiver.encode(storage, forKey: LoginItemsDatabase.storeKey)
        archiver.encode(16, forKey: "version")
        archiver.finishEncoding()
        return archiver.encodedData
    }

    func testParsesKindsDispositionAndJoins() throws {
        let db = try LoginItemsDatabase.parse(fixture())
        XCTAssertEqual(db.version, 16)
        XCTAssertEqual(db.items.count, 6, "the developer group is kept once across users")
        let byId = Dictionary(uniqueKeysWithValues: db.items.map { ($0.identifier, $0) })

        let agent = try XCTUnwrap(byId["8.com.acme.updater"])
        XCTAssertEqual(agent.kind, .agent)
        XCTAssertTrue(agent.legacy)
        XCTAssertTrue(agent.enabled); XCTAssertFalse(agent.allowed); XCTAssertFalse(agent.hidden); XCTAssertTrue(agent.notified)
        XCTAssertEqual(agent.url, "file:///Library/LaunchAgents/com.acme.updater.plist")
        XCTAssertEqual(agent.teamIdentifier, "ABCDE12345")
        XCTAssertEqual(agent.container, "Acme Inc")

        let app = try XCTUnwrap(byId["2.com.example.magnet"])
        XCTAssertEqual(app.kind, .app)
        XCTAssertTrue(app.enabled && app.allowed)
        XCTAssertFalse(app.legacy)

        XCTAssertEqual(byId["4.com.example.magnetLauncher"]?.kind, .loginItemHelper)
        XCTAssertEqual(byId["4.com.example.magnetLauncher"]?.url, "Contents/Library/LoginItems/magnetLauncher.app")
        XCTAssertEqual(byId["64.com.example.foo"]?.kind, .other(type: 0x40))
        XCTAssertFalse(byId["64.com.example.foo"]!.isStartupItem)
        XCTAssertEqual(byId["Acme Inc"]?.kind, .other(type: 0x20))
        XCTAssertEqual(byId["Unknown Developer"]?.name, "Unknown Developer", "falls back to the identifier")
    }

    func testRejectsForeignArchive() {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.encode("not a storage" as NSString, forKey: LoginItemsDatabase.storeKey)
        archiver.finishEncoding()
        XCTAssertThrowsError(try LoginItemsDatabase.parse(archiver.encodedData))
        XCTAssertThrowsError(try LoginItemsDatabase.parse(Data("junk".utf8)))
    }

    func testThisMachineDatabaseParses() throws {
        guard LoginItemsDatabase.currentFile() != nil else { throw XCTSkip("no login-items database here") }
        let db = try LoginItemsDatabase.readCurrent()
        XCTAssertGreaterThanOrEqual(db.version, 13)
        XCTAssertFalse(db.items.isEmpty)
        XCTAssertTrue(db.items.contains { $0.kind == .app }, "at least one app opens at login")
        XCTAssertTrue(db.items.allSatisfy { !$0.identifier.isEmpty })

        // Older schema versions left on disk should parse too.
        let files = try FileManager.default.contentsOfDirectory(at: LoginItemsDatabase.folder, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "btm" {
            XCTAssertNoThrow(try LoginItemsDatabase.parse(Data(contentsOf: file)), file.lastPathComponent)
        }
    }
}
