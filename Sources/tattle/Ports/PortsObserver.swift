import Foundation
import Observation

/// Reads the socket table on demand and keeps names and signatures cached.
@MainActor @Observable
final class PortsObserver {
    private(set) var snapshot: PortsSnapshot?
    private(set) var error: String?
    private let signatures = SignatureCache()
    private var services: ServiceNames?

    func refresh(priority: TaskPriority = .userInitiated) async {
        let signatures = signatures
        let services = self.services ?? ServiceNames.load()
        self.services = services
        let result = await Task.detached(priority: priority) { () -> Result<PortsSnapshot, Error> in
            do {
                let entries = try SocketTable.read()
                // Listed without their signatures: each listener's is read when it is named.
                let byPid = Dictionary(try ProcessTable.list(signature: { _, _ in nil }).map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
                return .success(PortsSnapshot.build(
                    entries: entries, services: services,
                    processes: { byPid[$0] }, executable: signatures.signature(of:at:)))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let snapshot):
            self.snapshot = snapshot
            error = nil
        case .failure(let failure):
            error = String(describing: failure)
            Log.app.error("ports snapshot failed: \(failure, privacy: .public)")
        }
    }
}
