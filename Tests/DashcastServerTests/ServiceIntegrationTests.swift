import DashcastContracts
import Foundation
import XCTest
@testable import DashcastServer

/// Collects everything a URLSessionWebSocketTask receives, in order.
final class WSClient: @unchecked Sendable {
    enum Item {
        case text([String: Any])
        case binary(Data)
    }

    let task: URLSessionWebSocketTask
    private let session: URLSession
    private let lock = NSLock()
    private var _items: [Item] = []
    private var _error: Error?

    init(url: URL, delegate: URLSessionDelegate? = nil) {
        session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 16 << 20
        task.resume()
        receiveNext()
    }

    private func receiveNext() {
        task.receive { [weak self] result in
            guard let self else { return }
            self.lock.lock()
            switch result {
            case .success(.string(let s)):
                let obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? ["raw": s]
                self._items.append(.text(obj))
            case .success(.data(let d)):
                self._items.append(.binary(d))
            case .success:
                break
            case .failure(let error):
                self._error = error
            }
            self.lock.unlock()
            if case .success = result { self.receiveNext() }
        }
    }

    var items: [Item] { lock.lock(); defer { lock.unlock() }; return _items }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return _error }
    var texts: [[String: Any]] { items.compactMap { if case .text(let t) = $0 { return t }; return nil } }
    var binaries: [Data] { items.compactMap { if case .binary(let b) = $0 { return b }; return nil } }
    func texts(_ type: String) -> [[String: Any]] { texts.filter { $0["t"] as? String == type } }
    func headers(_ type: MediaType) -> [MediaHeader] { binaries.compactMap(MediaHeader.init).filter { $0.type == type } }

    func send(_ dict: [String: Any]) async throws {
        try await task.send(.string(Fixtures.json(dict)))
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

@MainActor
final class ServiceIntegrationTests: XCTestCase {
    var engine: MockEngine!
    var network: MockNetwork!
    var rtc: MockRTCFactory?
    var service: DashcastService!
    var awake: FakeDisplayAwake!

    override func setUp() async throws {
        engine = MockEngine()
        network = MockNetwork()
        awake = FakeDisplayAwake()
    }

    override func tearDown() async throws {
        await service?.stop()
        service = nil
    }

    /// Starts on `preferredPort` (8080 for the main test) and falls back to a free port if something
    /// else on this Mac holds it.
    func startService(preferredPort: UInt16 = 0, grace: TimeInterval = 0.6, settings: ServiceSettings = .init(),
                      configure: (inout ServerOptions) -> Void = { _ in }) async throws -> UInt16 {
        func make(_ port: UInt16) -> DashcastService {
            var options = ServerOptions()
            options.devPort = port
            options.plainHTTPPort = nil
            options.reconnectGracePeriod = grace
            configure(&options)
            return DashcastService(engine: engine, network: network, rtc: rtc, settings: settings, options: options,
                                   displayAwake: awake)
        }
        service = make(preferredPort)
        await service.start()
        if service.devPort == nil, preferredPort != 0 {
            print("Port \(preferredPort) busy; using an ephemeral port")
            await service.stop()
            service = make(0)
            await service.start()
        }
        return try XCTUnwrap(service.devPort)
    }

    // MARK: Main streaming flow on ws://127.0.0.1:8080/ws

    func testCarSessionEndToEnd() async throws {
        let port = try await startService(preferredPort: 8080)
        XCTAssertEqual(service.state.phase, .waitingForCar)
        XCTAssertEqual(service.state.displays.count, 1)
        XCTAssertTrue(service.state.screenRecordingGranted)
        XCTAssertEqual(network.localServicesStarts, 1)

        let client = WSClient(url: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        defer { client.close() }
        try await client.send(Fixtures.mcu2Hello)

        // config first…
        let gotConfig = await waitUntil(timeout: 5) { !client.texts("config").isEmpty }
        XCTAssertTrue(gotConfig, "no config; error: \(String(describing: client.error))")
        let config = try XCTUnwrap(client.texts("config").first)
        XCTAssertEqual(config["transport"] as? String, "ws")
        XCTAssertEqual(config["codec"] as? String, "avc1.4D401F")
        XCTAssertEqual(config["tier"] as? String, "mcu2")
        XCTAssertEqual(config["width"] as? Int, 1206)
        XCTAssertEqual(config["height"] as? Int, 752)
        XCTAssertEqual(config["fps"] as? Int, 30)
        XCTAssertEqual(config["bitrateKbps"] as? Int, 6000)
        XCTAssertEqual(config["latencyMode"] as? String, "interactive")
        XCTAssertEqual(config["inputEnabled"] as? Bool, true)
        XCTAssertEqual((config["audio"] as? [String: Int])?["channels"], 2)
        XCTAssertGreaterThan((config["serverTime"] as? NSNumber)?.uint64Value ?? 0, 0)

        let startConfig = try XCTUnwrap(engine.starts.first)
        XCTAssertEqual(engine.starts.count, 1)
        XCTAssertEqual(startConfig.width, 1206); XCTAssertEqual(startConfig.height, 752)
        XCTAssertEqual(startConfig.h264Profile, .auto)
        XCTAssertEqual(startConfig.displayWidth, 1280); XCTAssertEqual(startConfig.displayHeight, 800)
        XCTAssertEqual(startConfig.codec, .h264); XCTAssertEqual(startConfig.fps, 30)
        XCTAssertEqual(startConfig.bitrateKbps, 6000); XCTAssertTrue(startConfig.captureAudio)
        XCTAssertEqual(startConfig.displayMode, .extend); XCTAssertTrue(startConfig.hiDPI)

        // …then binary video + audio with correct headers.
        let gotMedia = await waitUntil(timeout: 5) {
            client.headers(.videoH264).count >= 15 && client.headers(.audioPCM).count >= 30
        }
        XCTAssertTrue(gotMedia)
        let items = client.items
        let configIndex = try XCTUnwrap(items.firstIndex { if case .text(let t) = $0 { return t["t"] as? String == "config" }; return false })
        let firstBinary = try XCTUnwrap(items.firstIndex { if case .binary = $0 { return true }; return false })
        XCTAssertLessThan(configIndex, firstBinary, "media before config")

        let video = client.headers(.videoH264)
        XCTAssertTrue(video[0].isKeyframe, "first video frame must be a keyframe")
        XCTAssertEqual(video.map(\.seq), Array(0..<UInt32(video.count)))
        XCTAssertEqual(zip(video, video.dropFirst()).filter { $0.pts > $1.pts }.count, 0)
        let audio = client.headers(.audioPCM)
        XCTAssertEqual(audio.map(\.seq), Array(0..<UInt32(audio.count)))
        XCTAssertTrue(audio.allSatisfy { $0.flags == 0 })
        for data in client.binaries {
            XCTAssertEqual(data[2], 0); XCTAssertEqual(data[3], 0)   // reserved
            let h = try XCTUnwrap(MediaHeader(data))
            if h.type == .videoH264 { XCTAssertEqual([UInt8](data[16..<20]), [0, 0, 0, 1]) }
            if h.type == .audioPCM { XCTAssertEqual(data.count, 16 + 1920) }
        }
        let nowMicros = DashClock.nowMicros()
        XCTAssertLessThan(nowMicros - video.last!.pts, 2_000_000)

        // ping → pong
        try await client.send(["t": "ping", "id": 7, "clientTime": 12.5])
        let gotPong = await waitUntil(timeout: 3) { !client.texts("pong").isEmpty }
        XCTAssertTrue(gotPong)
        let pong = try XCTUnwrap(client.texts("pong").first)
        XCTAssertEqual(pong["id"] as? Int, 7)
        XCTAssertEqual(pong["clientTime"] as? Double, 12.5)
        let serverTime = try XCTUnwrap((pong["serverTime"] as? NSNumber)?.uint64Value)
        XCTAssertLessThan(DashClock.nowMicros() - serverTime, 2_000_000)

        // input → engine
        try await client.send(["t": "input", "kind": "down", "x": 0.5, "y": 0.25, "dx": 0, "dy": 0])
        let injected = await waitUntil(timeout: 3) { !self.engine.injected.isEmpty }
        XCTAssertTrue(injected)
        XCTAssertEqual(engine.injected.first, InputEvent(kind: .down, x: 0.5, y: 0.25, dx: 0, dy: 0))

        // keyframe request → engine
        let before = engine.keyframeRequests
        try await client.send(["t": "keyframe"])
        let keyframeAsked = await waitUntil(timeout: 3) { self.engine.keyframeRequests > before }
        XCTAssertTrue(keyframeAsked)

        // acks feed congestion control without disturbing a healthy stream
        for h in video.prefix(10) {
            try await client.send(["t": "ack", "seq": h.seq, "recvAt": Double(h.pts) + 15_000, "decodeMs": 3.0, "presented": true])
        }

        // stats reach the UI state ~2×/s
        try await client.send(["t": "stats", "fps": 29.8, "decodeMs": 4.2, "dropped": 1, "queue": 0, "latencyMs": 61, "audioBufferMs": 40])
        let statsShown = await waitUntil(timeout: 3) {
            self.service.state.stats.decodeMs == 4.2 && self.service.state.stats.fps > 10 && self.service.state.stats.rttMs != nil
        }
        XCTAssertTrue(statsShown, "stats: \(service.state.stats)")
        XCTAssertEqual(service.state.stats.latencyMs, 61)
        XCTAssertEqual(service.state.stats.dropped, 1)
        XCTAssertGreaterThan(service.state.stats.bitrateKbps, 100)
        XCTAssertEqual(service.state.stats.effectiveLatencyMode, .interactive)
        XCTAssertEqual(service.debugSessionSnapshot().bitrateKbps, 6000)

        XCTAssertEqual(service.state.phase, .streaming)
        XCTAssertEqual(service.state.car?.computer, .mcu2)
        XCTAssertEqual(service.state.car?.tier, .mcu2)
        XCTAssertTrue(service.state.log.contains { $0.message.hasPrefix("Car connected · MCU2 · 1206×752 H.264 30 fps") },
                      service.state.log.map(\.message).joined(separator: "\n"))

        // Disconnect → waiting immediately, engine stopped after the grace period.
        client.close()
        let waiting = await waitUntil(timeout: 3) { self.service.state.phase == .waitingForCar && self.service.state.car == nil }
        XCTAssertTrue(waiting)
        XCTAssertEqual(engine.stops, 0, "engine stopped before the grace period")
        let stopped = await waitUntil(timeout: 3) { self.engine.stops == 1 }
        XCTAssertTrue(stopped)
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(service.state.phase, .waitingForCar)
        XCTAssertTrue(service.state.log.contains { $0.message.contains("stream stopped") })
    }

    // MARK: Session management

    func testReconnectWithinGraceKeepsEngine() async throws {
        let port = try await startService(grace: 1.0)
        let url = URL(string: "ws://127.0.0.1:\(port)/ws")!
        let first = WSClient(url: url)
        try await first.send(Fixtures.mcu2Hello)
        let firstConfigured = await waitUntil(timeout: 5) { !first.texts("config").isEmpty }
        XCTAssertTrue(firstConfigured)
        first.close()
        let waiting = await waitUntil(timeout: 3) { self.service.state.phase == .waitingForCar }
        XCTAssertTrue(waiting)

        let second = WSClient(url: url)
        defer { second.close() }
        try await second.send(Fixtures.mcu2Hello)
        let gotMedia = await waitUntil(timeout: 5) { !second.texts("config").isEmpty && second.headers(.videoH264).count > 3 }
        XCTAssertTrue(gotMedia)
        XCTAssertTrue(second.headers(.videoH264).first?.isKeyframe ?? false)
        try await Task.sleep(nanoseconds: 1_500_000_000)   // past the grace period
        XCTAssertEqual(engine.starts.count, 1)
        XCTAssertEqual(engine.stops, 0)
        XCTAssertEqual(service.state.phase, .streaming)
    }

    func testNewHelloReplacesOldSession() async throws {
        let port = try await startService()
        let url = URL(string: "ws://127.0.0.1:\(port)/ws")!
        let a = WSClient(url: url)
        defer { a.close() }
        try await a.send(Fixtures.mcu2Hello)
        let aConfigured = await waitUntil(timeout: 5) { !a.texts("config").isEmpty }
        XCTAssertTrue(aConfigured)

        let b = WSClient(url: url)
        defer { b.close() }
        try await b.send(Fixtures.mcu3Hello)
        let replaced = await waitUntil(timeout: 5) { !a.texts("bye").isEmpty && !b.texts("config").isEmpty }
        XCTAssertTrue(replaced)
        XCTAssertEqual(a.texts("bye").first?["reason"] as? String, "replaced")
        let aClosed = await waitUntil(timeout: 3) { a.error != nil }
        XCTAssertTrue(aClosed, "old socket should be closed")
        XCTAssertEqual(b.texts("config").first?["tier"] as? String, "mcu3-hevc")
        XCTAssertEqual(b.texts("config").first?["codec"] as? String, "hvc1.1.6.L123.B0")
        // Engine was reconfigured for the new car rather than restarted.
        XCTAssertEqual(engine.starts.count, 1)
        let updated = await waitUntil(timeout: 3) { self.engine.updates.count == 1 }
        XCTAssertTrue(updated)
        XCTAssertEqual(engine.updates.first?.codec, .hevc)
        XCTAssertEqual(engine.updates.first?.fps, 60)
        let hevc = await waitUntil(timeout: 3) { b.headers(.videoHEVC).count > 2 }
        XCTAssertTrue(hevc)
        XCTAssertTrue(b.headers(.videoH264).isEmpty, "no stale H.264 after the switch")
        XCTAssertEqual(service.state.car?.computer, .mcu3)
    }

    func testApplySettingsReconfiguresLiveSession() async throws {
        let port = try await startService()
        let client = WSClient(url: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        defer { client.close() }
        try await client.send(Fixtures.mcu2Hello)
        let configured = await waitUntil(timeout: 5) { !client.texts("config").isEmpty }
        XCTAssertTrue(configured)

        // Latency mode alone → a `mode` message, no reconfigure.
        service.settings.latencyMode = .cinema
        await service.applySettings()
        let mode = await waitUntil(timeout: 3) { client.texts("mode").last?["latencyMode"] as? String == "cinema" }
        XCTAssertTrue(mode)
        XCTAssertEqual(client.texts("config").count, 1)

        // Tier override → engine.update + a new config (+ keyframe).
        service.settings.tierOverrideID = "mcu2-low"
        await service.applySettings()
        let reconfigured = await waitUntil(timeout: 3) { client.texts("config").count == 2 }
        XCTAssertTrue(reconfigured)
        let config = try XCTUnwrap(client.texts("config").last)
        XCTAssertEqual(config["codec"] as? String, "jpeg")
        XCTAssertEqual(config["tier"] as? String, "mcu2-low")
        XCTAssertEqual(config["latencyMode"] as? String, "cinema")
        XCTAssertEqual(engine.updates.last?.codec, .jpeg)
        let jpeg = await waitUntil(timeout: 3) { client.headers(.videoJPEG).count > 2 }
        XCTAssertTrue(jpeg)
        XCTAssertTrue(client.headers(.videoJPEG).allSatisfy(\.isKeyframe))

        // Input disabled → not injected.
        service.settings.inputEnabled = false
        await service.applySettings()
        let third = await waitUntil(timeout: 3) { client.texts("config").count == 3 }
        XCTAssertTrue(third)
        XCTAssertEqual(client.texts("config").last?["inputEnabled"] as? Bool, false)
        try await client.send(["t": "input", "kind": "down", "x": 0.1, "y": 0.1])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(engine.injected.isEmpty)
    }

    func testAutoLatencyGoesCinemaWithAudio() async throws {
        engine.loudAudio = true
        let port = try await startService()
        let client = WSClient(url: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        defer { client.close() }
        try await client.send(Fixtures.mcu2Hello)
        let cinema = await waitUntil(timeout: 5) { client.texts("mode").last?["latencyMode"] as? String == "cinema" }
        XCTAssertTrue(cinema)
        // Touch → interactive right away.
        try await client.send(["t": "input", "kind": "down", "x": 0.5, "y": 0.5])
        let interactive = await waitUntil(timeout: 2) { client.texts("mode").last?["latencyMode"] as? String == "interactive" }
        XCTAssertTrue(interactive)
        // Car-side override pins it.
        try await client.send(["t": "setLatencyMode", "latencyMode": "cinema"])
        let pinned = await waitUntil(timeout: 2) { client.texts("mode").last?["latencyMode"] as? String == "cinema" }
        XCTAssertTrue(pinned)
    }

    func testEngineStartFailureEndsSession() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "screen capture unavailable" } }
        engine.startError = Boom()
        let port = try await startService()
        let client = WSClient(url: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        defer { client.close() }
        try await client.send(Fixtures.mcu2Hello)
        let bye = await waitUntil(timeout: 5) { !client.texts("bye").isEmpty }
        XCTAssertTrue(bye)
        XCTAssertEqual(service.state.phase, .error("screen capture unavailable"))
        XCTAssertNil(service.state.car)
    }

    // MARK: Backpressure

    /// A car that stops reading: the socket backs up, the server drops video (never audio), asks for a
    /// keyframe, and when the car reads again the stream resumes on a keyframe.
    func testSendSideDropsResumeOnKeyframe() async throws {
        engine.largeFrames = true
        let port = try await startService()
        let raw = try RawWebSocket(port: port)
        defer { raw.close() }
        try raw.handshake()
        try raw.sendText(Fixtures.json(Fixtures.mcu2Hello))

        let dropped = await waitUntil(timeout: 6) { self.service.debugSessionSnapshot().serverDropped > 5 }
        XCTAssertTrue(dropped, "server never dropped frames")
        let keyframeRequestsWhileBlocked = engine.keyframeRequests

        let frames = await raw.readFrames(for: 1.5)
        let headers = frames.compactMap { $0.opcode == .binary ? MediaHeader($0.payload) : nil }
        let video = headers.filter { $0.type == .videoH264 }
        let audio = headers.filter { $0.type == .audioPCM }
        XCTAssertGreaterThan(video.count, 5)
        XCTAssertEqual(video.map(\.seq), Array(0..<UInt32(video.count)), "seq must stay contiguous across drops")
        XCTAssertEqual(audio.map(\.seq), Array(0..<UInt32(audio.count)), "audio is never dropped")
        var resumedAfterGap = 0
        for (prev, next) in zip(video, video.dropFirst()) where next.pts - prev.pts > 60_000 {
            XCTAssertTrue(next.isKeyframe, "resumed on a delta frame after a \((next.pts - prev.pts) / 1000) ms gap")
            resumedAfterGap += 1
        }
        XCTAssertGreaterThan(resumedAfterGap, 0, "expected at least one gap from dropping")
        XCTAssertGreaterThan(engine.keyframeRequests, 1)
        _ = keyframeRequestsWhileBlocked
    }

    // MARK: HTTP over the real listener

    func testPageAndHealthzOverHTTP() async throws {
        let port = try await startService()
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let session = URLSession(configuration: .ephemeral)

        let (page, pageResponse) = try await session.data(from: base)
        let http = try XCTUnwrap(pageResponse as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertTrue(String(decoding: page, as: UTF8.self).lowercased().contains("<!doctype html"))

        let (index, _) = try await session.data(from: base.appendingPathComponent("index.html"))
        XCTAssertEqual(index, page)

        let (health, healthResponse) = try await session.data(from: base.appendingPathComponent("healthz"))
        XCTAssertEqual((healthResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: health, as: UTF8.self), "ok")
        XCTAssertEqual((healthResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control"), "no-store")

        let (_, missing) = try await session.data(from: base.appendingPathComponent("nope"))
        XCTAssertEqual((missing as? HTTPURLResponse)?.statusCode, 404)

        // Keep-alive: two requests on one connection.
        let twice = await rawHTTP(port: port, "GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\nGET /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        XCTAssertEqual(twice.components(separatedBy: "HTTP/1.1 200 OK").count - 1, 2)

        // DNS-rebinding guard.
        let foreign = await rawHTTP(port: port, "GET / HTTP/1.1\r\nHost: attacker.example:\(port)\r\n\r\n")
        XCTAssertTrue(foreign.hasPrefix("HTTP/1.1 403"), foreign)
        let crossSiteWS = await rawHTTP(port: port, "GET /ws HTTP/1.1\r\nHost: localhost:\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nOrigin: https://evil.example\r\n\r\n")
        XCTAssertTrue(crossSiteWS.hasPrefix("HTTP/1.1 403"), crossSiteWS)
        let bad = await rawHTTP(port: port, "BLAH\r\n\r\n")
        XCTAssertTrue(bad.hasPrefix("HTTP/1.1 400"), bad)
    }

    /// No certificate → HTTP mode: :80 answers the probes and serves the page + /ws itself.
    func testPlainListenerHTTPMode() async throws {
        rtc = MockRTCFactory()
        _ = try await startService { options in
            options.plainHTTPHost = "127.0.0.1"
            options.plainHTTPPort = 0
        }
        let port = try XCTUnwrap(service.plainHTTPPort)
        XCTAssertTrue(service.state.log.contains { $0.message.hasPrefix("HTTP mode") })
        let tesla = await rawHTTP(port: port, "GET / HTTP/1.1\r\nHost: connman.vn.tesla.services\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(tesla.hasPrefix("HTTP/1.1 200 OK\r\n"), tesla)
        XCTAssertTrue(tesla.contains("\r\nX-ConnMan-Status: online\r\n"))
        XCTAssertTrue(tesla.contains("\r\nContent-Type: text/html\r\n"))
        XCTAssertTrue(tesla.hasSuffix("\r\n\r\n<html><body>Connectivity OK</body></html>\n"))

        let apple = await rawHTTP(port: port, "GET /hotspot-detect.html HTTP/1.0\r\nHost: captive.apple.com\r\n\r\n")
        XCTAssertTrue(apple.hasPrefix("HTTP/1.1 200 OK\r\n"), apple)
        XCTAssertTrue(apple.hasSuffix("<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"))

        let page = await rawHTTP(port: port, "GET / HTTP/1.1\r\nHost: \(DashcastDefaults.serviceAddress)\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(page.hasPrefix("HTTP/1.1 200 OK\r\n"), page)
        XCTAssertTrue(page.contains("Content-Type: text/html; charset=utf-8"))

        let stray = await rawHTTP(port: port, "GET /whatever HTTP/1.1\r\nHost: example.com\r\n\r\n")
        XCTAssertTrue(stray.contains("\r\nLocation: http://\(DashcastDefaults.serviceAddress)/\r\n"), stray)

        // A car on plain HTTP (no `secure` flag in its hello): WebRTC, bound to the listener's address.
        let client = WSClient(url: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        defer { client.close() }
        var hello = Fixtures.httpModeHello
        var caps = hello["caps"] as! [String: Any]
        caps["secure"] = nil
        hello["caps"] = caps
        try await client.send(hello)
        let offered = await waitUntil(timeout: 5) { !client.texts("rtcOffer").isEmpty }
        XCTAssertTrue(offered)
        XCTAssertEqual(client.texts("config").first?["transport"] as? String, "webrtc")
        XCTAssertEqual(rtc?.peers.first?.options.bindAddress, "127.0.0.1")
    }

    /// Certificate present → HTTPS mode: :80 answers probes and redirects everything else to https.
    func testPlainListenerHTTPSModeRedirects() async throws {
        let pki = try TestPKI.make()
        defer { try? FileManager.default.removeItem(at: pki.dir) }
        network.material = pki.material
        _ = try await startService { options in
            options.plainHTTPHost = "127.0.0.1"
            options.plainHTTPPort = 0
            options.tlsHost = "127.0.0.1"
            options.tlsPort = 0
        }
        let port = try XCTUnwrap(service.plainHTTPPort)
        XCTAssertNotNil(service.tlsPort)
        XCTAssertTrue(service.state.log.contains { $0.message.hasPrefix("HTTPS mode") })
        let tesla = await rawHTTP(port: port, "GET / HTTP/1.1\r\nHost: connman.vn.tesla.services\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(tesla.contains("\r\nX-ConnMan-Status: online\r\n"), tesla)
        let other = await rawHTTP(port: port, "GET /whatever HTTP/1.1\r\nHost: example.com\r\n\r\n")
        XCTAssertTrue(other.hasPrefix("HTTP/1.1 301 Moved Permanently\r\n"), other)
        XCTAssertTrue(other.contains("\r\nLocation: https://\(TestPKI.hostname)/\r\n"), other)
        let own = await rawHTTP(port: port, "GET / HTTP/1.1\r\nHost: \(DashcastDefaults.serviceAddress)\r\n\r\n")
        XCTAssertTrue(own.contains("\r\nLocation: https://\(TestPKI.hostname)/\r\n"), own)

        // Certificate removed → back to HTTP mode on the next refresh.
        network.material = nil
        await service.refreshNetwork()
        XCTAssertNil(service.tlsPort)
        let served = await rawHTTP(port: port, "GET /healthz HTTP/1.1\r\nHost: \(DashcastDefaults.serviceAddress)\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(served.hasSuffix("\r\n\r\nok"), served)
    }

    // MARK: WebRTC transport

    func testWebRTCSession() async throws {
        let factory = MockRTCFactory()
        rtc = factory
        let port = try await startService()
        let client = WSClient(url: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        try await client.send(Fixtures.httpModeHello)

        // config (transport webrtc) then rtcOffer.
        let offered = await waitUntil(timeout: 5) { !client.texts("rtcOffer").isEmpty }
        XCTAssertTrue(offered, "no offer; texts: \(client.texts)")
        let texts = client.texts.map { $0["t"] as? String ?? "" }
        XCTAssertLessThan(try XCTUnwrap(texts.firstIndex(of: "config")), try XCTUnwrap(texts.firstIndex(of: "rtcOffer")))
        let config = try XCTUnwrap(client.texts("config").first)
        XCTAssertEqual(config["transport"] as? String, "webrtc")
        XCTAssertEqual(config["codec"] as? String, "avc1.42E01F")
        XCTAssertEqual(config["tier"] as? String, "mcu2")
        XCTAssertEqual(config["width"] as? Int, 1206)
        XCTAssertEqual(config["height"] as? Int, 752)
        XCTAssertEqual(config["fps"] as? Int, 30)
        XCTAssertEqual(client.texts("rtcOffer").first?["sdp"] as? String, MockPeer.offerSDP)

        let peer = try XCTUnwrap(factory.peers.first)
        XCTAssertEqual(factory.peers.count, 1)
        XCTAssertTrue(peer.started)
        XCTAssertEqual(peer.options.bindAddress, "127.0.0.1")   // dev listener → local testing works
        XCTAssertTrue(peer.options.audio)
        let engineConfig = try XCTUnwrap(engine.starts.first)
        XCTAssertEqual(engineConfig.h264Profile, .constrainedBaseline)
        XCTAssertEqual(engineConfig.codec, .h264)
        XCTAssertEqual(engineConfig.fps, 30)
        XCTAssertEqual(engineConfig.width, 1206)
        XCTAssertTrue(engineConfig.captureAudio)

        // Answer → setRemoteDescription.
        try await client.send(["t": "rtcAnswer", "sdp": "v=0\r\ns=car\r\n"])
        let answered = await waitUntil(timeout: 3) { peer.remote != nil }
        XCTAssertTrue(answered)
        XCTAssertEqual(peer.remote?.type, "answer")
        XCTAssertEqual(peer.remote?.sdp, "v=0\r\ns=car\r\n")

        // Media goes to the peer, never the socket.
        let flowing = await waitUntil(timeout: 5) { peer.videoFrames > 10 && peer.audioPackets > 20 }
        XCTAssertTrue(flowing)
        XCTAssertGreaterThan(peer.videoKeyframes, 0)
        XCTAssertTrue(client.binaries.isEmpty, "no binary media on the socket in WebRTC mode")

        // PLI → keyframe; REMB → clamped bitrate.
        let keyframesBefore = engine.keyframeRequests
        try await Task.sleep(nanoseconds: 300_000_000)   // past the keyframe-request rate limit
        peer.emit(.keyframeRequested)
        let pli = await waitUntil(timeout: 2) { self.engine.keyframeRequests > keyframesBefore }
        XCTAssertTrue(pli)
        peer.emit(.bitrateEstimate(kbps: 100))       // below the 25 % floor
        let floor = await waitUntil(timeout: 2) { self.engine.bitrates.last == 1500 }
        XCTAssertTrue(floor, "bitrates: \(engine.bitrates)")
        peer.emit(.bitrateEstimate(kbps: 99_000))    // above the tier
        let ceiling = await waitUntil(timeout: 2) { self.engine.bitrates.last == 6000 }
        XCTAssertTrue(ceiling, "bitrates: \(engine.bitrates)")

        // Input and stats still ride the WebSocket; acks aren't expected.
        try await client.send(["t": "input", "kind": "move", "x": 0.3, "y": 0.6])
        let injected = await waitUntil(timeout: 2) { !self.engine.injected.isEmpty }
        XCTAssertTrue(injected)
        try await client.send(["t": "stats", "fps": 30, "decodeMs": 2.5, "dropped": 0, "queue": 0, "latencyMs": 80])
        let stats = await waitUntil(timeout: 3) { self.service.state.stats.latencyMs == 80 && self.service.state.stats.fps > 10 }
        XCTAssertTrue(stats, "\(service.state.stats)")
        XCTAssertEqual(service.debugSessionSnapshot().transport, .webrtc)
        XCTAssertTrue(service.state.log.contains { $0.message.contains("H.264 over WebRTC") })
        XCTAssertTrue(service.state.log.contains { $0.message == "WebRTC connected" })

        // Closing the socket closes the peer.
        client.close()
        let closed = await waitUntil(timeout: 3) { peer.closed }
        XCTAssertTrue(closed)
    }

    func testWebRTCPeerFailureEndsSession() async throws {
        let factory = MockRTCFactory()
        rtc = factory
        let port = try await startService()
        let client = WSClient(url: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        defer { client.close() }
        try await client.send(Fixtures.httpModeHello)
        let offered = await waitUntil(timeout: 5) { !client.texts("rtcOffer").isEmpty }
        XCTAssertTrue(offered)
        let peer = try XCTUnwrap(factory.peers.first)
        peer.emit(.failed("ICE failed"))
        let bye = await waitUntil(timeout: 3) { client.texts("bye").first?["reason"] as? String == "rtc-failed" }
        XCTAssertTrue(bye)
        XCTAssertTrue(peer.closed)
        let waiting = await waitUntil(timeout: 3) { self.service.state.phase == .waitingForCar }
        XCTAssertTrue(waiting)
    }

    func testWebRTCCarWithoutFactoryGetsJPEG() async throws {
        let port = try await startService()
        let client = WSClient(url: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        defer { client.close() }
        try await client.send(Fixtures.httpModeHello)
        let jpeg = await waitUntil(timeout: 5) { client.headers(.videoJPEG).count > 2 }
        XCTAssertTrue(jpeg)
        XCTAssertEqual(client.texts("config").first?["transport"] as? String, "ws")
        XCTAssertEqual(client.texts("config").first?["codec"] as? String, "jpeg")
        XCTAssertTrue(client.texts("rtcOffer").isEmpty)
    }

    func testServiceAddressListenersFailGracefullyWithoutAlias() async throws {
        // The real service address isn't on lo0 on this Mac (unless the helper is installed).
        network.material = TLSMaterial(pkcs12URL: URL(fileURLWithPath: "/nonexistent.p12"), passphrase: "x", hostname: TestPKI.hostname)
        _ = try await startService { options in
            options.plainHTTPPort = 18_080
            options.tlsPort = 18_443
        }
        XCTAssertEqual(service.state.phase, .waitingForCar)
        XCTAssertNil(service.tlsPort)
        let messages = service.state.log.map(\.message)
        XCTAssertTrue(messages.contains { $0.contains("TLS certificate unusable") }, messages.joined(separator: "\n"))
        if service.plainHTTPPort == nil {
            XCTAssertTrue(messages.contains { $0.contains("\(DashcastDefaults.serviceAddress):18080") && $0.contains("will retry") })
        }
        // Refreshing again doesn't spam the log.
        let count = service.state.log.count
        await service.refreshNetwork()
        XCTAssertEqual(service.state.log.count, count)
    }

    func testStopClosesEverything() async throws {
        let port = try await startService()
        let client = WSClient(url: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        defer { client.close() }
        try await client.send(Fixtures.mcu2Hello)
        let configured = await waitUntil(timeout: 5) { !client.texts("config").isEmpty }
        XCTAssertTrue(configured)
        await service.stop()
        XCTAssertEqual(service.state.phase, .idle)
        XCTAssertEqual(engine.stops, 1)
        XCTAssertEqual(network.localServicesStops, 1)
        XCTAssertNil(service.devPort)
        let bye = await waitUntil(timeout: 3) { client.texts("bye").first?["reason"] as? String == "stopped" }
        XCTAssertTrue(bye)
        let refused = await rawHTTP(port: port, "GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n", timeout: 0.5)
        XCTAssertEqual(refused, "")
    }
}

// MARK: - Raw WebSocket client (for a client that stops reading)

final class RawWebSocket: @unchecked Sendable {
    let fd: Int32

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var small: Int32 = 32 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &small, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { throw TimeoutError() }
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private var leftover: [UInt8] = []

    func handshake() throws {
        writeAll(Array("GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8))
        var buf = [UInt8](repeating: 0, count: 4096)
        var got: [UInt8] = []
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let n = read(fd, &buf, buf.count)
            if n > 0 { got += buf[0..<n] }
            if let r = got.firstRange(of: Array("\r\n\r\n".utf8)) {
                XCTAssertTrue(String(decoding: got[..<r.lowerBound], as: UTF8.self).hasPrefix("HTTP/1.1 101"))
                leftover = Array(got[r.upperBound...])
                return
            }
        }
        throw TimeoutError()
    }

    func sendText(_ text: String) throws {
        writeAll([UInt8](WebSocketFrameEncoder.encode(WebSocketFrame(opcode: .text, payload: Data(text.utf8)), maskKey: [1, 2, 3, 4])))
    }

    private func writeAll(_ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return }
            offset += n
        }
    }

    /// Reads and parses server frames for `seconds`.
    func readFrames(for seconds: TimeInterval) async -> [WebSocketFrame] {
        let fd = self.fd
        let initial = leftover
        return await Task.detached {
            var parser = WebSocketFrameParser(requireMasked: false, maxPayload: 16 << 20)
            parser.append(initial)
            var frames: [WebSocketFrame] = []
            var buf = [UInt8](repeating: 0, count: 256 * 1024)
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                let n = read(fd, &buf, buf.count)
                if n > 0 { parser.append(Array(buf[0..<n])) }
                if n == 0 { break }
                while let f = try? parser.next() { frames.append(f) }
            }
            return frames
        }.value
    }

    func close() { Darwin.close(fd) }
}
