import AppKit
import Foundation

/// Asking a process to quit. Only processes of the current user can be signalled.
enum ProcessControl {
    enum ControlError: Error, Equatable {
        case notYours
        case failed(errno: Int32)
    }

    static func canQuit(uid: UInt32) -> Bool { uid == getuid() }

    /// What a detail says in place of Quit. Root's code is not always macOS's: it says whose
    /// process it is, not that the process is the system.
    static func whyNoQuit(uid: UInt32) -> String { "Runs as \(UserName.describe(uid)), so Tattle cannot quit it" }

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

    /// SIGKILL: the process gets no chance to save or clean up.
    static func forceQuit(pid: Int32, uid: UInt32) throws {
        guard canQuit(uid: uid) else { throw ControlError.notYours }
        guard kill(pid, SIGKILL) == 0 else { throw ControlError.failed(errno: errno) }
    }
}
