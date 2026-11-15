import Foundation
import Security

/// Who signed a binary or bundle, read from its code signature.
struct CodeSignature: Equatable, Sendable {
    enum Signer: Equatable, Sendable {
        /// Apple's own code, as macOS is: signed by Apple itself (`anchor apple`).
        case apple
        /// Apple's signature on a file that is not where only macOS installs programs
        /// (`located`). It says who made the file and not that the file is part of macOS: a
        /// copy of one of Apple's binaries keeps it anywhere, a running program can move such
        /// a file over its own, and a copy of one of Apple's tools can be made to load other
        /// code.
        case appleElsewhere
        case appStore
        /// Developer ID: the name on the certificate is the publisher.
        case developerID(name: String)
        /// A development certificate: built locally by a developer. Its name is the
        /// developer's Apple account, usually an email address, so it is not kept.
        case development
        /// Signed without any certificate.
        case adHoc
        case unsigned
        /// A script an interpreter runs, from a file or its standard input, whose signature,
        /// if it has one, is not read; the interpreter's says nothing about it.
        case script
        /// Code the command line does not name as a file: inline, a module, class or package
        /// by name, in arguments that cannot be read, or what one of Apple's developer tools is
        /// told to run. Whose code it is cannot be known.
        case unnamed
        /// A launch item that is not Apple's, running one of Apple's programs, named here when
        /// it is where macOS installs it and its plist does not change the root folder, when
        /// the path would not say which file runs. No one signs the plist that says what the
        /// program is told to do, so Apple's signature on the program vouches for nothing the
        /// item does.
        case launchItem(applesProgram: String?)
        /// Signed, but the signature does not match the binary.
        case invalid
        /// Signed with a certificate Apple did not issue. Anyone can make one, with any name.
        case notIssuedByApple
        /// Some other certificate Apple issued.
        case other(String)
    }

    var signer: Signer
    var identifier: String?
    var teamIdentifier: String?
    /// The code directory hash: which version of the code this is, whoever signed it.
    var codeHash: String?

    /// One or two words for a row: Apple, App Store, the publisher, or unsigned.
    var summary: String {
        switch signer {
        case .apple: "Apple"
        case .appleElsewhere: "Apple, outside macOS"
        case .appStore: "App Store"
        case .developerID(let name), .other(let name): name
        case .development: teamIdentifier.map { "Apple Development (\($0))" } ?? "Apple Development"
        case .adHoc: "ad hoc signed"
        case .unsigned: "unsigned"
        case .script: "script, not signed"
        case .unnamed: "unnamed code"
        case .launchItem: "launch item, not signed"
        case .invalid: "invalid signature"
        case .notIssuedByApple: "certificate not issued by Apple"
        }
    }

    /// Whether the signature names someone as the signer: Apple, the App Store, or the holder
    /// of a certificate Apple issued. The others say only that no one is named.
    var namesSigner: Bool {
        switch signer {
        case .apple, .appleElsewhere, .appStore, .developerID, .development, .other: true
        case .adHoc, .unsigned, .script, .unnamed, .launchItem, .invalid, .notIssuedByApple: false
        }
    }

    /// The same signer, whichever of its programs each signature is on.
    func isSameSigner(as other: CodeSignature?) -> Bool {
        signer == other?.signer && teamIdentifier == other?.teamIdentifier
    }

    /// Whether `other` is this signer's code, as a bundle's own executable is its bundle's:
    /// Apple's or the same team's, which a signature proves. Code with no team has no signer
    /// to share, so only the very same code counts.
    func owns(_ other: CodeSignature?) -> Bool {
        if signer == .apple || signer == .appleElsewhere { return isSameSigner(as: other) }
        if let teamIdentifier { return teamIdentifier == other?.teamIdentifier }
        return codeHash != nil && codeHash == other?.codeHash
    }

    /// This signature, read from the file at `path`, as a row shows it: Apple's stays Apple's
    /// only where only macOS installs programs (`ApplesProgram.isInstalled`). `path` has its
    /// links resolved.
    func located(at path: String?) -> CodeSignature {
        guard signer == .apple, path.map(ApplesProgram.isInstalled(at:)) != true else { return self }
        var elsewhere = self
        elsewhere.signer = .appleElsewhere
        return elsewhere
    }

    /// How a launch item reads, from the code its command line runs (`LaunchedCode.started`):
    /// the program's signature, through any of Apple's wrappers, or the first program's on the
    /// way that is not Apple's; "script" when an interpreter runs a script, whatever file the
    /// command line names as the script, and "unnamed code" when it runs code the command line
    /// does not name as a file; nil when Apple's programs lead to one the command line does
    /// not locate. Startup lists only items that are not Apple's (its own, under
    /// /System/Library, are counted), so a program of Apple's reads as `launchItem`.
    ///
    /// A script file's signature is not read: a script rarely carries one, and no interpreter
    /// runs a signed binary as its script, so a signed file in the script's place is an
    /// argument read there by mistake.
    static func read(
        program: String, arguments: [String], environmentPath: String? = nil, changesRoot: Bool = false,
        reading: (String) -> CodeSignature? = { read(path: $0) }
    ) -> CodeSignature? {
        started(program: program, arguments: arguments, environmentPath: environmentPath, changesRoot: changesRoot, reading: reading).signature
    }

    /// How the launch item reads (`read`), and what says which version of its code this is.
    static func started(
        program: String, arguments: [String], environmentPath: String? = nil, changesRoot: Bool = false,
        reading: (String) -> CodeSignature? = { read(path: $0) }
    ) -> (signature: CodeSignature?, version: LaunchedVersion) {
        let identify = {
            LaunchedCode.Identity(path: $0, signature: reading($0), realPath: URL(fileURLWithPath: $0).resolvingSymlinksInPath().path)
        }
        let code = LaunchedCode.started(program: program, arguments: arguments, environmentPath: environmentPath, identify: identify)
        switch code {
        case .program(let path):
            let signature = launchItem(running: path, signature: reading(path), changesRoot: changesRoot)
            return (signature, .of(program: path, signature: signature))
        case .script(let path, _): return (CodeSignature(signer: .script), .file(path))
        case .inline: return (CodeSignature(signer: .unnamed), .line)
        case .standardInput: return (CodeSignature(signer: .script), .unknown)
        case .unnamed: return (CodeSignature(signer: .unnamed), .unknown)
        case .undetermined: return (nil, .unknown)
        }
    }

    /// `signature`, the signature of `program`, as a launch item that is not Apple's shows it.
    static func launchItem(running program: String, signature: CodeSignature?, changesRoot: Bool = false) -> CodeSignature? {
        guard signature?.signer == .apple else { return signature }
        // A plist's path is as written: a link, or ".." out of a system folder. A copy of
        // Apple's binary keeps Apple's signature under any name.
        let path = URL(fileURLWithPath: program).resolvingSymlinksInPath().path
        let name = URL(fileURLWithPath: path).lastPathComponent
        let isNamed = !changesRoot && ApplesProgram.isNamed(name, path: path, signature: signature)
        return CodeSignature(signer: .launchItem(applesProgram: isNamed ? name : nil), codeHash: signature?.codeHash)
    }

    /// A signature as read, with the files and folders the reading rests on
    /// (`files(readWith:at:)`), so that what keeps it can tell when to read it again.
    struct Reading: Sendable {
        var signature: CodeSignature
        var files: [String] = []
    }

    /// Reads and validates the signature at `path`. Resources are not validated: that
    /// takes seconds on a large app and the question here is who signed it.
    ///
    /// Apple's own code is known by its chain alone (`anchor apple`): Apple has signed it
    /// under more than one subject ("Software Signing", "macOS Software Signing"). Every
    /// other kind is read from the leaf certificate's subject, which is whatever its maker
    /// wrote, so it counts only when the chain shows Apple issued it (`anchor apple generic`).
    static func read(path: String) -> CodeSignature { reading(path: path).signature }

    static func reading(path: String) -> Reading {
        var staticCode: SecStaticCode?
        let url = URL(fileURLWithPath: path) as CFURL
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess, let code = staticCode else {
            return Reading(signature: CodeSignature(signer: .unsigned), files: files(readWith: nil, at: path))
        }
        var error: Unmanaged<CFError>?
        let validity = SecStaticCodeCheckValidityWithErrors(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), nil, &error)
        // Taken whatever the verdict: the error is this caller's to release.
        _ = error?.takeRetainedValue()
        // Asked of unsigned and invalid code too, which it still names the main executable of.
        let info = information(of: code, SecCSFlags(rawValue: kSecCSSigningInformation))
        return Reading(signature: signature(of: code, validity: validity, info: info), files: files(readWith: mainExecutable(in: info), at: path))
    }

    /// The files `reading(path:)` would name, asked without validating anything: what keeps a
    /// reading notes them before the read as well as after it.
    static func files(readAt path: String) -> [String] {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode else {
            return files(readWith: nil, at: path)
        }
        return files(readWith: mainExecutable(in: information(of: code, [])), at: path)
    }

    private static func information(of code: SecStaticCode, _ flags: SecCSFlags) -> [String: Any]? {
        var info: CFDictionary?
        return SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess ? info as? [String: Any] : nil
    }

    private static func mainExecutable(in info: [String: Any]?) -> String? {
        (info?[kSecCodeInfoMainExecutable as String] as? URL)?.path
    }

    /// The files and folders a reading of the code at `path` rests on, given its main
    /// executable, whether or not each is there: one that arrives later changes the reading
    /// as much as one written over. Code in a bundle is read with the bundle's Info.plist and
    /// what `_CodeSignature` holds, whether the path read is the bundle or the executable, and
    /// writing over one of them leaves the bundle folder's own dates as they were. They are
    /// beside the executable, or beside its `MacOS` folder in a bundle with `Contents`. The
    /// folders between them are named too: a folder renamed over another brings files with the
    /// dates they had, and only the folder that holds it shows the change.
    static func files(readWith executable: String?, at path: String) -> [String] {
        guard let executable else {
            // Code that cannot be opened names no executable. A folder may be an app still
            // being put in place, whose files arrive in `Contents`.
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else { return [] }
            return ["\(path)/Contents", "\(path)/Contents/MacOS", "\(path)/Contents/Info.plist"]
        }
        let folder = (executable as NSString).deletingLastPathComponent
        let hasContents = folder.hasSuffix("/Contents/MacOS")
        let bundle = hasContents ? (folder as NSString).deletingLastPathComponent : folder
        let info = "\(bundle)/Info.plist"
        // A file with no Info.plist beside it is no bundle until one arrives.
        guard hasContents || FileManager.default.fileExists(atPath: info) else { return [executable, info] }
        let seal = "\(bundle)/_CodeSignature"
        let sealed = ((try? FileManager.default.contentsOfDirectory(atPath: seal)) ?? []).sorted().map { "\(seal)/\($0)" }
        return [executable, info, seal] + sealed + [bundle] + (hasContents ? [folder, (bundle as NSString).deletingLastPathComponent] : [])
    }

    private static func signature(of code: SecStaticCode, validity: OSStatus, info: [String: Any]?) -> CodeSignature {
        if validity == errSecCSUnsigned { return CodeSignature(signer: .unsigned) }
        if validity != errSecSuccess { return CodeSignature(signer: .invalid) }
        guard let info else { return CodeSignature(signer: .invalid) }
        let identifier = info[kSecCodeInfoIdentifier as String] as? String
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        let flags = info[kSecCodeInfoFlags as String] as? UInt32 ?? 0
        let codeHash = (info[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined()
        let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []

        if flags & SecCodeSignatureFlags.adhoc.rawValue != 0 || certificates.isEmpty {
            return CodeSignature(signer: .adHoc, identifier: identifier, codeHash: codeHash)
        }
        if satisfies(code, "anchor apple") {
            return CodeSignature(signer: .apple, identifier: identifier, teamIdentifier: team, codeHash: codeHash)
        }
        guard satisfies(code, "anchor apple generic") else {
            return CodeSignature(signer: .notIssuedByApple, identifier: identifier, codeHash: codeHash)
        }
        let signer = classify((SecCertificateCopySubjectSummary(certificates[0]) as String?) ?? "")
        return CodeSignature(signer: signer, identifier: identifier, teamIdentifier: team, codeHash: codeHash)
    }

    private static func satisfies(_ code: SecStaticCode, _ requirement: String) -> Bool {
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess, let compiled else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), compiled) == errSecSuccess
    }

    /// Maps the leaf certificate's subject to a signer kind other than Apple's own. A subject
    /// issued to a team ends in its parenthesised id, which is dropped: the team comes from
    /// the signing information, where it is authoritative.
    static func classify(_ subject: String) -> Signer {
        if subject == "Apple Mac OS Application Signing" { return .appStore }
        for prefix in ["Developer ID Application: "] where subject.hasPrefix(prefix) {
            return .developerID(name: stripId(subject.dropFirst(prefix.count)))
        }
        for prefix in ["Apple Development: ", "Mac Developer: ", "iPhone Developer: "] where subject.hasPrefix(prefix) {
            return .development
        }
        return .other(stripId(Substring(subject)))
    }

    private static func stripId(_ name: Substring) -> String {
        var name = String(name)
        if name.hasSuffix(")"), let open = name.lastIndex(of: "(") {
            name = String(name[..<open]).trimmingCharacters(in: .whitespaces)
        }
        return name
    }
}
