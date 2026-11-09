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
    static func containing(_ path: String) -> AppBundle? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") && $0.count > 4 }),
              index < components.count - 1, !isFrameworkHelper(in: components[..<index]) else { return nil }
        return AppBundle(path: components[...index].joined(separator: "/"))
    }

    /// How the app reads, from its bundle's signature. An app Apple signed in a toolchain, an
    /// Xcode or the Command Line Tools is one of Apple's developer tools, which runs what it is
    /// told; any other there keeps its signer.
    func signature(reading signature: (String) -> CodeSignature?) -> CodeSignature? {
        let signed = signature(path)
        return LaunchedCode.Identity(path: path, signature: signed).isDeveloperTool ? CodeSignature(signer: .unnamed) : signed
    }

    /// Whether the executable at `path` is a file in this bundle that the bundle's signer did
    /// not sign. The bundle's signature is read without its resources, so it says nothing of a
    /// file put there: an answer given for the app is not about that file.
    func holdsForeign(_ path: String?, signed executable: CodeSignature?, bundle: CodeSignature?) -> Bool {
        guard let path, path.hasPrefix(self.path + "/") else { return false }
        return bundle?.owns(executable) != true
    }

    /// Whether `opened`, the bundle Launch Services reports for a process, is this one. It
    /// names Safari by /Applications/Safari.app, a link into the cryptex Safari runs from.
    func isOpened(from opened: String?) -> Bool {
        guard let opened else { return false }
        return opened == path || URL(fileURLWithPath: opened).resolvingSymlinksInPath().path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// The bundle Launch Services reports a process was opened from, when it is an app.
    /// Launch Services registers some command-line processes too (node servers that open a
    /// browser, say) and then reports the bare executable, and a script that opens a window
    /// (tkinter) under its interpreter's framework app.
    static func opened(_ path: String) -> AppBundle? {
        guard path.hasSuffix(".app"), !isFrameworkHelper(in: path.split(separator: "/").dropLast()) else { return nil }
        return AppBundle(path: path)
    }

    /// An .app inside a framework is the framework's helper, not an app anyone opened: the
    /// Python.app that runs Python's scripts, Tk's Wish.app.
    private static func isFrameworkHelper(in ancestors: some Sequence<Substring>) -> Bool {
        ancestors.contains { $0.hasSuffix(".framework") }
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
    /// standard input under launchd, or a developer tool's (`ProcessEntry.interpreter`).
    var interpreter: String?
    /// Known for the user's own processes. Tells two copies of one program apart: two
    /// shells, two servers, two agent sessions.
    var workingDirectory: String?
    var started: Date
    var usage: ProcessUsage?
    /// Cores busy since the previous snapshot: 1.0 is one core fully used, as in
    /// Activity Monitor. Nil until there is a previous reading of this process.
    var cpu: Double?
    /// Who signed the code the process runs: its executable, or no one for a script or
    /// unnamed code.
    var signature: CodeSignature?
    /// The executable's signature when it is an interpreter running a script or unnamed code.
    var interpreterSignature: CodeSignature?
    /// The app the process belongs to, by its own path or by an ancestor's.
    var app: AppBundle?
    /// What tells this process's code from another's of its name (`ProcessEntry.identity`).
    var identity: CodeIdentity?

    var id: Int32 { pid }
    var memoryBytes: UInt64 { usage?.memoryBytes ?? 0 }
    /// Part of macOS: signed by Apple as its own code, or the kernel. A script is not,
    /// whoever signed its interpreter.
    var isPartOfMacOS: Bool { pid == 0 || signature?.signer == .apple }
    var isApplesProgram: Bool { pid == 0 || ApplesProgram.isNamed(name, path: path, signature: signature) }

    /// What the row says after the name: "node script", "node, unnamed code", the signer, or
    /// that the executable has been deleted since the process started (an upgraded tool).
    var signerText: String? {
        if let interpreter { return signature?.signer == .unnamed ? "\(interpreter), unnamed code" : "\(interpreter) script" }
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
        let signers = [(signature, "Signed by", "Team"), (interpreterSignature, "Interpreter signed by", "Interpreter team")]
        for (signature, label, teamLabel) in signers {
            guard let signature else { continue }
            facts.append(.signedBy(signature, as: label))
            if let team = signature.teamIdentifier { facts.append(Fact(name: teamLabel, value: team)) }
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
    /// What tells the row's program from another's of its name: the app, or the top process.
    /// None while a file in the app's bundle that its signer did not sign is running.
    var identity: CodeIdentity?
    /// The member `leader` names.
    var leaderPid: Int32?

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

    /// The process that stands for the whole group: the app's own, the oldest of several, or
    /// the program at the top of the row's tree. Nil for macOS, and for an app that is not
    /// open while its helpers or widgets run: quitting one of those would not quit the app.
    var leader: ProcessItem? { members.first { $0.pid == leaderPid } }

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
                signature: entry.codeSignature(executable: executableSignature),
                interpreterSignature: entry.interpreter == nil ? nil : executableSignature,
                app: app(of: entry.pid, in: { byPid[$0] }, runningApp: runningApp, responsible: responsible, memo: &apps),
                identity: entry.identity(executable: executableSignature)))
        }

        let itemsByPid = Dictionary(items.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var groupsByID: [String: ProcessGroup] = [:]
        var order: [String] = []
        for item in items {
            let key = groupKey(for: item, in: itemsByPid)
            if groupsByID[key.id] == nil {
                let groupSignature: CodeSignature?
                var identity: CodeIdentity?
                switch key.kind {
                case .app(let bundle):
                    groupSignature = bundle.signature(reading: signature)
                    identity = CodeIdentity.of(groupSignature, path: bundle.path)
                case .process:
                    groupSignature = key.root?.signature
                    identity = key.root?.identity
                case .system: groupSignature = CodeSignature(signer: .apple)
                }
                groupsByID[key.id] = ProcessGroup(id: key.id, kind: key.kind, name: key.name, members: [], signature: groupSignature, identity: identity, leaderPid: key.root?.pid)
                order.append(key.id)
            }
            groupsByID[key.id]!.members.append(item)
        }
        var groups = order.compactMap { groupsByID[$0] }
        for index in groups.indices {
            groups[index].members.sort { ($0.memoryBytes, $1.pid) > ($1.memoryBytes, $0.pid) }
            guard case .app(let bundle) = groups[index].kind else { continue }
            if groups[index].members.contains(where: {
                bundle.holdsForeign($0.path, signed: $0.interpreterSignature ?? $0.signature, bundle: groups[index].signature)
            }) {
                groups[index].identity = nil
            }
            groups[index].leaderPid = groups[index].members.filter { bundle.isOpened(from: runningApp($0.pid)) }
                .min { ($0.started, $0.pid) < ($1.started, $1.pid) }?.pid
        }
        return ProcessSnapshot(items: items, groups: groups, takenAt: takenAt)
    }

    /// The app a process belongs to: the bundle on its own path unless it runs a script,
    /// else the one Launch Services opened it from, else the nearest ancestor's, else, for a
    /// service that launchd started on an app's behalf (Safari's networking service, say),
    /// the app macOS holds responsible for it. Memoized, since whole trees share an answer.
    /// The Network tab uses it too, to put a helper's connection under its app.
    static func app(
        of pid: Int32, in entries: (Int32) -> ProcessEntry?, runningApp: (Int32) -> String?,
        responsible: (Int32) -> Int32? = ResponsibleProcess.pid(for:), memo: inout [Int32: AppBundle?]
    ) -> AppBundle? {
        if let known = memo[pid] { return known }
        memo[pid] = .some(nil)  // breaks a cycle in a corrupt table
        guard let entry = entries(pid) else { return nil }
        // An interpreter or developer tool inside an app (Xcode's Python, swift, git) says
        // nothing about whose code it runs.
        var result = (entry.interpreter == nil ? entry.path.flatMap(AppBundle.containing) : nil)
            ?? runningApp(pid).flatMap(AppBundle.opened)
        if result == nil, entry.parentPid > 1, entry.parentPid != pid {
            result = app(of: entry.parentPid, in: entries, runningApp: runningApp, responsible: responsible, memo: &memo)
        }
        if result == nil, entry.parentPid <= 1, let owner = responsible(pid), entries(owner) != nil {
            result = app(of: owner, in: entries, runningApp: runningApp, responsible: responsible, memo: &memo)
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
