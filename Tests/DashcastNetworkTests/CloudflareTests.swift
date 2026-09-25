import XCTest
@testable import DashcastNetwork

final class CloudflareTests: XCTestCase {
    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    private func ok(_ result: Any) -> (Int, Data) { (200, json(["success": true, "errors": [], "messages": [], "result": result])) }
    private let zone = ["id": "zone123", "name": "example.com"]
    private func record(_ id: String, _ content: String, proxied: Bool = false, ttl: Int = 300) -> [String: Any] {
        ["id": id, "type": "A", "name": "car.example.com", "content": content, "proxied": proxied, "ttl": ttl]
    }
    /// Zone lookups by exact name: only example.com exists.
    private func zones(_ request: URLRequest) -> (Int, Data) {
        let name = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value
        return ok(name == "example.com" ? [zone] : [])
    }

    private func client() -> CloudflareClient {
        CloudflareClient(token: "tok_ABC", session: StubURLProtocol.session())
    }

    func testRequestConstruction() throws {
        let c = client()
        let zoneRequest = c.zoneLookupRequest(zone: "example.com")
        XCTAssertEqual(zoneRequest.httpMethod, "GET")
        XCTAssertEqual(zoneRequest.url?.absoluteString, "https://api.cloudflare.com/client/v4/zones?name=example.com")
        XCTAssertEqual(zoneRequest.value(forHTTPHeaderField: "Authorization"), "Bearer tok_ABC")

        let lookup = c.recordLookupRequest(zoneID: "zone123", name: "car.example.com")
        XCTAssertEqual(lookup.url?.absoluteString,
                       "https://api.cloudflare.com/client/v4/zones/zone123/dns_records?type=A&name=car.example.com")

        let create = c.createRequest(zoneID: "zone123", name: "car.example.com", address: svc)
        XCTAssertEqual(create.httpMethod, "POST")
        XCTAssertEqual(create.url?.absoluteString, "https://api.cloudflare.com/client/v4/zones/zone123/dns_records")
        XCTAssertEqual(create.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(create.httpBody)) as? [String: Any])
        XCTAssertEqual(body["type"] as? String, "A")
        XCTAssertEqual(body["name"] as? String, "car.example.com")
        XCTAssertEqual(body["content"] as? String, svc)
        XCTAssertEqual(body["ttl"] as? Int, 300)
        XCTAssertEqual(body["proxied"] as? Bool, false)

        let update = c.updateRequest(zoneID: "zone123", recordID: "rec9", name: "car.example.com", address: svc)
        XCTAssertEqual(update.httpMethod, "PUT")
        XCTAssertEqual(update.url?.absoluteString, "https://api.cloudflare.com/client/v4/zones/zone123/dns_records/rec9")
    }

    func testCreatesRecordWhenMissing() async throws {
        StubURLProtocol.reset { request, body in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/client/v4/zones"): return self.zones(request)
            case ("GET", "/client/v4/zones/zone123/dns_records"): return self.ok([])
            case ("POST", "/client/v4/zones/zone123/dns_records"): return self.ok(self.record("new1", svc))
            default: return (404, Data())
            }
        }
        let change = try await client().ensureARecord(name: "car.example.com", address: svc)
        XCTAssertEqual(change, .created)
        let calls = StubURLProtocol.recorded
        XCTAssertEqual(calls.map { "\($0.request.httpMethod!) \($0.request.url!.path)" + ($0.request.url!.query.map { "?\($0)" } ?? "") }, [
            "GET /client/v4/zones?name=car.example.com",
            "GET /client/v4/zones?name=example.com",
            "GET /client/v4/zones/zone123/dns_records?type=A&name=car.example.com",
            "POST /client/v4/zones/zone123/dns_records",
        ])
        XCTAssertTrue(calls.allSatisfy { $0.request.value(forHTTPHeaderField: "Authorization") == "Bearer tok_ABC" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(calls[3].body)) as? [String: Any])
        XCTAssertEqual(body["content"] as? String, svc)
        XCTAssertEqual(body["proxied"] as? Bool, false)
        XCTAssertEqual(body["ttl"] as? Int, 300)
    }

    func testUpdatesWrongRecordAndRemovesDuplicates() async throws {
        StubURLProtocol.reset { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/client/v4/zones"): return self.zones(request)
            case ("GET", "/client/v4/zones/zone123/dns_records"):
                return self.ok([self.record("r1", "192.168.2.1", proxied: true, ttl: 1), self.record("r2", "10.0.0.1")])
            case ("DELETE", "/client/v4/zones/zone123/dns_records/r2"): return self.ok(["id": "r2"])
            case ("PUT", "/client/v4/zones/zone123/dns_records/r1"): return self.ok(self.record("r1", svc))
            default: return (404, Data())
            }
        }
        let change = try await client().ensureARecord(name: "car.example.com", address: svc)
        XCTAssertEqual(change, .updated)
        let calls = StubURLProtocol.recorded.map { "\($0.request.httpMethod!) \($0.request.url!.lastPathComponent)" }
        XCTAssertEqual(calls, ["GET zones", "GET zones", "GET dns_records", "DELETE r2", "PUT r1"])
        let put = try XCTUnwrap(StubURLProtocol.recorded.last?.body)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: put) as? [String: Any])
        XCTAssertEqual(body["content"] as? String, svc)
        XCTAssertEqual(body["proxied"] as? Bool, false)
    }

    func testLeavesCorrectRecordAlone() async throws {
        StubURLProtocol.reset { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/client/v4/zones"): return self.zones(request)
            case ("GET", "/client/v4/zones/zone123/dns_records"): return self.ok([self.record("r1", svc)])
            default: return (500, Data())
            }
        }
        let change = try await client().ensureARecord(name: "car.example.com", address: svc)
        XCTAssertEqual(change, .unchanged)
        XCTAssertEqual(StubURLProtocol.recorded.count, 3)
    }

    func testAuthErrorIsExplained() async {
        StubURLProtocol.reset { _, _ in
            (403, self.json(["success": false, "errors": [["code": 10000, "message": "Authentication error"]], "result": NSNull()]))
        }
        do {
            _ = try await client().ensureARecord(name: "car.example.com", address: svc)
            XCTFail("expected an error")
        } catch NetworkError.cloudflare(let message) {
            XCTAssertTrue(message.contains("Authentication error (10000)"), message)
            XCTAssertTrue(message.contains("DNS → Edit"), message)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testMissingZone() async {
        StubURLProtocol.reset { _, _ in self.ok([]) }
        do {
            _ = try await client().zone(for: "car.example.com")
            XCTFail("expected zoneNotFound")
        } catch NetworkError.zoneNotFound(let hostname) {
            XCTAssertEqual(hostname, "car.example.com")
            XCTAssertTrue(NetworkError.zoneNotFound(hostname).localizedDescription.contains("Zone Resources include your domain"))
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(StubURLProtocol.recorded.compactMap(\.request.url?.query),
                       ["name=car.example.com", "name=example.com"], "every suffix, then give up")
    }

    func testZoneCandidatesFromSuffixes() {
        XCTAssertEqual(CloudflareClient.zoneCandidates(for: "car.example.com"), ["car.example.com", "example.com"])
        XCTAssertEqual(CloudflareClient.zoneCandidates(for: "Car.Home.Example.co.uk"),
                       ["car.home.example.co.uk", "home.example.co.uk", "example.co.uk", "co.uk"])
        XCTAssertEqual(CloudflareClient.zoneCandidates(for: "example.com"), ["example.com"])
        XCTAssertEqual(CloudflareClient.zoneCandidates(for: "localhost"), [])
    }

    /// A delegated subdomain zone wins over its parent: the most specific suffix is asked first.
    func testZoneDiscoveryPrefersTheMostSpecificZone() async throws {
        StubURLProtocol.reset { request, _ in
            let name = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value
            switch name {
            case "home.example.com": return self.ok([["id": "sub", "name": "home.example.com"]])
            case "example.com": return self.ok([["id": "apex", "name": "example.com"]])
            default: return self.ok([])
            }
        }
        let zone = try await client().zone(for: "car.home.example.com")
        XCTAssertEqual(zone, CloudflareClient.Zone(id: "sub", name: "home.example.com"))
        XCTAssertEqual(StubURLProtocol.recorded.compactMap(\.request.url?.query),
                       ["name=car.home.example.com", "name=home.example.com"])
    }

    /// A zone lookup that returns a different zone (Cloudflare matches names exactly, but be strict).
    func testZoneMustMatchTheCandidateName() async {
        StubURLProtocol.reset { _, _ in self.ok([["id": "other", "name": "unrelated.example"]]) }
        do {
            _ = try await client().zone(for: "car.example.com")
            XCTFail("expected zoneNotFound")
        } catch NetworkError.zoneNotFound {
        } catch {
            XCTFail("\(error)")
        }
    }

    // MARK: DNS-over-HTTPS

    func testDoHRequestAndParsing() async throws {
        let doh = DoHClient(session: StubURLProtocol.session())
        let request = doh.request(name: "car.example.com")
        XCTAssertEqual(request.url?.absoluteString, "https://cloudflare-dns.com/dns-query?name=car.example.com&type=A")
        XCTAssertEqual(request.value(forHTTPHeaderField: "accept"), "application/dns-json")

        StubURLProtocol.reset { _, _ in
            (200, self.json(["Status": 0, "Answer": [
                ["name": "car.example.com", "type": 5, "TTL": 300, "data": "alias.example."],
                ["name": "car.example.com", "type": 1, "TTL": 300, "data": svc],
            ]]))
        }
        let answer = try await doh.queryA("car.example.com")
        XCTAssertEqual(answer, DoHClient.Answer(status: 0, addresses: [svc]))

        // The real NXDOMAIN shape cloudflare-dns.com returns for a missing name (recorded 2026-09-23).
        StubURLProtocol.reset { _, _ in
            (200, Data(#"{"Status":3,"TC":false,"RD":true,"RA":true,"AD":false,"CD":false,"Question":[{"name":"car.example.com","type":1}],"Authority":[{"name":"example.com","type":6,"TTL":1800,"data":"julio.ns.cloudflare.com. dns.cloudflare.com. 2415332167 10000 2400 604800 1800"}]}"#.utf8))
        }
        let missing = try await doh.queryA("car.example.com")
        XCTAssertEqual(missing, DoHClient.Answer(status: 3, addresses: []))
    }
}
