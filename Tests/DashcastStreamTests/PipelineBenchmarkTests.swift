import CoreMedia
import CoreVideo
import DashcastContracts
import Foundation
import VideoToolbox
import XCTest
@testable import DashcastStream

/// Opt-in micro-benchmarks for the per-frame hot path: `DASHCAST_BENCH=1 swift test --filter PipelineBenchmarkTests`.
/// Synthetic pixel buffers and sample buffers only: no capture, no displays. Numbers are printed, not asserted.
final class PipelineBenchmarkTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DASHCAST_BENCH"] == "1", "set DASHCAST_BENCH=1")
    }

    /// Encoded sample → Annex B access unit (`VideoEncoder.makeFrame`), per frame, keyframe every 15th.
    func testBenchPacketize() throws {
        for codec in [VideoCodec.h264, .hevc] {
            let samples = try Self.encodedSamples(codec: codec, count: 60, keyframeEvery: 15)
            XCTAssertEqual(samples.count, 60)
            for sample in samples { _ = VideoEncoder.makeFrame(from: sample, codec: codec) } // warm-up
            let iterations = 500
            var bytes = 0
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations {
                for sample in samples { bytes &+= VideoEncoder.makeFrame(from: sample, codec: codec)?.data.count ?? 0 }
            }
            let nanos = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iterations * samples.count)
            print("bench packetize \(codec): \(String(format: "%.2f", nanos / 1000)) µs/frame (mean AU \(bytes / (iterations * samples.count)) B)")
        }
    }

    /// Real-time paced encode through `VideoEncoder`: this process's CPU per frame and submit→output latency.
    func testBenchEncoderRealtime() throws {
        let cases: [(VideoCodec, Int, Int, Int, Int)] = [
            (.h264, 1280, 720, 30, 6_000), (.h264, 1920, 1200, 60, 16_000), (.hevc, 1920, 1200, 60, 12_000),
        ]
        for (codec, width, height, fps, kbps) in cases {
            let pool = (0..<4).map { TestMedia.pixelBuffer(width: width, height: height, frame: $0 * 7) }
            let queue = DispatchQueue(label: "bench.encoder", qos: .userInteractive)
            let latencies = Recorder<UInt64>()
            let sizes = Recorder<Int>()
            let encoder = try VideoEncoder(
                settings: .init(codec: codec, width: width, height: height, fps: fps, bitrateKbps: kbps), queue: queue,
                onFrame: { frame in
                    latencies.append(DashClock.nowMicros() - frame.pts)
                    sizes.append(frame.data.count)
                })
            let count = fps * 4
            let interval = 1.0 / Double(fps)
            let cpuStart = Self.processCPUSeconds()
            let wallStart = Date()
            for index in 0..<count {
                let due = wallStart.addingTimeInterval(Double(index) * interval)
                let wait = due.timeIntervalSinceNow
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                let buffer = pool[index % pool.count]
                queue.sync { encoder.encode(buffer, pts: DashClock.nowMicros()) }
            }
            XCTAssertTrue(waitFor(3) { latencies.count >= count - 2 }, "\(latencies.count)/\(count) frames")
            let cpu = Self.processCPUSeconds() - cpuStart
            queue.sync { encoder.invalidate() }
            let sorted = latencies.items.sorted()
            let p = { (q: Double) in Double(sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]) / 1000 }
            print(String(format: "bench encode %@ %dx%d@%d: %.0f µs CPU/frame (%.1f%% of a core), latency p50 %.2f ms p95 %.2f ms, mean %d B",
                         codec.rawValue, width, height, fps, cpu / Double(count) * 1e6,
                         cpu / Date().timeIntervalSince(wallStart) * 100, p(0.5), p(0.95),
                         sizes.items.reduce(0, +) / max(sizes.count, 1)))
        }
    }

    /// SCK-shaped audio (1024-frame planar float chunks) → 10 ms s16 packets.
    func testBenchAudioRepacketize() {
        var packets = 0
        let repacketizer = AudioRepacketizer { _ in packets += 1 }
        let left = (0..<1024).map { Float(sin(Double($0) / 10)) * 0.5 }
        let right = left.map { -$0 }
        let chunks = 48_000 * 60 / 1024 // one minute of audio
        let start = DispatchTime.now().uptimeNanoseconds
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                for i in 0..<chunks {
                    repacketizer.append(left: .init(base: l.baseAddress!, stride: 1), right: .init(base: r.baseAddress!, stride: 1),
                                        frameCount: 1024, pts: 1_000_000 + UInt64(i) * 21_333)
                }
            }
        }
        let millis = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        print(String(format: "bench audio repacketize: %.2f ms per minute of audio (%d packets)", millis, packets))
    }

    // MARK: Helpers

    /// Raw VideoToolbox output (AVCC sample buffers) for `count` animated 1280x720 frames.
    static func encodedSamples(codec: VideoCodec, count: Int, keyframeEvery: Int) throws -> [CMSampleBuffer] {
        var created: VTCompressionSession?
        let type = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let status = VTCompressionSessionCreate(
            allocator: nil, width: 1280, height: 720, codecType: type, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &created)
        guard status == noErr, let session = created else { throw StreamEngineError.encoderUnavailable(codec, status) }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 6_000_000 as CFNumber)
        let samples = Recorder<CMSampleBuffer>()
        for index in 0..<count {
            let buffer = TestMedia.pixelBuffer(width: 1280, height: 720, frame: index)
            let force = index % keyframeEvery == 0
            let properties = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
            VTCompressionSessionEncodeFrame(
                session, imageBuffer: buffer, presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30),
                duration: CMTime(value: 1, timescale: 30), frameProperties: properties, infoFlagsOut: nil
            ) { status, _, sample in
                if status == noErr, let sample { samples.append(sample) }
            }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return samples.items
    }

    static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
