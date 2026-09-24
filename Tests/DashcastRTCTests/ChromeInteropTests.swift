import DashcastContracts
@testable import DashcastRTC
import Foundation
import Network
import XCTest

/// Chrome interop: our peer (bound to 127.0.0.1) streams real H.264 + Opus to Vendor/dev/rtc-interop.html
/// through a tiny HTTP signaling shim. Opt-in, because a browser has to open the page:
///
///   DASHCAST_CHROME_INTEROP=1 swift test --filter ChromeInteropTests --scratch-path .build/rtc
///   → open http://127.0.0.1:8765/ in Chrome (the page is muted: no sound)
///
/// The page posts its getStats() every second; the test passes once Chrome decodes our video
/// (framesDecoded rising, videoWidth 1280) and receives our audio (packetsReceived rising), and it
/// prints the numbers plus this process's CPU while streaming 720p30.
final class ChromeInteropTests: XCTestCase {
    func testChromeReceivesVideoAndAudio() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["DASHCAST_CHROME_INTEROP"] == "1", "set DASHCAST_CHROME_INTEROP=1 and open the page in Chrome")
        let port = UInt16(env["DASHCAST_INTEROP_PORT"] ?? "") ?? 8765
        let waitSeconds = Double(env["DASHCAST_INTEROP_WAIT"] ?? "") ?? 240
        let streamSeconds = Double(env["DASHCAST_INTEROP_STREAM"] ?? "") ?? 20

        let page = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/dev/rtc-interop.html")
        let shim = try InteropShim(port: port, page: try Data(contentsOf: page), units: try H264Fixture.accessUnits())
        defer { shim.stop() }
        print("[chrome] open http://127.0.0.1:\(port)/ (waiting up to \(Int(waitSeconds)) s)")

        // 1. Chrome connects and decodes.
        let connected = shim.waitForStats(timeout: waitSeconds) { ($0["state"] as? String) == "connected" && Self.framesDecoded($0) > 0 }
        let first = try XCTUnwrap(connected, "Chrome never connected/decoded")
        let cpuStart = ProcessCPU.nanos()
        let sendStart = shim.feeder.totals
        let wallStart = Date()

        // 2. Stream for a while; measure.
        Thread.sleep(forTimeInterval: streamSeconds)
        let wall = Date().timeIntervalSince(wallStart)
        let cpu = Double(ProcessCPU.nanos() - cpuStart) / 1e9
        let sendEnd = shim.feeder.totals
        let last = try XCTUnwrap(shim.latestStats)

        let decoded = Self.framesDecoded(last) - Self.framesDecoded(first)
        let audioPackets = Self.int(last, "audio", "packetsReceived") - Self.int(first, "audio", "packetsReceived")
        let sendCPU = Double(sendEnd.sendCPUNanos - sendStart.sendCPUNanos) / 1e9
        let bitrate = Double(sendEnd.videoBytes - sendStart.videoBytes) * 8 / wall / 1000
        print("""
        [chrome] over \(String(format: "%.1f", wall)) s: framesDecoded +\(decoded) (\(String(format: "%.1f", Double(decoded) / wall)) fps), \
        audio packetsReceived +\(audioPackets); video \(last["videoWidth"] ?? "?")x\(last["videoHeight"] ?? "?"); \
        video bitrate \(Int(bitrate)) kbps
        [chrome] CPU (whole test process: peer + Opus + feeder + shim) \(String(format: "%.1f", cpu / wall * 100))% of one core; \
        inside send(video:)/send(audio:) \(String(format: "%.1f", sendCPU / wall * 100))%
        [chrome] audio probe (MediaStreamTrackProcessor, never played): \(Self.json(last["audioProbe"] ?? "none"))
        [chrome] peer: selected pair \(shim.selectedPair ?? "-"); keyframe requests \(shim.keyframeRequests)
        [chrome] last getStats: \(Self.json(last))
        """)

        XCTAssertEqual(last["videoWidth"] as? Int, H264Fixture.width)
        XCTAssertEqual(last["videoHeight"] as? Int, H264Fixture.height)
        XCTAssertGreaterThan(Double(decoded), wall * 25, "framesDecoded should rise at ~30 fps")
        XCTAssertGreaterThan(Double(audioPackets), wall * 40, "audio packetsReceived should rise at 50/s")
        XCTAssertEqual(last["muted"] as? Bool, true, "the page must stay muted")
        let remoteOut = last["remoteOut"] as? [String: Any]
        XCTAssertGreaterThan(Self.int(remoteOut?["video"], "reportsSent"), 0, "Chrome saw no video sender reports")
        XCTAssertGreaterThan(Self.int(remoteOut?["audio"], "reportsSent"), 0, "Chrome saw no audio sender reports")
        XCTAssertTrue(shim.selectedPair?.contains("prflx") == true, "expected a peer-reflexive remote: \(shim.selectedPair ?? "-")")
    }

    static func framesDecoded(_ stats: [String: Any]) -> Int { int(stats, "video", "framesDecoded") }

    static func int(_ stats: [String: Any], _ group: String, _ key: String) -> Int {
        int(stats[group], key)
    }

    static func int(_ object: Any?, _ key: String) -> Int {
        ((object as? [String: Any])?[key] as? NSNumber)?.intValue ?? 0
    }

    static func json(_ object: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\(object)"
    }
}

/// Minimal HTTP/1.1 signaling server on 127.0.0.1 (one request per connection).
final class InteropShim: @unchecked Sendable {
    let feeder: MediaFeeder
    private let listener: NWListener
    private let queue = DispatchQueue(label: "interop.shim")
    private let page: Data
    private let factory = DataChannelPeerFactory()
    private let lock = NSCondition()
    private var peer: DataChannelPeer?
    private var events = EventRecorder()
    private var stats: [[String: Any]] = []

    init(port: UInt16, page: Data, units: [H264Fixture.AccessUnit]) throws {
        self.page = page
        feeder = MediaFeeder(units: units)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed(let error) = state { print("[chrome] listener failed: \(error)"); ready.signal() }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)

        // L 440 Hz, R 660 Hz: a mono downmix in the browser shows up as L/R correlation ≈ 1.
        feeder.makeAudio = { SinePCM.packet(index: $0, frequency: 440, rightFrequency: 660) }
        feeder.sendVideo = { [weak self] frame in self?.currentPeer?.send(video: frame) }
        feeder.sendAudio = { [weak self] packet in self?.currentPeer?.send(audio: packet) }
        feeder.start()
    }

    func stop() {
        listener.cancel()
        feeder.stop()
        currentPeer?.close()
    }

    var currentPeer: DataChannelPeer? { lock.withLock { peer } }
    var latestStats: [String: Any]? { lock.withLock { stats.last } }
    var keyframeRequests: Int { lock.withLock { events }.keyframeRequests }
    var selectedPair: String? {
        currentPeer?.selectedCandidatePair().map { "\($0.local) ⇄ \($0.remote)" }
    }

    func waitForStats(timeout: TimeInterval, _ predicate: ([String: Any]) -> Bool) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock()
        defer { lock.unlock() }
        while true {
            if let last = stats.last, predicate(last) { return last }
            if !lock.wait(until: deadline) { return nil }
        }
    }

    // MARK: HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                DispatchQueue.global().async { self.handle(request, on: connection) }
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private struct Request { var method: String; var path: String; var body: Data }

    private static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        let length = lines.dropFirst().compactMap { line -> Int? in
            let kv = line.split(separator: ":", maxSplits: 1)
            guard kv.count == 2, kv[0].lowercased() == "content-length" else { return nil }
            return Int(kv[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(parts[0]), path: String(parts[1]), body: Data(body.prefix(length)))
    }

    private func handle(_ request: Request, on connection: NWConnection) {
        var status = "200 OK"
        var type = "application/json"
        var body = Data("{}".utf8)
        switch (request.method, request.path.split(separator: "?").first.map(String.init) ?? "/") {
        case ("GET", "/"):
            type = "text/html; charset=utf-8"
            body = page
        case ("GET", "/offer"):
            if let sdp = newOffer() {
                body = (try? JSONSerialization.data(withJSONObject: ["type": "offer", "sdp": sdp])) ?? body
            } else {
                status = "500 Internal Server Error"
            }
        case ("POST", "/answer"):
            let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            var sdp = json?["sdp"] as? String ?? ""
            if json?["stripCandidates"] as? Bool == true {
                sdp = sdp.components(separatedBy: "\r\n").filter { !$0.hasPrefix("a=candidate") }.joined(separator: "\r\n")
            }
            do {
                try currentPeer?.setRemoteDescription(type: "answer", sdp: sdp)
                print("[chrome] answer applied (\(sdp.count) bytes, candidates stripped)")
            } catch {
                status = "500 Internal Server Error"
                print("[chrome] setRemoteDescription failed: \(error)")
            }
        case ("POST", "/stats"):
            if let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] {
                lock.withLock {
                    stats.append(json)
                    lock.broadcast()
                }
            }
        default:
            status = "404 Not Found"
        }
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// One peer per page load (a reload replaces it).
    private func newOffer() -> String? {
        currentPeer?.close()
        let peer = factory.makePeer(options: RTCPeerOptions(bindAddress: "127.0.0.1", audio: true)) as! DataChannelPeer
        let events = EventRecorder()
        peer.onEvent = { [weak self] event in
            events.record(event)
            switch event {
            case .keyframeRequested: self?.feeder.requestKeyframe()
            case .connected: print("[chrome] peer connected")
            case .disconnected: print("[chrome] peer disconnected")
            case .failed(let why): print("[chrome] peer failed: \(why)")
            case .bitrateEstimate(let kbps): if kbps > 0 { self?.noteREMB(kbps) }
            case .localDescription: break
            }
        }
        lock.withLock {
            self.peer = peer
            self.events = events
            self.stats.removeAll()
        }
        do { try peer.start() } catch { print("[chrome] start failed: \(error)"); return nil }
        events.wait(timeout: 5) { EventRecorder.offer(in: $0) != nil }
        return events.offer
    }

    private var lastREMBLog = Date.distantPast
    private func noteREMB(_ kbps: Int) {
        let now = Date()
        guard now.timeIntervalSince(lastREMBLog) > 5 else { return }
        lastREMBLog = now
        print("[chrome] REMB \(kbps) kbps")
    }
}
