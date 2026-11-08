import XCTest
@testable import tattle

/// Every binary here is Apple-signed, as a copy of one of Apple's binaries is.
final class ApplesProgramTests: XCTestCase {
    private let started = Date(timeIntervalSince1970: 1_700_000_000)
    private let appleSigned: (String) -> CodeSignature? = { _ in CodeSignature(signer: .apple) }

    private var machine: [ProcessEntry] {
        [
            ProcessEntry(pid: 0, parentPid: 0, uid: 0, name: "kernel_task", started: started),
            ProcessEntry(pid: 1, parentPid: 0, uid: 0, name: "launchd", path: "/sbin/launchd", started: started),
            ProcessEntry(pid: 70, parentPid: 1, uid: 501, name: "Mail", path: "/System/Applications/Mail.app/Contents/MacOS/Mail", started: started),
            ProcessEntry(pid: 90, parentPid: 1, uid: 65, name: "mDNSResponder", path: "/usr/sbin/mDNSResponder", started: started),
            // cp /usr/sbin/mDNSResponder /tmp
            ProcessEntry(pid: 500, parentPid: 1, uid: 501, name: "mDNSResponder", path: "/private/tmp/mDNSResponder", started: started),
            // exec -a mDNSResponder /bin/bash
            ProcessEntry(pid: 501, parentPid: 1, uid: 501, name: "mDNSResponder", path: "/bin/bash", arguments: ["mDNSResponder"], started: started),
            // /bin/sh ~/mDNSResponder
            ProcessEntry(pid: 502, parentPid: 1, uid: 501, name: "mDNSResponder", path: "/bin/sh", interpreter: "sh", arguments: ["/bin/sh", "/Users/x/mDNSResponder"], started: started),
        ]
    }

    private let impostors: [(pid: Int32, what: String)] = [
        (500, "a copy outside the system volume"), (501, "a process started under the name"), (502, "a script Apple's shell runs"),
    ]

    func testProcesses() throws {
        let snapshot = ProcessSnapshot.build(entries: machine, previous: nil, signature: appleSigned, responsible: { _ in nil }, takenAt: started)
        XCTAssertEqual(snapshot.item(pid: 90)?.isApplesProgram, true)
        XCTAssertEqual(snapshot.item(pid: 0)?.isApplesProgram, true, "the kernel has no executable")
        for impostor in impostors {
            XCTAssertEqual(snapshot.item(pid: impostor.pid)?.isApplesProgram, false, impostor.what)
        }
        XCTAssertEqual(snapshot.group(id: "/System/Applications/Mail.app")?.isApplesProgram, true)
        XCTAssertEqual(snapshot.group(id: "pid:502")?.isApplesProgram, false, "the script's own row")
    }

    /// One row holds every process by the name; the real daemon's connection is the newest,
    /// so its signature heads the row.
    func testNetworkGroupsCountOnlyWhenEveryConnectionIsApplesProgram() throws {
        let byPid = Dictionary(machine.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        func group(_ pids: [Int32]) throws -> ConnectionGroup {
            let connections = pids.enumerated().map { index, pid in
                let owner = ConnectionOwner.resolve(pid: pid, in: byPid, runningApp: { _ in nil }, responsible: { _ in nil }, signature: appleSigned)
                return LiveConnection(connection: connection(pid, at: -Double(index)), owner: owner, isNew: false)
            }
            let groups = NetworkSnapshot(connections: connections, takenAt: started).groups
            XCTAssertEqual(groups.count, 1)
            return try XCTUnwrap(groups.first)
        }
        XCTAssertTrue(try group([90]).isApplesProgram)
        for impostor in impostors {
            XCTAssertFalse(try group([90, impostor.pid]).isApplesProgram, impostor.what)
        }
    }

    /// The kernel names a listener after its executable's file, whatever it was started as
    /// (measured with `exec -a` and a symlink), so a copy is the impostor this tab sees.
    func testPorts() {
        let identities: [Int32: ProcessIdentity] = [
            90: ProcessIdentity(pid: 90, name: "mDNSResponder", path: "/usr/sbin/mDNSResponder"),
            500: ProcessIdentity(pid: 500, name: "mDNSResponder", path: "/private/tmp/mDNSResponder"),
        ]
        let snapshot = PortsSnapshot.build(entries: [listener(90), listener(500)], services: .empty,
                                           identity: { identities[$0] }, signature: appleSigned)
        XCTAssertEqual(snapshot.items.map(\.explainKey), ["mDNSResponder:udp/5353", "mDNSResponder:udp/5353"])
        XCTAssertEqual(snapshot.items.map(\.isApplesProgram), [true, false])
    }

    /// /usr/local is on the Data volume, and Preboot's cryptex folders are world-writable, so a
    /// copy placed there is not the program. /Library/Apple is kept for Apple's updates.
    func testWhereTheProgramRuns() {
        let apple = CodeSignature(signer: .apple)
        XCTAssertFalse(ApplesProgram.isNamed("mDNSResponder", path: "/usr/local/bin/mDNSResponder", signature: apple))
        XCTAssertFalse(ApplesProgram.isNamed("mDNSResponder", path: "/System/Volumes/Preboot/Cryptexes/App/usr/sbin/mDNSResponder", signature: apple))
        XCTAssertTrue(ApplesProgram.isNamed("XProtect", path: "/Library/Apple/System/Library/CoreServices/XProtect.app/Contents/MacOS/XProtect", signature: apple))
    }

    private func connection(_ pid: Int32, at: TimeInterval) -> Connection {
        Connection(id: "\(pid):udp/\(Int(at))", proto: .udp, pid: pid, uid: 501, localPort: 5353,
                   remoteAddress: "224.0.0.251", remotePort: 5353, isIPv6: false, scope: .local, tcpState: nil,
                   firstSeen: started + at, lastSeen: started + at, ended: nil, preExisting: false)
    }

    private func listener(_ pid: Int32) -> SocketEntry {
        SocketEntry(proto: .udp, isIPv6: false, localAddress: "0.0.0.0", localPort: 5353, remoteAddress: "0.0.0.0",
                    remotePort: 0, tcpState: nil, pid: pid, effectivePid: 0, uid: 65)
    }
}
