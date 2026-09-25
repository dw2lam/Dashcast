import Foundation
import Network
import SystemConfiguration

/// One-shot flag for callbacks that may race (all callers are on the server's queue, but NW can
/// deliver a late state change after we've already resolved).
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

/// UDP + TCP DNS responder. Answers the car-facing names itself (A → service address, any other
/// type → empty NOERROR) and relays every other query verbatim to the Mac's resolvers.
final class LocalDNSServer: @unchecked Sendable {
    struct Configuration: Sendable {
        var bindHost: String
        /// 0 = pick a free port (tests).
        var port: UInt16
        /// Lowercased names answered locally (see `setLocalNames`).
        var localNames: Set<String>
        var answerAddress: String
        var ttl: UInt32 = 60
        var upstreamTimeout: TimeInterval = 1.5
        var maxParallelUpstreams = 2
        var upstreams: @Sendable () -> [NWEndpoint]
    }

    struct Stats: Equatable, Sendable {
        var queries = 0
        var localAnswers = 0
        var cacheHits = 0
        var forwarded = 0
        var failures = 0
    }

    let configuration: Configuration
    /// Called (on the server queue) if a listener dies after starting, e.g. the lo0 alias vanished.
    var onUnexpectedStop: (@Sendable (Error) -> Void)?

    private let queue = DispatchQueue(label: "online.davidlam.dashcast.dns", qos: .userInitiated)
    private let answerBytes: [UInt8]?
    // Queue-confined:
    private var udpListener: NWListener?
    private var tcpListener: NWListener?
    private var flows: [ObjectIdentifier: Flow] = [:]
    private var cache = DNSCache()
    private var sweepTimer: DispatchSourceTimer?
    private var _stats = Stats()
    private var _port: UInt16?
    private var localNames: Set<String>

    private final class Flow {
        let connection: NWConnection
        var lastActive = Date()
        var pending = 0
        var closing = false
        init(_ connection: NWConnection) { self.connection = connection }
    }

    init(_ configuration: Configuration) {
        self.configuration = configuration
        localNames = configuration.localNames
        answerBytes = IPv4.parse(configuration.answerAddress).map {
            [UInt8($0 >> 24), UInt8($0 >> 16 & 0xFF), UInt8($0 >> 8 & 0xFF), UInt8($0 & 0xFF)]
        }
    }

    var port: UInt16? { queue.sync { _port } }
    var isRunning: Bool { queue.sync { _port != nil } }
    var stats: Stats { queue.sync { _stats } }

    /// Replaces the names answered locally (the own domain changed). Lowercased.
    func setLocalNames(_ names: Set<String>) {
        queue.sync { localNames = names }
    }

    // MARK: Lifecycle

    /// Binds UDP, then TCP on the same port. Returns the port.
    @discardableResult
    func start() async throws -> UInt16 {
        let udp = try await makeListener(.udp, port: configuration.port, udp: true)
        let port = udp.port?.rawValue ?? configuration.port
        let tcp: NWListener
        do {
            tcp = try await makeListener(.tcp, port: port, udp: false)
        } catch {
            udp.cancel()
            throw error
        }
        queue.sync {
            udpListener = udp
            tcpListener = tcp
            _port = port
            startSweeper()
        }
        return port
    }

    func stop() {
        queue.sync { teardown() }
    }

    private func teardown() {
        udpListener?.cancel(); udpListener = nil
        tcpListener?.cancel(); tcpListener = nil
        flows.values.forEach { $0.connection.cancel() }
        flows = [:]
        sweepTimer?.cancel(); sweepTimer = nil
        _port = nil
    }

    private func makeListener(_ parameters: NWParameters, port: UInt16, udp: Bool) async throws -> NWListener {
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(configuration.bindHost),
                                                     port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection, udp: udp) }
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    if once.fire(), let listener { continuation.resume(returning: listener) }
                case .failed(let error), .waiting(let error):
                    if once.fire() {
                        listener?.cancel()
                        continuation.resume(throwing: error)
                    } else if case .failed = state {
                        self?.listenerDied(error)
                    }
                case .cancelled:
                    if once.fire() { continuation.resume(throwing: NWError.posix(.ECANCELED)) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func listenerDied(_ error: Error) {
        guard _port != nil else { return }
        teardown()
        onUnexpectedStop?(error)
    }

    private func startSweeper() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let cutoff = Date().addingTimeInterval(-30)
            for flow in self.flows.values where flow.pending == 0 && flow.lastActive < cutoff {
                flow.connection.cancel()
            }
        }
        timer.resume()
        sweepTimer = timer
    }

    // MARK: Client flows

    private func accept(_ connection: NWConnection, udp: Bool) {
        let key = ObjectIdentifier(connection)
        let flow = Flow(connection)
        flows[key] = flow
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.flows[key] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        if udp { receiveUDP(flow) } else { receiveTCP(flow, buffer: Data()) }
    }

    private func receiveUDP(_ flow: Flow) {
        flow.connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                flow.lastActive = Date()
                self.process(data, overTCP: false) { reply in
                    guard let reply else { return }
                    flow.connection.send(content: reply, completion: .contentProcessed { _ in })
                }
            }
            if error == nil { self.receiveUDP(flow) } else { flow.connection.cancel() }
        }
    }

    private func receiveTCP(_ flow: Flow, buffer: Data) {
        flow.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_537) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data, !data.isEmpty {
                buffer.append(data)
                flow.lastActive = Date()
            }
            let (messages, rest) = DNSTCPFraming.split(buffer)
            for message in messages {
                flow.pending += 1
                self.process(message, overTCP: true) { reply in
                    let finish = {
                        flow.pending -= 1
                        if flow.closing, flow.pending == 0 { flow.connection.cancel() }
                    }
                    guard let reply else { return finish() }
                    flow.connection.send(content: DNSTCPFraming.frame(reply), completion: .contentProcessed { _ in finish() })
                }
            }
            if isComplete || error != nil || rest.count > 65_537 {
                flow.closing = true
                if flow.pending == 0 { flow.connection.cancel() }
                return
            }
            self.receiveTCP(flow, buffer: rest)
        }
    }

    // MARK: Query handling (on `queue`)

    /// Test hook: run one query through the full pipeline.
    func handle(_ raw: Data, overTCP: Bool = false) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                self.process(raw, overTCP: overTCP) { continuation.resume(returning: $0) }
            }
        }
    }

    private func process(_ raw: Data, overTCP: Bool, reply: @escaping (Data?) -> Void) {
        guard let query = try? DNSMessage.parse(raw) else {
            reply(DNSMessage.formatError(for: raw))
            return
        }
        guard !query.isResponse else { return reply(nil) }
        _stats.queries += 1

        if let local = localAnswer(for: query) {
            _stats.localAnswers += 1
            return reply(local)
        }
        if let hit = cache.lookup(query, now: Date()), overTCP || hit.count <= query.maxUDPResponseSize {
            _stats.cacheHits += 1
            return reply(hit)
        }
        let upstreams = configuration.upstreams()
        guard !upstreams.isEmpty else {
            _stats.failures += 1
            return reply(DNSMessage.serverFailure(for: query))
        }
        _stats.forwarded += 1
        forwardUDP(raw, query: query, to: Array(upstreams.prefix(configuration.maxParallelUpstreams))) { [weak self] response in
            guard let self else { return }
            guard let response else {
                self._stats.failures += 1
                return reply(DNSMessage.serverFailure(for: query))
            }
            if overTCP, (try? DNSMessage.parse(response))?.truncated == true, let first = upstreams.first {
                self.forwardTCP(raw, query: query, to: first) { full in
                    let final = full ?? response
                    self.cache.store(final, for: query, now: Date())
                    reply(final)
                }
                return
            }
            self.cache.store(response, for: query, now: Date())
            reply(response)
        }
    }

    private func localAnswer(for query: DNSMessage) -> Data? {
        guard query.opcode == 0, query.questions.count == 1, let question = query.questions.first,
              question.qclass == 1 || question.qclass == DNSType.any,
              localNames.contains(question.key) else { return nil }
        if question.type == DNSType.a || question.type == DNSType.any, let answerBytes {
            return DNSMessage.response(to: query, rcode: DNSRCode.noError,
                                       answers: [.init(type: DNSType.a, ttl: configuration.ttl, rdata: answerBytes)])
        }
        // AAAA, HTTPS, … → NOERROR, no data: the car sticks to IPv4 and doesn't ask the internet.
        return DNSMessage.response(to: query, rcode: DNSRCode.noError)
    }

    private func isReply(_ data: Data, to query: DNSMessage) -> Bool {
        guard let message = try? DNSMessage.parse(data), message.isResponse, message.id == query.id else { return false }
        guard let asked = query.questions.first else { return true }
        guard let answered = message.questions.first else { return message.rcode != DNSRCode.noError }
        return answered.key == asked.key && answered.type == asked.type
    }

    /// Sends the untouched query to up to N upstreams at once; first valid reply wins.
    private func forwardUDP(_ raw: Data, query: DNSMessage, to endpoints: [NWEndpoint],
                            completion: @escaping (Data?) -> Void) {
        let once = Once()
        var connections: [NWConnection] = []
        var failed = Set<Int>()
        let finish: (Data?) -> Void = { data in
            guard once.fire() else { return }
            connections.forEach { $0.cancel() }
            completion(data)
        }
        func fail(_ index: Int) {
            failed.insert(index)
            if failed.count == endpoints.count { finish(nil) }
        }
        for (index, endpoint) in endpoints.enumerated() {
            let connection = NWConnection(to: endpoint, using: .udp)
            connections.append(connection)
            connection.stateUpdateHandler = { state in
                if case .failed = state { fail(index) }
            }
            connection.start(queue: queue)
            connection.send(content: raw, completion: .contentProcessed { error in
                if error != nil { fail(index) }
            })
            func receive() {
                connection.receiveMessage { [weak self] data, _, _, error in
                    guard let self else { return }
                    if let data, self.isReply(data, to: query) { return finish(data) }
                    if error != nil { return fail(index) }
                    receive() // ignore strays, keep listening until the deadline
                }
            }
            receive()
        }
        queue.asyncAfter(deadline: .now() + configuration.upstreamTimeout) { finish(nil) }
    }

    /// Re-asks over TCP when the UDP answer was truncated and the car asked over TCP.
    private func forwardTCP(_ raw: Data, query: DNSMessage, to endpoint: NWEndpoint,
                            completion: @escaping (Data?) -> Void) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let once = Once()
        let finish: (Data?) -> Void = { data in
            guard once.fire() else { return }
            connection.cancel()
            completion(data)
        }
        connection.stateUpdateHandler = { state in
            if case .failed = state { finish(nil) }
        }
        connection.start(queue: queue)
        connection.send(content: DNSTCPFraming.frame(raw), completion: .contentProcessed { error in
            if error != nil { finish(nil) }
        })
        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] header, _, _, _ in
            guard let self, let header, header.count == 2 else { return finish(nil) }
            let bytes = [UInt8](header)
            let length = Int(bytes[0]) << 8 | Int(bytes[1])
            guard length > 0 else { return finish(nil) }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, _ in
                guard let body, body.count == length, self.isReply(body, to: query) else { return finish(nil) }
                finish(body)
            }
        }
        queue.asyncAfter(deadline: .now() + configuration.upstreamTimeout + 1) { finish(nil) }
    }
}

/// The Mac's own resolvers (State:/Network/Global/DNS), minus loopback and our own address.
final class SystemResolvers: @unchecked Sendable {
    static let fallback = ["1.1.1.1"]
    private let store = SCDynamicStoreCreate(nil, "online.davidlam.dashcast.dns" as CFString, nil, nil)
    private let excluded: Set<String>

    init(excluding: Set<String>) { excluded = excluding }

    func addresses() -> [String] {
        var servers: [String] = []
        if let store,
           let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any] {
            servers = value["ServerAddresses"] as? [String] ?? []
        }
        return Self.filter(servers, excluding: excluded)
    }

    func endpoints() -> [NWEndpoint] {
        addresses().map { .hostPort(host: NWEndpoint.Host($0), port: 53) }
    }

    static func filter(_ servers: [String], excluding: Set<String>) -> [String] {
        var seen = Set<String>()
        let usable = servers.filter { server in
            let s = server.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !excluding.contains(s), seen.insert(s).inserted else { return false }
            if IPv4.isValid(s) { return !IPv4.isLoopback(s) && s != "0.0.0.0" }
            return s != "::1" && s != "::"
        }
        return usable.isEmpty ? fallback : usable
    }
}
