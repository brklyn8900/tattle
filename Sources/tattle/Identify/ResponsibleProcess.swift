import Darwin
import Foundation

/// The process macOS holds responsible for another: the app behind a service that launchd
/// started on its behalf, such as Safari's networking service. It is what `launchctl
/// procinfo` reports and what the system's own permission prompts attribute to. The
/// lookup is a private libquarantine function, resolved at run time so a macOS without
/// it degrades to no attribution rather than a failed launch.
enum ResponsibleProcess {
    private typealias Lookup = @convention(c) (pid_t) -> pid_t

    private static let lookup: Lookup? = {
        guard let handle = dlopen("/usr/lib/system/libquarantine.dylib", RTLD_LAZY),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: Lookup.self)
    }()

    /// The responsible pid when it is another process; nil when the process answers for
    /// itself or the lookup is unavailable.
    static func pid(for pid: Int32) -> Int32? {
        guard pid > 0, let lookup else { return nil }
        let responsible = lookup(pid)
        return responsible > 0 && responsible != pid ? responsible : nil
    }
}
