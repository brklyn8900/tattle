import XCTest

extension XCTestCase {
    /// Waits at most `seconds` for `process` to exit, then kills it and fails the test. macOS
    /// has held a launch here before its first instruction (2026-10-22: a just-signed probe and
    /// a stand-in launchctl, each for the rest of the run), and an unbounded wait turns that
    /// into a hung test run. Returns whether the process exited on its own.
    @discardableResult
    func waitForExit(_ process: Process, within seconds: TimeInterval = 60, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        guard process.isRunning else { return true }
        kill(process.processIdentifier, SIGKILL)
        XCTFail("\(process.executableURL?.lastPathComponent ?? "a process") did not exit within \(Int(seconds)) s", file: file, line: line)
        return false
    }
}
