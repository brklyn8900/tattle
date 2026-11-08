import Foundation
import Security

/// Who signed a binary or bundle, read from its code signature.
struct CodeSignature: Equatable, Sendable {
    enum Signer: Equatable, Sendable {
        /// Apple's own code, as macOS is: signed by Apple itself (`anchor apple`).
        case apple
        /// Distributed through the Mac App Store.
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
        /// A launch item that is not Apple's, running one of Apple's programs, named here. No
        /// one signs the plist that says what the program is told to do, so Apple's signature on
        /// the program vouches for nothing the item does.
        case launchItem(applesProgram: String)
        /// Signed, but the signature does not match the binary.
        case invalid(String)
        /// Signed with a certificate Apple did not issue. Anyone can make one, with any name.
        case notIssuedByApple
        /// Some other certificate Apple issued.
        case other(String)
    }

    var signer: Signer
    var identifier: String?
    var teamIdentifier: String?

    /// One or two words for a row: Apple, App Store, the publisher, or unsigned.
    var summary: String {
        switch signer {
        case .apple: "Apple"
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
        program: String, arguments: [String], environmentPath: String? = nil,
        reading: (String) -> CodeSignature? = { read(path: $0) }
    ) -> CodeSignature? {
        let identify = {
            LaunchedCode.Identity(path: $0, signature: reading($0), realPath: URL(fileURLWithPath: $0).resolvingSymlinksInPath().path)
        }
        let code = LaunchedCode.started(program: program, arguments: arguments, environmentPath: environmentPath, identify: identify)
        switch code {
        case .program(let path): return launchItem(running: path, signature: reading(path))
        case .script, .standardInput: return CodeSignature(signer: .script)
        case .unnamed: return CodeSignature(signer: .unnamed)
        case .undetermined: return nil
        }
    }

    /// `signature`, the signature of `program`, as a launch item that is not Apple's shows it.
    static func launchItem(running program: String, signature: CodeSignature?) -> CodeSignature? {
        guard signature?.signer == .apple else { return signature }
        return CodeSignature(signer: .launchItem(applesProgram: URL(fileURLWithPath: program).lastPathComponent))
    }

    /// Reads and validates the signature at `path`. Resources are not validated: that
    /// takes seconds on a large app and the question here is who signed it.
    ///
    /// Apple's own code is known by its chain alone (`anchor apple`): Apple has signed it
    /// under more than one subject ("Software Signing", "macOS Software Signing"). Every
    /// other kind is read from the leaf certificate's subject, which is whatever its maker
    /// wrote, so it counts only when the chain shows Apple issued it (`anchor apple generic`).
    static func read(path: String) -> CodeSignature {
        var staticCode: SecStaticCode?
        let url = URL(fileURLWithPath: path) as CFURL
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess, let code = staticCode else {
            return CodeSignature(signer: .unsigned)
        }
        var error: Unmanaged<CFError>?
        let validity = SecStaticCodeCheckValidityWithErrors(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), nil, &error)
        if validity == errSecCSUnsigned { return CodeSignature(signer: .unsigned) }
        if validity != errSecSuccess {
            let message = error?.takeRetainedValue().localizedDescription
                ?? (SecCopyErrorMessageString(validity, nil) as String?) ?? "OSStatus \(validity)"
            return CodeSignature(signer: .invalid(message))
        }

        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else {
            return CodeSignature(signer: .invalid("no signing information"))
        }
        let identifier = info[kSecCodeInfoIdentifier as String] as? String
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        let flags = info[kSecCodeInfoFlags as String] as? UInt32 ?? 0
        let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []

        if flags & SecCodeSignatureFlags.adhoc.rawValue != 0 || certificates.isEmpty {
            return CodeSignature(signer: .adHoc, identifier: identifier)
        }
        if satisfies(code, "anchor apple") {
            return CodeSignature(signer: .apple, identifier: identifier, teamIdentifier: team)
        }
        guard satisfies(code, "anchor apple generic") else {
            return CodeSignature(signer: .notIssuedByApple, identifier: identifier)
        }
        let signer = classify((SecCertificateCopySubjectSummary(certificates[0]) as String?) ?? "")
        return CodeSignature(signer: signer, identifier: identifier, teamIdentifier: team)
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
