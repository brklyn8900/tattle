import CryptoKit
import Foundation

/// What tells one program's code from another's of the same name, kept with an explanation
/// given for it: a process name, a port's owner or a launch label is anyone's to take. Compared
/// and stored, never shown or sent. Nil when nothing tells them apart.
enum CodeIdentity {
    /// The code at `path`, by its signature. A publisher's programs are known by the team Apple
    /// issued it and their signing identifier, wherever they are and whatever their version.
    /// Apple's are known by identifier where only macOS installs programs; a copy elsewhere
    /// keeps Apple's signature, so it is that copy, at its path. Anything else has only its path.
    /// A script, unnamed code or a launch item is not its program's signature.
    static func of(_ signature: CodeSignature?, path: String?) -> String? {
        guard let signature else { return nil }
        switch signature.signer {
        case .script, .unnamed, .launchItem: return nil
        case .apple:
            guard let path else { return nil }
            return "apple:\(signature.identifier ?? ""):" + (ApplesProgram.isInstalled(at: path) ? "" : path)
        default:
            if let team = signature.teamIdentifier { return "team:\(team):\(signature.identifier ?? "")" }
            return path.map { "path:\($0)" }
        }
    }

    /// A script, by the file it is.
    static func script(at path: String) -> String { "script:\(path)" }

    /// A launch item's command line, which is what its plist says runs. Hashed because
    /// arguments can carry tokens.
    static func command(_ line: String) -> String {
        "command:" + SHA256.hash(data: Data(line.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
