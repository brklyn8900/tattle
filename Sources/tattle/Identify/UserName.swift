import Foundation
import os

/// The account a process runs as, in words: "root", "you (e)", "_spotlight", or the
/// number when the directory has no name for it.
enum UserName {
    private static let cache = OSAllocatedUnfairLock<[uid_t: String]>(initialState: [:])

    static func describe(_ uid: uid_t) -> String {
        if uid == 0 { return "root" }
        if let known = cache.withLock({ $0[uid] }) { return known }
        let text: String
        if let entry = getpwuid(uid), let name = entry.pointee.pw_name {
            let login = String(cString: name)
            text = uid == getuid() ? "you (\(login))" : login
        } else {
            text = "user \(uid)"
        }
        cache.withLock { $0[uid] = text }
        return text
    }

    /// The same without the login name of the user's own account, for text that leaves
    /// the machine.
    static func describeForModel(_ uid: uid_t) -> String {
        uid == getuid() && uid != 0 ? "you" : describe(uid)
    }
}
