import Foundation

/// An app bundle a process lives in or descends from.
struct AppBundle: Hashable, Sendable {
    var path: String

    var name: String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }

    /// System UI such as the Dock, Control Center and the Finder lives under
    /// /System/Library, and Apple's updatable system pieces (XProtect) under
    /// /Library/Apple; apps the user opens live in /Applications or /System/Applications.
    var isSystem: Bool { path.hasPrefix("/System/Library/") || path.hasPrefix("/Library/Apple/") }

    /// The outermost .app on a path: a helper app nested inside Slack.app belongs to Slack.
    /// An .app inside a framework is the framework's helper, not an app anyone opened: the
    /// Python.app that runs Python's scripts, Tk's Wish.app.
    static func containing(_ path: String) -> AppBundle? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") && $0.count > 4 }),
              index < components.count - 1,
              !components[..<index].contains(where: { $0.hasSuffix(".framework") }) else { return nil }
        return AppBundle(path: components[...index].joined(separator: "/"))
    }
}

/// One process as the Processes tab shows it.
struct ProcessItem: Equatable, Sendable, Identifiable {
    var pid: Int32
    var parentPid: Int32
    var parentName: String?
    var uid: UInt32
    var name: String
    var path: String?
    /// Set when the process runs code that is not its executable's: a script, inline code,
    /// or standard input under launchd (`ProcessEntry.interpreter`).
    var interpreter: String?
    /// Known for the user's own processes. Tells two copies of one program apart: two
    /// shells, two servers, two agent sessions.
    var workingDirectory: String?
    var started: Date
    var usage: ProcessUsage?
    /// Cores busy since the previous snapshot: 1.0 is one core fully used, as in
    /// Activity Monitor. Nil until there is a previous reading of this process.
    var cpu: Double?
    /// Who signed the code the process runs: its executable, or no one for a script.
    var signature: CodeSignature?
    /// The executable's signature when it is an interpreter running a script.
    var interpreterSignature: CodeSignature?
    /// The app the process belongs to, by its own path or by an ancestor's.
    var app: AppBundle?

    var id: Int32 { pid }
    var memoryBytes: UInt64 { usage?.memoryBytes ?? 0 }
    /// Part of macOS: signed by Apple as its own code, or the kernel. A script is not,
    /// whoever signed its interpreter.
    var isPartOfMacOS: Bool { pid == 0 || signature?.signer == .apple }
    var isApplesProgram: Bool { pid == 0 || ApplesProgram.isNamed(name, path: path, signature: signature) }

    /// What the row says after the name: "node script", the signer, or that the
    /// executable has been deleted since the process started (an upgraded tool).
    var signerText: String? {
        if let interpreter { return "\(interpreter) script" }
        if path == nil, pid > 0 { return "executable no longer on disk" }
        return signature?.summary
    }

    /// The working directory with the home folder as "~", when it says something: the
    /// root and the home folder themselves do not.
    var workingDirectoryText: String? {
        guard let workingDirectory, workingDirectory != "/" else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if workingDirectory == home { return nil }
        return workingDirectory.hasPrefix(home + "/") ? "~" + workingDirectory.dropFirst(home.count) : workingDirectory
    }

    /// Knowledge-base key: the name, so a rule reads "nsurlsessiond" and a glob like
    /// "Slack Helper*" covers the helpers. The path is a fact.
    var explainKey: String { name }

    var facts: [Fact] {
        var facts = [Fact(name: "Process", value: "\(name) (pid \(pid))")]
        if let interpreter, let path {
            facts.append(Fact(name: "Runs with", value: "\(interpreter) (\(path))"))
        } else if let path {
            facts.append(Fact(name: "Path", value: path))
        }
        for (signature, label) in [(signature, "Signed by"), (interpreterSignature, "Interpreter signed by")] {
            guard let signature else { continue }
            facts.append(.signedBy(signature, as: label))
            if let team = signature.teamIdentifier { facts.append(Fact(name: "Team", value: team)) }
        }
        if let app, app.name != name { facts.append(Fact(name: "Part of", value: app.name)) }
        if pid > 0 { facts.append(Fact(name: "Parent", value: "\(parentName ?? "pid \(parentPid)") (pid \(parentPid))")) }
        // A folder name can say what the user is working on: the panel shows it, the model is not told.
        if let directory = workingDirectoryText { facts.append(Fact(name: "Working in", value: directory, inPrompt: false)) }
        facts.append(.runsAs(uid))
        facts.append(Fact(name: "Started", value: started.formatted(.relative(presentation: .named))))
        if let usage {
            facts.append(Fact(name: "Memory", value: Self.memoryText(usage.memoryBytes) + (usage.memoryIsFootprint ? " footprint" : " resident")))
        }
        if let cpu { facts.append(Fact(name: "CPU", value: Self.cpuText(cpu))) }
        return facts
    }

    static func memoryText(_ bytes: UInt64) -> String {
        Int64(bytes).formatted(.byteCount(style: .memory))
    }

    /// Percent of one core, so a process using two cores reads 200%.
    static func cpuText(_ cores: Double) -> String {
        cores.formatted(.percent.precision(.fractionLength(cores < 0.1 ? 1 : 0)))
    }
}

/// A row of the tab: an app with its helpers, a top-level process with its children, or
/// everything that is part of macOS.
struct ProcessGroup: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case app(AppBundle)
        /// A process outside any app, rolled up with its descendants.
        case process
        /// Apple's daemons and system UI, in one row.
        case system
    }

    static let systemID = "macos"

    var id: String
    var kind: Kind
    var name: String
    /// Members by memory, largest first.
    var members: [ProcessItem]
    var signature: CodeSignature?

    /// The bundle, or the top-level program; macOS is not one place.
    var path: String? {
        switch kind {
        case .app(let bundle): bundle.path
        case .process: leader?.path
        case .system: nil
        }
    }

    var memoryBytes: UInt64 { members.reduce(0) { $0 + $1.memoryBytes } }

    /// Nil until any member has a reading.
    var cpu: Double? {
        let readings = members.compactMap(\.cpu)
        return readings.isEmpty ? nil : readings.reduce(0, +)
    }

    /// Apple's own program by the group's name, which every member must be: an app's
    /// helpers go by other names, and macOS is not one program.
    var isApplesProgram: Bool {
        kind != .system && members.allSatisfy { ApplesProgram.isNamed(name, path: $0.path, signature: $0.signature) }
    }

    /// The group explains as its one process, or as the app; macOS is not one thing.
    var explainKey: String? { kind == .system ? nil : name }

    /// Members as a tree: each process followed by its children, largest first at every
    /// level, with the depth for indenting. A member whose parent is outside the group
    /// is a root. `showsDirectory` is set where the working directory differs from the
    /// parent's, since children inherit it and repeating it says nothing.
    var tree: [(item: ProcessItem, depth: Int, showsDirectory: Bool)] {
        let pids = Set(members.map(\.pid))
        var children: [Int32: [ProcessItem]] = [:]
        var roots: [ProcessItem] = []
        for member in members {
            if pids.contains(member.parentPid), member.parentPid != member.pid {
                children[member.parentPid, default: []].append(member)
            } else {
                roots.append(member)
            }
        }
        var result: [(item: ProcessItem, depth: Int, showsDirectory: Bool)] = []
        var seen = Set<Int32>()
        func visit(_ item: ProcessItem, _ depth: Int, parentDirectory: String?) {
            guard seen.insert(item.pid).inserted else { return }
            let directory = item.workingDirectoryText
            result.append((item, depth, directory != nil && directory != parentDirectory))
            for child in children[item.pid] ?? [] { visit(child, depth + 1, parentDirectory: directory ?? parentDirectory) }
        }
        for root in roots { visit(root, 0, parentDirectory: nil) }
        return result
    }

    /// The process to quit for the whole group: the one launchd started, else the
    /// oldest. Nil for macOS.
    var leader: ProcessItem? {
        guard kind != .system else { return nil }
        return members.filter { $0.parentPid <= 1 }.min { $0.pid < $1.pid } ?? members.min { $0.pid < $1.pid }
    }

    var facts: [Fact] {
        var facts = [Fact(name: "Processes", value: String(members.count))]
        if let path { facts.append(Fact(name: "Path", value: path)) }
        if let signature {
            facts.append(.signedBy(signature))
            if let team = signature.teamIdentifier { facts.append(Fact(name: "Team", value: team)) }
        }
        facts.append(Fact(name: "Memory", value: ProcessItem.memoryText(memoryBytes)))
        if let cpu { facts.append(Fact(name: "CPU", value: ProcessItem.cpuText(cpu))) }
        return facts
    }
}

struct ProcessSnapshot: Equatable, Sendable {
    enum Sort: String, CaseIterable, Sendable {
        case memory = "Memory"
        case cpu = "CPU"
    }

    var items: [ProcessItem]
    var groups: [ProcessGroup]
    var takenAt: Date

    func groups(sortedBy sort: Sort) -> [ProcessGroup] {
        switch sort {
        case .memory: groups.sorted { ($0.memoryBytes, $1.name) > ($1.memoryBytes, $0.name) }
        case .cpu: groups.sorted { ($0.cpu ?? -1, $0.memoryBytes) > ($1.cpu ?? -1, $1.memoryBytes) }
        }
    }

    func item(pid: Int32) -> ProcessItem? { items.first { $0.pid == pid } }
    func group(id: String) -> ProcessGroup? { groups.first { $0.id == id } }

    /// Attributes and rolls up. `signature` is called per executable and app bundle path;
    /// the observer passes a cached reader, tests pass a table. `runningApp` gives the
    /// bundle Launch Services opened a pid from, for the processes whose path does not
    /// say: Chromium browsers run their main process from a code-sign clone of the
    /// bundle under a .app.bundle name. CPU shares come from the difference against
    /// `previous`.
    static func build(
        entries: [ProcessEntry], previous: ProcessSnapshot?,
        signature: (String) -> CodeSignature?, runningApp: (Int32) -> String? = { _ in nil },
        responsible: (Int32) -> Int32? = ResponsibleProcess.pid(for:), takenAt: Date = Date()
    ) -> ProcessSnapshot {
        let byPid = Dictionary(entries.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let elapsed = previous.map { takenAt.timeIntervalSince($0.takenAt) } ?? 0
        let earlier = Dictionary((previous?.items ?? []).map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })

        var items: [ProcessItem] = []
        items.reserveCapacity(entries.count)
        var apps: [Int32: AppBundle?] = [:]
        for entry in entries {
            let executableSignature = entry.path.flatMap(signature)
            var cpu: Double?
            if elapsed > 0.5, let before = earlier[entry.pid], abs(before.started.timeIntervalSince(entry.started)) < 1,
               let now = entry.usage?.cpuSeconds, let then = before.usage?.cpuSeconds {
                cpu = max(now - then, 0) / elapsed
            }
            items.append(ProcessItem(
                pid: entry.pid, parentPid: entry.parentPid, parentName: byPid[entry.parentPid]?.name,
                uid: entry.uid, name: entry.name, path: entry.path, interpreter: entry.interpreter,
                workingDirectory: entry.workingDirectory, started: entry.started,
                usage: entry.usage, cpu: cpu,
                signature: entry.interpreter == nil ? executableSignature : CodeSignature(signer: .script),
                interpreterSignature: entry.interpreter == nil ? nil : executableSignature,
                app: app(of: entry.pid, in: byPid, runningApp: runningApp, responsible: responsible, memo: &apps)))
        }

        let itemsByPid = Dictionary(items.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var groupsByID: [String: ProcessGroup] = [:]
        var order: [String] = []
        for item in items {
            let key = groupKey(for: item, in: itemsByPid)
            if groupsByID[key.id] == nil {
                let groupSignature: CodeSignature?
                switch key.kind {
                case .app(let bundle): groupSignature = signature(bundle.path)
                case .process: groupSignature = key.root?.signature
                case .system: groupSignature = CodeSignature(signer: .apple)
                }
                groupsByID[key.id] = ProcessGroup(id: key.id, kind: key.kind, name: key.name, members: [], signature: groupSignature)
                order.append(key.id)
            }
            groupsByID[key.id]!.members.append(item)
        }
        var groups = order.compactMap { groupsByID[$0] }
        for index in groups.indices {
            groups[index].members.sort { ($0.memoryBytes, $1.pid) > ($1.memoryBytes, $0.pid) }
        }
        return ProcessSnapshot(items: items, groups: groups, takenAt: takenAt)
    }

    /// The app a process belongs to: the bundle on its own path unless it runs a script,
    /// else the one Launch Services opened it from, else the nearest ancestor's, else, for a service that
    /// launchd started on an app's behalf (Safari's networking service, say), the app
    /// macOS holds responsible for it. Memoized, since whole trees share an answer. The
    /// Network tab uses it too, to put a helper's connection under its app.
    static func app(
        of pid: Int32, in byPid: [Int32: ProcessEntry], runningApp: (Int32) -> String?,
        responsible: (Int32) -> Int32? = ResponsibleProcess.pid(for:), memo: inout [Int32: AppBundle?]
    ) -> AppBundle? {
        if let known = memo[pid] { return known }
        memo[pid] = .some(nil)  // breaks a cycle in a corrupt table
        guard let entry = byPid[pid] else { return nil }
        // Launch Services registers some command-line processes too (node servers that
        // open a browser, say) and then reports the bare executable as their bundle;
        // only a real .app counts. An interpreter inside an app (Xcode's Python, make and
        // swift) says nothing about whose script it runs.
        var result = (entry.interpreter == nil ? entry.path.flatMap(AppBundle.containing) : nil)
            ?? runningApp(pid).flatMap { $0.hasSuffix(".app") ? AppBundle(path: $0) : nil }
        if result == nil, entry.parentPid > 1, entry.parentPid != pid {
            result = app(of: entry.parentPid, in: byPid, runningApp: runningApp, responsible: responsible, memo: &memo)
        }
        if result == nil, entry.parentPid <= 1, let owner = responsible(pid), byPid[owner] != nil {
            result = app(of: owner, in: byPid, runningApp: runningApp, responsible: responsible, memo: &memo)
        }
        memo[pid] = result
        return result
    }

    /// Where a process rolls up. An app that is not system UI gets its own row; otherwise
    /// the topmost non-Apple ancestor is the row, so a server's workers sit under the
    /// server; otherwise it is part of macOS.
    private struct GroupKey {
        var id: String
        var kind: ProcessGroup.Kind
        var name: String
        var root: ProcessItem?
    }

    private static func groupKey(for item: ProcessItem, in byPid: [Int32: ProcessItem]) -> GroupKey {
        if let app = item.app, !app.isSystem {
            return GroupKey(id: app.path, kind: .app(app), name: app.name)
        }
        var root: ProcessItem?
        var cursor: ProcessItem? = item.pid > 0 ? item : nil
        var seen = Set<Int32>()
        while let current = cursor, seen.insert(current.pid).inserted {
            if !current.isPartOfMacOS { root = current }
            cursor = current.parentPid > 1 ? byPid[current.parentPid] : nil
        }
        if let root { return GroupKey(id: "pid:\(root.pid)", kind: .process, name: root.name, root: root) }
        return GroupKey(id: ProcessGroup.systemID, kind: .system, name: "macOS")
    }
}
