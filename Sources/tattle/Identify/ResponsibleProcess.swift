import Darwin
import Foundation

/// The process macOS holds responsible for another: the app behind a service that launchd
/// started on its behalf, such as Safari's networking service. It is what `launchctl
/// procinfo` reports and what the system's own permission prompts attribute to. Both calls
/// here are private libquarantine functions, resolved at run time so a macOS without them
/// does not fail at launch (ADR-0004).
enum ResponsibleProcess {
    private typealias Lookup = @convention(c) (pid_t) -> pid_t
    private typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    private static let lookup = resolve("responsibility_get_pid_responsible_for_pid", as: Lookup.self)
    private static let setDisclaim = resolve("responsibility_spawnattrs_setdisclaim", as: SetDisclaim.self)

    private static func resolve<Function>(_ name: String, as type: Function.Type) -> Function? {
        guard let handle = dlopen("/usr/lib/system/libquarantine.dylib", RTLD_LAZY),
              let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    /// The responsible pid when it is another process; nil when the process answers for
    /// itself or the lookup is unavailable.
    static func pid(for pid: Int32) -> Int32? {
        guard pid > 0, let lookup else { return nil }
        let responsible = lookup(pid)
        return responsible > 0 && responsible != pid ? responsible : nil
    }

    /// Makes the process these attributes start answer for itself, so macOS does not charge
    /// its access to this app. False when the call is missing or refuses.
    @Sendable static func disclaim(_ attributes: inout posix_spawnattr_t?) -> Bool {
        setDisclaim?(&attributes, 1) == 0
    }
}
