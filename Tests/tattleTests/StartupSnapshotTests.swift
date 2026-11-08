import XCTest
@testable import tattle

final class StartupSnapshotTests: XCTestCase {
    private func job(_ label: String, scope: LaunchdItem.Scope = .userAgent, program: String? = "/usr/bin/x", plist: String? = nil, triggers: [Trigger] = [.atLoad], disabled: Bool = false, placeholder: Bool = false) -> LaunchdItem {
        LaunchdItem(label: label, scope: scope, plistURL: URL(fileURLWithPath: plist ?? "/Library/LaunchAgents/\(label).plist"),
                    program: program, arguments: ["--run"], triggers: triggers, disabled: disabled,
                    associatedBundleIdentifiers: [], isPlaceholder: placeholder)
    }

    private func login(_ identifier: String, name: String, kind: LoginItem.Kind, url: String? = nil, executable: String? = nil,
                       container: String? = nil, developer: String? = nil, team: String? = nil, bundle: String? = nil,
                       enabled: Bool = true, allowed: Bool = true, legacy: Bool = false) -> LoginItem {
        LoginItem(identifier: identifier, name: name, kind: kind, developerName: developer, teamIdentifier: team,
                  bundleIdentifier: bundle, executablePath: executable, url: url, container: container,
                  enabled: enabled, allowed: allowed, hidden: false, notified: false, legacy: legacy)
    }

    func testJoinsRegisteredPlistAndGroupsTheRest() {
        let launchd = LaunchdReader.Result(items: [
            job("com.acme.updater"),
            job("com.other.daemon", scope: .daemon, triggers: [.keepAlive]),
            job("com.empty", placeholder: true),
            job("com.off", disabled: true),
        ], appleCount: 880, skipped: [:])
        let loginItems = [
            login("8.com.acme.updater", name: "Acme Updater", kind: .agent, url: "file:///Library/LaunchAgents/com.acme.updater.plist",
                  executable: "/usr/bin/x", container: "Acme Inc", developer: "Acme Inc", team: "TEAM1", legacy: true),
            login("Acme Inc", name: "Acme Inc", kind: .other(type: 0x20)),
            login("2.com.example.magnet", name: "Magnet", kind: .app, url: "file:///Applications/Magnet.app/", bundle: "com.example.magnet"),
            login("4.com.example.magnetLauncher", name: "magnetLauncher", kind: .loginItemHelper, url: "Contents/Library/LoginItems/magnetLauncher.app",
                  container: "2.com.example.magnet", bundle: "com.example.magnetLauncher", enabled: false, allowed: true),
            login("64.com.example.importer", name: "importer", kind: .spotlightImporter, url: "Contents/Library/Spotlight/Foo.mdimporter", container: "2.com.example.magnet", allowed: false),
            login("2.com.example.logic", name: "Logic", kind: .app, url: "file:///Applications/Logic.app/", bundle: "com.example.logic", enabled: false, allowed: true),
            login("4096.com.example.podcasts", name: "Podcasts refresh", kind: .backgroundRefresh, container: "2.com.example.logic", enabled: true, allowed: false),
        ]
        let state = LaunchctlState(
            services: ["com.acme.updater": .init(pid: 42, lastExitStatus: nil), "com.other.daemon": .init(pid: nil, lastExitStatus: 1),
                       "com.example.magnet": .init(pid: 7, lastExitStatus: nil)],
            overrides: [:])
        let snapshot = StartupSnapshot.build(launchd: launchd, loginItems: loginItems, state: state, signature: { path in
            path == "/usr/bin/x" ? CodeSignature(signer: .developerID(name: "Acme"), teamIdentifier: "TEAM1") : nil
        })

        XCTAssertEqual(snapshot.appleCount, 880)
        XCTAssertEqual(snapshot.items.count, 8, "developer groups and container-only apps are not rows")
        let extensions = snapshot.items(in: .extensions)
        XCTAssertEqual(extensions.map(\.name), ["importer"])
        XCTAssertEqual(extensions[0].trigger, "when Spotlight indexes its files")
        XCTAssertEqual(extensions[0].state, .off)
        XCTAssertEqual(extensions[0].parent, "Magnet")

        let updater = snapshot.items(in: .userAgents).first { $0.id == "com.acme.updater" }!
        XCTAssertEqual(updater.name, "Acme Updater", "the login-items name wins over the label")
        XCTAssertEqual(updater.state, .running(pid: 42))
        XCTAssertEqual(updater.developer, "Acme Inc")
        XCTAssertTrue(updater.isLoginItem)
        XCTAssertEqual(updater.runs, "/usr/bin/x --run")
        XCTAssertEqual(updater.trigger, "at login")
        XCTAssertEqual(updater.facts.map(\.name), ["Runs", "When", "State", "Signed by", "Team", "Developer", "Plist"])
        let prompt = Prompt.build(instructions: "", request: ExplainRequest(kind: .launchItem, key: updater.explainKey, facts: updater.facts), redactor: .addressesOnly)
        XCTAssertTrue(prompt.contains(#"{"name":"Runs","value":"/usr/bin/x (1 argument, not sent)"}"#),
                      "arguments can carry tokens and addresses: only the program goes out")
        XCTAssertFalse(snapshot.items.contains { $0.id == "8.com.acme.updater" }, "joined, not duplicated")

        XCTAssertEqual(snapshot.items(in: .daemons).first?.state, .idle(lastExitStatus: 1))
        XCTAssertEqual(snapshot.items(in: .daemons).first?.trigger, "kept running")
        XCTAssertEqual(snapshot.items(in: .userAgents).first { $0.id == "com.empty" }?.state, .placeholder)
        XCTAssertEqual(snapshot.items(in: .userAgents).first { $0.id == "com.off" }?.state, .disabled)

        let apps = snapshot.items(in: .loginItems)
        XCTAssertEqual(apps.map(\.name), ["Magnet"], "only apps, as in System Settings' Open at Login")
        XCTAssertEqual(apps[0].id, "com.example.magnet")
        XCTAssertEqual(apps[0].state, .running(pid: 7))
        XCTAssertEqual(apps[0].runs, "/Applications/Magnet.app")
        let background = snapshot.items(in: .background)
        XCTAssertEqual(background.map(\.name), ["magnetLauncher", "Podcasts refresh"])
        XCTAssertEqual(background[0].state, .enabled, "the allowed bit is the System Settings toggle")
        XCTAssertEqual(background[0].parent, "Magnet")
        XCTAssertEqual(background[0].runs, "/Applications/Magnet.app/Contents/Library/LoginItems/magnetLauncher.app")
        XCTAssertEqual(background[1].state, .off, "set by the app but switched off by the user")
    }

    /// What the panel shows differs from what a prompt carries: a development certificate is
    /// named after the developer, and the user's account after their login.
    private func assertPromptValuesDiffer(_ facts: [Fact], runsAs: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let signed = facts.first { $0.name == "Signed by" }
        XCTAssertEqual(signed?.value, "Apple Development (ABCDE12345)", file: file, line: line)
        XCTAssertNil(signed?.promptValue, "the panel's value carries no name, so the model gets it too", file: file, line: line)
        guard runsAs else { return }
        let login = String(cString: getpwuid(getuid()).pointee.pw_name)
        let account = facts.first { $0.name == "Runs as" }
        XCTAssertEqual(account?.value, "you (\(login))", file: file, line: line)
        XCTAssertEqual(account?.promptValue, "you", file: file, line: line)
    }

    func testStartupFactKeepsTheCertificateNameOutOfItsPromptValue() throws {
        let snapshot = StartupSnapshot.build(
            launchd: LaunchdReader.Result(items: [job("com.acme.updater")], appleCount: 0, skipped: [:]),
            loginItems: [], state: LaunchctlState(services: [:], overrides: [:]),
            signature: { _ in CodeSignature(signer: .development, teamIdentifier: "ABCDE12345") })
        assertPromptValuesDiffer(try XCTUnwrap(snapshot.items.first).facts, runsAs: false)
    }

    func testALaunchItemThatIsNotApplesNeverReadsAsApple() throws {
        let apple: (String) -> CodeSignature? = { _ in CodeSignature(signer: .apple, identifier: "com.apple.x", teamIdentifier: nil) }
        let snapshot = StartupSnapshot.build(
            launchd: LaunchdReader.Result(items: [job("local.sqlite", program: "/usr/bin/sqlite3")], appleCount: 0, skipped: [:]),
            loginItems: [
                login("1.agent", name: "registered agent", kind: .agent, executable: "/usr/bin/sqlite3"),
                login("1.daemon", name: "registered daemon", kind: .daemon, executable: "/bin/ls"),
                login("1.helper", name: "Apple's helper", kind: .loginItemHelper, executable: "/System/Applications/Passwords.app/Contents/MacOS/x"),
            ],
            state: LaunchctlState(services: [:], overrides: [:]), signature: apple)

        let item = try XCTUnwrap(snapshot.items.first { $0.id == "local.sqlite" })
        XCTAssertEqual(item.signature?.signer, .launchItem(applesProgram: "sqlite3"))
        XCTAssertEqual(item.signature?.summary, "launch item, not signed")
        XCTAssertEqual(item.facts.first { $0.name == "Signed by" }?.value, "launch item, not signed")
        XCTAssertEqual(item.facts.first { $0.name == "Runs Apple's" }?.value, "sqlite3")
        XCTAssertFalse(item.facts.contains { $0.value == "Apple" })

        let background = snapshot.items(in: .background)
        XCTAssertEqual(background.first { $0.name == "registered agent" }?.signature?.signer, .launchItem(applesProgram: "sqlite3"))
        XCTAssertEqual(background.first { $0.name == "registered daemon" }?.signature?.signer, .launchItem(applesProgram: "ls"))
        XCTAssertEqual(background.first { $0.name == "Apple's helper" }?.signature?.signer, .apple, "no plist says what it runs")
    }

    func testALaunchItemThatChangesItsRootDoesNotNameTheProgram() throws {
        var rooted = job("local.rooted", program: "/bin/ls")
        rooted.rootDirectory = "/x"
        let snapshot = StartupSnapshot.build(
            launchd: LaunchdReader.Result(items: [rooted], appleCount: 0, skipped: [:]),
            loginItems: [], state: LaunchctlState(services: [:], overrides: [:]),
            signature: { _ in CodeSignature(signer: .apple) })
        let item = try XCTUnwrap(snapshot.items.first)
        XCTAssertEqual(item.signature?.signer, .launchItem(applesProgram: nil))
        XCTAssertEqual(item.signature?.summary, "launch item, not signed")
        XCTAssertFalse(item.facts.contains { $0.name == "Runs Apple's" }, "the path does not say which file runs")
    }

    func testARegisteredItemAmongApplesDeveloperToolsReadsAsUnnamedCode() {
        let xcode = "/Applications/Xcode.app/Contents/Developer"
        let tools = "/Library/Developer/CommandLineTools"
        let snapshot = StartupSnapshot.build(
            launchd: LaunchdReader.Result(items: [], appleCount: 0, skipped: [:]),
            loginItems: [
                login("1.app", name: "app", kind: .app, executable: "\(xcode)/Applications/App.app"),
                login("1.helper", name: "helper", kind: .loginItemHelper, executable: "\(tools)/usr/libexec/helper"),
                login("1.agent", name: "agent", kind: .agent, executable: "\(xcode)/usr/bin/agent"),
                login("1.extension", name: "extension", kind: .appExtension, executable: "\(xcode)/Library/X.appex"),
                login("1.publisher", name: "publisher", kind: .appExtension, executable: "\(tools)/Library/Y.appex"),
            ],
            state: LaunchctlState(services: [:], overrides: [:]),
            signature: { $0.hasSuffix("Y.appex") ? CodeSignature(signer: .developerID(name: "Acme")) : CodeSignature(signer: .apple) })
        for name in ["app", "helper", "agent", "extension"] {
            XCTAssertEqual(snapshot.items.first { $0.name == name }?.signature?.signer, .unnamed, name)
        }
        XCTAssertEqual(snapshot.items.first { $0.name == "publisher" }?.signature?.signer, .developerID(name: "Acme"))
    }

    func testALaunchItemRunningAnotherPublishersProgramKeepsItsSigner() throws {
        let snapshot = StartupSnapshot.build(
            launchd: LaunchdReader.Result(items: [job("com.acme.updater")], appleCount: 0, skipped: [:]),
            loginItems: [], state: LaunchctlState(services: [:], overrides: [:]),
            signature: { _ in CodeSignature(signer: .developerID(name: "Acme")) })
        let item = try XCTUnwrap(snapshot.items.first)
        XCTAssertEqual(item.signature?.signer, .developerID(name: "Acme"))
        XCTAssertFalse(item.facts.contains { $0.name == "Runs Apple's" })
    }

    func testLaunchctlOverrideAndNotLoaded() {
        let launchd = LaunchdReader.Result(items: [job("a"), job("b")], appleCount: 0, skipped: [:])
        let state = LaunchctlState(services: [:], overrides: ["a": true])
        let snapshot = StartupSnapshot.build(launchd: launchd, loginItems: [], state: state, signature: { _ in nil })
        XCTAssertEqual(snapshot.items.map(\.state), [.disabled, .notLoaded])
    }

    func testThisMachineBuilds() throws {
        // Without Full Disk Access the app builds from the launchd jobs alone, and so does this.
        let loginItems: [LoginItem]
        do {
            loginItems = try LoginItemsDatabase.readCurrent().items
        } catch LoginItemsDatabase.ReadError.cannotList(_), LoginItemsDatabase.ReadError.noDatabase {
            loginItems = []
        }
        let cache = SignatureCache()
        let snapshot = StartupSnapshot.build(
            launchd: LaunchdReader().read(), loginItems: loginItems,
            state: LaunchctlState.read(), signature: cache.signature(at:))
        XCTAssertFalse(snapshot.items.isEmpty)
        XCTAssertEqual(Set(snapshot.items.map(\.id)).count, snapshot.items.count, "ids are unique")
        XCTAssertTrue(snapshot.items.contains { $0.signature != nil }, "signatures are read")
    }

    func testStateText() {
        XCTAssertEqual(StartupItem.State.running(pid: 3).text, "running, pid 3")
        XCTAssertEqual(StartupItem.State.idle(lastExitStatus: 0).text, "not running")
        XCTAssertEqual(StartupItem.State.idle(lastExitStatus: -9).text, "not running, last exit -9")
        XCTAssertTrue(StartupItem.State.enabled.isActive)
        XCTAssertFalse(StartupItem.State.off.isActive)
    }
}
