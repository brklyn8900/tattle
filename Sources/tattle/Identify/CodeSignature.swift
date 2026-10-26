import Foundation
import Security

/// Who signed a binary or bundle, read from its code signature.
struct CodeSignature: Equatable, Sendable {
    enum Signer: Equatable, Sendable {
        /// Part of macOS, signed by Apple's Software Signing certificate.
        case apple
        /// Distributed through the Mac App Store.
        case appStore
        /// Developer ID: the name on the certificate is the publisher.
        case developerID(name: String)
        /// A development certificate: built locally by a developer.
        case development(name: String)
        /// Signed without any certificate.
        case adHoc
        case unsigned
        /// A script run by an interpreter: the interpreter is Apple's, the code is not signed.
        case script
        /// Signed, but the signature does not match the binary.
        case invalid(String)
        /// Some other certificate.
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
        case .developerID(let name), .development(let name), .other(let name): name
        case .adHoc: "ad hoc signed"
        case .unsigned: "unsigned"
        case .script: "script, not signed"
        case .invalid: "invalid signature"
        }
    }

    /// `summary` for text that leaves the machine: a development certificate is named after
    /// the developer, so only its kind is given.
    var promptSummary: String {
        if case .development = signer { return "Apple Development" }
        return summary
    }

    /// Interpreters whose signature says nothing about what they run.
    static let interpreters: Set<String> = [
        "sh", "bash", "zsh", "ksh", "csh", "tcsh", "dash", "osascript", "python", "python3",
        "perl", "ruby", "php", "node", "env", "open",
    ]

    /// The signature that matters for a command line: the script's when an interpreter
    /// runs a file, "script" when it runs inline code, otherwise the program's.
    static func read(program: String, arguments: [String], reading: (String) -> CodeSignature? = { read(path: $0) }) -> CodeSignature? {
        guard interpreters.contains(URL(fileURLWithPath: program).lastPathComponent) else { return reading(program) }
        for argument in arguments where argument.hasPrefix("/") && FileManager.default.fileExists(atPath: argument) {
            return reading(argument)
        }
        return CodeSignature(signer: .script)
    }

    /// Reads and validates the signature at `path`. Resources are not validated: that
    /// takes seconds on a large app and the question here is who signed it.
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
            return CodeSignature(signer: .adHoc, identifier: identifier, teamIdentifier: team)
        }
        let leaf = (SecCertificateCopySubjectSummary(certificates[0]) as String?) ?? ""
        return CodeSignature(signer: classify(leaf), identifier: identifier, teamIdentifier: team)
    }

    /// Maps the leaf certificate's subject to a signer kind. Developer ID and development
    /// subjects end in a parenthesised id, which is dropped: the team comes from the
    /// signing information, where it is authoritative.
    static func classify(_ subject: String) -> Signer {
        if subject == "Software Signing" { return .apple }
        if subject == "Apple Mac OS Application Signing" { return .appStore }
        for prefix in ["Developer ID Application: "] where subject.hasPrefix(prefix) {
            return .developerID(name: stripId(subject.dropFirst(prefix.count)))
        }
        for prefix in ["Apple Development: ", "Mac Developer: ", "iPhone Developer: "] where subject.hasPrefix(prefix) {
            return .development(name: stripId(subject.dropFirst(prefix.count)))
        }
        return .other(subject)
    }

    private static func stripId(_ name: Substring) -> String {
        var name = String(name)
        if name.hasSuffix(")"), let open = name.lastIndex(of: "(") {
            name = String(name[..<open]).trimmingCharacters(in: .whitespaces)
        }
        return name
    }
}
