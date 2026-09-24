import CoreGraphics
import CoreVideo
import DashcastContracts
import Foundation
import XCTest
@testable import DashcastStream

/// End-to-end: real ScreenCaptureKit capture. Skipped when the test process lacks Screen Recording.
final class StreamEngineTests: XCTestCase {
    private final class Sink {
        let video = Recorder<EncodedVideoFrame>()
        let audio = Recorder<AudioPacket>()
        let events = Recorder<EngineEvent>()

        init(_ engine: StreamEngine) {
            engine.onVideo = video.append
            engine.onAudio = audio.append
            engine.onEvent = events.append
        }

        var started: [CGDirectDisplayID] {
            events.items.compactMap { if case .started(let id) = $0 { return id } else { return nil } }
        }
        var stoppedCount: Int { events.items.filter { if case .stopped = $0 { return true } else { return false } }.count }
        var errors: [String] { events.items.compactMap { if case .error(let m) = $0 { return m } else { return nil } } }
    }

    private func requireScreenRecording() throws {
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "Screen Recording permission not granted to the test runner")
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testMirrorCaptureEndToEnd() async throws {
        try skipUnlessScreenAvailable()
        try requireScreenRecording()
        let engine = StreamEngine()
        let sink = Sink(engine)
        let config = StreamConfig(displayMode: .mirror, width: 1280, height: 720, fps: 30, codec: .h264,
                                  bitrateKbps: 6000, captureAudio: true)
        try await engine.start(config)
        await sleep(1)
        let beforeRequest = sink.video.count
        engine.requestKeyframe()
        await sleep(1)

        // Profile-only update (WebRTC needs constrained baseline): encoder rebuilt in place, and the
        // next keyframe (re-encoded last frame if the screen is static) carries a 42e0xx SPS.
        let beforeProfile = sink.video.count
        var baseline = config
        baseline.h264Profile = .constrainedBaseline
        try await engine.update(baseline)
        func baselineKeyframe() -> EncodedVideoFrame? {
            sink.video.items.dropFirst(beforeProfile).first { frame in
                // VideoToolbox writes this SPS with nal_ref_idc 1 (header 0x27), so match on the NAL type.
                guard frame.isKeyframe, let sps = AnnexB.nalUnits(in: frame.data).first, sps.count > 3 else { return false }
                let b = [UInt8](sps.prefix(3))
                return b[0] & 0x1F == 7 && b[1] == 0x42 && b[2] == 0xE0
            }
        }
        XCTAssertTrue(waitFor(1) { baselineKeyframe() != nil }, "no constrained-baseline keyframe after the profile update")
        XCTAssertEqual(sink.started.count, 1, "profile change rebuilds the encoder, not the capture")
        let profileLevelID = baselineKeyframe().flatMap { AnnexB.nalUnits(in: $0.data).first }
            .map { $0[1...3].map { String(format: "%02x", $0) }.joined() } ?? "none"
        print("mirror profile update: SPS profile-level-id \(profileLevelID)")

        await engine.stop()
        await sleep(0.1)

        let frames = Array(sink.video.items.prefix(beforeProfile))
        print("mirror 2 s: \(frames.count) video frames (\(frames.filter(\.isKeyframe).count) keyframes), \(sink.audio.count) audio packets, events \(sink.events.items)")
        XCTAssertEqual(sink.started, [CGMainDisplayID()])
        XCTAssertEqual(sink.stoppedCount, 1)
        XCTAssertTrue(sink.errors.isEmpty, "\(sink.errors)")
        let first = try XCTUnwrap(frames.first, "no frames captured")
        XCTAssertTrue(first.isKeyframe)
        XCTAssertEqual(nalTypes(first.data, codec: .h264).prefix(2), [7, 8])
        XCTAssertTrue(frames[beforeRequest...].contains(where: \.isKeyframe), "keyframe after requestKeyframe()")
        let now = DashClock.nowMicros()
        XCTAssertTrue(frames.allSatisfy { $0.pts > now - 5_000_000 && $0.pts <= now }, "pts on the host clock")
        let decoded = try decodeAnnexB(Array(frames.map(\.data).prefix(10)), codec: .h264)
        XCTAssertEqual(CVPixelBufferGetWidth(decoded[0]), 1280)
        XCTAssertEqual(CVPixelBufferGetHeight(decoded[0]), 720)
        for packet in sink.audio.items { XCTAssertEqual(packet.data.count, 1920) }
        let audioPTS = sink.audio.items.map(\.pts)
        let steps = zip(audioPTS.dropFirst(), audioPTS).map { Int($0) - Int($1) }
        print("audio: \(audioPTS.count) packets, pts steps \(Set(steps).sorted()), first audio − first video = \((Int(audioPTS.first ?? 0) - Int(first.pts)) / 1000) ms")
        XCTAssertTrue(steps.allSatisfy { $0 == 10_000 }, "continuous 10 ms audio pts")

        // SCK letterboxes a display whose aspect differs from the frame, centered; InputInjector
        // relies on exactly that geometry.
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let contentWidth = 720 * bounds.width / bounds.height
        if contentWidth < 1270 {
            let bar = Int((1280 - contentWidth) / 2)
            let image = decoded[0]
            let edge = TestMedia.meanLuma(image, columns: 0..<max(bar - 4, 1))
            let rightEdge = TestMedia.meanLuma(image, columns: (1280 - max(bar - 4, 1))..<1280)
            print("letterbox: expected bars \(bar) px, edge luma \(edge) / \(rightEdge)")
            XCTAssertLessThan(edge, 20, "left bar should be black")
            XCTAssertLessThan(rightEdge, 20, "right bar should be black")
        }

        // Nothing arrives after stop.
        let count = sink.video.count
        await sleep(0.3)
        XCTAssertEqual(sink.video.count, count)
    }

    /// Extend mode: virtual display appears, is captured and listed, updates apply, stop removes it.
    /// Two short-lived virtual displays, about 1 s in total.
    func testExtendModeLifecycle() async throws {
        try skipUnlessScreenAvailable()
        try requireScreenRecording()
        let engine = StreamEngine()
        let sink = Sink(engine)
        var config = StreamConfig(displayMode: .extend, width: 1280, height: 720, fps: 30, codec: .h264,
                                  bitrateKbps: 6000, captureAudio: false, hiDPI: true)
        try await engine.start(config)
        let displayID = try XCTUnwrap(sink.started.first ?? waitForStarted(sink))
        XCTAssertTrue(VirtualDisplay.activeDisplayIDs().contains(displayID))
        XCTAssertEqual(CGDisplayBounds(displayID).size, CGSize(width: 1280, height: 720))
        let listed = try XCTUnwrap(engine.availableDisplays().first { $0.id == displayID })
        XCTAssertTrue(listed.isVirtual)
        XCTAssertEqual(listed.name, "Dashcast (Tesla)")
        XCTAssertEqual(listed.width, 1280)
        XCTAssertEqual(engine.availableDisplays().filter(\.isVirtual).count, 1)

        // Live input onto the virtual display makes the (captured) cursor move → more frames.
        if ProcessInfo.processInfo.environment["DASHCAST_LIVE_INPUT"] == "1", engine.hasAccessibilityPermission() {
            let original = CGEvent(source: nil)?.location ?? .zero
            for step in 0..<30 {
                engine.inject(InputEvent(kind: .move, x: 0.1 + Double(step) / 40, y: 0.5))
                await sleep(0.033)
            }
            CGWarpMouseCursorPosition(original)
        }

        XCTAssertTrue(waitFor(3) { sink.video.count >= 1 }, "no frames from the virtual display")
        let first = sink.video.items[0]
        XCTAssertTrue(first.isKeyframe)
        print("extend: \(sink.video.count) frames after start")

        // Bitrate-only update: in place, no restart.
        config.bitrateKbps = 3000
        try await engine.update(config)
        XCTAssertEqual(sink.started.count, 1)

        // Resolution change: encoder rebuilt, same virtual display, a keyframe at the new size follows
        // even though the virtual display is static.
        let before = sink.video.count
        config.width = 960
        config.height = 540
        try await engine.update(config)
        XCTAssertTrue(waitFor(2) { sink.video.items.dropFirst(before).contains(where: \.isKeyframe) }, "no keyframe after resize")
        let resized = try XCTUnwrap(sink.video.items.dropFirst(before).first(where: \.isKeyframe))
        let decoded = try decodeAnnexB([resized.data], codec: .h264)
        XCTAssertEqual(CVPixelBufferGetWidth(decoded[0]), 960)
        XCTAssertEqual(CVPixelBufferGetHeight(decoded[0]), 540)
        XCTAssertEqual(sink.started.count, 1, "virtual display kept")
        XCTAssertTrue(VirtualDisplay.activeDisplayIDs().contains(displayID))

        // Codec change to JPEG: in place as well.
        let beforeJPEG = sink.video.count
        config.codec = .jpeg
        try await engine.update(config)
        XCTAssertTrue(waitFor(2) { sink.video.items.dropFirst(beforeJPEG).contains { $0.codec == .jpeg } })
        XCTAssertEqual(sink.started.count, 1)

        // Display size change: new virtual display.
        config.displayWidth = 1024
        config.displayHeight = 576
        config.codec = .h264
        try await engine.update(config)
        let replacement = try XCTUnwrap(sink.started.count == 2 ? sink.started.last : waitForStarted(sink, count: 2))
        XCTAssertNotEqual(replacement, displayID)
        XCTAssertFalse(VirtualDisplay.activeDisplayIDs().contains(displayID), "old display released")
        XCTAssertEqual(CGDisplayBounds(replacement).size, CGSize(width: 1024, height: 576))

        await engine.stop()
        XCTAssertFalse(VirtualDisplay.activeDisplayIDs().contains(replacement), "virtual display removed on stop")
        XCTAssertTrue(engine.availableDisplays().allSatisfy { !$0.isVirtual })
        XCTAssertTrue(sink.errors.isEmpty, "\(sink.errors)")
        XCTAssertTrue(waitFor(1) { sink.stoppedCount == 1 })
    }

    /// Static virtual display: nothing to capture, so the engine should cost ~no CPU.
    /// Holds a virtual display for ~4 s, so it is opt-in: DASHCAST_SLOW_TESTS=1.
    func testIdleCPU() async throws {
        try skipUnlessScreenAvailable()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DASHCAST_SLOW_TESTS"] == "1", "set DASHCAST_SLOW_TESTS=1")
        try requireScreenRecording()
        let engine = StreamEngine()
        let sink = Sink(engine)
        try await engine.start(StreamConfig(displayMode: .extend, width: 1920, height: 1080, fps: 60, codec: .h264,
                                            bitrateKbps: 12_000, captureAudio: true))
        await sleep(1)
        let framesBefore = sink.video.count
        let cpuBefore = Self.processCPUSeconds()
        let wallBefore = Date()
        await sleep(3)
        let cpu = (Self.processCPUSeconds() - cpuBefore) / Date().timeIntervalSince(wallBefore)
        await engine.stop()
        print("idle: \(String(format: "%.2f", cpu * 100))% CPU over 3 s, \(sink.video.count - framesBefore) frames, \(sink.audio.count) audio packets")
        XCTAssertLessThan(cpu, 0.05)
    }

    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    func testStopWhenIdleIsHarmless() async throws {
        let engine = StreamEngine()
        let sink = Sink(engine)
        await engine.stop()
        try await engine.update(StreamConfig(displayMode: .extend, width: 1280, height: 720, fps: 30, codec: .h264,
                                             bitrateKbps: 6000, captureAudio: false))
        engine.requestKeyframe()
        engine.setBitrate(kbps: 1000)
        engine.inject(InputEvent(kind: .down, x: 0.5, y: 0.5))
        await sleep(0.1)
        XCTAssertTrue(sink.events.items.isEmpty)
        XCTAssertFalse(engine.availableDisplays().isEmpty)
        XCTAssertTrue(engine.availableDisplays().allSatisfy { !$0.isVirtual })
    }

    private func waitForStarted(_ sink: Sink, count: Int = 1) -> CGDirectDisplayID? {
        waitFor(2) { sink.started.count >= count }
        return sink.started.count >= count ? sink.started[count - 1] : nil
    }
}
