import Foundation

/// One row of the Startup tab: a launchd job, a login item, or both joined.
struct StartupItem: Equatable, Sendable, Identifiable {
    enum Group: Int, CaseIterable, Sendable {
        case loginItems, background, userAgents, globalAgents, daemons, extensions

        var title: String {
            switch self {
            case .loginItems: "Open at login"
            case .background: "Allowed in the background"
            case .userAgents: LaunchdItem.Scope.userAgent.title
            case .globalAgents: LaunchdItem.Scope.globalAgent.title
            case .daemons: LaunchdItem.Scope.daemon.title
            case .extensions: "App extensions"
            }
        }

        var description: String {
            switch self {
            case .loginItems: "Apps you or they added to System Settings' Open at Login list."
            case .background: "Helpers, agents and background refresh that apps registered; System Settings lists them under Allow in the Background by app."
            case .userAgents: "Jobs in your Library/LaunchAgents: run as you when you log in, usually installed by apps you use."
            case .globalAgents: "Jobs in /Library/LaunchAgents: run for whoever logs in, installed with an administrator password."
            case .daemons: "Jobs in /Library/LaunchDaemons: run as root from boot, logged in or not."
            case .extensions: "Spotlight importers, Quick Look and other extensions, Dock tile plug-ins: run when macOS needs them, not at startup."
            }
        }
    }

    enum State: Equatable, Sendable {
        case running(pid: Int32)
        case idle(lastExitStatus: Int32?)
        case notLoaded
        case disabled
        /// An empty plist.
        case placeholder
        /// A login item with its System Settings toggle on or off.
        case enabled, off
        /// A plist Tattle could not read: launchd may still run the job.
        case unreadable(reason: String)
        /// A folder Tattle could not list: launchd may still run the jobs in it.
        case unlisted(reason: String)

        var text: String {
            switch self {
            case .running(let pid): "running, pid \(pid)"
            case .idle(let status?) where status != 0: "not running, last exit \(status)"
            case .idle: "not running"
            case .notLoaded: "not loaded"
            case .disabled: "disabled"
            case .placeholder: "empty file, nothing runs"
            case .enabled: "on"
            case .off: "off"
            case .unreadable: "could not be read"
            case .unlisted: "could not be listed"
            }
        }

        var isActive: Bool {
            switch self {
            case .running, .enabled: true
            default: false
            }
        }
    }

    var id: String
    var group: Group
    var name: String
    /// What runs: the program, or the app.
    var program: String?
    var arguments: [String] = []
    /// When it runs; nil when nothing says.
    var trigger: String?
    var state: State
    var signature: CodeSignature?
    /// What says which version of the code its command line reaches this is.
    var codeVersion: LaunchedVersion = .unknown
    var developer: String?
    var teamIdentifier: String?
    /// The app this item belongs to, for helpers and registered agents.
    var parent: String?
    var plistURL: URL?
    /// Managed in System Settings, Login Items.
    var isLoginItem: Bool
    var launchdScope: LaunchdItem.Scope?
    /// Where Load and Unload act.
    var launchDomain = LaunchDomain.gui

    var runs: String? { program.map { ([$0] + arguments).joined(separator: " ") } }

    /// The knowledge-base key: the launchd label, or the bundle id for an app.
    var explainKey: String { id }

    /// Tattle's own daemon, the one system job Tattle removes (ADR-0003). An agent that
    /// carries its label is someone else's job.
    var isCaptureBroker: Bool { id == CaptureBroker.label && launchdScope == .daemon }

    var isUnlistedFolder: Bool {
        if case .unlisted = state { return true }
        return false
    }

    /// Of a file Tattle could not read it knows only the name, unless macOS's record says
    /// what runs: otherwise there is nothing to ask a model.
    var canExplain: Bool {
        switch state {
        case .unreadable: program != nil
        case .unlisted: false
        default: true
        }
    }

    /// What tells this item's code from another's of its label (`CodeIdentity`): its
    /// publisher's signature, else its command line. `signature` is of the code the line
    /// reaches, and `program` its first word, which can be a wrapper: only a team says whose
    /// code it is whichever file that is. Nil when the line does not say where its code is.
    var identity: CodeIdentity? {
        if signature?.teamIdentifier != nil, let published = CodeIdentity.of(signature, path: program) { return published }
        guard let runs else { return nil }
        switch codeVersion {
        case .line: return CodeIdentity.command(runs)
        case .file(let file): return CodeIdentity.command(runs, codeHash: signature?.codeHash, file: file)
        case .unknown: return nil
        }
    }

    /// The app's sentence that opens "Why it is probably here": when it runs, or what keeps it
    /// from running, and the app it belongs to. In the past tense once it is gone.
    func whyHere(gone: Bool) -> String {
        let (be, does) = gone ? ("was", "did") : ("is", "does")
        let when = switch state {
        case .disabled: "It \(be) disabled, so macOS \(does) not start it."
        case .off: "It \(be) switched off in System Settings, so it \(does) not run."
        case .placeholder: "Its file \(be) empty, so nothing \(gone ? "ran" : "runs")."
        case .unreadable, .unlisted: "Tattle could not read its file, so when it runs is not known."
        default: trigger.map { "It \(gone ? "ran" : "runs") \($0)." } ?? "Nothing says when it runs."
        }
        guard let parent else { return when }
        return when + " It \(gone ? "belonged" : "belongs") to \(parent)."
    }

    /// Deterministic facts sent with an explain request and shown in the detail view.
    var facts: [Fact] {
        var facts: [Fact] = []
        if let program, let runs {
            // Arguments can carry tokens, addresses and paths: the model gets only their count.
            let count = arguments.count == 1 ? "1 argument" : "\(arguments.count) arguments"
            facts.append(Fact(name: "Runs", value: runs, promptValue: arguments.isEmpty ? nil : "\(program) (\(count), not sent)"))
        }
        facts.append(Fact(name: "When", value: trigger ?? "unknown"))
        facts.append(Fact(name: "State", value: state.text))
        switch state {
        case .unreadable(let reason), .unlisted(let reason): facts.append(Fact(name: "Reason", value: reason))
        default: break
        }
        if let signature {
            facts.append(.signedBy(signature))
            if case .launchItem(let program?) = signature.signer { facts.append(Fact(name: "Runs Apple's", value: program)) }
            if let team = signature.teamIdentifier ?? teamIdentifier { facts.append(Fact(name: "Team", value: team)) }
        } else if let teamIdentifier {
            facts.append(Fact(name: "Team", value: teamIdentifier))
        }
        if let developer { facts.append(Fact(name: "Developer", value: developer)) }
        if let parent { facts.append(Fact(name: "Part of", value: parent)) }
        if let plistURL { facts.append(Fact(name: isUnlistedFolder ? "Folder" : "Plist", value: plistURL.path)) }
        return facts
    }
}

/// Everything the tab shows at one moment.
struct StartupSnapshot: Equatable, Sendable {
    var items: [StartupItem]
    var appleCount: Int
    var loginItemsError: String?
    /// The error is one that granting Full Disk Access would cure.
    var loginItemsNeedFullDiskAccess = false

    func items(in group: StartupItem.Group) -> [StartupItem] {
        items.filter { $0.group == group }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Joins the sources. `signature` is called for each executable path; the observer
    /// passes a cached reader, tests pass a table.
    static func build(
        launchd: LaunchdReader.Result, loginItems: [LoginItem], state: LaunchctlState,
        signature: (String) -> CodeSignature?
    ) -> StartupSnapshot {
        let byIdentifier = Dictionary(loginItems.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
        let byPlistPath = Dictionary(
            loginItems.compactMap { item -> (String, LoginItem)? in
                guard item.legacy, let url = item.url.flatMap(URL.init(string:)), url.isFileURL else { return nil }
                return (url.path, item)
            }, uniquingKeysWith: { a, _ in a })

        var items: [StartupItem] = []
        var joined = Set<String>()

        for job in launchd.items {
            let registered = byPlistPath[job.plistURL.path]
            if let registered { joined.insert(registered.identifier) }
            let started = job.program.map {
                CodeSignature.started(program: $0, arguments: job.arguments, environmentPath: job.environmentPath,
                                      changesRoot: job.rootDirectory != nil, reading: signature)
            }
            items.append(StartupItem(
                id: job.label,
                group: group(for: job.scope),
                name: registered?.name ?? job.label,
                program: job.program,
                arguments: job.arguments,
                trigger: job.isPlaceholder ? "never" : job.triggers.map { $0.description(scope: job.scope) }.joined(separator: ", "),
                state: launchdState(job, state: state),
                signature: started?.signature,
                codeVersion: started?.version ?? .unknown,
                developer: registered?.developerName,
                teamIdentifier: registered?.teamIdentifier,
                parent: nil,
                plistURL: job.plistURL,
                isLoginItem: registered != nil,
                launchdScope: job.scope,
                launchDomain: job.domains.first { state[$0].services[job.label] != nil } ?? job.domains[0]))
        }

        for plist in launchd.unreadable {
            // With Full Disk Access macOS has a record of the plist, which knows what runs.
            let registered = byPlistPath[plist.url.path]
            if let registered { joined.insert(registered.identifier) }
            let path = registered?.executablePath.flatMap { $0.hasPrefix("/") ? $0 : nil }
            let signed = registered.flatMap { item in path.flatMap { registeredSignature(of: item, at: $0, reading: signature) } }
            items.append(StartupItem(
                id: registered?.jobLabel ?? plist.url.path,
                group: group(for: plist.scope),
                name: registered?.name ?? plist.url.deletingPathExtension().lastPathComponent,
                program: path,
                trigger: nil,
                state: plist.isFolder ? .unlisted(reason: plist.reason) : .unreadable(reason: plist.reason),
                signature: signed,
                codeVersion: path.map { .of(program: $0, signature: signed) } ?? .unknown,
                developer: registered?.developerName,
                teamIdentifier: registered?.teamIdentifier,
                plistURL: plist.url,
                isLoginItem: registered != nil,
                launchdScope: plist.isFolder ? nil : plist.scope))
        }

        for item in loginItems where (item.isStartupItem || item.isExtension) && !joined.contains(item.identifier) {
            // An app record without the enabled bit is only the container for its helpers
            // and extensions; System Settings does not list it under Open at Login.
            if item.kind == .app && !item.enabled { continue }
            let container = item.container.flatMap { byIdentifier[$0] }
            let path = executablePath(of: item, container: container)
            let plist = item.url.flatMap(URL.init(string:)).flatMap { $0.isFileURL && $0.pathExtension == "plist" ? $0 : nil }
            let signed = path.flatMap { registeredSignature(of: item, at: $0, reading: signature) }
            items.append(StartupItem(
                id: item.jobLabel ?? item.identifier,
                group: item.isExtension ? .extensions : item.kind == .app ? .loginItems : .background,
                name: item.name,
                program: path,
                trigger: trigger(for: item),
                state: loginItemState(item, state: state),
                signature: signed,
                codeVersion: path.map { .of(program: $0, signature: signed) } ?? .unknown,
                developer: item.developerName ?? container?.developerName,
                teamIdentifier: item.teamIdentifier,
                parent: container.map { $0.name } ?? item.container,
                plistURL: plist,
                isLoginItem: true,
                launchdScope: nil))
        }

        return StartupSnapshot(items: items, appleCount: launchd.appleCount)
    }

    private static func group(for scope: LaunchdItem.Scope) -> StartupItem.Group {
        switch scope {
        case .userAgent: .userAgents
        case .globalAgent: .globalAgents
        case .daemon: .daemons
        }
    }

    private static func launchdState(_ job: LaunchdItem, state: LaunchctlState) -> StartupItem.State {
        if job.isPlaceholder { return .placeholder }
        let domains = job.domains.map { state[$0] }
        // A loaded job runs whatever the plist says, and a disable only stops the next load.
        if let service = domains.lazy.compactMap({ $0.services[job.label] }).first {
            if let pid = service.pid { return .running(pid: pid) }
            return .idle(lastExitStatus: service.lastExitStatus)
        }
        return domains.lazy.compactMap({ $0.overrides[job.label] }).first ?? job.disabled ? .disabled : .notLoaded
    }

    private static func loginItemState(_ item: LoginItem, state: LaunchctlState) -> StartupItem.State {
        if let label = item.bundleIdentifier, let service = state[item.kind == .daemon ? .system : .gui].services[label], let pid = service.pid {
            return .running(pid: pid)
        }
        return item.allowed ? .enabled : .off
    }

    private static func trigger(for item: LoginItem) -> String? {
        switch item.kind {
        case .app, .loginItemHelper: "at login"
        case .agent: "at login, by its app"
        case .daemon: "at boot, by its app"
        case .backgroundRefresh: "in the background"
        case .spotlightImporter: "when Spotlight indexes its files"
        case .dockTilePlugin: "while its app is in the Dock"
        case .appExtension: "when macOS needs it"
        case .other: nil
        }
    }

    /// How a registered item reads: one among Apple's developer tools as unnamed code, and a
    /// launch agent or daemon as any launch item does.
    private static func registeredSignature(
        of item: LoginItem, at path: String, reading signature: (String) -> CodeSignature?
    ) -> CodeSignature? {
        let signed = signature(path)
        let realPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if LaunchedCode.Identity(path: path, signature: signed, realPath: realPath).isDeveloperTool { return CodeSignature(signer: .unnamed) }
        return item.isLaunchItem ? CodeSignature.launchItem(running: path, signature: signed) : signed
    }

    /// The app bundle for an app, or the helper's path inside its container.
    private static func executablePath(of item: LoginItem, container: LoginItem?) -> String? {
        if let path = item.executablePath, path.hasPrefix("/") { return path }
        guard let url = item.url else { return nil }
        if let absolute = URL(string: url), absolute.isFileURL { return absolute.path }
        if let base = container?.url.flatMap(URL.init(string:)), base.isFileURL {
            return base.appending(path: item.executablePath ?? url).path
        }
        return nil
    }
}
