import DashcastContracts
import Foundation
import Network

enum HTTPAction {
    case respond(HTTPResponse, close: Bool)
    case upgrade(HTTPResponse)
}

struct ListenerError: Error, CustomStringConvertible {
    var description: String
}

/// Listeners + connection registry + request routing. Everything runs on `queue`.
final class HTTPServer: @unchecked Sendable {   // confined to `queue`
    let queue: DispatchQueue
    let pages: ClientPageProvider
    let publicHostname: String
    /// Hostnames accepted in `Host` and in a WebSocket `Origin` (DNS-rebinding / cross-site guard).
    let allowedHosts: Set<String>
    weak var webSocketDelegate: WebSocketDelegate?
    /// HTTP mode (no TLS listener): the plain :80 listener serves the page and /ws itself instead of
    /// redirecting to https.
    var plainServesApp = true
    /// Diagnostic log sink (called on `queue`).
    var log: ((String) -> Void)?

    static let maxConnections = 64
    static let httpIdleTimeout: TimeInterval = 30

    private var listeners: [String: NWListener] = [:]
    private var connections: [UInt64: ServerConnection] = [:]
    private var nextConnectionID: UInt64 = 1
    private var sweepTimer: DispatchSourceTimer?

    init(queue: DispatchQueue, pages: ClientPageProvider, publicHostname: String, allowedHosts: Set<String>) {
        self.queue = queue
        self.pages = pages
        self.publicHostname = publicHostname
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
    }

    static func tcpOptions() -> NWProtocolTCP.Options {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true            // no Nagle: frames go out as soon as they're written
        tcp.enableKeepalive = true    // notice a car that drove off / lost Wi-Fi
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        return tcp
    }

    // MARK: Listeners

    func isListening(_ name: String) -> Bool { listeners[name] != nil }

    /// Starts a listener bound to `host:port` (port 0 = ephemeral). Completion runs on `queue` with the
    /// bound port once ready, or the error (address not available, in use, timeout).
    func startListener(name: String, role: ServerConnection.Role, host: String, port: UInt16, tls: TLSIdentity?,
                       completion: @escaping (Result<UInt16, Error>) -> Void) {
        stopListener(name)
        let tcp = Self.tcpOptions()
        let params = tls.map { NWParameters(tls: $0.tlsOptions(), tcp: tcp) } ?? NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false
        let nwPort: NWEndpoint.Port = port == 0 ? .any : (NWEndpoint.Port(rawValue: port) ?? .any)
        // Bind to exactly this address (NWListener(using:on:) would bind all interfaces).
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)

        let listener: NWListener
        do { listener = try NWListener(using: params) } catch { completion(.failure(error)); return }

        var finished = false
        let finish: (Result<UInt16, Error>) -> Void = { result in
            guard !finished else { return }
            finished = true
            completion(result)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready:
                finish(.success(listener.port?.rawValue ?? port))
            case .failed(let error), .waiting(let error):
                if self.listeners[name] === listener { self.listeners[name] = nil }
                listener.cancel()
                if finished { self.log?("Listener \(name) on \(host):\(port) stopped: \(error)") }
                finish(.failure(error))
            case .cancelled:
                if self.listeners[name] === listener { self.listeners[name] = nil }
                finish(.failure(ListenerError(description: "cancelled")))
            default:
                break
            }
        }
        let isTLS = tls != nil
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, role: role, listenerName: name, isTLS: isTLS, localHost: host)
        }
        listeners[name] = listener
        listener.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { [weak self, weak listener] in
            guard !finished else { return }
            if let listener {
                if self?.listeners[name] === listener { self?.listeners[name] = nil }
                listener.cancel()
            }
            finish(.failure(ListenerError(description: "timed out binding \(host):\(port)")))
        }
        startSweeper()
    }

    func stopListener(_ name: String) {
        guard let listener = listeners.removeValue(forKey: name) else { return }
        listener.cancel()
    }

    /// Cancels every listener and closes every connection (WebSockets get a close frame).
    func stopAll() {
        for name in Array(listeners.keys) { stopListener(name) }
        for connection in Array(connections.values) {
            connection.close(code: WebSocketCloseCode.goingAway, reason: "server stopping")
        }
        sweepTimer?.cancel()
        sweepTimer = nil
    }

    // MARK: Connections

    private func accept(_ nw: NWConnection, role: ServerConnection.Role, listenerName: String, isTLS: Bool, localHost: String) {
        guard connections.count < Self.maxConnections else {
            log?("Refusing connection from \(nw.endpoint): too many connections")
            nw.cancel()
            return
        }
        let id = nextConnectionID
        nextConnectionID += 1
        let connection = ServerConnection(id: id, connection: nw, role: role, listenerName: listenerName, isTLS: isTLS,
                                          localHost: localHost, queue: queue, server: self)
        connections[id] = connection
        connection.start()
    }

    func connectionDidTerminate(_ connection: ServerConnection) {
        connections[connection.id] = nil
    }

    var connectionCount: Int { connections.count }

    private func startSweeper() {
        guard sweepTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.sweep() }
        timer.resume()
        sweepTimer = timer
    }

    private func sweep() {
        let now = ServerConnection.now()
        for connection in connections.values where connection.mode == .http {
            if now - connection.lastActivity > Self.httpIdleTimeout { connection.terminate(reason: "idle") }
        }
    }

    // MARK: Routing

    /// Connectivity probes answered on plain HTTP so the car (and an iPhone hotspot client) believe
    /// they're online when their DNS for these names points at us.
    enum ConnectivityProbe {
        static let teslaHosts: Set<String> = ["connman.vn.tesla.services", "connman.vn.cloud.tesla.cn"]
        static let appleHosts: Set<String> = ["captive.apple.com"]
        static let teslaBody = "<html><body>Connectivity OK</body></html>\n"
        static let appleBody = "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"

        static func response(forHost host: String) -> HTTPResponse? {
            if teslaHosts.contains(host) {
                return HTTPResponse(status: 200, headers: [("X-ConnMan-Status", "online"), ("Content-Type", "text/html")],
                                    body: Data(teslaBody.utf8))
            }
            if appleHosts.contains(host) {
                return HTTPResponse(status: 200, headers: [("Content-Type", "text/html")], body: Data(appleBody.utf8))
            }
            return nil
        }
    }

    /// Routes one request. Pure apart from reading the client page from disk.
    func route(_ request: HTTPRequest, role: ServerConnection.Role, isTLS: Bool) -> HTTPAction {
        let host = request.headers["Host"].flatMap(Self.hostName(fromHostHeader:))

        if !isTLS, let host, let probe = ConnectivityProbe.response(forHost: host) {
            return .respond(probe, close: false)
        }

        if role == .plain && !plainServesApp {
            // HTTPS mode: everything else on :80 goes to the https origin (same path when it was already our name).
            let target = host == publicHostname.lowercased() && request.target.hasPrefix("/") ? request.target : "/"
            let location = "https://\(publicHostname)\(target)"
            let response = HTTPResponse(status: 301, headers: [("Location", location), ("Content-Type", "text/plain; charset=utf-8")],
                                        body: Data("Moved to \(location)\n".utf8))
            return .respond(response, close: true)
        }

        guard let host, allowedHosts.contains(host) else {
            if role == .plain {
                // HTTP mode: send stray names (whatever the car resolved to us) to the car page.
                let location = "http://\(publicHostname)/"
                return .respond(HTTPResponse(status: 301, headers: [("Location", location), ("Content-Type", "text/plain; charset=utf-8")],
                                             body: Data("Moved to \(location)\n".utf8)), close: true)
            }
            return .respond(.text(403, "Forbidden host\n"), close: true)
        }
        guard request.method == "GET" || request.method == "HEAD" else {
            var response = HTTPResponse.text(405, "Method Not Allowed\n")
            response.headers.add("Allow", "GET, HEAD")
            return .respond(response, close: false)
        }

        switch request.path {
        case "/ws":
            return webSocketUpgrade(request)
        case "/", "/index.html":
            let page = pages.indexPage()
            return .respond(HTTPResponse(status: 200, headers: [("Content-Type", page.contentType)], body: page.data), close: false)
        case "/healthz":
            return .respond(.text(200, "ok"), close: false)
        default:
            if let file = pages.staticFile(path: request.path) {
                return .respond(HTTPResponse(status: 200, headers: [("Content-Type", file.contentType)], body: file.data), close: false)
            }
            return .respond(.text(404, "Not Found\n"), close: false)
        }
    }

    private func webSocketUpgrade(_ request: HTTPRequest) -> HTTPAction {
        guard request.headers.tokens("Upgrade").contains("websocket") else {
            var response = HTTPResponse.text(426, "WebSocket upgrade required\n")
            response.headers.add("Upgrade", "websocket")
            return .respond(response, close: false)
        }
        // Browsers always send Origin; a page from another site must not be able to watch the
        // screen or inject input. Non-browser clients (no Origin) are allowed.
        if let origin = request.headers["Origin"] {
            guard let host = URL(string: origin)?.host?.lowercased(), allowedHosts.contains(Self.normalizeHost(host)) else {
                log?("Rejected WebSocket from origin \(origin)")
                return .respond(.text(403, "Forbidden origin\n"), close: true)
            }
        }
        guard webSocketDelegate != nil else { return .respond(.text(503, "Not ready\n"), close: true) }
        switch WebSocketHandshake.validate(request) {
        case .success(let key):
            return .upgrade(WebSocketHandshake.response(forKey: key))
        case .failure(.unsupportedVersion):
            var response = HTTPResponse.text(426, "Unsupported WebSocket version\n")
            response.headers.add("Sec-WebSocket-Version", "13")
            return .respond(response, close: true)
        case .failure(.badRequest(let why)):
            return .respond(.text(400, "Bad WebSocket handshake: \(why)\n"), close: true)
        }
    }

    /// `example.com:8080` → `example.com`, `[::1]:8080` → `::1`.
    static func hostName(fromHostHeader header: String) -> String? {
        let value = header.trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return nil }
            return String(value[value.index(after: value.startIndex)..<close])
        }
        if let colon = value.lastIndex(of: ":") {
            let port = value[value.index(after: colon)...]
            guard port.allSatisfy(\.isNumber) else { return nil }
            return String(value[..<colon])
        }
        return value
    }

    static func normalizeHost(_ host: String) -> String {
        host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    }
}
