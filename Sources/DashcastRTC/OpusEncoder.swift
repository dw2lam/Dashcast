import AudioToolbox
import DashcastContracts
import Foundation

/// PCM s16le stereo 48 kHz (any packet size, normally 10 ms) → 20 ms Opus packets, via AudioToolbox's
/// built-in Opus encoder (`kAudioFormatOpus`; no libopus needed).
///
/// Each output packet carries the pts of its first input sample. Input is expected to be contiguous
/// (the engine's repacketizer guarantees pts advance by exactly the packet duration); a pts jump
/// larger than `discontinuityMicros` drops the partial frame and restarts at the new pts, so
/// timestamps always follow capture time. Not thread-safe: one caller at a time.
final class OpusEncoder {
    struct Packet: Sendable {
        /// Server µs of the frame's first input sample.
        var pts: UInt64
        var data: Data
    }

    enum EncoderError: Error, CustomStringConvertible {
        case unavailable(OSStatus)
        case property(String, OSStatus)
        var description: String {
            switch self {
            case .unavailable(let status): return "AudioToolbox Opus encoder unavailable (OSStatus \(status))"
            case .property(let name, let status): return "Opus encoder \(name) failed (OSStatus \(status))"
            }
        }
    }

    static let sampleRate = 48_000
    static let channels = 2
    static let framesPerPacket = 960                  // 20 ms
    static let packetMicros: UInt64 = 20_000
    static let bytesPerFrame = 4                      // s16 × 2
    static let discontinuityMicros: UInt64 = 2_000

    /// Encoder delay (priming): decoded sample n is input sample n - lookaheadFrames.
    let lookaheadFrames: Int
    var lookaheadMicros: UInt64 { UInt64(lookaheadFrames) * 1_000_000 / UInt64(Self.sampleRate) }

    private let converter: AudioConverterRef
    private let maxPacketBytes: Int
    private let output: UnsafeMutableRawPointer
    /// Interleaved samples not yet encoded, and the pts of the first one.
    private var fifo: [Int16] = []
    private var fifoPTS: UInt64?
    /// pts of frames handed to the converter whose packets haven't come out yet.
    private var pending: [UInt64] = []

    init(bitrate: UInt32 = 128_000) throws {
        var input = AudioStreamBasicDescription(
            mSampleRate: Float64(Self.sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(Self.bytesPerFrame), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(Self.bytesPerFrame), mChannelsPerFrame: UInt32(Self.channels),
            mBitsPerChannel: 16, mReserved: 0)
        var opus = AudioStreamBasicDescription(
            mSampleRate: Float64(Self.sampleRate), mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(Self.framesPerPacket), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(Self.channels), mBitsPerChannel: 0, mReserved: 0)
        var converterRef: AudioConverterRef?
        let status = AudioConverterNew(&input, &opus, &converterRef)
        guard status == noErr, let converterRef else { throw EncoderError.unavailable(status) }
        converter = converterRef

        var rate = bitrate
        var setStatus = AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate,
                                                  UInt32(MemoryLayout<UInt32>.size), &rate)
        if setStatus != noErr {
            AudioConverterDispose(converter)
            throw EncoderError.property("bitrate", setStatus)
        }

        var maxBytes: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        setStatus = AudioConverterGetProperty(converter, kAudioConverterPropertyMaximumOutputPacketSize,
                                              &size, &maxBytes)
        maxPacketBytes = Int(max(maxBytes, 1_500))
        output = UnsafeMutableRawPointer.allocate(byteCount: maxPacketBytes, alignment: 16)

        var prime = AudioConverterPrimeInfo()
        size = UInt32(MemoryLayout<AudioConverterPrimeInfo>.size)
        if AudioConverterGetProperty(converter, kAudioConverterPrimeInfo, &size, &prime) == noErr {
            lookaheadFrames = Int(prime.leadingFrames)
        } else {
            lookaheadFrames = 312   // libopus default (6.5 ms)
        }
        fifo.reserveCapacity(Self.framesPerPacket * Self.channels * 2)
    }

    deinit {
        AudioConverterDispose(converter)
        output.deallocate()
    }

    /// Forget buffered input (e.g. when the track (re)opens) so the next packet starts fresh.
    func reset() {
        fifo.removeAll(keepingCapacity: true)
        fifoPTS = nil
        pending.removeAll()
        AudioConverterReset(converter)
    }

    func encode(_ packet: AudioPacket) -> [Packet] {
        let frameCount = packet.data.count / Self.bytesPerFrame
        guard frameCount > 0 else { return [] }

        if let start = fifoPTS {
            let expected = start + Self.micros(forFrames: fifo.count / Self.channels)
            let drift = expected > packet.pts ? expected - packet.pts : packet.pts - expected
            if drift > Self.discontinuityMicros {
                fifo.removeAll(keepingCapacity: true)   // drop the partial frame; restart at the new pts
                fifoPTS = nil
            }
        }
        if fifoPTS == nil { fifoPTS = packet.pts }

        packet.data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)   // s16le == host order on Apple silicon
            fifo.append(contentsOf: samples.prefix(frameCount * Self.channels))
        }

        var packets: [Packet] = []
        let samplesPerPacket = Self.framesPerPacket * Self.channels
        while fifo.count >= samplesPerPacket, let pts = fifoPTS {
            pending.append(pts)
            let data = fifo.withUnsafeBufferPointer { encodeFrame(UnsafeRawPointer($0.baseAddress!)) }
            fifo.removeFirst(samplesPerPacket)
            fifoPTS = pts + Self.packetMicros
            if let data {
                packets.append(Packet(pts: pending.removeFirst(), data: data))
            } else if pending.count > 4 {
                pending.removeFirst()   // never let a stalled converter skew later timestamps
            }
        }
        return packets
    }

    static func micros(forFrames frames: Int) -> UInt64 {
        (UInt64(frames) * 1_000_000 + UInt64(sampleRate / 2)) / UInt64(sampleRate)
    }

    // MARK: - AudioConverter

    private struct InputState {
        var pointer: UnsafeRawPointer?
        var frames: UInt32
    }

    /// Returned by the input proc when it has handed over its one frame: "no more input for now",
    /// which (unlike noErr + 0 packets) doesn't put the converter into end-of-stream.
    private static let inputExhausted: OSStatus = 0x6463_6E64   // 'dcnd'

    private static let inputProc: AudioConverterComplexInputDataProc = { _, ioPackets, ioData, _, userData in
        let state = userData!.assumingMemoryBound(to: InputState.self)
        guard let pointer = state.pointee.pointer, state.pointee.frames > 0 else {
            ioPackets.pointee = 0
            return OpusEncoder.inputExhausted
        }
        let frames = state.pointee.frames
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers = AudioBuffer(mNumberChannels: UInt32(OpusEncoder.channels),
                                              mDataByteSize: frames * UInt32(OpusEncoder.bytesPerFrame),
                                              mData: UnsafeMutableRawPointer(mutating: pointer))
        ioPackets.pointee = frames
        state.pointee = InputState(pointer: nil, frames: 0)
        return noErr
    }

    /// Feeds one 960-frame block; returns the Opus packet it produced (nil while the converter is still buffering).
    private func encodeFrame(_ samples: UnsafeRawPointer) -> Data? {
        var state = InputState(pointer: samples, frames: UInt32(Self.framesPerPacket))
        var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: UInt32(Self.channels), mDataByteSize: UInt32(maxPacketBytes), mData: output))
        var packetCount: UInt32 = 1
        var description = AudioStreamPacketDescription()
        let status = withUnsafeMutablePointer(to: &state) { statePointer in
            AudioConverterFillComplexBuffer(converter, Self.inputProc, statePointer,
                                            &packetCount, &buffers, &description)
        }
        guard status == noErr || status == Self.inputExhausted, packetCount > 0 else { return nil }
        let length = description.mDataByteSize > 0 ? Int(description.mDataByteSize) : Int(buffers.mBuffers.mDataByteSize)
        guard length > 0 else { return nil }
        return Data(bytes: output.advanced(by: Int(description.mStartOffset)), count: length)
    }
}
