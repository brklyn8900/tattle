import os
import XCTest
@testable import tattle

final class SnifferTests: XCTestCase {
    /// Waits at most `seconds` for `condition`, polling.
    private func eventually(within seconds: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { usleep(20_000) }
        return condition()
    }

    /// A restart (after the broker is installed or removed) must end the old run: a run left
    /// going keeps its own capture device and reports every flow a second time.
    func testRestartEndsThePreviousRunBeforeTheNextBegins() {
        let statuses = OSAllocatedUnfairLock<[Sniffer.Status]>(initialState: [])
        let sniffer = Sniffer(open: { _ in throw CaptureError.open(errno: EACCES) },
                              onEvents: { _ in },
                              onStatus: { status in statuses.withLock { $0.append(status) } })
        defer { sniffer.stop() }
        sniffer.start()
        XCTAssertTrue(eventually { !statuses.withLock { $0 }.isEmpty }, "the first run reports its failure")
        let failure = statuses.withLock { $0[0] }

        sniffer.stop()
        sniffer.start()
        XCTAssertTrue(eventually { statuses.withLock { $0 }.count >= 3 })
        XCTAssertEqual(Array(statuses.withLock { $0 }.prefix(3)), [failure, .stopped, failure],
                       "the first run stopped before the second reported")
    }
}
