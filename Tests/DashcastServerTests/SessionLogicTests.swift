import DashcastContracts
import XCTest
@testable import DashcastServer

final class TierSelectorTests: XCTestCase {
    func select(_ dict: [String: Any], override: String? = nil) -> TierDecision {
        TierSelector.select(hello: Fixtures.hello(dict), overrideID: override)
    }

    func testMCU2LikeHello() {
        let d = select(Fixtures.mcu2Hello)
        XCTAssertEqual(d.tier, .mcu2)
        XCTAssertEqual(d.computer, .mcu2)
        XCTAssertFalse(d.isOverride)
        XCTAssertEqual(d.ladder, [.mcu2Low, .mcu2, .mcu2High, .mcu3])
    }

    func testMCU2WithBetterDecoderStepsUpToHigh() {
        let d = select(Fixtures.helloDict(d720: 4, d1080: 10))
        XCTAssertEqual(d.tier, .mcu2High)
        XCTAssertEqual(d.computer, .mcu2)
    }

    func testMCU3LikeHello() {
        let d = select(Fixtures.mcu3Hello)
        XCTAssertEqual(d.tier, .mcu3HEVC)
        XCTAssertEqual(d.computer, .mcu3)
        XCTAssertEqual(select(Fixtures.helloDict(w: 1920, h: 1200, hevc: false, d720: 1.1, d1080: 2.4)).tier, .mcu3)
    }

    func testStrongDecoderWithoutH264HighIsNotMCU3() {
        let d = select(Fixtures.helloDict(high: false, hevc: true, d720: 1, d1080: 2))
        XCTAssertEqual(d.tier, .mcu2High)
        XCTAssertEqual(d.computer, .mcu2)
    }

    func testNoWebCodecsOrNoH264IsJPEG() {
        XCTAssertEqual(select(Fixtures.helloDict(webcodecs: false, d720: 1, d1080: 2)).tier, .mcu2Low)
        XCTAssertEqual(select(Fixtures.helloDict(high: false, main: false, baseline: false, d720: 1, d1080: 2)).tier, .mcu2Low)
        // Baseline-only can't decode the Main/High streams we produce.
        XCTAssertEqual(select(Fixtures.helloDict(high: false, main: false, baseline: true, d720: 1, d1080: 2)).tier, .mcu2Low)
        XCTAssertEqual(select(Fixtures.helloDict(webcodecs: false, d720: 1, d1080: 2)).ladder, [.mcu2Low])
    }

    func testSlow720pIsJPEG() {
        XCTAssertEqual(select(Fixtures.helloDict(d720: 25, d1080: 60)).tier, .mcu2Low)
    }

    func testMissing1080pBench() {
        XCTAssertEqual(select(Fixtures.helloDict(d720: 9, d1080: nil)).tier, .mcu2)       // > 8 ms → mcu2
        XCTAssertEqual(select(Fixtures.helloDict(d720: 4, d1080: nil)).tier, .mcu2High)   // est. 9 ms
        XCTAssertEqual(select(Fixtures.helloDict(d720: 1, d1080: nil)).tier, .mcu2High)   // never MCU3 on an estimate
    }

    func testMissingBenchIsUnknownComputer() {
        let d = select(Fixtures.helloDict(includeBench: false))
        XCTAssertEqual(d.tier, .mcu2)
        XCTAssertEqual(d.computer, .unknown)
        XCTAssertEqual(select(Fixtures.helloDict(d720: nil, d1080: nil)).computer, .unknown)
    }

    func testOverride() {
        let d = select(Fixtures.mcu2Hello, override: "mcu3")
        XCTAssertEqual(d.tier, .mcu3)
        XCTAssertTrue(d.isOverride)
        XCTAssertEqual(d.autoTier, .mcu2)
        XCTAssertEqual(d.computer, .mcu2)   // the car is still an MCU2
        let jpeg = select(Fixtures.mcu3Hello, override: "mcu2-low")
        XCTAssertEqual(jpeg.tier, .mcu2Low)
        // Unknown override id → automatic.
        let bogus = select(Fixtures.mcu2Hello, override: "nope")
        XCTAssertEqual(bogus.tier, .mcu2)
        XCTAssertFalse(bogus.isOverride)
    }

    func testEncodeSizeFitsBudgetAndAspect() {
        func vp(_ w: Double, _ h: Double, _ dpr: Double = 1) -> Viewport {
            Fixtures.hello(Fixtures.helloDict(w: w, h: h, dpr: dpr)).viewport
        }
        // Exactly the budget.
        XCTAssertEqual(TierSelector.encodeSize(tier: .mcu3, viewport: vp(1920, 1200)), PixelSize(width: 1920, height: 1200))
        // Never larger than the viewport's device pixels.
        XCTAssertEqual(TierSelector.encodeSize(tier: .mcu3, viewport: vp(1280, 720)), PixelSize(width: 1280, height: 720))
        // Budget-limited, aspect kept, even, and within level 3.1's 3600 macroblocks
        // (the pure pixel fit 1214×758 would be 76×48 = 3648 MBs).
        let s = TierSelector.encodeSize(tier: .mcu2, viewport: vp(1920, 1200))
        XCTAssertEqual(s, PixelSize(width: 1206, height: 752))
        XCTAssertLessThanOrEqual(s.width * s.height, 1280 * 720)
        XCTAssertLessThanOrEqual(TierSelector.macroblocks(s.width, s.height), 3600)
        XCTAssertEqual(TierSelector.encodeSize(tier: .mcu2, viewport: vp(1280, 800)), PixelSize(width: 1206, height: 752))
        // dpr counts.
        XCTAssertEqual(TierSelector.encodeSize(tier: .mcu2, viewport: vp(960, 600, 2)), PixelSize(width: 1206, height: 752))
        // 16:9 at the budget is exactly the tier.
        XCTAssertEqual(TierSelector.encodeSize(tier: .mcu2, viewport: vp(1920, 1080)), PixelSize(width: 1280, height: 720))
        // Odd device sizes round down to even.
        let odd = TierSelector.encodeSize(tier: .mcu3, viewport: vp(1181, 919))
        XCTAssertEqual(odd, PixelSize(width: 1180, height: 918))
        let jpeg = TierSelector.encodeSize(tier: .mcu2Low, viewport: vp(1280, 800))
        XCTAssertEqual(jpeg.width % 2, 0); XCTAssertEqual(jpeg.height % 2, 0)
        XCTAssertLessThanOrEqual(jpeg.width * jpeg.height, 960 * 540)
        XCTAssertEqual(Double(jpeg.width) / Double(jpeg.height), 1.6, accuracy: 0.01)
    }

    func testEncodeSizeNeverExceedsTierMacroblocks() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let w = Double.random(in: 320...3840, using: &rng), h = Double.random(in: 240...2400, using: &rng)
            let dpr = [1.0, 1.25, 1.5, 2.0].randomElement(using: &rng)!
            let viewport = Fixtures.hello(Fixtures.helloDict(w: w, h: h, dpr: dpr)).viewport
            for tier in Tier.all {
                let size = TierSelector.encodeSize(tier: tier, viewport: viewport)
                XCTAssertEqual(size.width % 2, 0); XCTAssertEqual(size.height % 2, 0)
                XCTAssertLessThanOrEqual(Double(size.width), w * dpr + 0.5)
                XCTAssertLessThanOrEqual(Double(size.height), h * dpr + 0.5)
                XCTAssertLessThanOrEqual(size.width * size.height, tier.width * tier.height)
                if tier.codec != .jpeg {
                    XCTAssertLessThanOrEqual(TierSelector.macroblocks(size.width, size.height),
                                             TierSelector.macroblocks(tier.width, tier.height), "\(tier.id) \(w)×\(h)@\(dpr)")
                }
            }
        }
    }

    func testDisplaySizeRoundsAndClamps() {
        func vp(_ w: Double, _ h: Double) -> Viewport { Fixtures.hello(Fixtures.helloDict(w: w, h: h)).viewport }
        XCTAssertEqual(TierSelector.displaySize(viewport: vp(1181.6, 919.4)), PixelSize(width: 1182, height: 919))
        XCTAssertEqual(TierSelector.displaySize(viewport: vp(640, 400)), PixelSize(width: 800, height: 480))
        XCTAssertEqual(TierSelector.displaySize(viewport: vp(1920, 400)), PixelSize(width: 1920, height: 480))
    }

    func testLenientHelloParsing() {
        // Missing caps/bench/viewport pieces must not wedge the session.
        let hello = ClientMessage.parseHello(["t": "hello", "ua": "x", "caps": ["webcodecs": true]])
        XCTAssertNotNil(hello)
        XCTAssertEqual(hello?.caps.h264.high, false)
        XCTAssertNil(hello?.bench)
        XCTAssertEqual(TierSelector.select(hello: hello!, overrideID: nil).tier, .mcu2Low)
    }
}

final class TierAdapterTests: XCTestCase {
    let ladder: [Tier] = [.mcu2Low, .mcu2, .mcu2High, .mcu3]

    func testStepsDownOnSlowDecode() {
        var a = TierAdapter(ladder: ladder, current: .mcu2High, ceiling: .mcu2High, allowStepUp: true, now: 0)
        XCTAssertNil(a.observe(Fixtures.stats(decodeMs: 30), now: 2))    // settling
        XCTAssertNil(a.observe(Fixtures.stats(decodeMs: 30), now: 5))    // 1st slow sample (30 > 26.7)
        guard case .stepDown(let t, _) = a.observe(Fixtures.stats(decodeMs: 30), now: 6) else { return XCTFail() }
        XCTAssertEqual(t, .mcu2)
        XCTAssertEqual(a.current, .mcu2)
    }

    func testSingleSpikeDoesNotStepDown() {
        var a = TierAdapter(ladder: ladder, current: .mcu2, ceiling: .mcu2, allowStepUp: true, now: 0)
        XCTAssertNil(a.observe(Fixtures.stats(decodeMs: 40), now: 5))
        XCTAssertNil(a.observe(Fixtures.stats(decodeMs: 10), now: 6))
        XCTAssertNil(a.observe(Fixtures.stats(decodeMs: 40), now: 7))
    }

    func testStepsDownWhenDropsKeepRisingFor3s() {
        var a = TierAdapter(ladder: ladder, current: .mcu2, ceiling: .mcu2, allowStepUp: true, now: 0)
        XCTAssertNil(a.observe(Fixtures.stats(decodeMs: 5, dropped: 0), now: 5))
        XCTAssertNil(a.observe(Fixtures.stats(decodeMs: 5, dropped: 2), now: 6))
        XCTAssertNil(a.observe(Fixtures.stats(decodeMs: 5, dropped: 5), now: 7))
        guard case .stepDown(let t, let reason) = a.observe(Fixtures.stats(decodeMs: 5, dropped: 9), now: 8) else { return XCTFail() }
        XCTAssertEqual(t, .mcu2Low)
        XCTAssertTrue(reason.contains("dropped"))
        // Bottom of the ladder: nothing lower.
        for i in 0..<10 { XCTAssertNil(a.observe(Fixtures.stats(decodeMs: 50, dropped: 20 + i * 5), now: 13 + Double(i))) }
    }

    func testStepsUpAfter20sHealthyButNotAboveCeiling() {
        var a = TierAdapter(ladder: ladder, current: .mcu2, ceiling: .mcu2High, allowStepUp: true, now: 0)
        var decision: TierAdapter.Decision?
        var t = 4.0
        while decision == nil && t < 60 {
            decision = a.observe(Fixtures.stats(decodeMs: 5), now: t)   // 5 < 13.3
            t += 1
        }
        guard case .stepUp(let tier, _) = decision else { return XCTFail() }
        XCTAssertEqual(tier, .mcu2High)
        XCTAssertEqual(t - 1, 24, accuracy: 0.01)   // first healthy at 4 s, +20 s
        // At the ceiling: never higher.
        for i in 0..<60 { XCTAssertNil(a.observe(Fixtures.stats(decodeMs: 1), now: 30 + Double(i))) }
    }

    func testNoStepUpWithOverride() {
        var a = TierAdapter(ladder: ladder, current: .mcu2, ceiling: .mcu2, allowStepUp: false, now: 0)
        for i in 0..<60 { XCTAssertNil(a.observe(Fixtures.stats(decodeMs: 1), now: 4 + Double(i))) }
    }

    func testFailedStepUpBacksOff() {
        var a = TierAdapter(ladder: ladder, current: .mcu2, ceiling: .mcu2High, allowStepUp: true, now: 0)
        var t = 4.0
        while a.current == .mcu2 { _ = a.observe(Fixtures.stats(decodeMs: 5), now: t); t += 1 }
        XCTAssertEqual(a.current, .mcu2High)
        // Too slow up there → back down quickly, and the next step-up waits 40 s.
        t += 4
        _ = a.observe(Fixtures.stats(decodeMs: 30), now: t); t += 1
        guard case .stepDown = a.observe(Fixtures.stats(decodeMs: 30), now: t) else { return XCTFail() }
        XCTAssertEqual(a.stepUpBackoff, 2)
    }
}

final class CongestionControllerTests: XCTestCase {
    /// Acks every 33 ms with the given queueing delay on top of a constant (arbitrary) clock offset.
    func feed(_ cc: CongestionController, from t0: Double, count: Int, offsetMicros: Double = -3_000_000,
              queueingMs: (Int) -> Double) -> (Double, [Int]) {
        var t = t0
        var changes: [Int] = []
        for i in 0..<count {
            let pts = UInt64(1_000_000_000 + t * 1_000_000)
            let recv = Double(pts) + offsetMicros + 20_000 + queueingMs(i) * 1000
            if let kbps = cc.onAck(ptsMicros: pts, recvAtMicros: recv, now: t) { changes.append(kbps) }
            t += 0.033
        }
        return (t, changes)
    }

    func testSteadyDelayKeepsTierBitrate() {
        let cc = CongestionController(maxKbps: 6000)
        let (_, changes) = feed(cc, from: 0, count: 300) { i in Double(i % 3) }   // jitter only
        XCTAssertEqual(cc.currentKbps, 6000)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertLessThan(cc.lastQueueingMs, 5)
    }

    func testRisingQueueingDelayCutsBitrateMultiplicativelyWithFloor() {
        let cc = CongestionController(maxKbps: 6000)
        var (t, _) = feed(cc, from: 0, count: 30) { _ in 0 }   // baseline
        // Queue grows 5 ms per frame (link slower than the stream).
        let (t2, changes) = feed(cc, from: t, count: 20) { i in Double(45 + i * 5) }
        t = t2
        XCTAssertFalse(changes.isEmpty)
        XCTAssertEqual(changes.first, 5100)            // 6000 × 0.85
        XCTAssertLessThan(cc.currentKbps, 6000)
        // Keep it congested for a long time: never below 25 %.
        _ = feed(cc, from: t, count: 600) { i in Double(150 + i) }
        XCTAssertEqual(cc.currentKbps, 1500)
    }

    func testDecreasesAreSpacedOut() {
        let cc = CongestionController(maxKbps: 10_000)
        _ = feed(cc, from: 0, count: 10) { _ in 0 }
        // 12 rising acks over ~0.4 s → at most two cuts, not twelve.
        let (_, changes) = feed(cc, from: 0.33, count: 12) { i in Double(50 + i * 10) }
        XCTAssertLessThanOrEqual(changes.count, 2)
        XCTAssertGreaterThanOrEqual(cc.currentKbps, Int(10_000 * 0.85 * 0.85))
    }

    func testAdditiveIncreaseOf5PercentPerSecond() {
        let cc = CongestionController(maxKbps: 8000)
        var (t, _) = feed(cc, from: 0, count: 30) { _ in 0 }
        (t, _) = feed(cc, from: t, count: 200) { i in Double(60 + i * 5) }   // drive it to the floor
        XCTAssertEqual(cc.currentKbps, 2000)
        // Queue drains back to baseline: +400 kbps (5 % of 8000) per second.
        let start = cc.currentKbps
        (t, _) = feed(cc, from: t, count: 31) { _ in 0 }   // ~1 s of acks
        XCTAssertEqual(Double(cc.currentKbps - start), 400, accuracy: 30)
        _ = feed(cc, from: t, count: 1000) { _ in 0 }
        XCTAssertEqual(cc.currentKbps, 8000)             // capped at the tier
    }

    func testHighButDrainingQueueHolds() {
        let cc = CongestionController(maxKbps: 6000)
        var (t, _) = feed(cc, from: 0, count: 30) { _ in 0 }
        (t, _) = feed(cc, from: t, count: 8) { i in Double(60 + i * 10) }
        let afterCut = cc.currentKbps
        XCTAssertLessThan(afterCut, 6000)
        // 100 ms of queue, now shrinking: neither cut nor grow.
        _ = feed(cc, from: t + 0.5, count: 5) { i in Double(120 - i * 10) }
        XCTAssertEqual(cc.currentKbps, afterCut)
    }

    func testBaselineIsTenSecondWindowMinimum() {
        let cc = CongestionController(maxKbps: 6000)
        // A lucky low sample at t=0, then the path settles 30 ms higher.
        _ = cc.onAck(ptsMicros: 1_000_000, recvAtMicros: 1_000_000 + 5_000, now: 0)
        var t = 0.033
        for _ in 0..<100 { _ = cc.onAck(ptsMicros: 2_000_000, recvAtMicros: 2_000_000 + 35_000, now: t); t += 0.033 }
        XCTAssertEqual(cc.baselineMicros, 5_000)
        XCTAssertEqual(cc.lastQueueingMs, 30, accuracy: 0.1)
        // After 10 s the old minimum ages out.
        for _ in 0..<400 { _ = cc.onAck(ptsMicros: 2_000_000, recvAtMicros: 2_000_000 + 35_000, now: t); t += 0.033 }
        XCTAssertEqual(cc.baselineMicros, 35_000)
        XCTAssertEqual(cc.lastQueueingMs, 0, accuracy: 0.1)
    }

    func testNewTierClampsTarget() {
        let cc = CongestionController(maxKbps: 16_000)
        cc.setMaxKbps(6000)
        XCTAssertEqual(cc.currentKbps, 6000)
        cc.setMaxKbps(20_000)
        XCTAssertEqual(cc.currentKbps, 6000)   // grows back additively, not instantly
    }
}

final class LatencyModePolicyTests: XCTestCase {
    func testFixedSettings() {
        var p = LatencyModePolicy(setting: .cinema)
        XCTAssertEqual(p.effective, .cinema)
        XCTAssertNil(p.noteInput(now: 1))            // input doesn't override a fixed mode
        XCTAssertEqual(p.effective, .cinema)
        XCTAssertEqual(p.setSetting(.interactive, now: 2), .interactive)
    }

    func testAutoGoesCinemaWithAudioAndNoInput() {
        var p = LatencyModePolicy(setting: .auto)
        XCTAssertEqual(p.effective, .interactive)
        var t = 0.0
        var change: LatencyMode?
        while change == nil && t < 10 {
            p.noteAudio(audible: true, now: t)
            change = p.evaluate(now: t)
            t += 0.25
        }
        XCTAssertEqual(change, .cinema)
        XCTAssertEqual(t - 0.25, 2.0, accuracy: 0.01)   // 2 s hysteresis
    }

    func testInputSwitchesToInteractiveImmediatelyAndHoldsFor3s() {
        var p = LatencyModePolicy(setting: .auto)
        var t = 0.0
        while p.effective != .cinema { p.noteAudio(audible: true, now: t); _ = p.evaluate(now: t); t += 0.25 }
        XCTAssertEqual(p.noteInput(now: t), .interactive)
        // Audio keeps playing; cinema only after 3 s without input + 2 s hysteresis.
        var back: Double?
        let inputAt = t
        while back == nil && t < inputAt + 20 {
            t += 0.25
            p.noteAudio(audible: true, now: t)
            if p.evaluate(now: t) == .cinema { back = t }
        }
        XCTAssertEqual(back! - inputAt, 5.0, accuracy: 0.26)
    }

    func testSilenceReturnsToInteractiveWithHysteresis() {
        var p = LatencyModePolicy(setting: .auto)
        var t = 0.0
        while p.effective != .cinema { p.noteAudio(audible: true, now: t); _ = p.evaluate(now: t); t += 0.25 }
        let silentFrom = t
        var back: Double?
        while back == nil && t < silentFrom + 10 {
            p.noteAudio(audible: false, now: t)
            if p.evaluate(now: t) == .interactive { back = t }
            t += 0.25
        }
        // 0.5 s "recently audible" window + 2 s hysteresis.
        XCTAssertEqual(back! - silentFrom, 2.5, accuracy: 0.26)
    }

    func testBriefSilenceDoesNotFlip() {
        var p = LatencyModePolicy(setting: .auto)
        var t = 0.0
        while p.effective != .cinema { p.noteAudio(audible: true, now: t); _ = p.evaluate(now: t); t += 0.25 }
        for i in 0..<40 {   // 10 s: 1.5 s gaps between audible bursts
            p.noteAudio(audible: i % 6 == 0, now: t)
            XCTAssertNil(p.evaluate(now: t))
            t += 0.25
        }
    }
}

final class MediaAndMessageTests: XCTestCase {
    func testBinaryHeaderLayout() {
        let h = MediaHeader(type: .videoH264, flags: 1, seq: 0x0102_0304, pts: 0x0102_0304_0506_0708)
        XCTAssertEqual([UInt8](h.encoded()), [1, 1, 0, 0, 1, 2, 3, 4, 1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(MediaHeader(h.encoded()), h)
        XCTAssertEqual(MediaHeader.size, 16)
    }

    func testHeaderTypesAndFlags() {
        let pts = DashClock.nowMicros()
        let key = MediaHeader.video(EncodedVideoFrame(pts: pts, isKeyframe: true, codec: .h264, data: Data()), seq: 7)
        XCTAssertEqual(key.type, .videoH264); XCTAssertTrue(key.isKeyframe); XCTAssertEqual(key.seq, 7); XCTAssertEqual(key.pts, pts)
        let delta = MediaHeader.video(EncodedVideoFrame(pts: pts, isKeyframe: false, codec: .hevc, data: Data()), seq: 8)
        XCTAssertEqual(delta.type, .videoHEVC); XCTAssertFalse(delta.isKeyframe)
        let jpeg = MediaHeader.video(EncodedVideoFrame(pts: pts, isKeyframe: false, codec: .jpeg, data: Data()), seq: 9)
        XCTAssertEqual(jpeg.type, .videoJPEG); XCTAssertTrue(jpeg.isKeyframe)   // always a keyframe
        let audio = MediaHeader.audio(AudioPacket(pts: 123, data: Data()), seq: 0xFFFF_FFFF)
        XCTAssertEqual([UInt8](audio.encoded()), [4, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 123])
    }

    func testAudioRMS() {
        XCTAssertEqual(AudioLevel.rms(s16le: Data(count: 1920)), 0)
        var loud = [Int16](repeating: 0, count: 960)
        for i in 0..<960 { loud[i] = i % 2 == 0 ? 16384 : -16384 }
        let rms = AudioLevel.rms(s16le: loud.withUnsafeBufferPointer { Data(buffer: $0) })
        XCTAssertEqual(rms, 0.5, accuracy: 0.001)
        var faint = [Int16](repeating: 0, count: 960)
        for i in 0..<960 { faint[i] = i % 4 < 2 ? 20 : -20 }   // ≈ -64 dBFS: still "silent"
        XCTAssertLessThan(AudioLevel.rms(s16le: faint.withUnsafeBufferPointer { Data(buffer: $0) }), AudioLevel.silenceThreshold)
    }

    func testServerMessages() throws {
        let config = ServerMessage.config(.init(transport: .websocket, codecString: "avc1.4D401F", width: 1214, height: 758, fps: 30, bitrateKbps: 6000,
                                                tierID: "mcu2", latencyMode: .interactive, audio: true, inputEnabled: true, serverTime: 99))
        let obj = try JSONSerialization.jsonObject(with: Data(config.utf8)) as! [String: Any]
        XCTAssertEqual(obj["t"] as? String, "config")
        XCTAssertEqual(obj["transport"] as? String, "ws")
        XCTAssertEqual(obj["codec"] as? String, "avc1.4D401F")
        XCTAssertEqual(obj["width"] as? Int, 1214)
        XCTAssertEqual(obj["tier"] as? String, "mcu2")
        XCTAssertEqual((obj["audio"] as? [String: Int])?["sampleRate"], 48000)
        XCTAssertEqual(obj["serverTime"] as? Int, 99)
        let noAudio = ServerMessage.config(.init(transport: .webrtc, codecString: "jpeg", width: 2, height: 2, fps: 30, bitrateKbps: 1, tierID: "mcu2-low",
                                                 latencyMode: .cinema, audio: false, inputEnabled: false, serverTime: 1))
        XCTAssertTrue(noAudio.contains("\"audio\":null"))
        XCTAssertTrue(noAudio.hasPrefix("{\"t\":\"config\",\"transport\":\"webrtc\","))
        XCTAssertEqual(ServerMessage.rtcOffer(sdp: "v=0\r\ns=x\r\n"), #"{"t":"rtcOffer","sdp":"v=0\r\ns=x\r\n"}"#)
        XCTAssertTrue(noAudio.contains("\"inputEnabled\":false"))

        XCTAssertEqual(ServerMessage.pong(id: .int(7), clientTime: .double(12.5), serverTime: 123456),
                       #"{"t":"pong","id":7,"clientTime":12.5,"serverTime":123456}"#)
        XCTAssertEqual(ServerMessage.mode(.cinema), #"{"t":"mode","latencyMode":"cinema"}"#)
        XCTAssertEqual(ServerMessage.bye("stop \"now\""), #"{"t":"bye","reason":"stop \"now\""}"#)
    }

    func testClientMessageParsing() {
        guard case .ping(let id, let ct) = ClientMessage.parse(#"{"t":"ping","id":7,"clientTime":1234.567891}"#) else { return XCTFail() }
        XCTAssertEqual(id, .int(7))
        XCTAssertEqual(ct.json, "1234.567891")
        guard case .ack(let ack) = ClientMessage.parse(#"{"t":"ack","seq":42,"recvAt":123456.5,"decodeMs":3.1,"presented":true}"#) else { return XCTFail() }
        XCTAssertEqual(ack, AckMessage(seq: 42, recvAt: 123456.5, decodeMs: 3.1, presented: true))
        guard case .input(let e) = ClientMessage.parse(#"{"t":"input","kind":"scroll","x":1.5,"y":0.25,"dx":0,"dy":-120,"text":null,"key":null}"#) else { return XCTFail() }
        XCTAssertEqual(e.kind, .scroll); XCTAssertEqual(e.x, 1); XCTAssertEqual(e.dy, -120)
        guard case .stats(let s) = ClientMessage.parse(#"{"t":"stats","fps":29.8,"decodeMs":4.2,"dropped":1,"queue":0,"latencyMs":61}"#) else { return XCTFail() }
        XCTAssertEqual(s.dropped, 1); XCTAssertEqual(s.latencyMs, 61); XCTAssertNil(s.audioBufferMs)
        guard case .setLatencyMode(.cinema) = ClientMessage.parse(#"{"t":"setLatencyMode","latencyMode":"cinema"}"#) else { return XCTFail() }
        guard case .keyframe = ClientMessage.parse(#"{"t":"keyframe"}"#) else { return XCTFail() }
        guard case .rtcAnswer("answer", "v=0\r\n") = ClientMessage.parse(#"{"t":"rtcAnswer","sdp":"v=0\r\n"}"#) else { return XCTFail() }
        XCTAssertNil(ClientMessage.parse(#"{"t":"rtcAnswer"}"#))
        guard case .hello(_, let caps) = ClientMessage.parse(Fixtures.json(Fixtures.httpModeHello)) else { return XCTFail() }
        XCTAssertEqual(caps, TransportCaps(secure: false, webrtc: true))
        guard case .hello(_, let legacy) = ClientMessage.parse(Fixtures.json(Fixtures.helloDict(secure: nil, webrtc: nil))) else { return XCTFail() }
        XCTAssertEqual(legacy, TransportCaps(secure: nil, webrtc: nil))
        XCTAssertNil(ClientMessage.parse("not json"))
        XCTAssertNil(ClientMessage.parse(#"{"no":"t"}"#))
        guard case .unknown("future") = ClientMessage.parse(#"{"t":"future"}"#) else { return XCTFail() }
    }

    func testSentFrameLog() {
        var log = SentFrameLog(capacity: 4)
        for seq in UInt32(0)..<6 { log.record(seq: seq, pts: UInt64(seq) * 10) }
        XCTAssertNil(log.pts(for: 1))          // overwritten
        XCTAssertEqual(log.pts(for: 5), 50)
        XCTAssertNil(log.pts(for: 99))
    }
}

final class TransportSelectionTests: XCTestCase {
    func plan(_ dict: [String: Any], secureFallback: Bool = true, rtc: Bool = true, override: String? = nil) -> SessionPlan {
        guard case .hello(let hello, let caps)? = ClientMessage.parse(Fixtures.json(dict)) else { fatalError() }
        return SessionPlanner.plan(hello: hello, transportCaps: caps, secureFallback: secureFallback,
                                   rtcAvailable: rtc, overrideID: override)
    }

    func testSecureWebCodecsH264IsWebSocket() {
        let p = plan(Fixtures.mcu2Hello)
        XCTAssertEqual(p.transport, .websocket)
        XCTAssertEqual(p.decision.tier, .mcu2)
        XCTAssertEqual(p.codecString, "avc1.4D401F")
        XCTAssertEqual(p.h264Profile, .auto)
        XCTAssertEqual(plan(Fixtures.mcu3Hello).decision.tier, .mcu3HEVC)
    }

    func testInsecureWithWebRTCIsWebRTC() {
        let p = plan(Fixtures.httpModeHello)
        XCTAssertEqual(p.transport, .webrtc)
        XCTAssertEqual(p.decision.tier, .mcu2)
        XCTAssertEqual(p.codecString, "avc1.42E01F")
        XCTAssertEqual(p.h264Profile, .constrainedBaseline)
        XCTAssertEqual(p.decision.computer, .unknown)   // no bench without WebCodecs
        XCTAssertEqual(p.decision.ladder, [.mcu2, .mcu2High])
        XCTAssertFalse(p.decision.isOverride)
        // WebCodecs present but not a secure context (can't happen in Chrome, but the rule is explicit).
        XCTAssertEqual(plan(Fixtures.helloDict(d720: 2, d1080: 4, secure: false, webrtc: true)).transport, .webrtc)
    }

    func testWebRTCOverrideTo1080p() {
        let high = plan(Fixtures.httpModeHello, override: "mcu2-high")
        XCTAssertEqual(high.decision.tier, .mcu2High)
        XCTAssertEqual(high.codecString, "avc1.42E028")
        XCTAssertTrue(high.decision.isOverride)
        XCTAssertEqual(plan(Fixtures.httpModeHello, override: "mcu3").decision.tier, .mcu2High)
        XCTAssertEqual(plan(Fixtures.httpModeHello, override: "mcu2-low").decision.tier, .mcu2)   // no JPEG over WebRTC
    }

    func testNoPeerFactoryOrNoWebRTCFallsBackToJPEG() {
        for p in [plan(Fixtures.httpModeHello, rtc: false),
                  plan(Fixtures.helloDict(webcodecs: false, includeBench: false, secure: false, webrtc: false)),
                  plan(Fixtures.helloDict(webcodecs: false, includeBench: false, secure: true, webrtc: false))] {
            XCTAssertEqual(p.transport, .websocket)
            XCTAssertEqual(p.decision.tier, .mcu2Low)
            XCTAssertEqual(p.codecString, "jpeg")
            XCTAssertEqual(p.decision.ladder, [.mcu2Low])
        }
        // An override can't force H.264 onto a client that can't decode it.
        XCTAssertEqual(plan(Fixtures.httpModeHello, rtc: false, override: "mcu3").decision.tier, .mcu2Low)
    }

    func testSecureButNoMainHighPrefersWebRTC() {
        let baselineOnly = Fixtures.helloDict(high: false, main: false, baseline: true, d720: 2, d1080: 4, secure: true, webrtc: true)
        XCTAssertEqual(plan(baselineOnly).transport, .webrtc)
        XCTAssertEqual(plan(baselineOnly, rtc: false).decision.tier, .mcu2Low)
    }

    func testMissingSecureFlagUsesListener() {
        let legacy = Fixtures.helloDict(d720: 9, d1080: 20, secure: nil, webrtc: nil)
        XCTAssertEqual(plan(legacy, secureFallback: true).transport, .websocket)
        XCTAssertEqual(plan(legacy, secureFallback: true).decision.tier, .mcu2)
        // Reached over plain :80 and no webrtc flag → JPEG.
        XCTAssertEqual(plan(legacy, secureFallback: false).decision.tier, .mcu2Low)
    }

    func testCodecStrings() {
        XCTAssertEqual(SessionPlanner.codecString(for: .mcu2, transport: .webrtc), "avc1.42E01F")
        XCTAssertEqual(SessionPlanner.codecString(for: .mcu2High, transport: .webrtc), "avc1.42E028")
        XCTAssertEqual(SessionPlanner.codecString(for: .mcu3, transport: .websocket), "avc1.640032")
    }
}
