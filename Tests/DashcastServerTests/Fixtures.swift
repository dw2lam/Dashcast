import DashcastContracts
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import DashcastServer

// MARK: - Hello builders

enum Fixtures {
    static func helloDict(ua: String = "Mozilla/5.0 (X11; Linux) Chrome/140 Tesla/2026.20",
                          w: Double = 1280, h: Double = 800, dpr: Double = 1,
                          webcodecs: Bool = true, high: Bool = true, main: Bool = true, baseline: Bool = true,
                          hevc: Bool = false, d720: Double? = nil, d1080: Double? = nil,
                          includeBench: Bool = true, secure: Bool? = true, webrtc: Bool? = true) -> [String: Any] {
        var caps: [String: Any] = ["webcodecs": webcodecs, "h264": ["high": high, "main": main, "baseline": baseline],
                                   "hevc": hevc, "hwAccel": "unknown", "audioWorklet": true, "offscreenCanvas": true, "webgl": true]
        if let secure { caps["secure"] = secure }
        if let webrtc { caps["webrtc"] = webrtc }
        var dict: [String: Any] = [
            "t": "hello", "version": 1, "ua": ua,
            "viewport": ["w": w, "h": h, "dpr": dpr],
            "caps": caps,
        ]
        if includeBench {
            dict["bench"] = ["h264_720p_decodeMs": d720 ?? NSNull(), "h264_1080p_decodeMs": d1080 ?? NSNull(),
                             "jpegDecodeMs": 4.0] as [String: Any]
        }
        return dict
    }

    static func hello(_ dict: [String: Any]) -> ClientHello {
        guard let hello = ClientMessage.parseHello(dict) else { fatalError("bad hello fixture") }
        return hello
    }

    static func json(_ dict: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: dict), encoding: .utf8)!
    }

    /// An MCU2-like car: Intel Atom, slow-ish software-ish decode.
    static var mcu2Hello: [String: Any] { helloDict(w: 1280, h: 800, dpr: 1, hevc: false, d720: 9.5, d1080: 21) }
    /// An MCU3-like car: AMD Ryzen, fast hardware decode.
    static var mcu3Hello: [String: Any] { helloDict(w: 1920, h: 1200, dpr: 1, hevc: true, d720: 1.1, d1080: 2.4) }
    /// A car on plain HTTP: not a secure context, so no WebCodecs and no bench; WebRTC available.
    static var httpModeHello: [String: Any] {
        helloDict(w: 1280, h: 800, webcodecs: false, high: false, main: false, baseline: false,
                  includeBench: false, secure: false, webrtc: true)
    }

    static func stats(fps: Double = 30, decodeMs: Double, dropped: Int = 0) -> ClientStats {
        ClientMessage.parseStats(["fps": fps, "decodeMs": decodeMs, "dropped": dropped, "queue": 0])!
    }
}

// MARK: - Mock engine

/// Emits fake video at 30 fps and 10 ms audio packets once started. Thread-safe.
final class MockEngine: StreamEngineProtocol, @unchecked Sendable {
    var onVideo: ((EncodedVideoFrame) -> Void)?
    var onAudio: ((AudioPacket) -> Void)?
    var onEvent: ((EngineEvent) -> Void)?

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "mock.engine")
    private var videoTimer: DispatchSourceTimer?
    private var audioTimer: DispatchSourceTimer?
    private var frameIndex = 0
    private var forceKeyframe = true
    private var config: StreamConfig?

    private var _starts: [StreamConfig] = []
    private var _updates: [StreamConfig] = []
    private var _stops = 0
    private var _keyframeRequests = 0
    private var _bitrates: [Int] = []
    private var _injected: [InputEvent] = []

    var startError: Error?
    var loudAudio = false
    /// ~6 MB/s of video, to back up a socket quickly.
    var largeFrames = false
    /// Emit decodable JPEGs (a moving bar + frame counter) when the codec is JPEG (browser harness).
    var realJPEG = false

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    var starts: [StreamConfig] { locked { _starts } }
    var updates: [StreamConfig] { locked { _updates } }
    var stops: Int { locked { _stops } }
    var keyframeRequests: Int { locked { _keyframeRequests } }
    var bitrates: [Int] { locked { _bitrates } }
    var injected: [InputEvent] { locked { _injected } }
    var isRunning: Bool { locked { videoTimer != nil } }

    func start(_ config: StreamConfig) async throws {
        if let startError { throw startError }
        locked { _starts.append(config); self.config = config; forceKeyframe = true }
        startTimers()
        onEvent?(.started(capturedDisplayID: 42))
    }

    func update(_ config: StreamConfig) async throws {
        locked { _updates.append(config); self.config = config; forceKeyframe = true }
    }

    func stop() async {
        let timers: [DispatchSourceTimer?] = locked {
            _stops += 1
            let t = [videoTimer, audioTimer]
            videoTimer = nil; audioTimer = nil
            return t
        }
        timers.forEach { $0?.cancel() }
        onEvent?(.stopped)
    }

    func requestKeyframe() { locked { _keyframeRequests += 1; forceKeyframe = true } }
    func setBitrate(kbps: Int) { locked { _bitrates.append(kbps) } }
    func inject(_ event: InputEvent) { locked { _injected.append(event) } }
    func availableDisplays() -> [DisplayInfo] { [DisplayInfo(id: 1, name: "Built-in", width: 3024, height: 1964, isVirtual: false)] }
    func hasScreenRecordingPermission() -> Bool { true }
    func requestScreenRecordingPermission() {}
    func hasAccessibilityPermission() -> Bool { false }
    func requestAccessibilityPermission() {}

    private func startTimers() {
        let video = DispatchSource.makeTimerSource(queue: queue)
        video.schedule(deadline: .now(), repeating: 1.0 / 30)
        video.setEventHandler { [weak self] in self?.emitVideo() }
        let audio = DispatchSource.makeTimerSource(queue: queue)
        audio.schedule(deadline: .now(), repeating: 0.01)
        audio.setEventHandler { [weak self] in self?.emitAudio() }
        locked { videoTimer = video; audioTimer = audio }
        video.resume()
        audio.resume()
    }

    private func emitVideo() {
        let (codec, key, index, large): (VideoCodec, Bool, Int, Bool) = locked {
            let key = forceKeyframe || frameIndex % 60 == 0
            forceKeyframe = false
            frameIndex += 1
            return (config?.codec ?? .h264, key, frameIndex, largeFrames)
        }
        if codec == .jpeg, locked({ realJPEG }), let cfg = locked({ config }),
           let jpeg = TestImages.jpeg(width: cfg.width, height: cfg.height, frame: index) {
            onVideo?(EncodedVideoFrame(pts: DashClock.nowMicros(), isKeyframe: true, codec: .jpeg, data: jpeg))
            return
        }
        var data = Data([0, 0, 0, 1, key ? 0x65 : 0x41])
        let size = large ? (key ? 400_000 : 200_000) : (key ? 6000 : 1500)
        data.append(Data(repeating: UInt8(index & 0xFF), count: size))
        onVideo?(EncodedVideoFrame(pts: DashClock.nowMicros(), isKeyframe: key, codec: codec, data: data))
    }

    private func emitAudio() {
        var samples = [Int16](repeating: 0, count: 960)
        if locked({ loudAudio }) {
            for i in 0..<480 {
                let s = Int16(8000 * sin(Double(i) * 2 * .pi * 440 / 48000))
                samples[2 * i] = s; samples[2 * i + 1] = s
            }
        }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }   // little-endian host
        onAudio?(AudioPacket(pts: DashClock.nowMicros(), data: data))
    }
}

// MARK: - Mock network

@MainActor
final class MockNetwork: NetworkManaging {
    var status = NetworkStatus()
    var material: TLSMaterial?
    var localServicesStarts = 0
    var localServicesStops = 0

    func currentStatus() async -> NetworkStatus { status }
    func installLoopbackHelper() async throws {}
    func uninstallLoopbackHelper() async throws {}
    func setOwnDomain(_ domain: OwnDomain?) throws { status.domain = domain }
    func setCloudflareToken(_ token: String) throws {}
    func hasCloudflareToken() -> Bool { false }
    func provisionCertificate() async throws {}
    func importCertificate(_ certificate: CertificateImport) async throws {}
    func tlsMaterial() -> TLSMaterial? { material }
    func routerSetupScript(macLANAddress: String) -> String { "" }
    func startLocalServices() async { localServicesStarts += 1 }
    func stopLocalServices() async { localServicesStops += 1 }
}

// MARK: - Async helpers

@MainActor
func waitUntil(timeout: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

struct TimeoutError: Error {}

func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// Blocking raw TCP exchange (lets tests set any Host header). Returns everything read until the
/// server closes or `timeout` passes.
func rawHTTP(port: UInt16, host: String = "127.0.0.1", _ request: String, timeout: TimeInterval = 2) async -> String {
    await Task.detached {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return "" }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { return "" }
        let bytes = Array(request.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return String(decoding: out, as: UTF8.self)
    }.value
}

// MARK: - Mock WebRTC

final class MockPeer: RTCPeerProtocol, @unchecked Sendable {
    var onEvent: ((RTCPeerEvent) -> Void)?
    let options: RTCPeerOptions
    private let lock = NSLock()
    private var _started = false
    private var _remote: (type: String, sdp: String)?
    private var _video = 0
    private var _videoKeyframes = 0
    private var _audio = 0
    private var _closed = false
    static let offerSDP = "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=dashcast-mock\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=sendonly\r\n"

    init(options: RTCPeerOptions) { self.options = options }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var started: Bool { locked { _started } }
    var remote: (type: String, sdp: String)? { locked { _remote } }
    var videoFrames: Int { locked { _video } }
    var videoKeyframes: Int { locked { _videoKeyframes } }
    var audioPackets: Int { locked { _audio } }
    var closed: Bool { locked { _closed } }

    func start() throws {
        locked { _started = true }
        // ICE gathering "finishes" a moment later on a library thread.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.onEvent?(.localDescription(type: "offer", sdp: Self.offerSDP))
        }
    }

    func setRemoteDescription(type: String, sdp: String) throws {
        locked { _remote = (type, sdp) }
        DispatchQueue.global().async { [weak self] in self?.onEvent?(.connected) }
    }

    func send(video frame: EncodedVideoFrame) { locked { _video += 1; if frame.isKeyframe { _videoKeyframes += 1 } } }
    func send(audio packet: AudioPacket) { locked { _audio += 1 } }
    func close() { locked { _closed = true } }

    /// Simulate the browser/library side.
    func emit(_ event: RTCPeerEvent) { onEvent?(event) }
}

final class MockRTCFactory: RTCPeerFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var _peers: [MockPeer] = []
    var peers: [MockPeer] { lock.lock(); defer { lock.unlock() }; return _peers }

    func makePeer(options: RTCPeerOptions) -> RTCPeerProtocol {
        let peer = MockPeer(options: options)
        lock.lock(); _peers.append(peer); lock.unlock()
        return peer
    }
}

enum TestImages {
    /// A test card: dark background, a bar sweeping left → right, and a white square that blinks.
    static func jpeg(width: Int, height: Int, frame: Int) -> Data? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.05, green: 0.08, blue: 0.16, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let barW = CGFloat(width) / 10
        let x = CGFloat(frame % 60) / 60 * (CGFloat(width) - barW)
        ctx.setFillColor(CGColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: x, y: 0, width: barW, height: CGFloat(height)))
        if frame % 30 < 15 {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 20, y: 20, width: 60, height: 60))
        }
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
