import AppKit
import Foundation

/// Asking a process to quit. Only processes of the current user can be signalled.
enum ProcessControl {
    enum ControlError: Error, Equatable, CustomStringConvertible {
        case notYours
        case failed(errno: Int32)

        /// What the panel shows.
        var description: String {
            switch self {
            case .notYours: "The process runs as another user, so Tattle cannot quit it."
            case .failed(let errno): "The process could not be signalled: \(String(cString: strerror(errno)))."
            }
        }
    }

    static func canQuit(uid: UInt32) -> Bool { uid == getuid() }

    /// What a detail says in place of Quit. Root's code is not always macOS's: it says whose
    /// process it is, not that the process is the system.
    static func whyNoQuit(uid: UInt32) -> String { "Runs as \(UserName.describe(uid)), so Tattle cannot quit it" }

    /// An app gets the regular quit; anything else gets SIGTERM, and so does an app the quit
    /// could not be sent to.
    @MainActor
    static func quit(pid: Int32, uid: UInt32) throws {
        guard canQuit(uid: uid) else { throw ControlError.notYours }
        if let app = NSRunningApplication(processIdentifier: pid), quitsAsApp(bundle: app.bundleURL?.path), app.terminate() { return }
        guard kill(pid, SIGTERM) == 0 else { throw ControlError.failed(errno: errno) }
    }

    /// Whether what Launch Services reports for a process is an app someone opened. A
    /// command-line process it registered is reported under its bare executable, and answers
    /// no quit event.
    static func quitsAsApp(bundle: String?) -> Bool { bundle.flatMap(AppBundle.opened) != nil }

    /// SIGKILL: the process gets no chance to save or clean up.
    static func forceQuit(pid: Int32, uid: UInt32) throws {
        guard canQuit(uid: uid) else { throw ControlError.notYours }
        guard kill(pid, SIGKILL) == 0 else { throw ControlError.failed(errno: errno) }
    }
}
