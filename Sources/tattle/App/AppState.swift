import Foundation
import Observation

/// Everything that lives for the whole run: the database and what is built on it.
@MainActor @Observable
final class AppState {
    let sampler = ResourceSampler()
    let startup = StartupObserver()
    let ports = PortsObserver()
    let processes = ProcessesObserver()
    let network: NetworkObserver
    let settings: AppSettings
    let rules: RuleStore
    let connections: ConnectionStore
    let explainer: Explainer

    /// Whether the panel is on screen. MenuBarExtra keeps the panel's views alive when it
    /// closes, so what they do while open follows this rather than their lifetime. True
    /// until the first close: nothing reads it before the panel first opens.
    var panelIsShowing = true {
        didSet {
            guard !panelIsShowing else { return }
            heldSample = sampler.sample
            heldNetworkSnapshot = network.snapshot
        }
    }
    @ObservationIgnored private var heldSample = ResourceSample.zero
    @ObservationIgnored private var heldNetworkSnapshot: NetworkSnapshot?

    /// The sampler and the network readings keep running with the panel closed, for the menu
    /// bar label and the history. The panel reads them through these, which do not touch the
    /// sources while it is closed, so a new reading leaves its views nothing to update for.
    var panelSample: ResourceSample { panelIsShowing ? sampler.sample : heldSample }
    var panelNetworkSnapshot: NetworkSnapshot? { panelIsShowing ? network.snapshot : heldNetworkSnapshot }

    /// Reads Processes, Startup and Ports once, at launch. A list's first reading reads the
    /// signature of every program it names, which takes seconds to tens of seconds; each
    /// later one finds them kept. Made here, in the background, the panel opens on a list
    /// and not on a wait. Processes does not wait for its signatures either: they go on being
    /// read after this returns (`ProcessesObserver`). What it leaves is as old as the launch,
    /// and is replaced by the reading each list makes when it comes on screen.
    func readListsAtLaunch() async {
        let start = ContinuousClock.now
        await processes.refresh(priority: .utility)
        await startup.refresh(priority: .utility)
        await ports.refresh(priority: .utility)
        Log.app.info("lists first read in \(String(describing: ContinuousClock.now - start), privacy: .public)")
    }

    init(database: AppDatabase, socketTable: @escaping @Sendable () throws -> [SocketEntry] = { try SocketTable.read() }) throws {
        rules = try RuleStore(database: database)
        connections = ConnectionStore(database: database)
        settings = try AppSettings(store: SettingsStore(database: database))
        explainer = Explainer(store: rules, settings: settings)
        network = NetworkObserver(store: connections, rules: rules, settings: settings, socketTable: socketTable)
        if let resources = Bundle.main.resourceURL {
            SeedLoader(rules: rules).load(from: resources.appending(path: "knowledge"))
        }
        let pruned = try rules.pruneExpired()
        if pruned > 0 {
            Log.app.info("pruned \(pruned) expired unconfirmed LLM rules")
        }
    }
}
