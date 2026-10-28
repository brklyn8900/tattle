import SystemConfiguration

/// The global state alone is not enough: a VPN or Tailscale puts its own resolver there and
/// forwards to the interface's servers, whose replies are what the capture sees.
struct SystemDNS {
    var servers: Set<IPAddress>
    var domains: [String]

    static var current: SystemDNS {
        guard let store = SCDynamicStoreCreate(nil, "Tattle" as CFString, nil, nil),
              let states = SCDynamicStoreCopyMultiple(
                  store, ["State:/Network/Global/DNS"] as CFArray,
                  ["State:/Network/Service/.*/DNS"] as CFArray) as? [String: [String: Any]]
        else { return SystemDNS(states: [:]) }
        return SystemDNS(states: states)
    }

    init(states: [String: [String: Any]]) {
        servers = Set(states.values.flatMap { $0["ServerAddresses"] as? [String] ?? [] }.compactMap(IPAddress.init(text:)))
        let domains = states.values.flatMap { ($0["SearchDomains"] as? [String] ?? []) + [$0["DomainName"] as? String].compactMap { $0 } }
            .map { domain in
                var name = domain.lowercased()
                while name.hasSuffix(".") { name.removeLast() }
                return name
            }
        self.domains = Set(domains).subtracting([""]).sorted()
    }
}
