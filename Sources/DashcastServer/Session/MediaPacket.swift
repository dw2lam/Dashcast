import DashcastContracts
import Foundation

/// Binary message types (PROTOCOL.md).
enum MediaType: UInt8 {
    case videoH264 = 1
    case videoHEVC = 2
    case videoJPEG = 3
    case audioPCM = 4

    init(codec: VideoCodec) {
        switch codec {
        case .h264: self = .videoH264
        case .hevc: self = .videoHEVC
        case .jpeg: self = .videoJPEG
        }
    }
}

/// 16-byte big-endian header: type u8 · flags u8 · reserved u16 · seq u32 · pts u64.
struct MediaHeader: Equatable {
    static let size = 16
    static let keyframeFlag: UInt8 = 0x01

    var type: MediaType
    var flags: UInt8
    var seq: UInt32
    var pts: UInt64

    var isKeyframe: Bool { flags & Self.keyframeFlag != 0 }

    func encoded() -> Data {
        var bytes = [UInt8](repeating: 0, count: Self.size)
        bytes[0] = type.rawValue
        bytes[1] = flags
        // bytes[2...3] reserved = 0
        for i in 0..<4 { bytes[4 + i] = UInt8((seq >> UInt32(24 - 8 * i)) & 0xFF) }
        for i in 0..<8 { bytes[8 + i] = UInt8((pts >> UInt64(56 - 8 * i)) & 0xFF) }
        return Data(bytes)
    }

    init(type: MediaType, flags: UInt8, seq: UInt32, pts: UInt64) {
        self.type = type; self.flags = flags; self.seq = seq; self.pts = pts
    }

    init?(_ data: Data) {
        guard data.count >= Self.size else { return nil }
        let b = [UInt8](data.prefix(Self.size))
        guard let type = MediaType(rawValue: b[0]) else { return nil }
        self.type = type
        flags = b[1]
        seq = b[4..<8].reduce(0) { $0 << 8 | UInt32($1) }
        pts = b[8..<16].reduce(0) { $0 << 8 | UInt64($1) }
    }

    static func video(_ frame: EncodedVideoFrame, seq: UInt32) -> MediaHeader {
        // JPEG frames are always independently decodable.
        let key = frame.isKeyframe || frame.codec == .jpeg
        return MediaHeader(type: MediaType(codec: frame.codec), flags: key ? keyframeFlag : 0, seq: seq, pts: frame.pts)
    }

    static func audio(_ packet: AudioPacket, seq: UInt32) -> MediaHeader {
        MediaHeader(type: .audioPCM, flags: 0, seq: seq, pts: packet.pts)
    }
}

enum AudioLevel {
    /// RMS of interleaved s16le PCM, normalized to 0…1 of full scale. Samples every other value
    /// (one channel of stereo) which is plenty for a silence check.
    static func rms(s16le data: Data) -> Double {
        let count = data.count / 2
        guard count > 0 else { return 0 }
        return data.withUnsafeBytes { raw -> Double in
            var sum: Double = 0
            var n = 0
            var i = 0
            while i < count {
                let lo = UInt16(raw[i * 2]), hi = UInt16(raw[i * 2 + 1])
                let s = Double(Int16(bitPattern: hi << 8 | lo))
                sum += s * s
                n += 1
                i += 2
            }
            return (sum / Double(n)).squareRoot() / 32768.0
        }
    }

    /// ~-54 dBFS. Anything above counts as "audio is playing" for the auto latency policy.
    static let silenceThreshold = 0.002
}
