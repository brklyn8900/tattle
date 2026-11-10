import Darwin
import Foundation
import XCTest
@testable import tattle

/// How often the Network tab loses the owner of a connection whose process exits within
/// milliseconds, which a change to its reading is judged by (`network-names.md` in the
/// verify-tattle skill). A helper (`Tests/quick-exit-helper.c`) connects to a loopback listener
/// and exits a set time later. The accept stands in for the sniffer seeing the opening, and one
/// reading is taken the prompt poll's delay after it, with the helper's socket made to look like a
/// connection on the local network. Prints, for each lifetime, how many of the helper's rows read
/// `pid <n>`, were named, or were missing; it asserts nothing about them, since the count depends
/// on the machine and its load. Runs only when `TATTLE_SIM_HELPER` names the built helper;
/// `TATTLE_SIM_RUNS` sets the runs per lifetime (20) and `TATTLE_SIM_LABEL` the printed label.
final class QuickExitSimulationTests: XCTestCase {
    @MainActor
    func testOwnersOfProcessesThatExitQuickly() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let helper = environment["TATTLE_SIM_HELPER"] else {
            throw XCTSkip("set TATTLE_SIM_HELPER to the helper built from Tests/quick-exit-helper.c")
        }
        let runs = Int(environment["TATTLE_SIM_RUNS"] ?? "") ?? 20
        let label = environment["TATTLE_SIM_LABEL"] ?? "this build"

        let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(listener) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, size) } }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(listener, 64), 0)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(listener, $0, &size) } }
        let port = UInt16(bigEndian: address.sin_port)

        let database = try AppDatabase.inMemory()
        let observer = NetworkObserver(store: ConnectionStore(database: database), rules: RuleStore(database: database),
                                       settings: try AppSettings(store: SettingsStore(database: database)),
                                       socketTable: { Self.onLocalNetwork(try SocketTable.read(), port: port) })
        // The first reading takes every socket as already open; the second settles the rest.
        await observer.poll()
        await observer.poll()
        for lifetime in [26, 29, 32, 35, 38, 42] {
            var exited = 0, named = 0, missing = 0, failed = 0
            for _ in 0..<runs {
                var pid: pid_t = 0
                let argv = [strdup(helper), strdup(String(port)), strdup(String(lifetime)), nil]
                defer { argv.forEach { free($0) } }
                guard posix_spawn(&pid, helper, nil, nil, argv, environ) == 0 else {
                    failed += 1
                    continue
                }
                var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard Darwin.poll(&waiting, 1, 2000) == 1 else {
                    failed += 1
                    waitpid(pid, nil, 0)
                    continue
                }
                let connection = Darwin.accept(listener, nil, nil)
                try await Task.sleep(for: NetworkObserver.promptPollDelay)
                await observer.poll()
                switch observer.snapshot?.connections.first(where: { $0.connection.pid == pid })?.owner.processName {
                case nil: missing += 1
                case "pid \(pid)": exited += 1
                default: named += 1
                }
                Darwin.close(connection)
                var status: Int32 = 0
                waitpid(pid, &status, 0)
                if status != 0 { failed += 1 }
                try await Task.sleep(for: .milliseconds(30))
            }
            print("SIM \(label) lifetime \(lifetime) ms: runs \(runs), pid-N \(exited), named \(named), missing \(missing), helper failures \(failed)")
        }
    }

    /// The helper's end of each loopback connection to `port`, as if both ends were on the local
    /// network, where the tracker takes it as a connection.
    private static func onLocalNetwork(_ entries: [SocketEntry], port: UInt16) -> [SocketEntry] {
        entries.map { entry in
            guard entry.remotePort == port, SocketEntry.isLoopback(entry.remoteAddress) else { return entry }
            var entry = entry
            entry.localAddress = "10.99.0.2"
            entry.remoteAddress = "10.99.0.1"
            return entry
        }
    }
}
