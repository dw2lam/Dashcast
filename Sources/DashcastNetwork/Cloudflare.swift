import Foundation

/// Minimal Cloudflare v4 API client: find the zone, then create/update the car's A record.
struct CloudflareClient {
    var token: String
    var session: URLSession
    var baseURL = URL(string: "https://api.cloudflare.com/client/v4")!

    struct DNSRecord: Codable, Equatable {
        var id: String
        var type: String
        var name: String
        var content: String
        var proxied: Bool?
        var ttl: Int?
    }


    private struct Zone: Decodable { var id: String; var name: String }
    private struct Message: Decodable { var code: Int?; var message: String }
    private struct Envelope<T: Decodable>: Decodable {
        var success: Bool
        var errors: [Message]?
        var result: T?
    }
    private struct Deleted: Decodable { var id: String }

    // MARK: Request construction (pure)

    func makeRequest(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func zoneLookupRequest(zone: String) -> URLRequest {
        makeRequest("GET", "zones", query: [URLQueryItem(name: "name", value: zone)])
    }

    func recordLookupRequest(zoneID: String, name: String) -> URLRequest {
        makeRequest("GET", "zones/\(zoneID)/dns_records",
                    query: [URLQueryItem(name: "type", value: "A"), URLQueryItem(name: "name", value: name)])
    }

    static func recordBody(name: String, address: String) -> Data {
        let body: [String: Any] = [
            "type": "A",
            "name": name,
            "content": address,
            "ttl": 300,
            "proxied": false,
            "comment": "Dashcast: car-browser stream address (lo0 alias on the Mac)",
        ]
        return try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    func createRequest(zoneID: String, name: String, address: String) -> URLRequest {
        makeRequest("POST", "zones/\(zoneID)/dns_records", body: Self.recordBody(name: name, address: address))
    }

    func updateRequest(zoneID: String, recordID: String, name: String, address: String) -> URLRequest {
        makeRequest("PUT", "zones/\(zoneID)/dns_records/\(recordID)", body: Self.recordBody(name: name, address: address))
    }

    func deleteRequest(zoneID: String, recordID: String) -> URLRequest {
        makeRequest("DELETE", "zones/\(zoneID)/dns_records/\(recordID)")
    }

    // MARK: Calls

    private func send<T: Decodable>(_ request: URLRequest, as: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data) else {
            throw NetworkError.cloudflare("HTTP \(status) from \(request.httpMethod ?? "") \(request.url?.path ?? "")")
        }
        guard envelope.success, let result = envelope.result else {
            let messages = (envelope.errors ?? []).map { m in m.code.map { "\(m.message) (\($0))" } ?? m.message }
            var text = messages.isEmpty ? "HTTP \(status)" : messages.joined(separator: "; ")
            if status == 401 || status == 403 || (envelope.errors ?? []).contains(where: { [9109, 10000].contains($0.code ?? 0) }) {
                text += ". Check the token has Zone → DNS → Edit and Zone → Zone → Read on davidlam.online."
            }
            throw NetworkError.cloudflare(text)
        }
        return result
    }

    func zoneID(named zone: String) async throws -> String {
        let zones = try await send(zoneLookupRequest(zone: zone), as: [Zone].self)
        guard let match = zones.first(where: { $0.name == zone }) ?? zones.first else {
            throw NetworkError.zoneNotFound(zone)
        }
        return match.id
    }

    func aRecords(zoneID: String, name: String) async throws -> [DNSRecord] {
        try await send(recordLookupRequest(zoneID: zoneID, name: name), as: [DNSRecord].self)
            .filter { $0.type == "A" && $0.name.lowercased() == name.lowercased() }
    }

    /// Makes `name` a single DNS-only A record → `address`, TTL 300.
    /// Extra A records for the same name are removed (the car would otherwise pick one at random).
    @discardableResult
    func ensureARecord(zone: String, name: String, address: String) async throws -> DNSRecordChange {
        let zoneID = try await zoneID(named: zone)
        let records = try await aRecords(zoneID: zoneID, name: name)
        guard let first = records.first else {
            _ = try await send(createRequest(zoneID: zoneID, name: name, address: address), as: DNSRecord.self)
            return .created
        }
        for extra in records.dropFirst() {
            _ = try await send(deleteRequest(zoneID: zoneID, recordID: extra.id), as: Deleted.self)
        }
        if first.content == address, first.proxied == false, first.ttl == 300, records.count == 1 {
            return .unchanged
        }
        if first.content == address, first.proxied == false, first.ttl == 300 {
            return .updated // only duplicates were removed
        }
        _ = try await send(updateRequest(zoneID: zoneID, recordID: first.id, name: name, address: address), as: DNSRecord.self)
        return .updated
    }
}

/// DNS-over-HTTPS (JSON API) — what the public internet says the car hostname resolves to.
struct DoHClient {
    var session: URLSession
    var endpoint = URL(string: "https://cloudflare-dns.com/dns-query")!

    struct Answer: Equatable, Sendable {
        /// DNS RCODE: 0 NOERROR, 3 NXDOMAIN.
        var status: Int
        var addresses: [String]
    }

    private struct Response: Decodable {
        struct Record: Decodable { var name: String; var type: Int; var data: String }
        var Status: Int
        var Answer: [Record]?
    }

    func request(name: String) -> URLRequest {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "type", value: "A")]
        var request = URLRequest(url: components.url!)
        request.setValue("application/dns-json", forHTTPHeaderField: "accept")
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    func queryA(_ name: String) async throws -> Answer {
        let (data, response) = try await session.data(for: request(name: name))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw NetworkError.cloudflare("DNS-over-HTTPS returned HTTP \(status)") }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return Answer(status: decoded.Status,
                      addresses: (decoded.Answer ?? []).filter { $0.type == 1 }.map(\.data))
    }
}
