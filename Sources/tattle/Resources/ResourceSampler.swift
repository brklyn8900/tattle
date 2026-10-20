import Foundation
import Observation

/// What the resources line and the menu bar label show.
struct ResourceSample: Equatable, Sendable {
    /// Share of all cores busy, 0 to 1.
    var cpu: Double
    var memory: MemoryUsage
    var bytesInPerSecond: Double
    var bytesOutPerSecond: Double

    static let zero = ResourceSample(
        cpu: 0, memory: MemoryUsage(used: 0, total: 0), bytesInPerSecond: 0, bytesOutPerSecond: 0)

    /// Rates over the interval between two snapshots; memory is the later reading.
    static func between(_ earlier: SystemSnapshot, _ later: SystemSnapshot) -> ResourceSample {
        let seconds = max(later.time.timeIntervalSince(earlier.time), 0.001)
        let ticks = later.cpu.total &- earlier.cpu.total
        let busy = later.cpu.busy &- earlier.cpu.busy
        let cpu = ticks == 0 ? 0 : min(max(Double(busy) / Double(ticks), 0), 1)
        let net = later.network.delta(from: earlier.network)
        return ResourceSample(
            cpu: cpu, memory: later.memory,
            bytesInPerSecond: Double(net.bytesIn) / seconds,
            bytesOutPerSecond: Double(net.bytesOut) / seconds)
    }
}

/// Reads the kernel counters once a second and publishes the latest sample.
@MainActor @Observable
final class ResourceSampler {
    private(set) var sample = ResourceSample.zero
    private var previous: SystemSnapshot?
    private var task: Task<Void, Never>?

    func start(every interval: Duration = .seconds(1)) {
        guard task == nil else { return }
        previous = SystemSnapshot.read()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                self?.tick()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func tick() {
        guard let current = SystemSnapshot.read() else { return }
        if let previous {
            sample = ResourceSample.between(previous, current)
        }
        previous = current
    }
}
