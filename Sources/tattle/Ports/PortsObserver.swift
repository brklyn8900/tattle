import Foundation
import Observation

/// Reads the socket table on demand and keeps names and signatures cached.
@MainActor @Observable
final class PortsObserver {
    private(set) var snapshot: PortsSnapshot?
    private(set) var error: String?
    private let signatures = SignatureCache()
    private var services: ServiceNames?

    func refresh() async {
        let signatures = signatures
        let services = self.services ?? ServiceNames.load()
        self.services = services
        let result = await Task.detached(priority: .userInitiated) { () -> Result<PortsSnapshot, Error> in
            do {
                let entries = try SocketTable.read()
                return .success(PortsSnapshot.build(
                    entries: entries, services: services,
                    identity: ProcessIdentity.read(pid:), signature: signatures.signature(at:)))
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
