import DashcastContracts
import XCTest
@testable import DashcastNetwork

final class HostnameValidationTests: XCTestCase {
    private func normalized(_ raw: String) -> String? { try? OwnDomain.normalize(raw).get() }

    private func reason(_ raw: String) -> String? {
        if case .failure(let error) = OwnDomain.normalize(raw) { return error.reason }
        return nil
    }

    func testAcceptsAndNormalizesFQDNs() {
        XCTAssertEqual(normalized("car.example.com"), "car.example.com")
        XCTAssertEqual(normalized("  Car.Example.COM \n"), "car.example.com")
        XCTAssertEqual(normalized("https://car.example.com/"), "car.example.com")
        XCTAssertEqual(normalized("http://tesla.home.example.co.uk"), "tesla.home.example.co.uk")
        XCTAssertEqual(normalized("car.example.com."), "car.example.com", "trailing root dot")
        XCTAssertEqual(normalized("xn--bcher-kva.example"), "xn--bcher-kva.example")
        XCTAssertEqual(normalized("my-car-1.example.com"), "my-car-1.example.com")
        XCTAssertEqual(normalized("example.com"), "example.com", "a zone apex is allowed")
    }

    func testRejectsWhatIsNotAHostname() {
        XCTAssertEqual(reason(""), "Enter a hostname, like car.yourdomain.com.")
        XCTAssertEqual(reason("localhost"), "Use a full name on your domain, like car.yourdomain.com.")
        XCTAssertEqual(reason("203.0.113.77"), "That’s an IP address; enter a hostname.")
        XCTAssertNotNil(reason("bücher.example"))
        XCTAssertNotNil(reason("car..example.com"))
        XCTAssertNotNil(reason(".example.com"))
        XCTAssertNotNil(reason("-car.example.com"))
        XCTAssertNotNil(reason("car-.example.com"))
        XCTAssertNotNil(reason("car_1.example.com"))
        XCTAssertNotNil(reason("*.example.com"))
        XCTAssertNotNil(reason("car.example.com:443"))
        XCTAssertNotNil(reason("car.example.com/path"))
        XCTAssertNotNil(reason("user@car.example.com"))
        XCTAssertNotNil(reason("car example.com"))
        XCTAssertNotNil(reason(String(repeating: "a", count: 64) + ".example.com"), "63-character label limit")
        XCTAssertNotNil(reason(Array(repeating: "abcdefghi", count: 26).joined(separator: ".") + ".com"), "253-character limit")
    }
}

final class OwnDomainManagerTests: XCTestCase {
    @MainActor
    func testDomainIsPersistedValidatedAndReported() async throws {
        let world = FakeWorld()
        world.reachable = false
        let environment = makeEnvironment(world: world)
        let manager = NetworkManager(environment: environment)
        XCTAssertNil(manager.ownDomain)
        var status = await manager.currentStatus()
        XCTAssertNil(status.domain)

        try manager.setOwnDomain(OwnDomain(hostname: " HTTPS://Car.Example.com/ ", provider: .manual))
        XCTAssertEqual(manager.ownDomain, OwnDomain(hostname: "car.example.com", provider: .manual))
        status = await manager.currentStatus()
        XCTAssertEqual(status.domain, OwnDomain(hostname: "car.example.com", provider: .manual))
        XCTAssertEqual(NetworkManager(environment: environment).ownDomain?.hostname, "car.example.com", "kept in UserDefaults")

        XCTAssertThrowsError(try manager.setOwnDomain(OwnDomain(hostname: "not a host", provider: .cloudflare))) { error in
            guard case NetworkError.invalidHostname = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(manager.ownDomain?.hostname, "car.example.com", "a bad name leaves the old one")

        try manager.setOwnDomain(nil)
        XCTAssertNil(manager.ownDomain)
        status = await manager.currentStatus()
        XCTAssertNil(status.domain)
    }

    /// Without a domain nothing in the status or the guidance names a hostname: the car gets the
    /// service address, and no DoH lookup happens.
    @MainActor
    func testNoDomainMeansNoHostnameAnywhere() async throws {
        let world = FakeWorld()
        world.snapshot = InterfaceSnapshot(
            addresses: [InterfaceAddress(name: "lo0", address: svc), InterfaceAddress(name: "bridge100", address: "192.168.2.1")],
            primaryInterface: "en7", kinds: ["bridge100": .bridge])
        try world.installHelper()
        StubURLProtocol.reset { request, _ in XCTFail("no lookups without a domain: \(request)"); return (500, Data()) }
        let manager = NetworkManager(environment: makeEnvironment(world: world))
        let status = await manager.currentStatus()
        XCTAssertFalse(status.dnsRecordOK)
        XCTAssertNil(status.certificateExpiry)
        XCTAssertEqual(StubURLProtocol.recorded.count, 0)
        XCTAssertTrue(status.summary.contains("Ready (HTTP mode): open http://\(svc) in the car."), status.summary)

        let texts = [status.summary, manager.routerSetupScript(macLANAddress: "192.168.8.20")]
            + [Topology.macHotspot, .router, .phoneHotspot, .offline].map(NetworkManager.explain)
        for text in texts {
            XCTAssertFalse(text.contains("https://"), text)
            XCTAssertFalse(text.contains("For HTTPS"), text)
            XCTAssertFalse(text.lowercased().contains("davidlam"), text)
            XCTAssertNil(Self.hostname(in: text), text)
        }
    }

    /// The first dotted name that isn't a connectivity check, the router brand or the script's file name.
    static func hostname(in text: String) -> String? {
        let allowed = Set(NetworkManager.connectivityCheckNames + ["gl.inet", "dashcast-router.sh"])
        let pattern = try! NSRegularExpression(pattern: #"\b[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}\b"#, options: [.caseInsensitive])
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
            .first { !allowed.contains($0.lowercased()) }
    }

    @MainActor
    func testProvisionNeedsACloudflareDomain() async throws {
        let secrets = InMemorySecretStore()
        secrets.values["cloudflare-api-token"] = "tok"
        StubURLProtocol.reset { request, _ in XCTFail("no Cloudflare calls: \(request)"); return (500, Data()) }
        let manager = NetworkManager(environment: makeEnvironment(world: FakeWorld(), secrets: secrets))
        do {
            try await manager.provisionCertificate()
            XCTFail("expected noOwnDomain")
        } catch NetworkError.noOwnDomain {}
        do {
            try await manager.ensureDNSRecord()
            XCTFail("expected noOwnDomain")
        } catch NetworkError.noOwnDomain {}

        try manager.setOwnDomain(OwnDomain(hostname: "car.example.com", provider: .manual))
        do {
            try await manager.provisionCertificate()
            XCTFail("expected Cloudflare-only")
        } catch NetworkError.invalidArgument(let message) {
            XCTAssertTrue(message.contains("Import a certificate for car.example.com"), message)
        }
        XCTAssertEqual(StubURLProtocol.recorded.count, 0)
    }

    /// The record lands in whichever zone holds the configured hostname.
    @MainActor
    func testEnsureDNSRecordUsesTheConfiguredHostname() async throws {
        let secrets = InMemorySecretStore()
        secrets.values["cloudflare-api-token"] = "tok"
        let manager = NetworkManager(environment: makeEnvironment(world: FakeWorld(), secrets: secrets))
        try manager.setOwnDomain(OwnDomain(hostname: "tesla.garage.example.net", provider: .cloudflare))
        StubURLProtocol.reset { request, _ in
            let ok: (Any) -> (Int, Data) = { (200, try! JSONSerialization.data(withJSONObject: ["success": true, "errors": [], "result": $0])) }
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/client/v4/zones"):
                return ok(request.url?.query == "name=example.net" ? [["id": "znet", "name": "example.net"]] : [])
            case ("GET", "/client/v4/zones/znet/dns_records"): return ok([])
            case ("POST", "/client/v4/zones/znet/dns_records"):
                return ok(["id": "r", "type": "A", "name": "tesla.garage.example.net", "content": svc, "proxied": false, "ttl": 300])
            default: return (404, Data())
            }
        }
        let change = try await manager.ensureDNSRecord()
        XCTAssertEqual(change, .created)
        let calls = StubURLProtocol.recorded
        XCTAssertEqual(calls.compactMap(\.request.url?.query),
                       ["name=tesla.garage.example.net", "name=garage.example.net", "name=example.net",
                        "type=A&name=tesla.garage.example.net"])
        XCTAssertTrue(calls.allSatisfy { $0.request.value(forHTTPHeaderField: "Authorization") == "Bearer tok" })
        let post = try XCTUnwrap(calls.last)
        XCTAssertEqual(post.request.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(post.body)) as? [String: Any])
        XCTAssertEqual(body["type"] as? String, "A")
        XCTAssertEqual(body["name"] as? String, "tesla.garage.example.net")
        XCTAssertEqual(body["content"] as? String, svc)
        XCTAssertEqual(body["proxied"] as? Bool, false)
        XCTAssertEqual(body["ttl"] as? Int, 300)
    }

    /// The responder answers the configured name (and only it), following changes while it runs.
    @MainActor
    func testLocalDNSAnswersTheConfiguredName() async throws {
        let world = FakeWorld()
        world.reachable = false
        let manager = NetworkManager(environment: makeEnvironment(world: world))
        XCTAssertEqual(manager.localDNSNames, NetworkManager.connectivityCheckNames)
        await manager.startLocalServices()
        defer { Task { await manager.stopLocalServices() } }
        let port = try XCTUnwrap(manager.localDNSEndpoint?.split(separator: ":").last.map(String.init))

        func dig(_ name: String) async throws -> String {
            let result = try await ProcessRunner.run("/usr/bin/dig", ["@127.0.0.1", "-p", port, "+time=2", "+tries=1", name, "A"], timeout: 10)
            return result.stdout
        }
        func answeredLocally(_ name: String) async throws -> Bool {
            let out = try await dig(name)
            return out.contains("flags: qr aa") && out.contains("IN\tA\t\(svc)")
        }

        // No domain: only the connectivity checks are local (no upstreams → SERVFAIL for the rest).
        let before = try await dig("car.example.com")
        XCTAssertTrue(before.contains("status: SERVFAIL"), before)
        let connman = try await answeredLocally("connman.vn.tesla.services")
        XCTAssertTrue(connman)

        try manager.setOwnDomain(OwnDomain(hostname: "car.example.com", provider: .cloudflare))
        XCTAssertEqual(manager.localDNSNames.first, "car.example.com")
        let configured = try await answeredLocally("car.example.com")
        XCTAssertTrue(configured)

        try manager.setOwnDomain(OwnDomain(hostname: "tesla.example.org", provider: .manual))
        let renamed = try await answeredLocally("tesla.example.org")
        XCTAssertTrue(renamed)
        let old = try await dig("car.example.com")
        XCTAssertTrue(old.contains("status: SERVFAIL"), "the previous name is no longer answered: \(old)")

        try manager.setOwnDomain(nil)
        let removed = try await dig("tesla.example.org")
        XCTAssertTrue(removed.contains("status: SERVFAIL"), removed)
    }
}
