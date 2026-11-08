import CryptoKit
import Foundation

/// What tells one program's code from another's of the same name, kept with an explanation
/// given for it: a process name, a port's owner or a launch label is anyone's to take. Compared
/// and stored, never shown or sent. Nil when nothing tells them apart.
///
/// A script's identity has two limits, because a command line is all that says which script
/// a process runs. A process can rewrite its own arguments, so it can claim another script's
/// path. A relative path is joined to the working directory at the time it is read, not the
/// one the script started in, so after a `chdir` it can name another file.
struct CodeIdentity: Hashable, Sendable {
    /// All that a poll can know of it, without reading the code.
    var text: String
    /// The file whose content finishes the identity, for code nothing else pins to one
    /// version. Read only when an answer is looked up for an open detail or stored
    /// (`FileDigests`); one that cannot be read leaves no identity.
    var contentFile: String?

    init(text: String, contentFile: String? = nil) {
        self.text = text
        self.contentFile = contentFile
    }

    /// As stored with an answer, given the content file's digest.
    func stored(digest: String) -> String { "\(text):sha256:\(digest)" }

    /// Whether `stored`, an identity kept with an answer, was this code's at some version.
    func wasStored(as stored: String) -> Bool { stored.hasPrefix(text + ":sha256:") }

    /// The code at `path`, by its signature. A publisher's programs are known by the team Apple
    /// issued it and their signing identifier, wherever they are and whatever their version.
    /// Apple's are known by identifier where only macOS installs programs; a copy elsewhere
    /// keeps Apple's signature, so it is that copy, at its path. Anything else has no publisher
    /// to say what it is, so it is that file at one version: by its signature's own hash, or
    /// with none, by its content. A script, unnamed code or a launch item is not its program's
    /// signature.
    static func of(_ signature: CodeSignature?, path: String?) -> CodeIdentity? {
        guard let signature else { return nil }
        switch signature.signer {
        case .script, .unnamed, .launchItem: return nil
        case .apple:
            guard let path else { return nil }
            return CodeIdentity(text: "apple:\(signature.identifier ?? ""):" + (ApplesProgram.isInstalled(at: path) ? "" : path))
        default:
            if let team = signature.teamIdentifier { return CodeIdentity(text: "team:\(team):\(signature.identifier ?? "")") }
            guard let path else { return nil }
            let kind = kind(of: signature.signer)
            if let hash = signature.codeHash { return CodeIdentity(text: "\(kind):\(hash):\(path)") }
            return CodeIdentity(text: "\(kind):\(path)", contentFile: path)
        }
    }

    private static func kind(of signer: CodeSignature.Signer) -> String {
        switch signer {
        case .unsigned: "unsigned"
        case .adHoc: "ad-hoc"
        case .invalid: "invalid"
        case .notIssuedByApple: "not-issued-by-apple"
        default: "signed"
        }
    }

    /// A script, by the file it is and what is in it.
    static func script(at path: String) -> CodeIdentity { CodeIdentity(text: "script:\(path)", contentFile: path) }

    /// A launch item's command line, which is what its plist says runs, and the version of the
    /// code it reaches: its signature's hash, else the content of the file, with neither the
    /// line alone (`LaunchedVersion`). Hashed because arguments can carry tokens. Nil for a
    /// file at a relative path, which the plist's line does not locate.
    static func command(_ line: String, codeHash: String? = nil, file: String? = nil) -> CodeIdentity? {
        let text = "command:" + SHA256.hash(data: Data(line.utf8)).map { String(format: "%02x", $0) }.joined()
        if let codeHash { return CodeIdentity(text: "\(text):\(codeHash)") }
        guard let file else { return CodeIdentity(text: text) }
        return file.hasPrefix("/") ? CodeIdentity(text: text, contentFile: file) : nil
    }
}

/// What says which version of the code a launch item's line reaches.
enum LaunchedVersion: Equatable, Sendable {
    /// The line itself, which holds the code.
    case line
    /// The file the line reaches, a program or a script.
    case file(String)
    /// Nothing: the line does not say where its code is.
    case unknown

    /// The program at `path`, which reads as `signature`. Only macOS installs a program where
    /// Apple's are, and an update rebuilds it, so there the line says all there is.
    static func of(program path: String, signature: CodeSignature?) -> LaunchedVersion {
        switch signature?.signer {
        case .launchItem(applesProgram: .some): .line
        case .apple where ApplesProgram.isInstalled(at: URL(fileURLWithPath: path).resolvingSymlinksInPath().path): .line
        default: .file(path)
        }
    }
}
