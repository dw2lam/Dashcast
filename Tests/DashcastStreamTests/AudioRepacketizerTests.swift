import AVFAudio
import CoreMedia
import DashcastContracts
import XCTest
@testable import DashcastStream

final class AudioRepacketizerTests: XCTestCase {
    private func samples(_ packet: AudioPacket) -> [Int16] {
        packet.data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    /// Odd-sized planar chunks → exact 480-frame packets, contiguous pts, samples in order.
    func testOddChunksBecomeExactPackets() {
        let packets = Recorder<AudioPacket>()
        let r = AudioRepacketizer(onPacket: packets.append)
        let base: UInt64 = 5_000_000_000
        let chunkSizes = [137, 1001, 3, 999, 480, 1, 2047, 332]
        let total = chunkSizes.reduce(0, +)
        // Left ramps up, right ramps down, both inside [-1, 1].
        let left = (0..<total).map { Float($0 % 2000) / 2000 - 0.5 }
        let right = left.map { -$0 }

        var offset = 0
        for size in chunkSizes {
            // Chunk pts as a capture clock would report it (rounded µs, so slightly jittery).
            let pts = base + UInt64((Double(offset) * 1_000_000 / 48_000).rounded())
            left[offset...].withUnsafeBufferPointer { l in
                right[offset...].withUnsafeBufferPointer { rr in
                    r.append(left: .init(base: l.baseAddress!, stride: 1), right: .init(base: rr.baseAddress!, stride: 1),
                             frameCount: size, pts: pts)
                }
            }
            offset += size
        }

        let out = packets.items
        XCTAssertEqual(out.count, total / 480)
        XCTAssertTrue(out.allSatisfy { $0.data.count == 480 * 2 * 2 }, "480 stereo s16 frames per packet")
        XCTAssertEqual(out.map(\.pts), (0..<out.count).map { base + UInt64($0) * 10_000 })
        let interleaved = out.flatMap(samples)
        for i in stride(from: 0, to: interleaved.count / 2, by: 97) {
            XCTAssertEqual(interleaved[2 * i], AudioRepacketizer.int16(left[i]))
            XCTAssertEqual(interleaved[2 * i + 1], AudioRepacketizer.int16(right[i]))
        }
    }

    func testClipping() {
        XCTAssertEqual(AudioRepacketizer.int16(1.5), 32767)
        XCTAssertEqual(AudioRepacketizer.int16(-1.5), -32767)
        XCTAssertEqual(AudioRepacketizer.int16(1), 32767)
        XCTAssertEqual(AudioRepacketizer.int16(-1), -32767)
        XCTAssertEqual(AudioRepacketizer.int16(0.5), 16384)
        XCTAssertEqual(AudioRepacketizer.int16(0), 0)
        XCTAssertEqual(AudioRepacketizer.int16(.nan), 0)
        XCTAssertEqual(AudioRepacketizer.int16(.infinity), 32767)

        let packets = Recorder<AudioPacket>()
        let r = AudioRepacketizer(onPacket: packets.append)
        let loud = [Float](repeating: 3, count: 480), quiet = [Float](repeating: -3, count: 480)
        loud.withUnsafeBufferPointer { l in
            quiet.withUnsafeBufferPointer { q in
                r.append(left: .init(base: l.baseAddress!, stride: 1), right: .init(base: q.baseAddress!, stride: 1),
                         frameCount: 480, pts: 1_000)
            }
        }
        let s = samples(packets.items[0])
        XCTAssertEqual(s[0], 32767)
        XCTAssertEqual(s[1], -32767)
    }

    /// Interleaved stereo and mono inputs via stride; mono is duplicated to both channels.
    func testInterleavedAndMono() {
        let packets = Recorder<AudioPacket>()
        let r = AudioRepacketizer(onPacket: packets.append)
        let interleaved: [Float] = (0..<960).map { $0 % 2 == 0 ? 0.25 : -0.25 }
        interleaved.withUnsafeBufferPointer { p in
            r.append(left: .init(base: p.baseAddress!, stride: 2), right: .init(base: p.baseAddress! + 1, stride: 2),
                     frameCount: 480, pts: 0)
        }
        let mono = [Float](repeating: 0.5, count: 480)
        mono.withUnsafeBufferPointer { p in
            let ch = AudioRepacketizer.Channel(base: p.baseAddress!, stride: 1)
            r.append(left: ch, right: ch, frameCount: 480, pts: 10_000)
        }
        let out = packets.items
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(Array(samples(out[0]).prefix(4)), [8192, -8192, 8192, -8192])
        XCTAssertEqual(Array(samples(out[1]).prefix(4)), [16384, 16384, 16384, 16384])
        XCTAssertEqual(out.map(\.pts), [0, 10_000])
    }

    /// A gap in the input clock re-anchors pts instead of drifting.
    func testDiscontinuityReanchors() {
        let packets = Recorder<AudioPacket>()
        let r = AudioRepacketizer(onPacket: packets.append)
        let buffer = [Float](repeating: 0.1, count: 4800)
        buffer.withUnsafeBufferPointer { p in
            let ch = AudioRepacketizer.Channel(base: p.baseAddress!, stride: 1)
            r.append(left: ch, right: ch, frameCount: 720, pts: 1_000_000)      // 1.5 packets
            r.append(left: ch, right: ch, frameCount: 720, pts: 3_000_000)      // after a ~2 s silence gap
        }
        let out = packets.items
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0].pts, 1_000_000)
        // Leftover 240 frames (5 ms) are placed right before the new chunk.
        XCTAssertEqual(out[1].pts, 3_000_000 - 5_000)
        XCTAssertEqual(out[2].pts, 3_000_000 + 5_000)
    }

    /// Full CMSampleBuffer path, including AVAudioConverter for a 44.1 kHz mono source.
    func testSampleBufferConversion() throws {
        let packets = Recorder<AudioPacket>()
        let converter = AudioSampleBufferConverter(onPacket: packets.append)

        // 48 kHz non-interleaved float stereo (what SCK delivers): direct path.
        let direct = try makeSampleBuffer(format: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                                                channels: 2, interleaved: false)!,
                                          frames: 1024, value: 0.5, ptsMicros: 2_000_000)
        converter.process(direct)
        XCTAssertEqual(packets.count, 2) // 960 of 1024 frames
        XCTAssertEqual(packets.items.map(\.pts), [2_000_000, 2_010_000])
        XCTAssertEqual(Array(samples(packets.items[0]).prefix(2)), [16384, 16384])

        // 44.1 kHz mono → resampled, duplicated to stereo.
        let other = AudioSampleBufferConverter(onPacket: packets.append)
        let mono = try makeSampleBuffer(format: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                                              channels: 1, interleaved: false)!,
                                        frames: 4410, value: 0.25, ptsMicros: 9_000_000)
        other.process(mono)
        let converted = packets.items.dropFirst(2)
        XCTAssertGreaterThanOrEqual(converted.count, 8) // ~100 ms minus converter latency
        let s = converted.flatMap(samples)
        let tail = Array(s.suffix(200))
        XCTAssertTrue(tail.allSatisfy { abs(Int($0) - 8192) < 300 }, "resampled level should stay near 0.25")
        XCTAssertTrue(stride(from: 0, to: tail.count, by: 2).allSatisfy { tail[$0] == tail[$0 + 1] }, "mono → L == R")
    }

    private func makeSampleBuffer(format: AVAudioFormat, frames: Int, value: Float, ptsMicros: Int64) throws -> CMSampleBuffer {
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<Int(format.channelCount) {
            for i in 0..<frames { pcm.floatChannelData![ch][i] = value }
        }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
                                        presentationTimeStamp: CMTime(value: ptsMicros, timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var status = CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                                          refcon: nil, formatDescription: format.formatDescription,
                                          sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                          sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        XCTAssertEqual(status, noErr)
        status = CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: nil,
                                                                blockBufferMemoryAllocator: nil, flags: 0,
                                                                bufferList: pcm.audioBufferList)
        XCTAssertEqual(status, noErr)
        return sample!
    }
}
