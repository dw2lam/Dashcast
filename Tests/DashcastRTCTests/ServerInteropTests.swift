import DashcastContracts
@testable import DashcastRTC
import DashcastServer
import Foundation
import XCTest

/// The real thing minus capture: the real `DashcastService` (HTTP + WebSocket + session logic) with
/// `DataChannelPeerFactory`, serving the real built client (Web/dist), fed by a synthetic engine
/// (libx264 fixture + a sine). Opt-in, because Chrome has to open the page:
///
///   DASHCAST_SERVER_INTEROP=1 swift test --filter ServerInteropTests --scratch-path .build/rtc
///   → open http://127.0.0.1:8766/?forceWebRTC=1&mute=1   (?mute=1: zero gain, no sound)
@MainActor
final class ServerInteropTests: XCTestCase {
    func testRealServerAndClientOverWebRTC() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["DASHCAST_SERVER_INTEROP"] == "1", "set DASHCAST_SERVER_INTEROP=1 and open the page in Chrome")
        let port = UInt16(env["DASHCAST_INTEROP_PORT"] ?? "") ?? 8766
        let waitSeconds = Double(env["DASHCAST_INTEROP_WAIT"] ?? "") ?? 240
        let streamSeconds = Double(env["DASHCAST_INTEROP_STREAM"] ?? "") ?? 20

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let client = root.appendingPathComponent("Web/dist")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: client.appendingPathComponent("index.html").path),
                          "Web/dist not built")

        let engine = SyntheticEngine(units: try H264Fixture.accessUnits())
        var options = ServerOptions()
        options.devHost = "127.0.0.1"
        options.devPort = port
        options.plainHTTPPort = nil
        options.clientDirectory = client
        var settings = ServiceSettings()
        settings.audioEnabled = true
        let service = DashcastService(engine: engine, network: StubNetwork(), rtc: DataChannelPeerFactory(),
                                      settings: settings, options: options)
        await service.start()
        defer { Task { await service.stop() } }
        print("[server] open http://127.0.0.1:\(service.devPort ?? port)/?forceWebRTC=1&mute=1 (waiting up to \(Int(waitSeconds)) s)")

        // 1. A car (Chrome) connects over WebRTC and reports decoding.
        let deadline = Date().addingTimeInterval(waitSeconds)
        while Date() < deadline, !(service.state.phase == .streaming && service.state.stats.fps > 20) {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTAssertEqual(service.state.phase, .streaming, "no car streaming; log: \(service.state.log.suffix(10).map(\.message))")
        guard service.state.phase == .streaming else { return }

        // 2. Stream; measure.
        let cpuStart = ProcessCPU.nanos()
        let wallStart = Date()
        let framesStart = engine.feeder.totals.videoFrames
        var fpsSamples: [Double] = []
        while Date().timeIntervalSince(wallStart) < streamSeconds {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            fpsSamples.append(service.state.stats.fps)
        }
        let wall = Date().timeIntervalSince(wallStart)
        let cpu = Double(ProcessCPU.nanos() - cpuStart) / 1e9
        let stats = service.state.stats
        print("""
        [server] car: \(String(describing: service.state.car))
        [server] client-reported stats: fps \(fpsSamples.map { Int($0.rounded()) }), decodeMs \(stats.decodeMs.map { String(format: "%.2f", $0) } ?? "-"), \
        latencyMs \(stats.latencyMs.map { String(format: "%.0f", $0) } ?? "-"), dropped \(stats.dropped)
        [server] engine: \(engine.feeder.totals.videoFrames - framesStart) frames sent in \(String(format: "%.1f", wall)) s, \
        keyframe requests \(engine.keyframeRequests), setBitrate \(engine.bitrates.suffix(5))
        [server] CPU (whole process: server + peer + Opus + feeder) \(String(format: "%.1f", cpu / wall * 100))% of one core
        [server] log: \(service.state.log.map(\.message).filter { $0.localizedCaseInsensitiveContains("rtc") || $0.localizedCaseInsensitiveContains("car") || $0.localizedCaseInsensitiveContains("stream") }.suffix(12))
        """)
        XCTAssertGreaterThan(fpsSamples.suffix(5).reduce(0, +) / 5, 25, "client-reported fps")
        XCTAssertGreaterThanOrEqual(engine.keyframeRequests, 1, "connect → keyframe")
    }
}

/// StreamEngineProtocol over the H.264 fixture + sine audio (L 440 Hz, R 660 Hz).
final class SyntheticEngine: StreamEngineProtocol, @unchecked Sendable {
    var onVideo: ((EncodedVideoFrame) -> Void)?
    var onAudio: ((AudioPacket) -> Void)?
    var onEvent: ((EngineEvent) -> Void)?

    let feeder: MediaFeeder
    private let lock = NSLock()
    private var running = false
    private var keyframes = 0
    private var bitrateLog: [Int] = []

    init(units: [H264Fixture.AccessUnit]) {
        feeder = MediaFeeder(units: units)
        feeder.makeAudio = { SinePCM.packet(index: $0, frequency: 440, rightFrequency: 660) }
        feeder.sendVideo = { [weak self] in self?.onVideo?($0) }
        feeder.sendAudio = { [weak self] in self?.onAudio?($0) }
    }

    var keyframeRequests: Int { lock.withLock { keyframes } }
    var bitrates: [Int] { lock.withLock { bitrateLog } }

    func start(_ config: StreamConfig) async throws {
        print("[server] engine.start \(config.width)x\(config.height)@\(config.fps) \(config.codec) \(config.bitrateKbps) kbps audio=\(config.captureAudio) profile=\(config.h264Profile)")
        let wasRunning = lock.withLock { () -> Bool in defer { running = true }; return running }
        if !wasRunning { feeder.start() }
        onEvent?(.started(capturedDisplayID: 1))
    }

    func update(_ config: StreamConfig) async throws {
        print("[server] engine.update \(config.width)x\(config.height)@\(config.fps) \(config.codec) \(config.bitrateKbps) kbps")
        feeder.requestKeyframe()
    }

    func stop() async {
        let wasRunning = lock.withLock { () -> Bool in defer { running = false }; return running }
        if wasRunning { feeder.stop() }
        onEvent?(.stopped)
    }

    func requestKeyframe() {
        lock.withLock { keyframes += 1 }
        feeder.requestKeyframe()
    }

    func setBitrate(kbps: Int) { lock.withLock { bitrateLog.append(kbps) } }
    func inject(_ event: InputEvent) {}
    func availableDisplays() -> [DisplayInfo] { [] }
    func hasScreenRecordingPermission() -> Bool { true }
    func requestScreenRecordingPermission() {}
    func hasAccessibilityPermission() -> Bool { true }
    func requestAccessibilityPermission() {}
}

@MainActor
final class StubNetwork: NetworkManaging {
    func currentStatus() async -> NetworkStatus { NetworkStatus() }
    func installLoopbackHelper() async throws {}
    func uninstallLoopbackHelper() async throws {}
    func setOwnDomain(_ domain: OwnDomain?) throws {}
    func setCloudflareToken(_ token: String) throws {}
    func hasCloudflareToken() -> Bool { false }
    func provisionCertificate() async throws {}
    func importCertificate(_ certificate: CertificateImport) async throws {}
    func tlsMaterial() -> TLSMaterial? { nil }
    func routerSetupScript(macLANAddress: String) -> String { "" }
}
