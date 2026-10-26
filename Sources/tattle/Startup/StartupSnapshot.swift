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
    /// What runs: the program and its arguments, or the app.
    var runs: String?
    var trigger: String
    var state: State
    var signature: CodeSignature?
    var developer: String?
    var teamIdentifier: String?
    /// The app this item belongs to, for helpers and registered agents.
    var parent: String?
    var plistURL: URL?
    /// Managed in System Settings, Login Items.
    var isLoginItem: Bool
    var launchdScope: LaunchdItem.Scope?

    /// The knowledge-base key: the launchd label, or the bundle id for an app.
    var explainKey: String { id }

    /// Deterministic facts sent with an explain request and shown in the detail view.
    var facts: [Fact] {
        var facts: [Fact] = []
        if let runs { facts.append(Fact(name: "Runs", value: runs)) }
        facts.append(Fact(name: "When", value: trigger))
        facts.append(Fact(name: "State", value: state.text))
        if let signature {
            facts.append(.signedBy(signature))
            if let team = signature.teamIdentifier ?? teamIdentifier { facts.append(Fact(name: "Team", value: team)) }
        } else if let teamIdentifier {
            facts.append(Fact(name: "Team", value: teamIdentifier))
        }
        if let developer { facts.append(Fact(name: "Developer", value: developer)) }
        if let parent { facts.append(Fact(name: "Part of", value: parent)) }
        if let plistURL { facts.append(Fact(name: "Plist", value: plistURL.path)) }
        return facts
    }
}

/// Everything the tab shows at one moment.
struct StartupSnapshot: Equatable, Sendable {
    var items: [StartupItem]
    var appleCount: Int
    var skipped: [String: String]
    /// Why the login-items database could not be read, if it could not.
    var loginItemsError: String?
    var takenAt: Date

    func items(in group: StartupItem.Group) -> [StartupItem] {
        items.filter { $0.group == group }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Joins the sources. `signature` is called for each executable path; the observer
    /// passes a cached reader, tests pass a table.
    static func build(
        launchd: LaunchdReader.Result, loginItems: [LoginItem], state: LaunchctlState,
        signature: (String) -> CodeSignature?, takenAt: Date = Date()
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
            let runs = job.program.map { ([$0] + job.arguments).joined(separator: " ") }
            items.append(StartupItem(
                id: job.label,
                group: group(for: job.scope),
                name: registered?.name ?? job.label,
                runs: runs,
                trigger: job.isPlaceholder ? "never" : job.triggers.map { $0.description(scope: job.scope) }.joined(separator: ", "),
                state: launchdState(job, state: state),
                signature: job.program.flatMap { CodeSignature.read(program: $0, arguments: job.arguments, reading: signature) },
                developer: registered?.developerName,
                teamIdentifier: registered?.teamIdentifier,
                parent: nil,
                plistURL: job.plistURL,
                isLoginItem: registered != nil,
                launchdScope: job.scope))
        }

        for item in loginItems where (item.isStartupItem || item.isExtension) && !joined.contains(item.identifier) {
            // An app record without the enabled bit is only the container for its helpers
            // and extensions; System Settings does not list it under Open at Login.
            if item.kind == .app && !item.enabled { continue }
            let container = item.container.flatMap { byIdentifier[$0] }
            let path = executablePath(of: item, container: container)
            let plist = item.url.flatMap(URL.init(string:)).flatMap { $0.isFileURL && $0.pathExtension == "plist" ? $0 : nil }
            items.append(StartupItem(
                id: item.bundleIdentifier ?? item.identifier,
                group: item.isExtension ? .extensions : item.kind == .app ? .loginItems : .background,
                name: item.name,
                runs: path,
                trigger: trigger(for: item),
                state: loginItemState(item, state: state),
                signature: path.flatMap(signature),
                developer: item.developerName ?? container?.developerName,
                teamIdentifier: item.teamIdentifier,
                parent: container.map { $0.name } ?? item.container,
                plistURL: plist,
                isLoginItem: true,
                launchdScope: nil))
        }

        return StartupSnapshot(items: items, appleCount: launchd.appleCount, skipped: launchd.skipped, takenAt: takenAt)
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
        if job.disabled || state.overrides[job.label] == true { return .disabled }
        guard let service = state.services[job.label] else { return .notLoaded }
        if let pid = service.pid { return .running(pid: pid) }
        return .idle(lastExitStatus: service.lastExitStatus)
    }

    private static func loginItemState(_ item: LoginItem, state: LaunchctlState) -> StartupItem.State {
        if let label = item.bundleIdentifier, let service = state.services[label], let pid = service.pid {
            return .running(pid: pid)
        }
        return item.allowed ? .enabled : .off
    }

    private static func trigger(for item: LoginItem) -> String {
        switch item.kind {
        case .app, .loginItemHelper: "at login"
        case .agent: "at login, by its app"
        case .daemon: "at boot, by its app"
        case .backgroundRefresh: "in the background"
        case .spotlightImporter: "when Spotlight indexes its files"
        case .dockTilePlugin: "while its app is in the Dock"
        case .appExtension: "when macOS needs it"
        case .other: "unknown"
        }
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
