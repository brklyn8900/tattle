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
    typealias Opener = @Sendable (String) throws -> PacketCapture

    private let open: Opener
    private let onEvents: @Sendable ([FlowEvent]) -> Void
    private let onStatus: @Sendable (Status) -> Void
    private let stopping = OSAllocatedUnfairLock(initialState: false)
    private var thread: Thread?

    private static let retryAfter: TimeInterval = 30
    private static let interfaceCheckEvery: TimeInterval = 5
    private static let addressRefreshEvery: TimeInterval = 60
    private static let readTimeout: Duration = .milliseconds(500)

    init(open: @escaping Opener = { try PacketCapture.open(interface: $0, timeout: Sniffer.readTimeout) },
         onEvents: @escaping @Sendable ([FlowEvent]) -> Void,
         onStatus: @escaping @Sendable (Status) -> Void) {
        self.open = open
        self.onEvents = onEvents
        self.onStatus = onStatus
    }

    func start() {
        guard thread == nil else { return }
        stopping.withLock { $0 = false }
        let thread = Thread { [self] in run() }
        thread.name = "tattle.sniffer"
        thread.qualityOfService = .utility
        self.thread = thread
        thread.start()
    }

    /// Returns at once; the thread notices within one read timeout.
    func stop() {
        stopping.withLock { $0 = true }
        thread = nil
    }

    private var shouldStop: Bool { stopping.withLock { $0 } }

    private func run() {
        var lastFailure: CaptureError?
        while !shouldStop {
            guard let interface = PacketCapture.primaryInterface() else {
                report(.unavailable(.noInterface), previous: &lastFailure)
                wait(Self.retryAfter)
                continue
            }
            let capture: PacketCapture
            do {
                capture = try open(interface)
            } catch let error as CaptureError {
                report(.unavailable(error), previous: &lastFailure)
                wait(Self.retryAfter)
                continue
            } catch {
                report(.unavailable(.open(errno: EIO)), previous: &lastFailure)
                wait(Self.retryAfter)
                continue
            }
            lastFailure = nil
            installFilter(on: capture, interface: interface)
            onStatus(.capturing(interface: interface))
            Log.sniffer.info("capturing on \(interface, privacy: .public), link type \(capture.dataLinkType)")
            captureLoop(capture, interface: interface)
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

    private func installFilter(on capture: PacketCapture, interface: String) {
        let direction: CaptureFilter.Direction
        if capture.dataLinkType == PacketCapture.linkEthernet, let mac = PacketCapture.hardwareAddress(of: interface) {
            direction = .hardwareAddress(mac)
        } else {
            direction = .sourceAddresses(localAddresses().map(\.bytes))
        }
        guard let filter = CaptureFilter.program(linkType: capture.dataLinkType, direction: direction) else {
            Log.sniffer.notice("no kernel filter for link type \(capture.dataLinkType); copying every packet")
            return
        }
        do {
            try capture.install(filter)
        } catch {
            Log.sniffer.error("kernel filter rejected, copying every packet: \(String(describing: error), privacy: .public)")
        }
    }

    /// Reads until the interface changes, the device fails, or stop is called.
    private func captureLoop(_ capture: PacketCapture, interface: String) {
        var namer = FlowNamer(localAddresses: localAddresses())
        var lastInterfaceCheck = Date()
        var lastAddressRefresh = Date()
        while !shouldStop {
            var events: [FlowEvent] = []
            do {
                try capture.readPackets { timestamp, bytes in
                    if let packet = Packet.parse(bytes, dlt: capture.dataLinkType) {
                        events += namer.observe(packet, at: timestamp)
                    }
                }
            } catch {
                Log.sniffer.error("packet read failed, reopening: \(String(describing: error), privacy: .public)")
                return
            }
            let now = Date()
            events += namer.expire(now: now.timeIntervalSince1970)
            if !events.isEmpty { onEvents(events) }
            if now.timeIntervalSince(lastAddressRefresh) >= Self.addressRefreshEvery {
                namer.updateLocalAddresses(localAddresses())
                lastAddressRefresh = now
            }
            if now.timeIntervalSince(lastInterfaceCheck) >= Self.interfaceCheckEvery {
                lastInterfaceCheck = now
                if let current = PacketCapture.primaryInterface(), current != interface {
                    Log.sniffer.info("default route moved to \(current, privacy: .public); reopening")
                    return
                }
            }
        }
    }

    private func wait(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while !shouldStop, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}
