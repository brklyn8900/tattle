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

    init(database: AppDatabase) throws {
        rules = RuleStore(database: database)
        connections = ConnectionStore(database: database)
        settings = try AppSettings(store: SettingsStore(database: database))
        explainer = Explainer(store: rules, settings: settings)
        network = NetworkObserver(store: connections, settings: settings)
        if let resources = Bundle.main.resourceURL {
            SeedLoader(rules: rules, settings: SettingsStore(database: database))
                .load(from: resources.appending(path: "knowledge"))
        }
        let pruned = try rules.pruneExpired()
        if pruned > 0 {
            Log.app.info("pruned \(pruned) expired unconfirmed LLM rules")
        }
    }
}
