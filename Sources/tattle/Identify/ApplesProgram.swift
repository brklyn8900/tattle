import Foundation

/// Apple's own program by a name, as a shipped rule about one of Apple's programs means it:
/// signed by Apple, run from where only macOS installs programs, and named for its own file.
/// A copy of Apple's binary elsewhere keeps Apple's signature, a process can start under any
/// name, and a script that Apple's interpreter runs is named for the script: none of them is
/// the program.
enum ApplesProgram {
    /// The sealed system volume, and /Library/Apple, which System Integrity Protection keeps
    /// for Apple's updates. /usr/local is the Data volume's, and /System/Volumes holds the
    /// other volumes: the Data volume, and Preboot, whose cryptex folders are world-writable.
    private static let roots = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"]
    private static let excluded = ["/usr/local/", "/System/Volumes/"]

    static func isNamed(_ name: String, path: String?, signature: CodeSignature?) -> Bool {
        guard let path, signature?.signer == .apple,
              roots.contains(where: { path.hasPrefix($0) }), !excluded.contains(where: { path.hasPrefix($0) }) else { return false }
        return URL(fileURLWithPath: path).lastPathComponent == name
    }
}
