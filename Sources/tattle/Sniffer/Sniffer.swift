import Foundation
import os

/// Reads packets from the default route's interface on its own thread and reports flow
/// events. Follows the interface when the default route moves; retries when the device
/// cannot be opened, which is the state until the broker (ADR-0003) exists.
final class Sniffer: @unchecked Sendable {
    enum Status: Equatable, Sendable {
        case stopped
        case capturing(interface: String)
        case unavailable(CaptureError)
    }

    /// How the capture is obtained for an interface: the device directly for now, the
    /// broker's descriptor later.
    typealias Opener = @Sendable (String) throws -> any CaptureSource

    /// What the loop reads about the machine's interfaces; tests change it underneath.
    struct Host: Sendable {
        var primaryInterface: @Sendable () -> String? = { PacketCapture.primaryInterface() }
        var hardwareAddress: @Sendable (String) -> [UInt8]? = { PacketCapture.hardwareAddress(of: $0) }
        /// Every address, or one interface's.
        var addresses: @Sendable (String?) -> Set<IPAddress> = { localAddresses(of: $0) }
        var interfaceCheckEvery: TimeInterval = 5
    }

    private let open: Opener
    private let host: Host
    private let onEvents: @Sendable ([FlowEvent]) -> Void
    private let onStatus: @Sendable (Status) -> Void
    /// The current run's stop flag and the signal that it has ended. Each run has its own,
    /// so a start right after a stop cannot clear the flag the old run is still to read.
    private var current: (stopping: OSAllocatedUnfairLock<Bool>, ended: DispatchSemaphore)?

    private static let retryAfter: TimeInterval = 30
    private static let addressRefreshEvery: TimeInterval = 60
    /// How often a packet from an unknown address may trigger a refresh.
    private static let staleRefreshEvery: TimeInterval = 1
    private static let readTimeout: Duration = .milliseconds(500)
    /// Longer than a read timeout or a wait step; a run still going after it is left to end
    /// on its own, under its own stop flag.
    private static let stopWait = 2.0

    init(open: @escaping Opener = { try PacketCapture.obtain(interface: $0, timeout: Sniffer.readTimeout) },
         host: Host = Host(),
         onEvents: @escaping @Sendable ([FlowEvent]) -> Void,
         onStatus: @escaping @Sendable (Status) -> Void) {
        self.open = open
        self.host = host
        self.onEvents = onEvents
        self.onStatus = onStatus
    }

    func start() {
        guard current == nil else { return }
        let stopping = OSAllocatedUnfairLock(initialState: false)
        let ended = DispatchSemaphore(value: 0)
        current = (stopping, ended)
        let thread = Thread { [self] in
            run { stopping.withLock { $0 } }
            ended.signal()
        }
        thread.name = "tattle.sniffer"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Waits for the run to end, which it does within one read timeout, so its capture
    /// device is closed and its last status reported before another run can start.
    func stop() {
        guard let run = current else { return }
        current = nil
        run.stopping.withLock { $0 = true }
        if run.ended.wait(timeout: .now() + Self.stopWait) == .timedOut {
            Log.sniffer.error("the previous capture run did not end within \(Self.stopWait) s")
        }
    }

    private func run(shouldStop: () -> Bool) {
        var lastFailure: CaptureError?
        while !shouldStop() {
            guard let interface = host.primaryInterface() else {
                report(.unavailable(.noInterface), previous: &lastFailure)
                wait(Self.retryAfter, shouldStop: shouldStop)
                continue
            }
            let capture: any CaptureSource
            do {
                capture = try open(interface)
            } catch let error as CaptureError {
                report(.unavailable(error), previous: &lastFailure)
                wait(Self.retryAfter, shouldStop: shouldStop)
                continue
            } catch {
                report(.unavailable(.open(errno: EIO)), previous: &lastFailure)
                wait(Self.retryAfter, shouldStop: shouldStop)
                continue
            }
            lastFailure = nil
            let direction = direction(for: capture, interface: interface)
            installFilter(on: capture, direction: direction, interface: interface)
            onStatus(.capturing(interface: interface))
            // Notice, not info: the unified log keeps notices, so a later comparison can
            // tell when capture was on.
            Log.sniffer.notice("capturing on \(interface, privacy: .public), link type \(capture.dataLinkType), \(CaptureBroker.isReachable ? "through the broker" : "from the device", privacy: .public)")
            captureLoop(capture, interface: interface, direction: direction, shouldStop: shouldStop)
        }
        onStatus(.stopped)
    }

    /// Reports a failure once, not every retry.
    private func report(_ status: Status, previous: inout CaptureError?) {
        guard case .unavailable(let error) = status else { return }
        if error != previous {
            Log.sniffer.notice("packet capture unavailable: \(error.text, privacy: .public)")
            onStatus(status)
        }
        previous = error
    }

    /// How the kernel filter tells this interface's outbound packets, as the interface is now.
    private func direction(for capture: any CaptureSource, interface: String) -> CaptureFilter.Direction {
        if capture.dataLinkType == PacketCapture.linkEthernet, let mac = host.hardwareAddress(interface) {
            return .hardwareAddress(mac)
        }
        // Only this interface's: every address costs instructions, and a packet captured
        // here leaves from one of them. Sorted, so an unchanged set compares equal.
        return .sourceAddresses(host.addresses(interface).map(\.bytes).sorted { $0.lexicographicallyPrecedes($1) })
    }

    private func installFilter(on capture: any CaptureSource, direction: CaptureFilter.Direction, interface: String) {
        guard let filter = CaptureFilter.program(linkType: capture.dataLinkType, direction: direction) else {
            Log.sniffer.notice("no kernel filter for link type \(capture.dataLinkType) on \(interface, privacy: .public); copying every packet")
            return
        }
        do {
            try capture.install(filter)
        } catch {
            Log.sniffer.error("kernel filter rejected, copying every packet: \(String(describing: error), privacy: .public)")
        }
    }

    /// Reads until the interface changes, the device fails, or stop is called.
    private func captureLoop(_ capture: any CaptureSource, interface: String, direction installed: CaptureFilter.Direction, shouldStop: () -> Bool) {
        var installed = installed
        var namer = FlowNamer(localAddresses: host.addresses(nil))
        var lastInterfaceCheck = Date()
        var lastAddressRefresh = Date()
        while !shouldStop() {
            var events: [FlowEvent] = []
            do {
                try capture.readPackets { timestamp, bytes in
                    guard let packet = Packet.parse(bytes, dlt: capture.dataLinkType) else { return }
                    // A packet between two addresses that are not ours means ours changed:
                    // refresh now rather than at the next timer, or every flow until then
                    // goes unnamed.
                    if namer.endpointsUnknown(packet), Date().timeIntervalSince(lastAddressRefresh) >= Self.staleRefreshEvery {
                        namer.updateLocalAddresses(host.addresses(nil))
                        lastAddressRefresh = Date()
                        Log.sniffer.debug("refreshed local addresses on an unknown packet")
                    }
                    events += namer.observe(packet, at: timestamp)
                }
            } catch {
                Log.sniffer.error("packet read failed, reopening: \(String(describing: error), privacy: .public)")
                return
            }
            let now = Date()
            events += namer.expire(now: now.timeIntervalSince1970)
            if !events.isEmpty { onEvents(events) }
            if now.timeIntervalSince(lastAddressRefresh) >= Self.addressRefreshEvery {
                namer.updateLocalAddresses(host.addresses(nil))
                lastAddressRefresh = now
            }
            if now.timeIntervalSince(lastInterfaceCheck) >= host.interfaceCheckEvery {
                lastInterfaceCheck = now
                if let current = host.primaryInterface(), current != interface {
                    Log.sniffer.info("default route moved to \(current, privacy: .public); reopening")
                    return
                }
                // A rotated private Wi-Fi address or a renumbered tunnel would make the
                // filter class every outbound packet as inbound and drop it.
                let direction = direction(for: capture, interface: interface)
                if direction != installed {
                    Log.sniffer.notice("\(interface, privacy: .public) changed its addresses; rebuilding the kernel filter")
                    installFilter(on: capture, direction: direction, interface: interface)
                    installed = direction
                }
            }
        }
    }

    private func wait(_ seconds: TimeInterval, shouldStop: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !shouldStop(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}
