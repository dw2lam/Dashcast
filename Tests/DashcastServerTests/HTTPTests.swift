import DashcastContracts
import XCTest
@testable import DashcastServer

final class HTTPParserTests: XCTestCase {
    func parse(_ raw: String) -> HTTPParseResult { HTTPRequestParser.parse(Array(raw.utf8)) }

    func testSimpleGet() throws {
        let raw = "GET /index.html?x=1&y=%20 HTTP/1.1\r\nHost: localhost:8080\r\nUser-Agent: test\r\nAccept: */*\r\n\r\n"
        guard case .complete(let r, let consumed) = parse(raw) else { return XCTFail() }
        XCTAssertEqual(consumed, raw.utf8.count)
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/index.html")
        XCTAssertEqual(r.query, "x=1&y=%20")
        XCTAssertEqual(r.version, "HTTP/1.1")
        XCTAssertEqual(r.headers["host"], "localhost:8080")
        XCTAssertEqual(r.headers["USER-AGENT"], "test")
        XCTAssertTrue(r.keepAlive)
        XCTAssertFalse(r.isWebSocketUpgrade)
    }

    func testIncompleteUntilBlankLine() {
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nHost: a\r\n"), .incomplete)
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nHo"), .incomplete)
        XCTAssertEqual(parse(""), .incomplete)
    }

    func testPipelinedRequestsConsumeOnlyTheFirst() throws {
        let first = "GET /a HTTP/1.1\r\nHost: x\r\n\r\n"
        let raw = first + "GET /b HTTP/1.1\r\nHost: x\r\n\r\n"
        guard case .complete(let r, let consumed) = parse(raw) else { return XCTFail() }
        XCTAssertEqual(r.path, "/a")
        XCTAssertEqual(consumed, first.utf8.count)
    }

    func testBodyIsWaitedForAndSkipped() {
        let head = "POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\n"
        XCTAssertEqual(parse(head + "ab"), .incomplete)
        guard case .complete(_, let consumed) = parse(head + "abcdeGET") else { return XCTFail() }
        XCTAssertEqual(consumed, head.utf8.count + 5)
    }

    func testBareLFAndLeadingBlankLines() {
        guard case .complete(let r, _) = parse("\r\nGET /healthz HTTP/1.0\nHost: x\n\n") else { return XCTFail() }
        XCTAssertEqual(r.path, "/healthz")
        XCTAssertFalse(r.keepAlive)   // HTTP/1.0 without keep-alive
    }

    func testMultiValueAndTokenHeaders() {
        guard case .complete(let r, _) = parse("GET /ws HTTP/1.1\r\nHost: x\r\nConnection: keep-alive, Upgrade\r\nUpgrade: WebSocket\r\nX: 1\r\nx: 2\r\n\r\n") else { return XCTFail() }
        XCTAssertTrue(r.isWebSocketUpgrade)
        XCTAssertEqual(r.headers["x"], "1, 2")
        XCTAssertEqual(r.headers.tokens("connection"), ["keep-alive", "upgrade"])
    }

    func testConnectionClose() {
        guard case .complete(let r, _) = parse("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n") else { return XCTFail() }
        XCTAssertFalse(r.keepAlive)
    }

    func testAbsoluteFormTarget() {
        guard case .complete(let r, _) = parse("GET http://connman.vn.tesla.services/check?a HTTP/1.1\r\nHost: connman.vn.tesla.services\r\n\r\n") else { return XCTFail() }
        XCTAssertEqual(r.path, "/check")
        XCTAssertEqual(r.query, "a")
    }

    func testInvalidRequests() {
        XCTAssertEqual(parse("GARBAGE\r\n\r\n"), .invalid(status: 400, reason: "Bad Request"))
        XCTAssertEqual(parse("GET / HTTP/2.0\r\n\r\n"), .invalid(status: 505, reason: "HTTP Version Not Supported"))
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nBad Header\r\n\r\n"), .invalid(status: 400, reason: "Bad Request"))
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nA: b\r\n folded\r\n\r\n"), .invalid(status: 400, reason: "Bad Request"))
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"), .invalid(status: 501, reason: "Not Implemented"))
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nContent-Length: 999999\r\n\r\n"), .invalid(status: 413, reason: "Content Too Large"))
        XCTAssertEqual(parse("GET noslash HTTP/1.1\r\n\r\n"), .invalid(status: 400, reason: "Bad Request"))
        let huge = "GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 20_000)
        XCTAssertEqual(parse(huge), .invalid(status: 431, reason: "Request Header Fields Too Large"))
    }

    func testResponseSerialization() {
        let r = HTTPResponse.text(200, "ok")
        let text = String(decoding: r.serialized(keepAlive: true), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 2\r\n"))
        XCTAssertTrue(text.contains("Cache-Control: no-store\r\n"))
        XCTAssertTrue(text.contains("Content-Type: text/plain; charset=utf-8\r\n"))
        XCTAssertTrue(text.contains("Connection: keep-alive\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\nok"))
        let head = String(decoding: r.serialized(includeBody: false, keepAlive: false), as: UTF8.self)
        XCTAssertTrue(head.hasSuffix("\r\n\r\n"))
        XCTAssertTrue(head.contains("Connection: close\r\n"))
    }

    func testHostHeaderParsing() {
        XCTAssertEqual(HTTPServer.hostName(fromHostHeader: "LocalHost:8080"), "localhost")
        XCTAssertEqual(HTTPServer.hostName(fromHostHeader: "car.example.com"), "car.example.com")
        XCTAssertEqual(HTTPServer.hostName(fromHostHeader: "[::1]:8080"), "::1")
        XCTAssertEqual(HTTPServer.hostName(fromHostHeader: "127.0.0.1"), "127.0.0.1")
        XCTAssertNil(HTTPServer.hostName(fromHostHeader: "evil.com:80x"))
        XCTAssertNil(HTTPServer.hostName(fromHostHeader: ""))
    }
}

/// Host-based routing (connectivity probes, :80 redirect, allowlists), tested on the pure router.
final class HTTPRoutingTests: XCTestCase {
    var clientDir: URL!
    var server: HTTPServer!

    final class NoopDelegate: WebSocketDelegate {
        func webSocketDidOpen(_ connection: ServerConnection) {}
        func webSocket(_ connection: ServerConnection, didReceiveText text: String) {}
        func webSocket(_ connection: ServerConnection, didReceivePong payload: Data) {}
        func webSocketDidDrain(_ connection: ServerConnection) {}
        func webSocketDidClose(_ connection: ServerConnection, reason: String) {}
    }
    let delegate = NoopDelegate()

    override func setUpWithError() throws {
        clientDir = FileManager.default.temporaryDirectory.appendingPathComponent("dashcast-client-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: clientDir.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Data("<!doctype html><title>client</title>".utf8).write(to: clientDir.appendingPathComponent("index.html"))
        try Data("console.log(1)".utf8).write(to: clientDir.appendingPathComponent("assets/app.js"))
        try Data("secret".utf8).write(to: clientDir.appendingPathComponent(".env"))
        server = HTTPServer(queue: DispatchQueue(label: "test"), pages: ClientPageProvider(directory: clientDir),
                            publicHostname: "car.example.com",
                            allowedHosts: ["localhost", "127.0.0.1", "::1", DashcastDefaults.serviceAddress])
        server.webSocketDelegate = delegate
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: clientDir)
    }

    func request(_ path: String, host: String?, method: String = "GET", extra: String = "") -> HTTPRequest {
        let raw = "\(method) \(path) HTTP/1.1\r\n" + (host.map { "Host: \($0)\r\n" } ?? "") + extra + "\r\n"
        guard case .complete(let r, _) = HTTPRequestParser.parse(Array(raw.utf8)) else { fatalError(raw) }
        return r
    }

    func response(_ action: HTTPAction) -> (HTTPResponse, close: Bool)? {
        if case .respond(let r, let close) = action { return (r, close) }
        return nil
    }

    func wire(_ r: HTTPResponse) -> String { String(decoding: r.serialized(keepAlive: false), as: UTF8.self) }

    // MARK: Connectivity probes

    func testTeslaConnManProbe() throws {
        for host in ["connman.vn.tesla.services", "CONNMAN.vn.tesla.services:80", "connman.vn.cloud.tesla.cn"] {
            for role in [ServerConnection.Role.plain, .app] {
                let (r, _) = try XCTUnwrap(response(server.route(request("/", host: host), role: role, isTLS: false)))
                XCTAssertEqual(r.status, 200, host)
                XCTAssertEqual(r.headers["X-ConnMan-Status"], "online")
                XCTAssertEqual(r.headers["Content-Type"], "text/html")
                XCTAssertEqual(String(data: r.body, encoding: .utf8), "<html><body>Connectivity OK</body></html>\n")
                let text = wire(r)
                XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
                XCTAssertTrue(text.contains("\r\nX-ConnMan-Status: online\r\n"))
                XCTAssertTrue(text.contains("\r\nContent-Type: text/html\r\n"))
            }
        }
    }

    func testTeslaProbeAnyPath() throws {
        let (r, _) = try XCTUnwrap(response(server.route(request("/generate_204?x=1", host: "connman.vn.tesla.services"), role: .plain, isTLS: false)))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.headers["X-ConnMan-Status"], "online")
    }

    func testAppleCaptiveProbe() throws {
        let (r, _) = try XCTUnwrap(response(server.route(request("/hotspot-detect.html", host: "captive.apple.com"), role: .plain, isTLS: false)))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.headers["Content-Type"], "text/html")
        XCTAssertEqual(String(data: r.body, encoding: .utf8), "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>")
        XCTAssertNil(r.headers["X-ConnMan-Status"])
    }

    func testProbesAreNotAnsweredOverTLS() throws {
        let (r, _) = try XCTUnwrap(response(server.route(request("/", host: "connman.vn.tesla.services"), role: .app, isTLS: true)))
        XCTAssertEqual(r.status, 403)
    }

    // MARK: :80 in HTTPS mode (redirect) and HTTP mode (serve)

    func testPlainListenerRedirectsOtherHostsToHTTPSRoot() throws {
        server.plainServesApp = false
        for host in ["example.com", "neverssl.com:80", DashcastDefaults.serviceAddress] {
            let (r, close) = try XCTUnwrap(response(server.route(request("/some/path?q", host: host), role: .plain, isTLS: false)))
            XCTAssertEqual(r.status, 301, host)
            XCTAssertEqual(r.headers["Location"], "https://car.example.com/")
            XCTAssertTrue(close)
        }
        let (noHost, _) = try XCTUnwrap(response(server.route(request("/x", host: nil), role: .plain, isTLS: false)))
        XCTAssertEqual(noHost.headers["Location"], "https://car.example.com/")
    }

    func testPlainListenerKeepsPathForOwnHostname() throws {
        server.plainServesApp = false
        let (r, _) = try XCTUnwrap(response(server.route(request("/index.html?v=2", host: "car.example.com"), role: .plain, isTLS: false)))
        XCTAssertEqual(r.status, 301)
        XCTAssertEqual(r.headers["Location"], "https://car.example.com/index.html?v=2")
    }

    func testHTTPModePlainListenerServesAppAndWebSocket() throws {
        // HTTP mode, as the service sets it up: no certificate, so no public hostname.
        server.plainServesApp = true
        server.publicHostname = nil
        for host in [DashcastDefaults.serviceAddress, "\(DashcastDefaults.serviceAddress):80"] {
            let (page, _) = try XCTUnwrap(response(server.route(request("/", host: host), role: .plain, isTLS: false)))
            XCTAssertEqual(page.status, 200, host)
            XCTAssertEqual(page.headers["Content-Type"], "text/html; charset=utf-8")
        }
        let (health, _) = try XCTUnwrap(response(server.route(request("/healthz", host: DashcastDefaults.serviceAddress), role: .plain, isTLS: false)))
        XCTAssertEqual(String(data: health.body, encoding: .utf8), "ok")
        let ws = "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nOrigin: http://\(DashcastDefaults.serviceAddress)\r\n"
        guard case .upgrade(let up) = server.route(request("/ws", host: DashcastDefaults.serviceAddress, extra: ws), role: .plain, isTLS: false) else {
            return XCTFail("HTTP mode must accept /ws on :80")
        }
        XCTAssertEqual(up.status, 101)
        // Connectivity probes still win.
        let (probe, _) = try XCTUnwrap(response(server.route(request("/", host: "connman.vn.tesla.services"), role: .plain, isTLS: false)))
        XCTAssertEqual(probe.headers["X-ConnMan-Status"], "online")
        // Stray names go to the car page over http (never served under a foreign Host).
        for host in ["example.com", "car.example.com"] {
            let (stray, close) = try XCTUnwrap(response(server.route(request("/x", host: host), role: .plain, isTLS: false)))
            XCTAssertEqual(stray.status, 301, host)
            XCTAssertEqual(stray.headers["Location"], "http://\(DashcastDefaults.serviceAddress)/", host)
            XCTAssertTrue(close)
        }
    }

    /// The certificate's hostname is accepted (Host and Origin) only while HTTPS mode has one.
    func testAllowedHostsFollowTheCertificateHostname() throws {
        let ws = "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nOrigin: https://car.example.com\r\n"
        XCTAssertTrue(server.allowedHosts.contains("car.example.com"))
        XCTAssertEqual(response(server.route(request("/", host: "car.example.com"), role: .app, isTLS: true))?.0.status, 200)
        guard case .upgrade = server.route(request("/ws", host: "car.example.com", extra: ws), role: .app, isTLS: true) else {
            return XCTFail("the certificate's own origin must be accepted")
        }

        server.publicHostname = nil
        XCTAssertFalse(server.allowedHosts.contains("car.example.com"))
        XCTAssertEqual(response(server.route(request("/", host: "car.example.com"), role: .app, isTLS: true))?.0.status, 403)
        XCTAssertEqual(response(server.route(request("/ws", host: "localhost", extra: ws), role: .app, isTLS: false))?.0.status, 403)

        server.publicHostname = "Car.Other.Example"
        XCTAssertTrue(server.allowedHosts.contains("car.other.example"), "hostnames compare lowercased")
    }

    // MARK: App routes

    func testPageHealthzAnd404() throws {
        for path in ["/", "/index.html"] {
            let (r, _) = try XCTUnwrap(response(server.route(request(path, host: "localhost:8080"), role: .app, isTLS: false)))
            XCTAssertEqual(r.status, 200)
            XCTAssertEqual(r.headers["Content-Type"], "text/html; charset=utf-8")
            XCTAssertEqual(String(data: r.body, encoding: .utf8), "<!doctype html><title>client</title>")
            XCTAssertTrue(wire(r).contains("Cache-Control: no-store\r\n"))
        }
        let (health, _) = try XCTUnwrap(response(server.route(request("/healthz", host: "car.example.com"), role: .app, isTLS: true)))
        XCTAssertEqual(health.status, 200)
        XCTAssertEqual(String(data: health.body, encoding: .utf8), "ok")
        let (missing, _) = try XCTUnwrap(response(server.route(request("/nope", host: "127.0.0.1:8080"), role: .app, isTLS: false)))
        XCTAssertEqual(missing.status, 404)
    }

    func testStaticAssetsWithoutTraversal() throws {
        let (js, _) = try XCTUnwrap(response(server.route(request("/assets/app.js", host: "localhost"), role: .app, isTLS: false)))
        XCTAssertEqual(js.status, 200)
        XCTAssertEqual(js.headers["Content-Type"], "text/javascript; charset=utf-8")
        for path in ["/.env", "/../Package.swift", "/assets/../../etc/passwd", "/assets/%2e%2e/%2e%2e/etc/passwd", "/assets"] {
            let (r, _) = try XCTUnwrap(response(server.route(request(path, host: "localhost"), role: .app, isTLS: false)))
            XCTAssertEqual(r.status, 404, path)
        }
    }

    func testForeignHostIsForbidden() throws {
        for host in ["evil.com", "evil.com:8080", "192.168.1.5:8080"] {
            let (r, close) = try XCTUnwrap(response(server.route(request("/", host: host), role: .app, isTLS: false)))
            XCTAssertEqual(r.status, 403, host)
            XCTAssertTrue(close)
        }
        let (noHost, _) = try XCTUnwrap(response(server.route(request("/", host: nil), role: .app, isTLS: false)))
        XCTAssertEqual(noHost.status, 403)
    }

    func testMethodNotAllowed() throws {
        let (r, _) = try XCTUnwrap(response(server.route(request("/", host: "localhost", method: "POST"), role: .app, isTLS: false)))
        XCTAssertEqual(r.status, 405)
        XCTAssertEqual(r.headers["Allow"], "GET, HEAD")
    }

    func testWebSocketUpgradeAndOriginChecks() throws {
        let ws = "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
        func upgrade(_ origin: String?) -> HTTPAction {
            server.route(request("/ws", host: "localhost:8080", extra: ws + (origin.map { "Origin: \($0)\r\n" } ?? "")), role: .app, isTLS: false)
        }
        for origin in [nil, "http://localhost:8080", "http://localhost:5173", "https://car.example.com", "http://127.0.0.1:8080"] {
            guard case .upgrade(let r) = upgrade(origin) else { return XCTFail("origin \(origin ?? "nil") rejected") }
            XCTAssertEqual(r.status, 101)
            XCTAssertEqual(r.headers["Sec-WebSocket-Accept"], "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        }
        for origin in ["https://evil.com", "null", "http://car.example.com.evil.com"] {
            XCTAssertEqual(response(upgrade(origin))?.0.status, 403, origin)
        }
        // /ws without Upgrade → 426; wrong version → 426 with the supported version.
        XCTAssertEqual(response(server.route(request("/ws", host: "localhost"), role: .app, isTLS: false))?.0.status, 426)
        let v8 = ws.replacingOccurrences(of: "Version: 13", with: "Version: 8")
        let (bad, _) = try XCTUnwrap(response(server.route(request("/ws", host: "localhost", extra: v8), role: .app, isTLS: false)))
        XCTAssertEqual(bad.status, 426)
        XCTAssertEqual(bad.headers["Sec-WebSocket-Version"], "13")
    }

    func testFallbackPageWhenClientMissing() {
        let provider = ClientPageProvider(directory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        let page = provider.indexPage()
        // Either the real Web/dist (found by walking up from the test's cwd) or the inline fallback.
        XCTAssertEqual(page.contentType, "text/html; charset=utf-8")
        XCTAssertFalse(page.data.isEmpty)
        if page.source == "inline fallback" {
            XCTAssertTrue(String(data: page.data, encoding: .utf8)!.contains("hasn't been built"))
        }
    }
}
