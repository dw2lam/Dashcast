import AudioToolbox
import DashcastContracts
@testable import DashcastRTC
import XCTest

final class ClockTests: XCTestCase {
    func testVideoTimestampsAre90kHzFromPTS() {
        let clock = RTPClock(clockRate: 90_000, baseTimestamp: 1_000, anchorMicros: 5_000_000)
        XCTAssertEqual(clock.timestamp(forMicros: 5_000_000), 1_000)
        // 1/30 s → exactly 3000 ticks, even with µs truncation in the pts (33333 µs).
        XCTAssertEqual(clock.timestamp(forMicros: 5_033_333), 4_000)
        XCTAssertEqual(clock.timestamp(forMicros: 5_066_666), 7_000)
        XCTAssertEqual(clock.timestamp(forMicros: 6_000_000), 91_000)
        // Frames captured before the anchor (pipeline latency) go backwards, not to garbage.
        XCTAssertEqual(clock.timestamp(forMicros: 4_966_667), 1_000 &- 3_000)
    }

    func testAudioTimestampsAre48kHzAndWrap() {
        let clock = RTPClock(clockRate: 48_000, baseTimestamp: .max - 100, anchorMicros: 1_000_000)
        XCTAssertEqual(clock.timestamp(forMicros: 1_010_000), (UInt32.max - 100) &+ 480)
        XCTAssertEqual(clock.timestamp(forMicros: 1_020_000) &- clock.timestamp(forMicros: 1_000_000), 960)
        let later: UInt64 = 1_000_000 + 30 * 3_600 * 1_000_000   // 30 h: wraps 32-bit several times
        let ts = clock.timestamp(forMicros: later)
        XCTAssertEqual(clock.micros(forTimestamp: ts, near: later - 1_000_000), later)
    }

    func testNTPRoundTrip() {
        let now = DashClock.nowMicros()
        let ntp = NTPClock.ntp(forMicros: now)
        XCTAssertLessThanOrEqual(abs(Int64(NTPClock.micros(forNTP: ntp)) - Int64(now)), 1)
        // Roughly "now" in NTP seconds.
        let unixNow = Date().timeIntervalSince1970
        XCTAssertEqual(Double(ntp >> 32) - 2_208_988_800, unixNow, accuracy: 2)
        // 1 ms apart → 1 ms apart.
        let delta = NTPClock.ntp(forMicros: now + 1_000) - ntp
        XCTAssertEqual(Double(delta) / 4_294_967_296, 0.001, accuracy: 1e-6)
    }
}

final class OpusEncoderTests: XCTestCase {
    func testEncodes20msStereoPacketsWithPTS() throws {
        let encoder = try OpusEncoder()
        XCTAssertGreaterThan(encoder.lookaheadFrames, 0)
        var packets: [OpusEncoder.Packet] = []
        let base: UInt64 = 7_000_000
        for i in 0 ..< 100 {   // 1 s of 10 ms input
            packets += encoder.encode(AudioPacket(pts: base + UInt64(i) * 10_000, data: SinePCM.packet(index: i)))
        }
        XCTAssertEqual(packets.count, 50)
        for (n, packet) in packets.enumerated() {
            XCTAssertEqual(packet.pts, base + UInt64(n) * 20_000)
            // TOC: config 31 (CELT FB 20 ms) or any 20 ms config; stereo bit set; one frame (c = 0).
            let toc = packet.data[packet.data.startIndex]
            XCTAssertEqual(Self.frameDurationMicros(toc: toc), 20_000, "packet \(n) TOC \(String(toc, radix: 16))")
            XCTAssertEqual((toc >> 2) & 1, 1, "stereo")
            XCTAssertEqual(toc & 0x3, 0, "one frame per packet")
            XCTAssertLessThanOrEqual(packet.data.count, 1_276)
        }
    }

    func testDiscontinuityRestartsAtNewPTS() throws {
        let encoder = try OpusEncoder()
        var packets: [OpusEncoder.Packet] = []
        packets += encoder.encode(AudioPacket(pts: 1_000_000, data: SinePCM.packet(index: 0)))   // half a frame
        // 500 ms gap (capture stalled): the half frame is dropped, output restarts at the new pts.
        for i in 0 ..< 4 {
            packets += encoder.encode(AudioPacket(pts: 1_500_000 + UInt64(i) * 10_000, data: SinePCM.packet(index: i)))
        }
        XCTAssertEqual(packets.map(\.pts), [1_500_000, 1_520_000])
    }

    func testRoundTripDecodesToTheSine() throws {
        let encoder = try OpusEncoder()
        var packets: [Data] = []
        for i in 0 ..< 100 {
            packets += encoder.encode(AudioPacket(pts: UInt64(i) * 10_000, data: SinePCM.packet(index: i))).map(\.data)
        }
        let pcm = try Self.decode(packets)
        XCTAssertEqual(Double(pcm.count), 50 * 960 * 2, accuracy: 960 * 2)   // decoder trims its own priming
        // Skip the priming region, then check level and pitch (zero crossings of the left channel).
        let left = stride(from: 2 * 4_800, to: pcm.count, by: 2).map { Double(pcm[$0]) / Double(Int16.max) }
        let rms = sqrt(left.reduce(0) { $0 + $1 * $1 } / Double(left.count))
        XCTAssertEqual(rms, 0.2 / 2.squareRoot(), accuracy: 0.03)
        var crossings = 0
        for i in 1 ..< left.count where (left[i - 1] < 0) != (left[i] < 0) { crossings += 1 }
        let hz = Double(crossings) / 2 / (Double(left.count) / 48_000)
        XCTAssertEqual(hz, 440, accuracy: 5)
    }

    // MARK: helpers

    static func frameDurationMicros(toc: UInt8) -> Int {
        let config = Int(toc >> 3)
        switch config {
        case 0 ... 11: return [10_000, 20_000, 40_000, 60_000][config % 4]           // SILK
        case 12 ... 15: return [10_000, 20_000][config % 2]                          // Hybrid
        default: return [2_500, 5_000, 10_000, 20_000][(config - 16) % 4]            // CELT
        }
    }

    /// AudioToolbox Opus decode to s16 stereo (in memory only).
    static func decode(_ packets: [Data]) throws -> [Int16] {
        var opus = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var pcm = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                              mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                              mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var converter: AudioConverterRef?
        let status = AudioConverterNew(&opus, &pcm, &converter)
        guard status == noErr, let converter else { throw XCTSkip("no Opus decoder (\(status))") }
        defer { AudioConverterDispose(converter) }

        /// Owns the packet bytes and its description for the converter's input callback.
        final class Feed {
            let bytes: UnsafeMutableRawPointer
            let size: Int
            let description = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
            var consumed = false
            init(_ packet: Data) {
                size = packet.count
                bytes = .allocate(byteCount: max(size, 1), alignment: 16)
                packet.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: size)
                description.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                   mDataByteSize: UInt32(size))
            }
            deinit { bytes.deallocate(); description.deallocate() }
        }
        var output: [Int16] = []
        let buffer = UnsafeMutablePointer<Int16>.allocate(capacity: 960 * 2)
        defer { buffer.deallocate() }
        for packet in packets {
            let feed = Feed(packet)
            var frames: UInt32 = 960
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(960 * 4), mData: UnsafeMutableRawPointer(buffer)))
            let result = withExtendedLifetime(feed) {
                AudioConverterFillComplexBuffer(converter, { _, count, data, descriptions, user in
                    let feed = Unmanaged<Feed>.fromOpaque(user!).takeUnretainedValue()
                    if feed.consumed { count.pointee = 0; return 1 }
                    feed.consumed = true
                    data.pointee.mNumberBuffers = 1
                    data.pointee.mBuffers = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(feed.size),
                                                        mData: feed.bytes)
                    descriptions?.pointee = feed.description
                    count.pointee = 1
                    return noErr
                }, Unmanaged.passUnretained(feed).toOpaque(), &frames, &list, nil)
            }
            guard result == noErr || result == 1 else { throw NSError(domain: "decode", code: Int(result)) }
            output += UnsafeBufferPointer(start: buffer, count: Int(frames) * 2)
        }
        return output
    }
}
