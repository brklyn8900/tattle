import Foundation
import SystemConfiguration

/// Replaces what would identify this Mac or its user before a prompt leaves the machine:
/// the home path, the username, private and local IP addresses, and the machine's names.
struct Redactor: Sendable {
    var home: String
    var username: String
    var machineNames: [String]

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
                hostName: hostName, domains: SystemDNS.current.domains))
    }

    /// The computer name, the Bonjour name bare and with .local, the hostname, and each host
    /// label under every search domain, which is how Tailscale and the router's DHCP name
    /// this Mac. The bare name covers name.lan, which reads <machine>.lan.
    static func machineNames(computerName: String?, localHostName: String?, hostName: String?, domains: [String]) -> [String] {
        let bare = [computerName, localHostName, localHostName.map { $0 + ".local" }, hostName].compactMap { $0 }
        let labels = [localHostName, hostName.map(firstLabel)].compactMap { $0 }
        let names = bare + labels.flatMap { label in domains.map { label + "." + $0 } }
        var seen = Set<String>()
        return names.filter { name in
            let first = firstLabel(name).lowercased()
            return first != "" && first != "localhost" && seen.insert(name.lowercased()).inserted
        }
    }

    private static func firstLabel(_ name: String) -> String {
        String(name.prefix { $0 != "." })
    }

    func redact(_ text: String) -> String {
        var out = text
        // Home path before username: the path contains the username.
        // On a path boundary: home "/Users/u" must not take the front off "/Users/eve/...".
        if !home.isEmpty {
            let pattern = NSRegularExpression.escapedPattern(for: home) + "(?![\\w.~@+-])"
            out = out.replacingOccurrences(of: pattern, with: "<home>", options: .regularExpression)
        }
        // A machine name matches only as a whole host name, so on a Mac called dev
        // "Apple Development" stays whole. It matches only as the first label, so
        // "pages.dev" stays whole and "dev.lan" reads <machine>.lan.
        for name in machineNames.sorted(by: { $0.count > $1.count }) {
            out = out.replacingOccurrences(
                of: "(?<![A-Za-z0-9-])(?<![A-Za-z0-9-]\\.)" + NSRegularExpression.escapedPattern(for: name) + "(?![A-Za-z0-9-])",
                with: "<machine>", options: [.regularExpression, .caseInsensitive])
        }
        // A one- or two-letter username would match ordinary text ("-e"). Where it appears
        // in a path the home replacement covers it; the facts built for a prompt never
        // carry the login (UserName.describeForModel). The username never matches as a label
        // of a dotted name, so "mail.google.com" stays whole for a user called mail. A dot that
        // ends a sentence does not join a label.
        if username.count >= 3 {
            let pattern = "(?<![\\w-]\\.)\\b" + NSRegularExpression.escapedPattern(for: username) + "\\b(?!\\.[\\w-])"
            out = out.replacingOccurrences(of: pattern, with: "<user>", options: .regularExpression)
        }
        return Self.redactAddresses(out)
    }

    /// Replaces private and local IP addresses only.
    static func redactAddresses(_ text: String) -> String {
        redactIPv6(redactIPv4(text))
    }

    private static let ipv4 = try! NSRegularExpression(
        pattern: "\\b(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})\\b")

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
        let ns = text as NSString
        var out = text
        for match in ipv4.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let octets = (1...4).compactMap { Int(ns.substring(with: match.range(at: $0))) }
            guard isPrivateIPv4(octets) else { continue }
            out = (out as NSString).replacingCharacters(in: match.range, with: "<private-ip>")
        }
        return out
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
