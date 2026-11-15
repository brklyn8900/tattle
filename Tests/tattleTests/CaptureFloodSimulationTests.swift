import Darwin
import Foundation
import os
import XCTest
@testable import tattle

/// What a flood of new flows costs behind the namer, which a cap on what the Network observer
/// holds is judged by. A stand-in capture delivers new TCP flows at a fixed rate, each a SYN
/// and a ClientHello with a server name of its own to an address of its own, so every flow
/// reports an opening and a name no other has; the socket table is empty, as it is for flows
/// that are forged or gone before a reading. Once a second it prints the flows delivered, the
/// flow events dropped on the way to the main actor (two a flow), the outcomes, openings and kinds the observer holds, the process's memory footprint, how long
/// a block queued on the main thread waited to run and how late a timer on its run loop
/// fired; after the flood, how long the main thread took to catch up. It asserts nothing: the numbers depend on the machine and its
/// load. Runs only when `TATTLE_FLOOD_RATE` gives the flows per second; `TATTLE_FLOOD_SECONDS`
/// sets how long (30) and `TATTLE_FLOOD_LABEL` the printed label.
final class CaptureFloodSimulationTests: XCTestCase {
    private static let me: [UInt8] = [192, 168, 1, 5]

    /// A raw-IP capture that hands over, at each read, the flows due by the clock.
    private final class Flood: CaptureSource, @unchecked Sendable {
        let dataLinkType = PacketCapture.linkRaw
        private let rate: Double
        private let total: Int
        private let started = Date()
        private let sent = OSAllocatedUnfairLock(initialState: 0)
        private let ended = OSAllocatedUnfairLock<Date?>(initialState: nil)

        init(rate: Double, seconds: Double) {
            self.rate = rate
            total = Int(rate * seconds)
        }

        var delivered: Int { sent.withLock { $0 } }
        /// When the last flow was delivered.
        var finished: Date? { ended.withLock { $0 } }

        func install(_ filter: CaptureFilter) throws {}

        func readPackets(_ handle: (Double, [UInt8]) -> Void) throws {
            let due = min(Int(Date().timeIntervalSince(started) * rate), total)
            let now = Date().timeIntervalSince1970
            for flow in delivered..<max(delivered, due) {
                handle(now, CaptureFloodSimulationTests.segment(of: flow, flags: 0x02, seq: 1, payload: []))
                handle(now, CaptureFloodSimulationTests.segment(of: flow, flags: 0x18, seq: 2, payload: CaptureFloodSimulationTests.hello(flow)))
            }
            sent.withLock { $0 = max($0, due) }
            if due == total { ended.withLock { $0 = $0 ?? Date() } }
            usleep(10_000)
        }
    }

    private static func hello(_ flow: Int) -> [UInt8] {
        let hello = SnifferParserTests.clientHello(sni: Array("h\(flow).flood.example".utf8))
        return [0x16, 0x03, 0x01, UInt8(hello.count >> 8), UInt8(hello.count & 0xff)] + hello
    }

    /// A TCP segment of flow number `flow`, whose local port and remote address are its own.
    private static func segment(of flow: Int, flags: UInt8, seq: UInt32, payload: [UInt8]) -> [UInt8] {
        let port = UInt16(1024 + flow % 60000)
        let remote: [UInt8] = [11, UInt8(flow >> 16 & 0xff), UInt8(flow >> 8 & 0xff), UInt8(flow & 0xff)]
        let total = 40 + payload.count
        return [0x45, 0, UInt8(total >> 8), UInt8(total & 0xff), 0, 0, 0, 0, 64, 6, 0, 0] + me + remote
            + [UInt8(port >> 8), UInt8(port & 0xff), 0x01, 0xbb, 0, 0, 0, UInt8(seq), 0, 0, 0, 0, 0x50, flags, 0xff, 0xff, 0, 0, 0, 0]
            + payload
    }

    private static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// How long the main thread keeps others waiting, two ways. A block queued on it once a
    /// second from another thread waits behind the main actor's work, which queues there too,
    /// in order. A 100 ms timer on its run loop fires late by as long as the run loop was kept
    /// from its sources, which is what the panel's events wait behind.
    private final class MainThreadLag: @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (last: 0.0, waiting: 0, late: 0.0, fired: Date(), stopped: false))
        private static let interval = 0.1

        @MainActor
        func start() {
            let timer = Timer(timeInterval: Self.interval, repeats: true) { [self] timer in
                let now = Date()
                let stopped = state.withLock { state -> Bool in
                    state.late = max(state.late, now.timeIntervalSince(state.fired) - Self.interval)
                    state.fired = now
                    return state.stopped
                }
                if stopped { timer.invalidate() }
            }
            RunLoop.main.add(timer, forMode: .common)
            Thread { [self] in
                while !state.withLock({ $0.stopped }) {
                    let queued = Date()
                    state.withLock { $0.waiting += 1 }
                    DispatchQueue.main.async { [self] in
                        state.withLock { $0.last = Date().timeIntervalSince(queued); $0.waiting -= 1 }
                    }
                    Thread.sleep(forTimeInterval: 1)
                }
            }.start()
        }

        func stop() { state.withLock { $0.stopped = true } }

        /// The wait of the last block that ran, how many still wait, and the latest the timer
        /// has fired since the last reading.
        func reading() -> (last: Double, waiting: Int, late: Double) {
            state.withLock { state in
                defer { state.late = 0 }
                return (state.last, state.waiting, state.late)
            }
        }
    }

    @MainActor
    func testWhatAFloodOfNewFlowsCosts() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rate = Double(environment["TATTLE_FLOOD_RATE"] ?? "") else {
            throw XCTSkip("set TATTLE_FLOOD_RATE to the new flows per second")
        }
        let seconds = Double(environment["TATTLE_FLOOD_SECONDS"] ?? "") ?? 30
        let label = environment["TATTLE_FLOOD_LABEL"] ?? "this build"

        // On disk with the write-ahead log, as the app's is.
        let folder = FileManager.default.temporaryDirectory.appending(path: "tattle-flood-\(getpid())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try AppDatabase(at: folder.appending(path: "tattle.sqlite"))

        let flood = Flood(rate: rate, seconds: seconds)
        let me = IPAddress(bytes: Self.me)
        let observer = NetworkObserver(
            store: ConnectionStore(database: database), rules: try RuleStore(database: database),
            settings: try AppSettings(store: SettingsStore(database: database)),
            socketTable: { [] }, processRecords: { nil },
            sniffer: { onEvents, onStatus in
                Sniffer(open: { _ in flood },
                        host: Sniffer.Host(primaryInterface: { "en0" }, hardwareAddress: { _ in nil }, addresses: { _ in [me] }, resolvers: { [] }),
                        onEvents: onEvents, onStatus: onStatus)
            })
        let lag = MainThreadLag()
        let began = Date()
        @discardableResult
        func line(_ phase: String) -> (last: Double, waiting: Int) {
            let held = observer.held
            let wait = lag.reading()
            print(String(format: "FLOOD %@ %@ t=%.0fs delivered=%d dropped=%d outcomes=%d openings=%d kinds=%d footprint=%.0fMB lag=%.0fms waiting=%d timer=%.0fms",
                         label, phase, Date().timeIntervalSince(began), flood.delivered, observer.eventsDropped, held.outcomes, held.openings, held.kinds,
                         Self.footprint(), wait.last * 1000, wait.waiting, wait.late * 1000))
            return (wait.last, wait.waiting)
        }
        line("start")
        observer.start()
        lag.start()
        defer {
            lag.stop()
            observer.stop()
        }
        // Caught up: a block queued on the main thread after the last flow ran, and at once.
        // The lines stop while the main thread is held, so a gap in `t` is its length.
        var caughtUp: Double?
        while caughtUp == nil, flood.finished.map({ Date().timeIntervalSince($0) < 600 }) ?? true {
            try await Task.sleep(for: .seconds(1))
            let wait = line(flood.finished == nil ? "flood" : "after")
            if let finished = flood.finished, Date().timeIntervalSince(finished) > 1, wait.waiting == 0, wait.last < 0.05 {
                caughtUp = Date().timeIntervalSince(finished)
            }
        }
        print(String(format: "FLOOD %@ done: %.0f flows/s for %.0f s, main thread caught up %@ after the last flow", label, rate, seconds,
                     caughtUp.map { String(format: "%.0f s", $0) } ?? "not within 600 s"))
    }
}
