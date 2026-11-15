import Foundation

/// Apple's own program by a name, as a shipped rule about one of Apple's programs means it:
/// signed by Apple, run from where only macOS installs programs, and named for its own file.
/// A copy of Apple's binary elsewhere keeps Apple's signature, a process can start under any
/// name, and a script that Apple's interpreter runs is named for the script, or in Processes
/// and Network signed as a script: none of them is the program.
enum ApplesProgram {
    /// The sealed system volume, and /Library/Apple, which System Integrity Protection keeps
    /// for Apple's updates. /usr/local is the Data volume's, and /System/Volumes holds the
    /// other volumes: the Data volume, and Preboot.
    private static let roots = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"]
    private static let excluded = ["/usr/local/", "/System/Volumes/"]
    /// Preboot's two cryptexes, where macOS keeps what it updates apart from the system
    /// volume, and the path Safari and WebKit run from. Their parent does not count: anyone can
    /// write to it, so a copy can be placed beside them, and its other folders are
    /// world-writable or lack the flag below. Nothing but that flag and its owner keeps a
    /// cryptex itself from being written to or replaced, so each counts only where it has
    /// them (`isKept`). They are looked at once: only root can change a folder that passes.
    private static let keptCryptexes = cryptexes()

    static func cryptexes(isKept: (String) -> Bool = isKept(folder:)) -> [String] {
        ["/System/Volumes/Preboot/Cryptexes/App", "/System/Volumes/Preboot/Cryptexes/OS"].filter(isKept).map { $0 + "/" }
    }

    /// Whether the folder is root's, closed to writing by anyone else, and carries the flag
    /// that keeps it from being unlinked or renamed. A link to such a folder is not one.
    static func isKept(folder: String) -> Bool {
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        return info.st_uid == 0 && info.st_mode & (S_IWGRP | S_IWOTH) == 0 && info.st_flags & UInt32(SF_NOUNLINK) != 0
    }

    static func isNamed(_ name: String, path: String?, signature: CodeSignature?) -> Bool {
        guard let path, signature?.signer == .apple, isInstalled(at: path) else { return false }
        return URL(fileURLWithPath: path).lastPathComponent == name
    }

    /// Where only macOS installs programs.
    static func isInstalled(at path: String) -> Bool { isInstalled(at: path, cryptexes: keptCryptexes) }

    static func isInstalled(at path: String, cryptexes: [String]) -> Bool {
        if cryptexes.contains(where: { path.hasPrefix($0) }) { return true }
        return roots.contains { path.hasPrefix($0) } && !excluded.contains { path.hasPrefix($0) }
    }
}
