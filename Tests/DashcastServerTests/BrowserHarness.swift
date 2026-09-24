import DashcastContracts
import Foundation
import XCTest
@testable import DashcastServer

/// Not a regular test: serves Web/dist on http://127.0.0.1:8080 with a JPEG-emitting mock engine so a
/// real browser can be pointed at it. Runs only when DASHCAST_BROWSER_HARNESS=<seconds> is set.
/// Audio is disabled server-side (nothing to play). Service log + stats go to DASHCAST_HARNESS_LOG.
@MainActor
final class BrowserHarness: XCTestCase {
    func testServeForBrowser() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let seconds = env["DASHCAST_BROWSER_HARNESS"].flatMap(Double.init) else {
            throw XCTSkip("set DASHCAST_BROWSER_HARNESS=<seconds> to run")
        }
        let logURL = env["DASHCAST_HARNESS_LOG"].map { URL(fileURLWithPath: $0) }
        let webDist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Web/dist", isDirectory: true)

        let engine = MockEngine()
        engine.realJPEG = true
        var settings = ServiceSettings()
        settings.audioEnabled = false
        settings.tierOverrideID = env["DASHCAST_HARNESS_TIER"] ?? "mcu2-low"
        var options = ServerOptions()
        options.plainHTTPPort = nil
        options.clientDirectory = webDist
        let service = DashcastService(engine: engine, network: MockNetwork(), settings: settings, options: options)
        await service.start()
        XCTAssertEqual(service.devPort, 8080)

        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if let logURL {
                let s = service.state.stats
                let car = service.state.car.map { "\($0.computer.rawValue) \($0.tier.id)" } ?? "none"
                let text = service.state.log.map { "\($0.date.formatted(date: .omitted, time: .standard)) \($0.message)" }
                    .joined(separator: "\n")
                    + "\n--\nphase=\(service.state.phase) car=\(car) fps=\(s.fps) kbps=\(s.bitrateKbps) decodeMs=\(s.decodeMs ?? -1) latencyMs=\(s.latencyMs ?? -1) rttMs=\(s.rttMs ?? -1) dropped=\(s.dropped) mode=\(s.effectiveLatencyMode.rawValue) injected=\(engine.injected.count) keyframeRequests=\(engine.keyframeRequests)\n"
                try? text.write(to: logURL, atomically: true, encoding: .utf8)
            }
        }
        await service.stop()
    }
}
