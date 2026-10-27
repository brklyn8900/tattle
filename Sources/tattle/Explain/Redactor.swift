import Foundation

/// Replaces what would identify this Mac or its user before a prompt leaves the machine:
/// the home path, the username, private and local IP addresses, and the machine's names.
struct Redactor: Sendable {
    var home: String
    var username: String
    var machineNames: [String]

    static var current: Redactor {
        let host = Host.current()
        var names = ([host.localizedName, host.name] + host.names)
            .compactMap { $0 }
            .filter { !$0.isEmpty && $0 != "localhost" }
        // The router's DNS knows the Bonjour name bare and as name.lan; Host gives only
        // name.local. The bare name covers name.lan, which reads <machine>.lan.
        for name in names where name.hasSuffix(".local") {
            names.append(String(name.dropLast(".local".count)))
        }
        return Redactor(
            home: NSHomeDirectory(),
            username: NSUserName(),
            machineNames: names)
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
        // "Apple Development" stays whole.
        for name in machineNames.sorted(by: { $0.count > $1.count }) {
            out = out.replacingOccurrences(
                of: "(?<![A-Za-z0-9-])" + NSRegularExpression.escapedPattern(for: name) + "(?![A-Za-z0-9-])",
                with: "<machine>", options: [.regularExpression, .caseInsensitive])
        }
        // A one- or two-letter username would match ordinary text ("-e"). Where it appears
        // in a path the home replacement covers it; the facts built for a prompt never
        // carry the login (UserName.describeForModel).
        if username.count >= 3 {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: username) + "\\b"
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
