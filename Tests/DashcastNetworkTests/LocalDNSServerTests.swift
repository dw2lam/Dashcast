import DashcastContracts
import Network
import XCTest
@testable import DashcastNetwork

/// A scriptable upstream resolver on 127.0.0.1 (UDP + TCP on the same port).
final class FakeUpstream: @unchecked Sendable {
    enum Mode { case answer, silent, truncateUDP }
    private let queue = DispatchQueue(label: "fake-upstream")
    private var udp: NWListener?
    private var tcp: NWListener?
    private let lock = NSLock()
    private var _udpQueries = 0
    private var _tcpQueries = 0
    var mode: Mode
    private(set) var port: UInt16 = 0

    var udpQueries: Int { lock.lock(); defer { lock.unlock() }; return _udpQueries }
    var tcpQueries: Int { lock.lock(); defer { lock.unlock() }; return _tcpQueries }
    var endpoint: NWEndpoint { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!) }

    init(mode: Mode) { self.mode = mode }

    func start() async throws {
        udp = try await listen(.udp, port: 0, isUDP: true)
        port = udp!.port!.rawValue
        tcp = try await listen(.tcp, port: port, isUDP: false)
    }

    func stop() { udp?.cancel(); tcp?.cancel() }

    /// 3 A records for anything (big enough to be interesting, tiny enough for UDP).
    func answer(to raw: Data, truncated: Bool) -> Data? {
        guard let query = try? DNSMessage.parse(raw) else { return nil }
        let answers = truncated ? [] : (1...3).map { DNSMessage.Answer(type: DNSType.a, ttl: 120, rdata: [192, 0, 2, UInt8($0)]) }
        var bytes = [UInt8](DNSMessage.response(to: query, rcode: 0, answers: answers, authoritative: false))
        if truncated { bytes[2] |= 0x02 }
        return Data(bytes)
    }

    private func listen(_ parameters: NWParameters, port: UInt16, isUDP: Bool) async throws -> NWListener {
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            c.start(queue: self.queue)
            isUDP ? self.serveUDP(c) : self.serveTCP(c)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.fire() { continuation.resume(returning: listener) }
                case .failed(let e), .waiting(let e): if once.fire() { continuation.resume(throwing: e) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func serveUDP(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self, let data else { return }
            self.lock.lock(); self._udpQueries += 1; self.lock.unlock()
            switch self.mode {
            case .silent: break
            case .answer, .truncateUDP:
                if let reply = self.answer(to: data, truncated: self.mode == .truncateUDP) {
                    c.send(content: reply, completion: .contentProcessed { _ in })
                }
            }
            if error == nil { self.serveUDP(c) }
        }
    }

    private func serveTCP(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] header, _, _, _ in
            guard let self, let header, header.count == 2 else { return c.cancel() }
            let length = Int(header.first!) << 8 | Int(header.last!)
            c.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, _ in
                guard let body else { return c.cancel() }
                self.lock.lock(); self._tcpQueries += 1; self.lock.unlock()
                if let reply = self.answer(to: body, truncated: false) {
                    c.send(content: DNSTCPFraming.frame(reply), completion: .contentProcessed { _ in })
                }
            }
        }
    }
}

final class LocalDNSServerTests: XCTestCase {
    private var server: LocalDNSServer!
    private var port: UInt16 = 0
    /// The user's own domain plus the connectivity checks, as NetworkManager configures it.
    private let localNames = ["car.example.com"] + NetworkManager.connectivityCheckNames

    private func startServer(upstreams: @escaping @Sendable () -> [NWEndpoint], timeout: TimeInterval = 1.5) async throws {
        server = LocalDNSServer(.init(bindHost: "127.0.0.1", port: 0,
                                      localNames: Set(localNames),
                                      answerAddress: DashcastDefaults.serviceAddress,
                                      upstreamTimeout: timeout,
                                      upstreams: upstreams))
        port = try await server.start()
        XCTAssertGreaterThan(port, 0)
        XCTAssertTrue(server.isRunning)
    }

    override func tearDown() {
        server?.stop()
        server = nil
    }

    private func ask(_ raw: Data, overTCP: Bool = false) async throws -> Data {
        let reply = await server.handle(raw, overTCP: overTCP)
        return try XCTUnwrap(reply)
    }

    private func dig(_ args: [String]) async throws -> String {
        let result = try await ProcessRunner.run("/usr/bin/dig",
                                                 ["@127.0.0.1", "-p", String(port), "+time=4", "+tries=1"] + args,
                                                 timeout: 20)
        return result.stdout + result.stderr
    }

    private func answerLines(_ output: String) -> [String] {
        guard let range = output.range(of: ";; ANSWER SECTION:\n") else { return [] }
        return output[range.upperBound...].split(separator: "\n", omittingEmptySubsequences: false)
            .prefix { !$0.isEmpty }.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    }

    // MARK: dig against the real sockets

    func testDigLocalNamesUDPandTCP() async throws {
        try await startServer(upstreams: { [] })
        for name in localNames {
            let out = try await dig([name, "A"])
            XCTAssertTrue(out.contains("status: NOERROR"), out)
            XCTAssertTrue(out.contains("flags: qr aa rd ra;"), out)
            XCTAssertEqual(answerLines(out), ["\(name). 60 IN A \(svc)"], out)
            XCTAssertTrue(out.contains("; EDNS: version: 0"), "dig sends EDNS by default; we answer with OPT: \(out)")
        }
        let tcp = try await dig(["+tcp", "car.example.com"])
        XCTAssertEqual(answerLines(tcp), ["car.example.com. 60 IN A \(svc)"], tcp)

        let short = try await dig(["+short", "car.example.com"])
        XCTAssertEqual(short.trimmingCharacters(in: .whitespacesAndNewlines), svc)
        print("[dns] dig @127.0.0.1 -p \(port) +short car.example.com → \(short.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    func testDigAAAAAndHTTPSAreEmptyNoError() async throws {
        try await startServer(upstreams: { [] })
        for type in ["AAAA", "HTTPS", "TXT"] {
            let out = try await dig(["car.example.com", type])
            XCTAssertTrue(out.contains("status: NOERROR"), out)
            XCTAssertTrue(out.contains("ANSWER: 0,"), out)
        }
        let viaTCP = try await dig(["+tcp", "connman.vn.tesla.services", "AAAA"])
        XCTAssertTrue(viaTCP.contains("status: NOERROR") && viaTCP.contains("ANSWER: 0,"), viaTCP)
    }

    func testDigPreservesCaseAndEchoesDO() async throws {
        try await startServer(upstreams: { [] })
        let out = try await dig(["+dnssec", "cAr.ExAmPlE.CoM"])
        XCTAssertEqual(answerLines(out), ["cAr.ExAmPlE.CoM. 60 IN A \(svc)"], out)
        XCTAssertTrue(out.contains("; EDNS: version: 0, flags: do;"), out)
        let noEDNS = try await dig(["+noedns", "car.example.com"])
        XCTAssertFalse(noEDNS.contains("OPT PSEUDOSECTION"), noEDNS)
        XCTAssertEqual(answerLines(noEDNS), ["car.example.com. 60 IN A \(svc)"], noEDNS)
    }

    /// Forwarding through the Mac's real resolvers (needs internet).
    func testDigForwardsToRealResolvers() async throws {
        let resolvers = SystemResolvers(excluding: [svc])
        print("[dns] upstream resolvers: \(resolvers.addresses())")
        try await startServer(upstreams: { resolvers.endpoints() })
        let out = try await dig(["apple.com", "A"])
        XCTAssertTrue(out.contains("status: NOERROR"), out)
        let answers = answerLines(out)
        XCTAssertFalse(answers.isEmpty, out)
        XCTAssertTrue(answers.allSatisfy { $0.hasPrefix("apple.com. ") }, out)
        XCTAssertFalse(out.contains("flags: qr aa"), "forwarded answers aren't ours to call authoritative")
        print("[dns] dig @127.0.0.1 -p \(port) apple.com → \(answers.joined(separator: " | "))")

        let tcp = try await dig(["+tcp", "www.apple.com", "A"])
        XCTAssertTrue(tcp.contains("status: NOERROR"), tcp)
        XCTAssertFalse(answerLines(tcp).isEmpty, tcp)

        // Second ask comes from the cache.
        let before = server.stats
        let cached = try await dig(["apple.com", "A"])
        XCTAssertTrue(cached.contains("status: NOERROR"), cached)
        XCTAssertEqual(server.stats.cacheHits, before.cacheHits + 1)
        print("[dns] stats: \(server.stats)")
    }

    // MARK: Pipeline against a fake upstream (deterministic)

    func testForwardRelaysRawAndCaches() async throws {
        let upstream = FakeUpstream(mode: .answer)
        try await upstream.start()
        defer { upstream.stop() }
        try await startServer(upstreams: { [upstream.endpoint] })

        let query = DNSMessage.query(id: 0x1111, name: "Example.COM", type: DNSType.a,
                                     edns: DNSOpt(udpPayloadSize: 1232, options: [0, 10, 0, 8, 1, 2, 3, 4, 5, 6, 7, 8]))
        let reply = try await DNSMessage.parse(ask(query))
        XCTAssertEqual(reply.id, 0x1111)
        XCTAssertEqual(reply.records.count, 3)
        XCTAssertEqual(reply.questions.first?.name, "Example.COM")
        XCTAssertNotNil(reply.opt, "EDNS passes through to the upstream and back")
        XCTAssertEqual(upstream.udpQueries, 1)

        let again = try await DNSMessage.parse(ask(
            DNSMessage.query(id: 0x2222, name: "eXAMPLE.com", type: DNSType.a,
                             edns: DNSOpt(udpPayloadSize: 1232))))
        XCTAssertEqual(again.id, 0x2222)
        XCTAssertEqual(again.questions.first?.name, "eXAMPLE.com")
        XCTAssertEqual(upstream.udpQueries, 1, "served from cache")
        XCTAssertEqual(server.stats.cacheHits, 1)
    }

    func testSilentUpstreamGivesServfailAfterTimeout() async throws {
        let upstream = FakeUpstream(mode: .silent)
        try await upstream.start()
        defer { upstream.stop() }
        try await startServer(upstreams: { [upstream.endpoint] })
        let started = Date()
        let reply = try await DNSMessage.parse(ask(DNSMessage.query(id: 5, name: "slow.test", type: DNSType.a)))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(reply.rcode, DNSRCode.servFail)
        XCTAssertEqual(reply.id, 5)
        XCTAssertEqual(elapsed, 1.5, accuracy: 0.4)
        XCTAssertEqual(server.stats.failures, 1)
    }

    func testClosedUpstreamFailsFast() async throws {
        try await startServer(upstreams: { [.hostPort(host: "127.0.0.1", port: 9)] })
        let started = Date()
        let reply = try await DNSMessage.parse(ask(DNSMessage.query(id: 6, name: "x.test", type: DNSType.a)))
        XCTAssertEqual(reply.rcode, DNSRCode.servFail)
        XCTAssertLessThanOrEqual(Date().timeIntervalSince(started), 1.9)
    }

    func testNoUpstreamsIsImmediateServfail() async throws {
        try await startServer(upstreams: { [] })
        let reply = try await DNSMessage.parse(ask(DNSMessage.query(id: 8, name: "x.test", type: DNSType.a)))
        XCTAssertEqual(reply.rcode, DNSRCode.servFail)
    }

    func testTruncatedUDPAnswerIsRetriedOverTCPForTCPClients() async throws {
        let upstream = FakeUpstream(mode: .truncateUDP)
        try await upstream.start()
        defer { upstream.stop() }
        try await startServer(upstreams: { [upstream.endpoint] })

        let viaUDP = try await DNSMessage.parse(ask(DNSMessage.query(id: 1, name: "big.test", type: DNSType.a)))
        XCTAssertTrue(viaUDP.truncated, "UDP clients get TC and retry over TCP themselves")
        XCTAssertEqual(upstream.tcpQueries, 0)

        let viaTCP = try await DNSMessage.parse(ask(DNSMessage.query(id: 2, name: "big2.test", type: DNSType.a), overTCP: true))
        XCTAssertFalse(viaTCP.truncated)
        XCTAssertEqual(viaTCP.records.count, 3)
        XCTAssertEqual(upstream.tcpQueries, 1)
    }

    func testGarbageGetsFormErrAndResponsesAreIgnored() async throws {
        try await startServer(upstreams: { [] })
        let formErr = try await ask(Data([0x12, 0x34, 0x01, 0x00, 0x00, 0x01]))
        XCTAssertEqual([UInt8](formErr.prefix(4)), [0x12, 0x34, 0x81, 0x81])
        let query = try DNSMessage.parse(DNSMessage.query(id: 3, name: "car.example.com", type: DNSType.a))
        let response = DNSMessage.response(to: query, rcode: 0)
        let ignored = await server.handle(response)
        XCTAssertNil(ignored, "never answer a response (reflection loops)")
    }

    func testStopReleasesThePort() async throws {
        try await startServer(upstreams: { [] })
        let first = port
        server.stop()
        XCTAssertFalse(server.isRunning)
        let again = LocalDNSServer(.init(bindHost: "127.0.0.1", port: first, localNames: [], answerAddress: svc, upstreams: { [] }))
        let rebound = try await again.start()
        XCTAssertEqual(rebound, first)
        again.stop()
    }
}

final class LocalServicesManagerTests: XCTestCase {
    @MainActor
    func testStartStopThroughNetworkManager() async throws {
        let world = FakeWorld()
        world.reachable = false
        let manager = NetworkManager(environment: makeEnvironment(world: world))
        XCTAssertFalse(manager.localDNSRunning)
        await manager.startLocalServices()
        XCTAssertTrue(manager.localDNSRunning)
        let endpoint = try XCTUnwrap(manager.localDNSEndpoint)
        XCTAssertTrue(endpoint.hasPrefix("127.0.0.1:"))
        XCTAssertEqual(world.touched, [HelperLayout.fake.triggerPath], "helper poked to add the redirect")

        let port = String(endpoint.split(separator: ":").last!)
        let dig = try await ProcessRunner.run("/usr/bin/dig", ["@127.0.0.1", "-p", port, "+short", "+time=3", "+tries=1", "captive.apple.com"])
        XCTAssertEqual(dig.stdout.trimmingCharacters(in: .whitespacesAndNewlines), svc)

        let status = await manager.currentStatus()
        XCTAssertTrue(status.summary.contains("Local DNS running on \(endpoint)."), status.summary)

        await manager.stopLocalServices()
        XCTAssertFalse(manager.localDNSRunning)
        XCTAssertNil(manager.localDNSEndpoint)
        XCTAssertEqual(world.touched.count, 2, "poked again to drop the redirect")
        let after = await manager.currentStatus()
        XCTAssertTrue(after.summary.contains("Local DNS off."), after.summary)
    }

    /// Before the helper exists, the service address isn't on lo0: start fails softly and retries.
    @MainActor
    func testStartWithoutAliasReportsWhy() async throws {
        let world = FakeWorld()
        world.reachable = false
        var environment = makeEnvironment(world: world)
        environment.localDNSHost = svc
        environment.localDNSPort = LoopbackHelper.dnsPort
        let aliasPresent = InterfaceScanner.ipv4Addresses().contains { $0.name == "lo0" && $0.address == svc }
        try XCTSkipIf(aliasPresent, "\(svc) is already on lo0 on this Mac")
        let manager = NetworkManager(environment: environment)
        await manager.startLocalServices()
        XCTAssertFalse(manager.localDNSRunning)
        let error = try XCTUnwrap(manager.localDNSLastError)
        print("[dns] bind \(svc):\(LoopbackHelper.dnsPort) without the alias → \(error)")
        XCTAssertTrue(error.contains("isn't on this Mac yet"), error)
        let status = await manager.currentStatus()
        XCTAssertTrue(status.summary.contains("Local DNS off: \(error)"), status.summary)
        await manager.stopLocalServices()
    }
}
