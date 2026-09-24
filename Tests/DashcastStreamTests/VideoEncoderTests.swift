import CoreVideo
import DashcastContracts
import ImageIO
import VideoToolbox
import XCTest
@testable import DashcastStream

final class VideoEncoderTests: XCTestCase {
    private let width = 1280, height = 720, fps = 30

    private struct Run {
        let encoder: VideoEncoder
        let queue: DispatchQueue
        let frames: Recorder<EncodedVideoFrame>
        let errors: Recorder<String>
        var nextIndex = 0
        let base = DashClock.nowMicros()

        /// Encodes `count` frames at 30 fps timestamps; `content` pins the picture (default: animated).
        /// Buffers are generated first (slow in debug builds) so they reach the encoder back to back.
        mutating func feed(_ count: Int, width: Int = 1280, height: Int = 720, content: Int? = nil) {
            let buffers = (0..<count).map {
                TestMedia.pixelBuffer(width: width, height: height, frame: content ?? nextIndex + $0)
            }
            for pb in buffers {
                let pts = base + UInt64(nextIndex) * 33_333
                queue.sync { encoder.encode(pb, pts: pts) }
                nextIndex += 1
            }
        }

        /// Requests a keyframe, then immediately encodes `buffer` (well inside the fallback window).
        mutating func feedAfterKeyframeRequest(_ buffer: CVPixelBuffer) {
            encoder.requestKeyframe()
            queue.sync {}
            let pts = base + UInt64(nextIndex) * 33_333
            queue.sync { encoder.encode(buffer, pts: pts) }
            nextIndex += 1
        }

        func waitForFrames(_ n: Int, timeout: TimeInterval = 5) -> Bool {
            waitFor(timeout) { frames.count >= n }
        }
    }

    private func makeRun(_ codec: VideoCodec, bitrateKbps: Int = 6000, softwareJPEG: Bool = false) throws -> Run {
        let queue = DispatchQueue(label: "test.encoder.\(codec)")
        let frames = Recorder<EncodedVideoFrame>()
        let errors = Recorder<String>()
        let encoder = try VideoEncoder(
            settings: .init(codec: codec, width: width, height: height, fps: fps, bitrateKbps: bitrateKbps),
            queue: queue, forceSoftwareJPEG: softwareJPEG, onFrame: frames.append, onError: errors.append)
        return Run(encoder: encoder, queue: queue, frames: frames, errors: errors)
    }

    // MARK: H.264 / HEVC

    func testH264() throws { try exerciseVideoCodec(.h264, parameterSetType: 7) }
    func testHEVC() throws { try exerciseVideoCodec(.hevc, parameterSetType: 32) }

    private func exerciseVideoCodec(_ codec: VideoCodec, parameterSetType: Int) throws {
        var run = try makeRun(codec)
        print("\(codec): low-latency rate control = \(run.encoder.usesLowLatencyRateControl)")
        XCTAssertEqual(run.encoder.rejectedProperties, [])

        run.feed(30)
        XCTAssertTrue(run.waitForFrames(30), "\(codec): only \(run.frames.count)/30 frames came out")
        var frames = run.frames.items
        let first = try XCTUnwrap(frames.first)
        XCTAssertTrue(first.isKeyframe)
        XCTAssertEqual(first.codec, codec)
        XCTAssertEqual([UInt8](first.data.prefix(4)), [0, 0, 0, 1])
        XCTAssertEqual(nalTypes(first.data, codec: codec).first, parameterSetType, "keyframe must lead with VPS/SPS")
        XCTAssertEqual(frames.filter(\.isKeyframe).count, 1, "no spontaneous keyframes within 1 s")
        for delta in frames.dropFirst() {
            XCTAssertFalse(nalTypes(delta.data, codec: codec).contains(parameterSetType), "parameter sets only on keyframes")
        }
        XCTAssertEqual(frames.map(\.pts), (0..<30).map { run.base + UInt64($0) * 33_333 }, "pts preserved, in order")

        // Forced keyframe on the next frame after a request.
        run.feedAfterKeyframeRequest(TestMedia.pixelBuffer(width: width, height: height, frame: 30))
        XCTAssertTrue(run.waitForFrames(31))
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(run.frames.count, 31, "the fallback must not fire once a frame satisfied the request")
        frames = run.frames.items
        XCTAssertTrue(frames[30].isKeyframe, "requestKeyframe() must force the next frame")
        XCTAssertEqual(nalTypes(frames[30].data, codec: codec).first, parameterSetType)

        // Live bitrate change keeps the stream going.
        run.queue.sync { run.encoder.setBitrate(kbps: 1500) }
        run.feed(15)
        XCTAssertTrue(run.waitForFrames(46))
        XCTAssertEqual(run.encoder.settings.bitrateKbps, 1500)

        // The whole stream decodes, and the content matches the source.
        frames = run.frames.items
        let decoded = try decodeAnnexB(frames.map(\.data), codec: codec)
        XCTAssertEqual(decoded.count, 46)
        XCTAssertEqual(CVPixelBufferGetWidth(decoded[0]), width)
        XCTAssertEqual(CVPixelBufferGetHeight(decoded[0]), height)
        let diff = TestMedia.lumaDifference(decoded[45], TestMedia.pixelBuffer(width: width, height: height, frame: 45))
        XCTAssertLessThan(diff, 12, "decoded picture should resemble the source (mean |ΔY| = \(diff))")
        print("\(codec): 46 frames, keyframe \(frames[0].data.count) B, mean delta \(frames.dropFirst().map(\.data.count).reduce(0, +) / 45) B, |ΔY| \(String(format: "%.2f", diff))")
        XCTAssertTrue(run.errors.items.isEmpty, "\(run.errors.items)")
        run.queue.sync { run.encoder.invalidate() }
    }

    /// A static screen delivers no new captures: a keyframe request must re-encode the last frame.
    func testKeyframeRequestReencodesLastFrameWhenIdle() throws {
        var run = try makeRun(.h264)
        run.feed(5)
        XCTAssertTrue(run.waitForFrames(5))
        let before = DashClock.nowMicros()
        run.encoder.requestKeyframe()
        XCTAssertTrue(run.waitForFrames(6, timeout: 1), "fallback keyframe never came")
        let frame = run.frames.items[5]
        XCTAssertTrue(frame.isKeyframe)
        XCTAssertGreaterThanOrEqual(frame.pts, before, "re-encoded frame is stamped now")
        XCTAssertEqual(nalTypes(frame.data, codec: .h264).prefix(2), [7, 8])
        // It fires once, not repeatedly.
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(run.frames.count, 6)
        run.queue.sync { run.encoder.invalidate() }
    }

    /// Frames of the wrong size (in flight during a resize) are scaled to the session size.
    func testMismatchedInputSizeIsScaled() throws {
        var run = try makeRun(.h264)
        run.feed(3, width: 1920, height: 1080)
        XCTAssertTrue(run.waitForFrames(3))
        let decoded = try decodeAnnexB(run.frames.items.map(\.data), codec: .h264)
        XCTAssertEqual(CVPixelBufferGetWidth(decoded[0]), width)
        XCTAssertEqual(CVPixelBufferGetHeight(decoded[0]), height)
        run.queue.sync { run.encoder.invalidate() }
    }

    func testNoOutputAfterInvalidate() throws {
        var run = try makeRun(.h264)
        run.feed(3)
        run.queue.sync { run.encoder.invalidate() }
        let count = run.frames.count
        run.feed(3)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(run.frames.count, count)
    }

    /// Profile follows fps (Main below 60, High at 60); rate control is readable back from the session.
    func testProfileAndRateControlProperties() throws {
        for (fps, profileIDC) in [(30, 77), (60, 100)] {
            let queue = DispatchQueue(label: "test.profile")
            let frames = Recorder<EncodedVideoFrame>()
            let encoder = try VideoEncoder(settings: .init(codec: .h264, width: 1280, height: 720, fps: fps, bitrateKbps: 6000),
                                           queue: queue, onFrame: frames.append)
            let pb = TestMedia.pixelBuffer(width: 1280, height: 720, frame: 0)
            queue.sync { encoder.encode(pb, pts: 1) }
            XCTAssertTrue(waitFor(3) { frames.count == 1 })
            let sps = try XCTUnwrap(AnnexB.nalUnits(in: frames.items[0].data).first)
            XCTAssertEqual(Int(sps[1]), profileIDC, "profile_idc at \(fps) fps")

            XCTAssertEqual((encoder.sessionProperty(kVTCompressionPropertyKey_AverageBitRate) as? NSNumber)?.intValue, 6_000_000)
            XCTAssertEqual(encoder.sessionProperty(kVTCompressionPropertyKey_RealTime) as? Bool, true)
            XCTAssertEqual(encoder.sessionProperty(kVTCompressionPropertyKey_AllowFrameReordering) as? Bool, false)
            XCTAssertEqual((encoder.sessionProperty(kVTCompressionPropertyKey_MaxKeyFrameInterval) as? NSNumber)?.intValue, fps * 10)
            queue.sync { encoder.setBitrate(kbps: 2000) }
            XCTAssertEqual((encoder.sessionProperty(kVTCompressionPropertyKey_AverageBitRate) as? NSNumber)?.intValue, 2_000_000)
            // DataRateLimits is accepted but not readable back under low-latency rate control.
            XCTAssertEqual(encoder.rejectedProperties, [], "every session property must be accepted")
            print("fps \(fps): profile_idc \(sps[1]) level_idc \(sps[3]), low-latency RC \(encoder.usesLowLatencyRateControl), rejected \(encoder.rejectedProperties)")
            queue.sync { encoder.invalidate() }
        }
    }

    /// Explicit profiles. Constrained baseline must be what browser WebRTC accepts: profile-level-id
    /// 42e0xx (profile_idc 66 with constraint_set0/1 set, so any Baseline decoder can take it).
    func testExplicitH264Profiles() throws {
        // VideoToolbox leaves constraint_set1 clear on Main (4d00xx), which is still plain Main.
        let cases: [(H264Profile, Int, UInt8)] = [(.constrainedBaseline, 66, 0xE0), (.main, 77, 0x00), (.high, 100, 0x00)]
        for (profile, profileIDC, constraints) in cases {
            let queue = DispatchQueue(label: "test.profile.\(profile)")
            let frames = Recorder<EncodedVideoFrame>()
            let encoder = try VideoEncoder(
                settings: .init(codec: .h264, width: 1280, height: 720, fps: 60, bitrateKbps: 6000, h264Profile: profile),
                queue: queue, onFrame: frames.append)
            let buffers = (0..<3).map { TestMedia.pixelBuffer(width: 1280, height: 720, frame: $0) }
            for (i, pb) in buffers.enumerated() { queue.sync { encoder.encode(pb, pts: UInt64(i + 1) * 16_667) } }
            XCTAssertTrue(waitFor(3) { frames.count == 3 })
            let sps = try XCTUnwrap(AnnexB.nalUnits(in: frames.items[0].data).first)
            let profileLevelID = sps[1...3].map { String(format: "%02x", $0) }.joined()
            print("\(profile): SPS profile-level-id \(profileLevelID), low-latency RC \(encoder.usesLowLatencyRateControl)")
            XCTAssertEqual(sps[0] & 0x1F, 7)
            XCTAssertEqual(Int(sps[1]), profileIDC, "\(profile) profile_idc")
            XCTAssertEqual(sps[2] & 0xE0, constraints, "\(profile) constraint_set0..2 flags")
            if profile == .constrainedBaseline {
                XCTAssertTrue(profileLevelID.hasPrefix("42e0"), profileLevelID)
                XCTAssertEqual(H264SPS.direct8x8Inference([UInt8](sps)), true)
            }
            XCTAssertEqual(encoder.rejectedProperties, [])
            XCTAssertEqual(try decodeAnnexB(frames.items.map(\.data), codec: .h264).count, 3)
            queue.sync { encoder.invalidate() }
        }
    }

    func testProfileChangeNeedsNewSession() {
        let base = VideoEncoder.Settings(codec: .h264, width: 1280, height: 720, fps: 30, bitrateKbps: 6000)
        var other = base
        other.h264Profile = .constrainedBaseline
        XCTAssertTrue(base.needsNewSession(comparedTo: other))
        other = base
        other.bitrateKbps = 1000
        XCTAssertFalse(base.needsNewSession(comparedTo: other))
        var hevc = base
        hevc.codec = .hevc
        var hevcOther = hevc
        hevcOther.h264Profile = .high
        XCTAssertFalse(hevc.needsNewSession(comparedTo: hevcOther), "profile is H.264-only")
    }

    // MARK: JPEG

    func testJPEGVideoToolbox() throws {
        let run = try makeRun(.jpeg, bitrateKbps: 60_000)
        XCTAssertFalse(run.encoder.usesSoftwareJPEG, "hardware JPEG expected on Apple silicon")
        XCTAssertEqual(run.encoder.rejectedProperties, [])
        try exerciseJPEG(run)
    }

    func testJPEGCoreImageFallback() throws {
        let run = try makeRun(.jpeg, bitrateKbps: 60_000, softwareJPEG: true)
        XCTAssertTrue(run.encoder.usesSoftwareJPEG)
        try exerciseJPEG(run)
    }

    private func exerciseJPEG(_ runIn: Run) throws {
        var run = runIn
        run.feed(10, content: 7)
        XCTAssertTrue(run.waitForFrames(10))
        run.encoder.requestKeyframe()
        run.queue.sync { run.encoder.setBitrate(kbps: 5_000) }
        run.feed(5, content: 7)
        XCTAssertTrue(run.waitForFrames(15))
        let frames = run.frames.items
        XCTAssertTrue(frames.allSatisfy(\.isKeyframe))
        XCTAssertTrue(frames.allSatisfy { $0.codec == .jpeg })
        for frame in frames {
            XCTAssertEqual([UInt8](frame.data.prefix(2)), [0xFF, 0xD8], "SOI")
            XCTAssertEqual([UInt8](frame.data.suffix(2)), [0xFF, 0xD9], "EOI")
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithData(frames[0].data as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, width)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, height)
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let early = frames[0..<10].map(\.data.count).reduce(0, +) / 10
        let late = frames[10...].map(\.data.count).reduce(0, +) / 5
        print("jpeg (\(run.encoder.usesSoftwareJPEG ? "Core Image" : "VideoToolbox")): \(early) B/frame at 60 Mbps, \(late) B/frame at 5 Mbps")
        XCTAssertLessThan(late, early, "lower bitrate → lower quality → smaller frames")
        run.queue.sync { run.encoder.invalidate() }
    }

    func testJPEGQualityMapping() {
        XCTAssertEqual(VideoEncoder.jpegQuality(bitrateKbps: 1_000, width: 1920, height: 1080, fps: 30), 0.4)
        XCTAssertEqual(VideoEncoder.jpegQuality(bitrateKbps: 200_000, width: 960, height: 540, fps: 30), 0.85)
        let mcu2Low = VideoEncoder.jpegQuality(bitrateKbps: 20_000, width: 960, height: 540, fps: 30)
        XCTAssert((0.55...0.75).contains(mcu2Low), "\(mcu2Low)")
    }

    // MARK: Decodability by an independent decoder

    /// Writes raw Annex B streams and checks them with ffprobe (skipped when ffmpeg is absent).
    func testFFprobeAcceptsAnnexBStreams() throws {
        let ffprobe = "/opt/homebrew/bin/ffprobe"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: ffprobe), "ffprobe not installed")
        for (codec, ext, name) in [(VideoCodec.h264, "h264", "h264"), (.hevc, "hevc", "hevc")] {
            var run = try makeRun(codec)
            run.feed(20)
            run.feedAfterKeyframeRequest(TestMedia.pixelBuffer(width: 1280, height: 720, frame: 20))
            run.feed(9)
            XCTAssertTrue(run.waitForFrames(30))
            Thread.sleep(forTimeInterval: 0.2)
            run.queue.sync { run.encoder.invalidate() }
            XCTAssertEqual(run.frames.items.indices.filter { run.frames.items[$0].isKeyframe }, [0, 20])
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("dashcast-test.\(ext)")
            try run.frames.items.map(\.data).reduce(Data(), +).write(to: url)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffprobe)
            process.arguments = ["-v", "error", "-count_frames", "-select_streams", "v:0", "-show_entries",
                                 "stream=codec_name,width,height,nb_read_frames", "-of", "default=nw=1", url.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            print("ffprobe \(ext): \(output.replacingOccurrences(of: "\n", with: " "))")
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertTrue(output.contains("codec_name=\(name)"), output)
            XCTAssertTrue(output.contains("width=1280"), output)
            XCTAssertTrue(output.contains("height=720"), output)
            XCTAssertTrue(output.contains("nb_read_frames=30"), output)
            try? FileManager.default.removeItem(at: url)
        }
    }
}
