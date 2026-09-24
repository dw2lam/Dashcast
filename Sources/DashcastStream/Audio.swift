import AVFAudio
import CoreMedia
import DashcastContracts
import Foundation
import os

/// Float PCM in arbitrary chunk sizes → interleaved s16le stereo 48 kHz packets of exactly
/// 480 frames (10 ms). Packet pts advance by exactly 10 000 µs while input is continuous.
final class AudioRepacketizer {
    static let sampleRate = 48_000
    static let framesPerPacket = 480
    /// Input whose pts is further than this from the expected position re-anchors the clock.
    static let discontinuityMicros: UInt64 = 20_000

    /// One channel of float samples: `base[i * stride]` is frame i.
    struct Channel {
        var base: UnsafePointer<Float>
        var stride: Int
    }

    var onPacket: (AudioPacket) -> Void

    private var pending: [Int16] = []           // interleaved L/R, fewer than 480 frames between calls
    private var anchorPTS: UInt64?              // pts of frame 0 since the last (re-)anchor
    private var framesSinceAnchor: UInt64 = 0   // frames emitted since the anchor

    init(onPacket: @escaping (AudioPacket) -> Void) {
        self.onPacket = onPacket
        pending.reserveCapacity(Self.framesPerPacket * 4)
    }

    /// Appends `frameCount` frames; `pts` is the server-µs time of the first one.
    /// Mono input: pass the same channel as `left` and `right`.
    func append(left: Channel, right: Channel, frameCount: Int, pts: UInt64) {
        guard frameCount > 0 else { return }
        let pendingFrames = UInt64(pending.count / 2)
        if let anchor = anchorPTS {
            let expected = anchor + Self.micros(forFrames: framesSinceAnchor + pendingFrames)
            let drift = expected > pts ? expected - pts : pts - expected
            if drift > Self.discontinuityMicros { reanchor(firstIncomingPTS: pts, pendingFrames: pendingFrames) }
        } else {
            reanchor(firstIncomingPTS: pts, pendingFrames: pendingFrames)
        }

        for i in 0..<frameCount {
            pending.append(Self.int16(left.base[i * left.stride]))
            pending.append(Self.int16(right.base[i * right.stride]))
            if pending.count == Self.framesPerPacket * 2 { emitPacket() }
        }
    }

    func reset() {
        pending.removeAll(keepingCapacity: true)
        anchorPTS = nil
        framesSinceAnchor = 0
    }

    /// Frame n of the current anchor lands at `anchor + n * 1e6 / 48000` (exact, no drift).
    static func micros(forFrames frames: UInt64) -> UInt64 {
        frames * 1_000_000 / UInt64(sampleRate)
    }

    /// Clamps to [-1, 1] and scales symmetrically by 32767; NaN becomes silence.
    static func int16(_ sample: Float) -> Int16 {
        guard !sample.isNaN else { return 0 }
        let clamped = Swift.min(Swift.max(sample, -1), 1)
        return Int16((clamped * 32767).rounded())
    }

    private func reanchor(firstIncomingPTS pts: UInt64, pendingFrames: UInt64) {
        // Keep the leftover samples and place them immediately before the incoming chunk.
        let leftover = Self.micros(forFrames: pendingFrames)
        anchorPTS = pts >= leftover ? pts - leftover : 0
        framesSinceAnchor = 0
    }

    private func emitPacket() {
        let pts = (anchorPTS ?? 0) + Self.micros(forFrames: framesSinceAnchor)
        let data = pending.withUnsafeBufferPointer { Data(buffer: $0) } // host is little-endian
        pending.removeAll(keepingCapacity: true)
        framesSinceAnchor += UInt64(Self.framesPerPacket)
        onPacket(AudioPacket(pts: pts, data: data))
    }
}

/// Feeds ScreenCaptureKit audio sample buffers (Float32, normally non-interleaved 48 kHz stereo)
/// into an `AudioRepacketizer`. Other formats go through AVAudioConverter first.
final class AudioSampleBufferConverter {
    let repacketizer: AudioRepacketizer
    private var converter: AVAudioConverter?
    private var converterSource: AudioStreamBasicDescription?
    private var loggedFailure = false

    private static let log = Logger(subsystem: "online.davidlam.dashcast", category: "audio")
    private static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                    sampleRate: Double(AudioRepacketizer.sampleRate),
                                                    channels: 2, interleaved: false)!

    init(onPacket: @escaping (AudioPacket) -> Void) {
        repacketizer = AudioRepacketizer(onPacket: onPacket)
    }

    func reset() { repacketizer.reset() }

    func process(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0,
              let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return }
        let frames = sampleBuffer.numSamples
        let pts = DashClock.micros(from: sampleBuffer.presentationTimeStamp)
        do {
            try sampleBuffer.withAudioBufferList { list, _ in
                if Self.isDirectlyUsable(asbd) {
                    appendFloat(list, asbd: asbd, frames: frames, pts: pts)
                } else {
                    convertAndAppend(list, asbd: asbd, frames: frames, pts: pts)
                }
            }
        } catch {
            logOnce("audio buffer list unavailable: \(error)")
        }
    }

    static func isDirectlyUsable(_ asbd: AudioStreamBasicDescription) -> Bool {
        asbd.mFormatID == kAudioFormatLinearPCM
            && asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
            && asbd.mBitsPerChannel == 32
            && asbd.mSampleRate == Double(AudioRepacketizer.sampleRate)
            && asbd.mChannelsPerFrame >= 1
    }

    private func appendFloat(_ list: UnsafeMutableAudioBufferListPointer, asbd: AudioStreamBasicDescription,
                             frames: Int, pts: UInt64) {
        let channels = Int(asbd.mChannelsPerFrame)
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let left: AudioRepacketizer.Channel
        let right: AudioRepacketizer.Channel
        if nonInterleaved {
            guard list.count >= 1, let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                  Int(list[0].mDataByteSize) >= frames * 4 else { return }
            left = .init(base: l, stride: 1)
            if list.count >= 2, let r = list[1].mData?.assumingMemoryBound(to: Float.self),
               Int(list[1].mDataByteSize) >= frames * 4 {
                right = .init(base: r, stride: 1)
            } else {
                right = left
            }
        } else {
            guard list.count >= 1, let p = list[0].mData?.assumingMemoryBound(to: Float.self),
                  Int(list[0].mDataByteSize) >= frames * channels * 4 else { return }
            left = .init(base: p, stride: channels)
            right = channels >= 2 ? .init(base: p + 1, stride: channels) : left
        }
        repacketizer.append(left: left, right: right, frameCount: frames, pts: pts)
    }

    private func convertAndAppend(_ list: UnsafeMutableAudioBufferListPointer, asbd: AudioStreamBasicDescription,
                                  frames: Int, pts: UInt64) {
        var source = asbd
        if converterSource.map({ !Self.same($0, source) }) ?? true {
            guard let format = AVAudioFormat(streamDescription: &source),
                  let made = AVAudioConverter(from: format, to: Self.targetFormat) else {
                logOnce("unsupported audio format: \(asbd)")
                return
            }
            if format.channelCount == 1 { made.channelMap = [0, 0] } // mono → both ears
            converter = made
            converterSource = source
        }
        guard let converter,
              let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, bufferListNoCopy: list.unsafePointer) else { return }
        input.frameLength = AVAudioFrameCount(frames)
        let ratio = Self.targetFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0, let channels = output.floatChannelData else {
            if let error { logOnce("audio conversion failed: \(error)") }
            return
        }
        repacketizer.append(left: .init(base: channels[0], stride: 1), right: .init(base: channels[1], stride: 1),
                            frameCount: Int(output.frameLength), pts: pts)
    }

    private static func same(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID && a.mFormatFlags == b.mFormatFlags
            && a.mBitsPerChannel == b.mBitsPerChannel && a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mBytesPerFrame == b.mBytesPerFrame
    }

    private func logOnce(_ message: String) {
        guard !loggedFailure else { return }
        loggedFailure = true
        Self.log.error("\(message, privacy: .public)")
    }
}
