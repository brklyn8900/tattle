import XCTest
@testable import tattle

final class SystemDNSTests: XCTestCase {
    func testReadsTheGlobalStateAndEveryService() {
        let dns = SystemDNS(states: [
            "State:/Network/Global/DNS": [
                "ServerAddresses": ["100.100.100.100"], "SearchDomains": ["tail1234.ts.net"],
            ],
            "State:/Network/Service/A1B2/DNS": [
                "ServerAddresses": ["192.168.1.1", "fe80::1%en0", "not-an-address"], "DomainName": "lan",
            ],
        ])
        XCTAssertEqual(dns.servers, [
            IPAddress(text: "100.100.100.100")!, IPAddress(text: "192.168.1.1")!, IPAddress(text: "fe80::1")!,
        ])
        XCTAssertEqual(dns.domains, ["lan", "tail1234.ts.net"])
    }

    func testDomainsLoseTrailingDotsEmptiesAndRepeats() {
        let dns = SystemDNS(states: [
            "State:/Network/Global/DNS": ["SearchDomains": ["", ".", "tail1234.ts.net.", "Tail1234.TS.net"]],
            "State:/Network/Service/A1B2/DNS": ["DomainName": "lan."],
        ])
        XCTAssertEqual(dns.domains, ["lan", "tail1234.ts.net"])
    }
}
