import Darwin
import Foundation

/// Name and path of a running process, from libproc. Works for other users' processes
/// too, which is what `ps` relies on.
struct ProcessIdentity: Equatable, Sendable {
    var pid: Int32
    var name: String
    var path: String?

    static func read(pid: Int32) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let path = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 ? String(cString: pathBuffer) : nil
        var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let name = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 ? String(cString: nameBuffer) : nil
        guard name != nil || path != nil else { return nil }
        return ProcessIdentity(
            pid: pid,
            name: name ?? URL(fileURLWithPath: path!).lastPathComponent,
            path: path)
    }
}
