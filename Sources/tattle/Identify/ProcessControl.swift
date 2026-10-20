import AppKit
import Foundation

/// Asking a process to quit. Only processes of the current user can be signalled.
enum ProcessControl {
    enum ControlError: Error, Equatable {
        case notYours
        case failed(errno: Int32)
    }

    static func canQuit(uid: UInt32) -> Bool { uid == getuid() }

    /// An app gets the regular quit; anything else gets SIGTERM.
    @MainActor
    static func quit(pid: Int32, uid: UInt32) throws {
        guard canQuit(uid: uid) else { throw ControlError.notYours }
        if let app = NSRunningApplication(processIdentifier: pid), app.bundleURL != nil {
            app.terminate()
            return
        }
        guard kill(pid, SIGTERM) == 0 else { throw ControlError.failed(errno: errno) }
    }
}
