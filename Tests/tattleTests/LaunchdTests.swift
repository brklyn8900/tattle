import XCTest
@testable import tattle

final class LaunchdTests: XCTestCase {
    private func plist(_ body: String) -> Data {
        Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>\(body)</dict></plist>
            """.utf8)
    }

    private func parse(_ body: String, scope: LaunchdItem.Scope = .userAgent) throws -> LaunchdItem {
        try LaunchdItem.parse(plist(body), url: URL(fileURLWithPath: "/tmp/x.plist"), scope: scope)
    }

    func testProgramAndArguments() throws {
        let a = try parse("<key>Label</key><string>a</string><key>ProgramArguments</key><array><string>/usr/bin/foo</string><string>--x</string></array>")
        XCTAssertEqual(a.program, "/usr/bin/foo")
        XCTAssertEqual(a.arguments, ["--x"])
        let b = try parse("<key>Label</key><string>b</string><key>Program</key><string>/bin/bar</string><key>ProgramArguments</key><array><string>bar</string><string>-v</string></array>")
        XCTAssertEqual(b.program, "/bin/bar")
        XCTAssertEqual(b.arguments, ["-v"], "with Program set, ProgramArguments[0] is argv[0], not an argument")
        XCTAssertFalse(b.disabled)
        let script = try parse("<key>Label</key><string>c</string><key>Program</key><string>/bin/sh</string><key>ProgramArguments</key><array><string>/bin/sh</string><string>/x.sh</string></array>")
        XCTAssertEqual(script.arguments, ["/x.sh"])
        XCTAssertNil(script.environmentPath)
        let path = try parse("<key>Label</key><string>d</string><key>Program</key><string>/bin/x</string><key>EnvironmentVariables</key><dict><key>PATH</key><string>/x:/bin</string></dict>")
        XCTAssertEqual(path.environmentPath, "/x:/bin")
    }

    func testRootDirectory() throws {
        let rooted = try parse("<key>Label</key><string>r</string><key>Program</key><string>/bin/ls</string><key>RootDirectory</key><string>/x</string>")
        XCTAssertEqual(rooted.rootDirectory, "/x")
        XCTAssertNil(try parse("<key>Label</key><string>n</string><key>Program</key><string>/bin/ls</string>").rootDirectory)
    }

    func testRejectsMissingLabelAndNonDictionary() {
        XCTAssertThrowsError(try parse("<key>Program</key><string>/bin/x</string>")) {
            XCTAssertEqual($0 as? LaunchdItem.ParseError, .noLabel)
        }
        XCTAssertThrowsError(try LaunchdItem.parse(Data("<plist version=\"1.0\"><array/></plist>".utf8), url: URL(fileURLWithPath: "/x"), scope: .daemon)) {
            XCTAssertEqual($0 as? LaunchdItem.ParseError, .notADictionary)
        }
    }

    func testEmptyPlistIsAPlaceholder() throws {
        let item = try LaunchdItem.parse(plist(""), url: URL(fileURLWithPath: "/Users/x/Library/LaunchAgents/com.google.keystone.agent.plist"), scope: .userAgent)
        XCTAssertTrue(item.isPlaceholder)
        XCTAssertEqual(item.label, "com.google.keystone.agent")
        XCTAssertNil(item.program)
        XCTAssertEqual(item.triggers, [])
    }

    func testTriggers() throws {
        let item = try parse("""
            <key>Label</key><string>t</string>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
            <key>StartInterval</key><integer>3600</integer>
            <key>StartCalendarInterval</key><dict><key>Hour</key><integer>10</integer><key>Minute</key><integer>30</integer></dict>
            <key>WatchPaths</key><array><string>/etc/hosts</string></array>
            <key>MachServices</key><dict><key>com.x.y</key><true/></dict>
            <key>Disabled</key><true/>
            <key>AssociatedBundleIdentifiers</key><string>com.x</string>
            """)
        XCTAssertEqual(item.triggers, [
            .atLoad, .keepAlive, .interval(seconds: 3600),
            .calendar([.init(minute: 30, hour: 10, day: nil, weekday: nil, month: nil)]),
            .watchPaths(["/etc/hosts"]), .onDemand,
        ])
        XCTAssertTrue(item.disabled)
        XCTAssertEqual(item.associatedBundleIdentifiers, ["com.x"])
        XCTAssertEqual(try parse("<key>Label</key><string>n</string><key>KeepAlive</key><false/>").triggers, [.onDemand], "nothing else means on demand")
        XCTAssertEqual(try parse("<key>Label</key><string>k</string><key>KeepAlive</key><true/>").triggers, [.keepAlive])
    }

    func testTriggerDescriptions() {
        XCTAssertEqual(Trigger.atLoad.description(scope: .userAgent), "at login")
        XCTAssertEqual(Trigger.atLoad.description(scope: .daemon), "at boot")
        XCTAssertEqual(Trigger.interval(seconds: 30).description(scope: .daemon), "every 30 s")
        XCTAssertEqual(Trigger.interval(seconds: 300).description(scope: .daemon), "every 5 min")
        XCTAssertEqual(Trigger.interval(seconds: 3600).description(scope: .daemon), "every hour")
        XCTAssertEqual(Trigger.interval(seconds: 7200).description(scope: .daemon), "every 2 h")
        XCTAssertEqual(Trigger.interval(seconds: 86_400).description(scope: .daemon), "every day")
        XCTAssertEqual(Trigger.calendar([.init(minute: 30, hour: 10, day: nil, weekday: nil, month: nil)]).description(scope: .daemon), "daily at 10:30")
        XCTAssertEqual(Trigger.calendar([.init(minute: 0, hour: 3, day: nil, weekday: 1, month: nil)]).description(scope: .daemon), "every Monday at 03:00")
        XCTAssertEqual(Trigger.calendar([.init(minute: 15, hour: nil, day: nil, weekday: nil, month: nil)]).description(scope: .daemon), "every hour at :15")
        XCTAssertEqual(Trigger.calendar([.init(minute: nil, hour: 1, day: 1, weekday: nil, month: nil)]).description(scope: .daemon), "monthly on day 1 at 01:00")
        XCTAssertEqual(Trigger.watchPaths(["/a", "/b"]).description(scope: .daemon), "when /a, /b change")
        XCTAssertEqual(Trigger.keepAlive.description(scope: .daemon), "kept running")
    }

    func testReaderReadsFoldersReportsBadFilesAndCountsApple() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appending(path: "user"), daemons = root.appending(path: "daemons"), apple = root.appending(path: "apple")
        for dir in [user, daemons, apple] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try plist("<key>Label</key><string>com.a</string><key>Program</key><string>/a</string>").write(to: user.appending(path: "com.a.plist"))
        try Data("junk".utf8).write(to: user.appending(path: "broken.plist"))
        try Data("<plist><dict>".utf8).write(to: user.appending(path: "corrupt.plist"))
        try Data("ignored".utf8).write(to: user.appending(path: "README"))
        try plist("<key>Label</key><string>com.d</string><key>Program</key><string>/d</string>").write(to: daemons.appending(path: "com.d.plist"))
        let locked = daemons.appending(path: "locked.plist")
        try plist("<key>Label</key><string>com.l</string>").write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        for i in 0..<3 { try plist("<key>Label</key><string>apple\(i)</string>").write(to: apple.appending(path: "apple\(i).plist")) }

        // A missing folder has no jobs in it, which is normal: a user may have no agents.
        let reader = LaunchdReader(folders: [.userAgent: user, .daemon: daemons, .globalAgent: root.appending(path: "missing")], appleFolders: [apple])
        let result = reader.read()
        XCTAssertEqual(result.items.map(\.label), ["com.a", "com.d"])
        XCTAssertEqual(result.items.map(\.scope), [.userAgent, .daemon])
        XCTAssertEqual(result.appleCount, 3)
        XCTAssertEqual(result.unreadable.map(\.url.lastPathComponent), ["broken.plist", "corrupt.plist", "locked.plist"])
        XCTAssertEqual(result.unreadable.map(\.scope), [.userAgent, .userAgent, .daemon])
        XCTAssertEqual(result.unreadable.map(\.reason), [
            "it is not a launchd job", "it is not a valid property list", "Tattle has no permission to read this file",
        ])
    }

    /// launchd runs as root and reads a folder Tattle cannot list: its jobs run unseen.
    func testAFolderThatCannotBeListedIsReported() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appending(path: "daemons").path)
            try? FileManager.default.removeItem(at: root)
        }
        let daemons = root.appending(path: "daemons")
        try FileManager.default.createDirectory(at: daemons, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: daemons.path)
        let result = LaunchdReader(folders: [.daemon: daemons, .userAgent: root.appending(path: "missing")], appleFolders: [daemons]).read()
        XCTAssertEqual(result.unreadable, [.init(url: daemons, scope: .daemon, reason: "Tattle has no permission to list this folder", isFolder: true)])
        XCTAssertEqual(result.appleCount, 0)
    }

    func testSessionTypesAreReadAsAStringOrAnArray() throws {
        func parsed(_ value: String) throws -> [String] {
            let xml = """
                <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Label</key><string>a</string>\(value)</dict></plist>
                """
            return try LaunchdItem.parse(Data(xml.utf8), url: URL(fileURLWithPath: "/x/a.plist"), scope: .userAgent).sessionTypes
        }
        XCTAssertEqual(try parsed("<key>LimitLoadToSessionType</key><string>Background</string>"), ["Background"])
        XCTAssertEqual(try parsed("<key>LimitLoadToSessionType</key><array><string>Aqua</string><string>Background</string></array>"), ["Aqua", "Background"])
        XCTAssertEqual(try parsed(""), [])
    }

    func testThisMachineParsesCleanly() {
        let result = LaunchdReader().read()
        // A plist only root may read is the machine's business, not a parser's failure.
        let failed = result.unreadable.filter { $0.reason != "Tattle has no permission to read this file" }
        XCTAssertTrue(failed.isEmpty, "\(failed)")
        XCTAssertGreaterThan(result.appleCount, 100)
    }
}
