import Foundation
import SystemConfiguration

/// Replaces what would identify this Mac or its user before a prompt leaves the machine:
/// the home path, the username, private and local IP addresses, the machine's names,
/// Tailscale names, which identify the account, other accounts' folders and disk names.
struct Redactor: Sendable {
    /// What a text is. An item's key and facts share one, so a fact cannot undo the key's
    /// redaction or the reverse.
    enum Context {
        case host
        /// A process or a listening port.
        case program
        case launchItem
        /// Prompt instructions the user has edited.
        case instructions

        init(_ kind: Rule.Kind) {
            switch kind {
            case .host: self = .host
            case .process, .port: self = .program
            case .launchItem: self = .launchItem
            }
        }
    }

    var home: String
    var username: String
    var machineNames: [String]
    /// The mounted disks' names, which can hold spaces and brackets.
    var volumeNames: [String] = []

    /// The machine's names come from the dynamic store and the kernel, never from a name
    /// lookup: macOS holds an app's reverse lookups of its own addresses, loopback included,
    /// behind the Local Network alert, and unanswered they fail after 35 s (measured on
    /// testmac, 2026-10-28). Host.current() makes those lookups.
    static var current: Redactor {
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        let hostName = gethostname(&buffer, buffer.count) == 0 ? String(cString: buffer) : nil
        return Redactor(
            home: NSHomeDirectory(),
            username: NSUserName(),
            machineNames: machineNames(
                computerName: SCDynamicStoreCopyComputerName(nil, nil) as String?,
                localHostName: SCDynamicStoreCopyLocalHostName(nil) as String?,
                hostName: hostName, domains: SystemDNS.current.domains),
            volumeNames: (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? [])
    }

    /// The computer name, the Bonjour name bare and with .local, the hostname, and each host
    /// label under every search domain, which is how Tailscale and the router's DHCP name
    /// this Mac.
    ///
    /// Not covered: a name the router invents and no search domain carries, Tailscale's suffix for a name another device
    /// already has (`-1`), and a rename in Tailscale's admin console.
    static func machineNames(computerName: String?, localHostName: String?, hostName: String?, domains: [String]) -> [String] {
        let bare = [computerName, localHostName, localHostName.map { $0 + ".local" }, hostName].compactMap { $0 }
        let labels = [localHostName, hostName.map(firstLabel), computerName.map(tailscaleLabel)].compactMap { $0 }
        let names = bare + labels.flatMap { label in domains.map { label + "." + $0 } }
        var seen = Set<String>()
        return names.filter { name in
            let first = firstLabel(name).lowercased()
            return first != "" && first != "localhost" && seen.insert(name.lowercased()).inserted
        }
    }

    /// The label Tailscale's MagicDNS gives this Mac, which it takes from the computer name,
    /// not the local host name: its HostName is the computer name (measured on this Mac,
    /// 2026-10-28). A port of SanitizeHostname in tailscale/tailscale util/dnsname/dnsname.go,
    /// byte for byte, so a curly apostrophe vanishes.
    static func tailscaleLabel(_ computerName: String) -> String {
        var name = Array(computerName.utf8)
        for suffix in [".local", ".localdomain", ".lan"].map({ Array($0.utf8) }) where name.suffix(suffix.count).elementsEqual(suffix) {
            name.removeLast(suffix.count)
        }
        let upper = UInt8(ascii: "A")...UInt8(ascii: "Z")
        func isAlphanumeric(_ byte: UInt8) -> Bool {
            upper.contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        }
        var label = name.prefix(63)
        while let byte = label.first, !isAlphanumeric(byte) { label.removeFirst() }
        while let byte = label.last, !isAlphanumeric(byte) { label.removeLast() }
        let dashes = Set("- .@_".utf8)
        let bytes = label.compactMap { byte -> UInt8? in
            if upper.contains(byte) { return byte + 32 }
            if isAlphanumeric(byte) { return byte }
            return dashes.contains(byte) ? UInt8(ascii: "-") : nil
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func firstLabel(_ name: String) -> String {
        String(name.prefix { $0 != "." })
    }

    func redact(_ text: String, as context: Context) -> String {
        let captured = context != .instructions
        var out = text
        // Home path before username: the path contains the username.
        // On a path boundary: home "/Users/u" must not take the front off "/Users/eve/...".
        // In any case, as APFS reads a path.
        if !home.isEmpty {
            let pattern = NSRegularExpression.escapedPattern(for: home) + "(?![\\w.~@+-])"
            out = out.replacingOccurrences(of: pattern, with: "<home>", options: [.regularExpression, .caseInsensitive])
        }
        out = redactMachineNames(out, in: context)
        // After the machine's names, so this Mac's own MagicDNS name reads as the machine. A
        // peer's is device.tailnet.ts.net, and the tailnet's name identifies the account.
        if captured {
            out = out.replacingOccurrences(
                of: "(?<![\\w.-])[a-z0-9-]+(?:\\.[a-z0-9-]+)*\\.ts\\.net(?![\\w-]|\\.[\\w-])",
                with: "<tailnet-device>", options: [.regularExpression, .caseInsensitive])
        }
        out = redactUsername(out, in: context)
        if captured { out = redactFolders(out) }
        return Self.redactAddresses(out)
    }

    /// Where a text can say it is this Mac. A host is, only when all of it is one of the Mac's
    /// names: "dev.azure.com" is not the Mac called dev. A process's name is its author's, so
    /// a Mac's name in it is a coincidence. Edited instructions read as prose: the name matches
    /// as a word or a first label, so "Apple Development" and "pages.dev" stay whole on a Mac
    /// called dev and "dev.lan" reads <machine>.lan. Either apostrophe matches: macOS stores
    /// a curly one in the computer name, and other text often has a straight one.
    private func redactMachineNames(_ text: String, in context: Context) -> String {
        let (before, after): (String, String)
        switch context {
        case .program, .launchItem: return text
        case .host: (before, after) = ("(?<![A-Za-z0-9.-])", "(?![A-Za-z0-9-]|\\.[A-Za-z0-9-])")
        case .instructions: (before, after) = ("(?<![A-Za-z0-9-])(?<![A-Za-z0-9-]\\.)", "(?![A-Za-z0-9-])")
        }
        var out = text
        for name in machineNames.sorted(by: { $0.count > $1.count }) {
            let escaped = NSRegularExpression.escapedPattern(for: name)
                .replacingOccurrences(of: "['’]", with: "['’]", options: .regularExpression)
            out = out.replacingOccurrences(of: before + escaped + after, with: "<machine>", options: [.regularExpression, .caseInsensitive])
        }
        return out
    }

    /// Another account's folder names that account, and a disk's name is the user's own words.
    /// /Users/Shared is no account. A mounted disk is found by its whole name; any other path
    /// under /Volumes loses one word, since text cannot show where a name with spaces ends.
    private func redactFolders(_ text: String) -> String {
        var out = text
        for name in volumeNames.sorted(by: { $0.count > $1.count }) {
            out = out.replacingOccurrences(
                of: "(?i)(?<![\\w.-])/Volumes/" + NSRegularExpression.escapedPattern(for: name) + "(?![\\w.~@+-])",
                with: "/Volumes/<volume>", options: .regularExpression)
        }
        return out
            .replacingOccurrences(of: "(?i)(?<![\\w.-])/Volumes/[^\\s/\",;:()<]+", with: "/Volumes/<volume>", options: .regularExpression)
            .replacingOccurrences(of: "(?i)(?<![\\w.-])/Users/(?!Shared(?![\\w.~@+-]))[\\w.~@+-]+", with: "/Users/<other-user>", options: .regularExpression)
    }

    /// The login matches only as written, so the login "code" leaves the app "Code" alone.
    /// In a host it matches only as a whole name, so "mail.google.com" and
    /// "mail-attachment.example" stay whole for a user called mail. Elsewhere the username
    /// never matches as a label of a dotted name. A dot that ends a sentence does not join a
    /// label.
    ///
    /// A login of one or two letters would match ordinary text ("-e"), so it goes only where
    /// a login stands: before an "@" ("e@ttys003") and first in a process title ("postgres: e
    /// db"). Where it appears in a path the home replacement covers it; the facts built for a
    /// prompt never carry it as "you (e)" (UserName.describeForModel).
    private func redactUsername(_ text: String, in context: Context) -> String {
        guard !username.isEmpty else { return text }
        let login = NSRegularExpression.escapedPattern(for: username)
        if username.count >= 3 {
            let pattern: String
            switch context {
            case .host: pattern = "(?<![\\w.-])" + login + "(?![\\w-]|\\.[\\w-])"
            case .launchItem: pattern = "\\b" + login + "\\b"
            case .program, .instructions: pattern = "(?<![\\w-]\\.)\\b" + login + "\\b(?!\\.[\\w-])"
            }
            return text.replacingOccurrences(of: pattern, with: "<user>", options: .regularExpression)
        }
        if context == .instructions { return text }
        let replaced = text
            .replacingOccurrences(of: "(?<![\\w.+-])" + login + "(?=@)", with: "<user>", options: .regularExpression)
            .replacingOccurrences(of: "(?m)^([\\w.-]+: )" + login + "(?=\\s|$)", with: "$1<user>", options: .regularExpression)
        if context != .launchItem { return replaced }
        return replaced.replacingOccurrences(
            of: "(?<![\\w-])" + login + "(?=\\.[\\w-])|(?<=[\\w-]\\.)" + login + "(?![\\w-])",
            with: "<user>", options: .regularExpression)
    }

    /// Replaces private and local IP addresses only.
    static func redactAddresses(_ text: String) -> String {
        redactIPv6(redactIPv4(text))
    }

    private static let ipv4 = try! NSRegularExpression(
        pattern: "\\b(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})\\b")

    /// An address spelled with hyphens in a host name ("ip-10-0-1-5.ec2.internal"): exactly
    /// four numbers, so a longer run of them is not read as one.
    private static let hyphenatedIPv4 = try! NSRegularExpression(
        pattern: "(?<!\\d)(?<!\\d-)(\\d{1,3})-(\\d{1,3})-(\\d{1,3})-(\\d{1,3})(?!-?\\d)")

    /// RFC 1918, loopback, link-local and CGNAT ranges.
    static func isPrivateIPv4(_ octets: [Int]) -> Bool {
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true
        default: return false
        }
    }

    private static func redactIPv4(_ text: String) -> String {
        [ipv4, hyphenatedIPv4].reduce(text) { text, form in
            let ns = text as NSString
            var out = text
            for match in form.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
                let octets = (1...4).compactMap { Int(ns.substring(with: match.range(at: $0))) }
                guard isPrivateIPv4(octets) else { continue }
                out = (out as NSString).replacingCharacters(in: match.range, with: "<private-ip>")
            }
            return out
        }
    }

    /// Link-local (fe80::/10), unique local (fc00::/7) and loopback (::1).
    private static let ipv6 = try! NSRegularExpression(
        pattern: "(?i)\\b(?:f[cd][0-9a-f]{2}|fe[89ab][0-9a-f])(?::[0-9a-f]{0,4}){1,7}(?:%[a-z0-9]+)?|(?<![0-9a-f:])::1\\b")

    private static func redactIPv6(_ text: String) -> String {
        ipv6.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: "<private-ip>")
    }
}
