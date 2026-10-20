import XCTest
@testable import tattle

final class ProcessSnapshotTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(_ pid: Int32, _ ppid: Int32, _ path: String?, uid: UInt32 = 501, memory: UInt64 = 0, cpu: Double = 0,
                       started: Date? = nil, name: String? = nil) -> ProcessEntry {
        ProcessEntry(pid: pid, parentPid: ppid, uid: uid,
                     name: name ?? path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "pid \(pid)",
                     path: path, started: started ?? epoch,
                     usage: ProcessUsage(memoryBytes: memory, cpuSeconds: cpu, memoryIsFootprint: uid == 501))
    }

    /// Apple signs everything on the system volume and in /bin, /usr; the rest is Developer ID.
    private func sign(_ path: String) -> CodeSignature? {
        for prefix in ["/System/", "/Library/Apple/", "/usr/libexec/", "/usr/bin/", "/bin/", "/sbin/"] where path.hasPrefix(prefix) {
            return CodeSignature(signer: .apple)
        }
        let vendor = path.split(separator: "/").first { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
            ?? URL(fileURLWithPath: path).lastPathComponent
        return CodeSignature(signer: .developerID(name: vendor), teamIdentifier: "T-\(vendor)")
    }

    private var machine: [ProcessEntry] {
        [
            entry(0, 0, nil, uid: 0, name: "kernel_task"),
            entry(1, 0, "/sbin/launchd", uid: 0, memory: 30),
            entry(50, 1, "/usr/libexec/trustd", uid: 0, memory: 20),
            entry(60, 1, "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock", memory: 90),
            entry(61, 1, "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", memory: 200),
            entry(70, 1, "/System/Applications/Mail.app/Contents/MacOS/Mail", memory: 300),
            entry(100, 1, "/Applications/Slack.app/Contents/MacOS/Slack", memory: 100, cpu: 10),
            entry(101, 100, "/Applications/Slack.app/Contents/Frameworks/Slack Helper (GPU).app/Contents/MacOS/Slack Helper (GPU)", memory: 400, cpu: 5),
            entry(200, 1, "/Applications/iTerm.app/Contents/MacOS/iTerm2", memory: 150),
            entry(201, 200, "/bin/zsh", memory: 5),
            entry(202, 201, "/usr/local/bin/claude", memory: 250),
            entry(300, 1, "/usr/local/bin/ollama", memory: 50),
            entry(301, 300, "/usr/local/bin/ollama", memory: 1000, name: "ollama runner"),
            entry(400, 1, "/bin/sh", uid: 0, memory: 1),
            entry(401, 400, "/opt/homebrew/bin/node", uid: 0, memory: 80),
            entry(500, 1, "/private/var/folders/x/T/X/ai.comet.code_sign_clone/code_sign_clone.1U/Comet.app.bundle/Contents/MacOS/Comet", memory: 600),
            entry(501, 500, "/Applications/Comet.app/Contents/Frameworks/Comet Framework.framework/Helpers/Comet Helper (GPU).app/Contents/MacOS/Comet Helper (GPU)", memory: 70),
            entry(510, 1, "/Library/Apple/System/Library/CoreServices/XProtect.app/Contents/MacOS/XProtect", uid: 0, memory: 8),
        ]
    }

    /// What Launch Services knows: the browser's main process came from /Applications.
    private func running(_ pid: Int32) -> String? {
        pid == 500 ? "/Applications/Comet.app" : nil
    }

    func testAttributionAndRollup() {
        let snapshot = ProcessSnapshot.build(entries: machine, previous: nil, signature: sign, runningApp: running, takenAt: epoch)
        XCTAssertEqual(snapshot.items.count, machine.count)
        let names = snapshot.groups(sortedBy: .memory).map { "\($0.name):\($0.members.count):\($0.memoryBytes)" }
        XCTAssertEqual(names, [
            "ollama:2:1050", "Comet:2:670", "Slack:2:500", "iTerm:3:405", "macOS:7:349", "Mail:1:300", "node:1:80",
        ])
        XCTAssertEqual(snapshot.group(id: "/Applications/Comet.app")?.members.map(\.pid), [500, 501],
                       "the code-sign clone main process joins the helpers under the installed bundle")

        let slack = snapshot.group(id: "/Applications/Slack.app")!
        XCTAssertEqual(slack.kind, .app(AppBundle(path: "/Applications/Slack.app")))
        XCTAssertEqual(slack.members.map(\.pid), [101, 100], "members by memory")
        XCTAssertEqual(slack.signature?.summary, "Slack")
        XCTAssertEqual(slack.explainKey, "Slack")
        XCTAssertEqual(slack.members[0].facts.first { $0.name == "Part of" }?.value, "Slack")
        XCTAssertNil(slack.members[1].facts.first { $0.name == "Part of" }, "the app's own process is not part of itself")

        let iterm = snapshot.group(id: "/Applications/iTerm.app")!
        XCTAssertEqual(Set(iterm.members.map(\.name)), ["iTerm2", "zsh", "claude"], "a shell and what it runs belong to the terminal")
        XCTAssertEqual(iterm.members.first { $0.name == "claude" }?.parentName, "zsh")

        let ollama = snapshot.group(id: "pid:300")!
        XCTAssertEqual(ollama.kind, .process)
        XCTAssertEqual(ollama.path, "/usr/local/bin/ollama", "the root's path, not the largest member's")
        XCTAssertEqual(ollama.signature?.summary, "ollama")
        XCTAssertEqual(ollama.explainKey, "ollama")

        let node = snapshot.group(id: "pid:401")!
        XCTAssertEqual(node.members.count, 1, "an Apple shell above a third-party process stays with macOS")

        let system = snapshot.group(id: ProcessGroup.systemID)!
        XCTAssertEqual(Set(system.members.map(\.name)), ["kernel_task", "launchd", "trustd", "Dock", "Finder", "sh", "XProtect"])
        XCTAssertNil(system.explainKey)
        XCTAssertEqual(system.signature?.signer, .apple)
        XCTAssertEqual(system.facts.first?.value, "7")

        XCTAssertEqual(snapshot.group(id: "/System/Applications/Mail.app")?.name, "Mail", "Apple apps the user opens are their own row")
        XCTAssertTrue(snapshot.groups.allSatisfy { $0.cpu == nil }, "no previous reading, no CPU")
        XCTAssertEqual(snapshot.item(pid: 101)?.explainKey, "Slack Helper (GPU)")
    }

    func testCPUComesFromTheDifferenceAgainstThePreviousSnapshot() {
        let first = ProcessSnapshot.build(entries: machine, previous: nil, signature: sign, takenAt: epoch)
        var later = machine
        later[6].usage!.cpuSeconds = 11       // Slack: +1 s over 2 s
        later[7].usage!.cpuSeconds = 9        // helper: +4 s
        later[11].usage!.cpuSeconds = 3       // ollama restarted: new start time, so no share
        later[11].started = epoch.addingTimeInterval(1.5)
        let second = ProcessSnapshot.build(entries: later, previous: first, signature: sign, takenAt: epoch.addingTimeInterval(2))

        XCTAssertEqual(second.item(pid: 100)?.cpu, 0.5)
        XCTAssertEqual(second.item(pid: 101)?.cpu, 2)
        XCTAssertNil(second.item(pid: 300)?.cpu)
        XCTAssertEqual(second.item(pid: 1)?.cpu, 0)
        XCTAssertEqual(second.group(id: "/Applications/Slack.app")?.cpu, 2.5)
        XCTAssertEqual(second.group(id: "pid:300")?.cpu, 0, "the runner still counts, the restarted server does not")
        XCTAssertEqual(second.groups(sortedBy: .cpu).first?.name, "Slack")
        XCTAssertEqual(second.item(pid: 101)?.facts.last, Fact(name: "CPU", value: "200%"))
        XCTAssertEqual(ProcessItem.cpuText(0.004), "0.4%")
    }

    func testAppBundleContainment() {
        XCTAssertEqual(AppBundle.containing("/Applications/Slack.app/Contents/Frameworks/Slack Helper (GPU).app/Contents/MacOS/Slack Helper (GPU)")?.path, "/Applications/Slack.app")
        XCTAssertEqual(AppBundle.containing("/Applications/Slack.app/Contents/MacOS/Slack")?.name, "Slack")
        XCTAssertNil(AppBundle.containing("/usr/bin/zsh"))
        XCTAssertNil(AppBundle.containing("/Applications/Slack.app"), "a bundle path is not an executable inside one")
        XCTAssertTrue(AppBundle(path: "/System/Library/CoreServices/Finder.app").isSystem)
        XCTAssertTrue(AppBundle(path: "/Library/Apple/System/Library/CoreServices/XProtect.app").isSystem)
        XCTAssertNil(AppBundle.containing("/private/var/x/Comet.app.bundle/Contents/MacOS/Comet"), "a clone is not the bundle")
        XCTAssertFalse(AppBundle(path: "/System/Applications/Mail.app").isSystem)
    }

    func testFacts() {
        let item = ProcessSnapshot.build(entries: machine, previous: nil, signature: sign, takenAt: epoch).item(pid: 401)!
        let facts = Dictionary(item.facts.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(facts["Process"], "node (pid 401)")
        XCTAssertEqual(facts["Parent"], "sh (pid 400)")
        XCTAssertEqual(facts["Runs as"], "root")
        XCTAssertEqual(facts["Signed by"], "node")
        XCTAssertEqual(facts["Team"], "T-node")
        XCTAssertEqual(facts["Memory"], "80 bytes resident")
        XCTAssertNil(facts["CPU"])
    }

    func testThisMachine() throws {
        let start = Date()
        let cache = SignatureCache()
        let snapshot = ProcessSnapshot.build(entries: try ProcessTable.read(), previous: nil, signature: cache.signature(at:))
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 10, "first build reads every signature: \(elapsed) s")
        XCTAssertEqual(snapshot.groups.reduce(0) { $0 + $1.members.count }, snapshot.items.count, "every process in exactly one row")
        XCTAssertEqual(Set(snapshot.groups.map(\.id)).count, snapshot.groups.count)
        let system = try XCTUnwrap(snapshot.group(id: ProcessGroup.systemID))
        XCTAssertTrue(system.members.contains { $0.pid == 0 && $0.name == "kernel_task" })
        XCTAssertTrue(system.members.contains { $0.pid == 1 })
        XCTAssertGreaterThan(system.members.count, 100)
        XCTAssertLessThan(snapshot.groups.count, snapshot.items.count / 4, "\(snapshot.groups.count) rows for \(snapshot.items.count) processes")
        let me = try XCTUnwrap(snapshot.item(pid: getpid()))
        XCTAssertTrue(me.usage?.memoryIsFootprint == true)
    }
}
