import DashcastContracts
import Foundation
import Network

protocol WebSocketDelegate: AnyObject {
    func webSocketDidOpen(_ connection: ServerConnection)
    func webSocket(_ connection: ServerConnection, didReceiveText text: String)
    func webSocket(_ connection: ServerConnection, didReceivePong payload: Data)
    /// A queued video frame finished sending (backpressure relief).
    func webSocketDidDrain(_ connection: ServerConnection)
    func webSocketDidClose(_ connection: ServerConnection, reason: String)
}

/// One accepted TCP/TLS connection: HTTP/1.1 requests, optionally upgraded to a WebSocket.
/// Every method runs on the server queue.
final class ServerConnection: @unchecked Sendable {   // confined to the server queue
    /// `app` serves the client page, /healthz and /ws; `plain` is the :80 listener on the service
    /// address (connectivity checks, then either the app itself in HTTP mode or a redirect to https).
    enum Role { case app, plain }
    enum Mode { case http, webSocket, closed }
    enum SendKind { case control, video, audio }

    let id: UInt64
    let role: Role
    let listenerName: String
    let isTLS: Bool
    /// Address this connection's listener is bound to (the address the car reached us on).
    let localHost: String
    let remote: String
    private let nw: NWConnection
    private let queue: DispatchQueue
    private weak var server: HTTPServer?

    private(set) var mode: Mode = .http
    private(set) var lastActivity: TimeInterval
    /// Bytes / video frames handed to Network.framework whose send hasn't completed.
    private(set) var pendingBytes = 0
    private(set) var pendingVideoFrames = 0
    private(set) var closeSent = false

    private var httpBuffer: [UInt8] = []
    private var parser = WebSocketFrameParser(requireMasked: true, maxPayload: 1 << 20)
    private var assembler = WebSocketMessageAssembler(maxMessageSize: 1 << 20)
    private var terminated = false
    private var draining = false   // HTTP response with Connection: close in flight

    /// A connection that has buffered this much unsent data is hopeless; drop it.
    static let maxPendingBytes = 32 << 20

    init(id: UInt64, connection: NWConnection, role: Role, listenerName: String, isTLS: Bool, localHost: String,
         queue: DispatchQueue, server: HTTPServer) {
        self.id = id
        self.nw = connection
        self.role = role
        self.listenerName = listenerName
        self.isTLS = isTLS
        self.localHost = localHost
        self.queue = queue
        self.server = server
        self.remote = "\(connection.endpoint)"
        self.lastActivity = Self.now()
    }

    static func now() -> TimeInterval { Double(DashClock.nowMicros()) / 1_000_000 }

    private var delegate: WebSocketDelegate? { server?.webSocketDelegate }

    func start() {
        nw.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.receiveNext()
            case .failed(let error): self.terminate(reason: "failed: \(error)")
            case .waiting(let error): self.terminate(reason: "waiting: \(error)")
            case .cancelled: self.terminate(reason: "cancelled")
            default: break
            }
        }
        nw.start(queue: queue)
    }

    private func receiveNext() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.terminated else { return }
            if let data, !data.isEmpty {
                self.lastActivity = Self.now()
                self.ingest(data)
            }
            if let error { self.terminate(reason: "receive error: \(error)"); return }
            if isComplete { self.terminate(reason: "peer closed"); return }
            if !self.terminated { self.receiveNext() }
        }
    }

    private func ingest(_ data: Data) {
        switch mode {
        case .http: ingestHTTP(data)
        case .webSocket: ingestWebSocket(data)
        case .closed: break
        }
    }

    // MARK: HTTP

    private func ingestHTTP(_ data: Data) {
        guard !draining else { return }
        httpBuffer.append(contentsOf: data)
        while mode == .http, !draining, !terminated {
            switch HTTPRequestParser.parse(httpBuffer) {
            case .incomplete:
                return
            case .invalid(let status, let reason):
                respondAndClose(HTTPResponse.text(status, reason + "\n"), head: false)
                return
            case .complete(let request, let consumed):
                httpBuffer.removeFirst(consumed)
                guard let server else { terminate(reason: "server gone"); return }
                switch server.route(request, role: role, isTLS: isTLS) {
                case .respond(let response, let close):
                    let keepAlive = request.keepAlive && !close
                    if keepAlive {
                        send(response.serialized(includeBody: request.method != "HEAD", keepAlive: true), kind: .control)
                    } else {
                        respondAndClose(response, head: request.method == "HEAD")
                    }
                case .upgrade(let response):
                    send(response.serialized(keepAlive: true), kind: .control)
                    mode = .webSocket
                    let leftover = httpBuffer
                    httpBuffer = []
                    delegate?.webSocketDidOpen(self)
                    if !leftover.isEmpty { ingestWebSocket(Data(leftover)) }
                    return
                }
            }
        }
    }

    private func respondAndClose(_ response: HTTPResponse, head: Bool) {
        draining = true
        send(response.serialized(includeBody: !head, keepAlive: false), kind: .control, final: true) { [weak self] in
            self?.terminate(reason: "response sent")
        }
    }

    // MARK: WebSocket

    private func ingestWebSocket(_ data: Data) {
        parser.append(data)
        do {
            while mode == .webSocket, !terminated, let frame = try parser.next() {
                if let message = try assembler.push(frame) { handle(message) }
            }
        } catch let error as WebSocketError {
            fail(error)
        } catch {
            fail(.protocolError("\(error)"))
        }
    }

    private func handle(_ message: WebSocketMessageAssembler.Message) {
        switch message {
        case .text(let text):
            if !closeSent { delegate?.webSocket(self, didReceiveText: text) }
        case .binary:
            break   // the protocol has no client → server binary messages
        case .ping(let payload):
            if !closeSent { sendFrame(.pong, payload) }
        case .pong(let payload):
            delegate?.webSocket(self, didReceivePong: payload)
        case .close(let code, let reason):
            if closeSent {
                terminate(reason: "closed (\(code.map(String.init) ?? "no status"))")
            } else {
                // Echo the close and finish.
                closeSent = true
                let why = "car closed (\(code.map(String.init) ?? "no status")\(reason.isEmpty ? "" : " \(reason)"))"
                sendFrame(.close, WebSocketFrameEncoder.closePayload(code: code), final: true) { [weak self] in
                    self?.terminate(reason: why)
                }
            }
        }
    }

    private func fail(_ error: WebSocketError) {
        server?.log?("WebSocket \(remote): \(error), closing with \(error.closeCode)")
        close(code: error.closeCode, reason: "")
    }

    func sendText(_ text: String) {
        sendFrame(.text, Data(text.utf8))
    }

    /// Whether the page that opened this socket is a secure context, judged by how it was reached
    /// (TLS, or the localhost dev listener). Used when the hello doesn't say.
    var impliesSecureContext: Bool { isTLS || role == .app }

    /// Unmasked binary frame (`prefix` + `payload`, one allocation).
    func sendBinary(prefix: Data, payload: Data, kind: SendKind) {
        guard mode == .webSocket, !closeSent else { return }
        send(WebSocketFrameEncoder.binaryFrame(prefix: prefix, payload: payload), kind: kind)
    }

    func sendPing(_ payload: Data) {
        sendFrame(.ping, payload)
    }

    /// Starts the closing handshake; the TCP connection is torn down when the peer echoes the close
    /// or after one second.
    func close(code: UInt16 = WebSocketCloseCode.normal, reason: String = "") {
        guard !terminated else { return }
        guard mode == .webSocket else { terminate(reason: reason.isEmpty ? "closed" : reason); return }
        guard !closeSent else { return }
        closeSent = true
        sendFrame(.close, WebSocketFrameEncoder.closePayload(code: code, reason: reason), final: true)
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.terminate(reason: reason.isEmpty ? "closed" : reason)
        }
    }

    private func sendFrame(_ opcode: WebSocketOpcode, _ payload: Data, final: Bool = false, completion: (() -> Void)? = nil) {
        guard mode == .webSocket, !terminated else { return }
        guard opcode == .close || !closeSent else { return }
        send(WebSocketFrameEncoder.encode(WebSocketFrame(opcode: opcode, payload: payload)), kind: .control, final: final, completion: completion)
    }

    private func send(_ data: Data, kind: SendKind, final: Bool = false, completion: (() -> Void)? = nil) {
        guard !terminated else { return }
        let count = data.count
        pendingBytes += count
        if kind == .video { pendingVideoFrames += 1 }
        if pendingBytes > Self.maxPendingBytes {
            terminate(reason: "send queue overflow (\(pendingBytes) bytes)")
            return
        }
        nw.send(content: data, contentContext: final ? .finalMessage : .defaultMessage, isComplete: true,
                completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingBytes -= count
            if kind == .video {
                self.pendingVideoFrames -= 1
                if !self.terminated { self.delegate?.webSocketDidDrain(self) }
            }
            if let error, !self.terminated {
                self.terminate(reason: "send error: \(error)")
                return
            }
            completion?()
        })
    }

    func terminate(reason: String) {
        guard !terminated else { return }
        terminated = true
        let wasWebSocket = mode == .webSocket
        mode = .closed
        nw.cancel()
        server?.connectionDidTerminate(self)
        if wasWebSocket { delegate?.webSocketDidClose(self, reason: reason) }
    }
}
