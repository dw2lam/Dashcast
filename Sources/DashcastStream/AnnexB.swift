import CoreMedia
import DashcastContracts
import Foundation

/// VideoToolbox emits AVCC/HVCC samples (big-endian length-prefixed NAL units, parameter sets
/// in the format description). WebCodecs without a `description` wants Annex B.
enum AnnexB {
    static let startCode: [UInt8] = [0, 0, 0, 1]

    /// Rewrites length-prefixed NAL units as start-code-delimited ones, preceded by
    /// `parameterSets` (each with its own start code). Returns nil on malformed input.
    static func convert(_ avcc: UnsafeRawBufferPointer, nalLengthSize: Int, parameterSets: [Data] = []) -> Data? {
        guard (1...4).contains(nalLengthSize) else { return nil }
        var out = Data()
        out.reserveCapacity(avcc.count + parameterSets.reduce(0) { $0 + $1.count + 4 } + 64)
        for set in parameterSets {
            out.append(contentsOf: startCode)
            out.append(set)
        }
        var offset = 0
        while offset < avcc.count {
            guard offset + nalLengthSize <= avcc.count else { return nil }
            var length = 0
            for i in 0..<nalLengthSize { length = length << 8 | Int(avcc[offset + i]) }
            offset += nalLengthSize
            guard offset + length <= avcc.count else { return nil }
            if length > 0 {
                out.append(contentsOf: startCode)
                out.append(contentsOf: UnsafeRawBufferPointer(rebasing: avcc[offset..<offset + length]))
            }
            offset += length
        }
        return out
    }

    static func convert(_ avcc: Data, nalLengthSize: Int, parameterSets: [Data] = []) -> Data? {
        avcc.withUnsafeBytes { convert($0, nalLengthSize: nalLengthSize, parameterSets: parameterSets) }
    }

    /// SPS+PPS (H.264) or VPS+SPS+PPS (HEVC) in format-description order, plus the NAL length-prefix size.
    static func parameterSets(of format: CMFormatDescription, codec: VideoCodec) -> (sets: [Data], nalLengthSize: Int)? {
        typealias Getter = (CMFormatDescription, Int, UnsafeMutablePointer<UnsafePointer<UInt8>?>?,
                            UnsafeMutablePointer<Int>?, UnsafeMutablePointer<Int>?, UnsafeMutablePointer<Int32>?) -> OSStatus
        let get: Getter
        switch codec {
        case .h264: get = CMVideoFormatDescriptionGetH264ParameterSetAtIndex
        case .hevc: get = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex
        case .jpeg: return nil
        }
        var count = 0
        var nalLength: Int32 = 0
        guard get(format, 0, nil, nil, &count, &nalLength) == noErr else { return nil }
        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard get(format, index, &pointer, &size, nil, nil) == noErr, let pointer else { return nil }
            sets.append(Data(bytes: pointer, count: size))
        }
        return (sets, Int(nalLength))
    }

    /// One Annex B access unit for an encoded sample; parameter sets are inlined on keyframes.
    static func accessUnit(from sample: CMSampleBuffer, codec: VideoCodec, isKeyframe: Bool) -> Data? {
        guard let block = sample.dataBuffer, let format = sample.formatDescription,
              let info = parameterSets(of: format, codec: codec) else { return nil }
        var sets = isKeyframe ? info.sets : []
        if codec == .h264 { sets = sets.map(H264SPS.withExtendedCompatibility) }

        var lengthAtOffset = 0
        var total = 0
        var pointer: UnsafeMutablePointer<CChar>?
        if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                                       totalLengthOut: &total, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
           let pointer, lengthAtOffset == total {
            return convert(UnsafeRawBufferPointer(start: pointer, count: total),
                           nalLengthSize: info.nalLengthSize, parameterSets: sets)
        }
        // Non-contiguous block buffer: flatten first.
        total = CMBlockBufferGetDataLength(block)
        var bytes = Data(count: total)
        let status = bytes.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: $0.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { return nil }
        return convert(bytes, nalLengthSize: info.nalLengthSize, parameterSets: sets)
    }

    /// True unless the sample is marked NotSync.
    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return !((first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
    }

    /// Splits an Annex B stream into NAL units (without start codes). Accepts 3- and 4-byte start codes.
    static func nalUnits(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var start: Int?
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if let s = start {
                    var end = i
                    if end > s, bytes[end - 1] == 0 { end -= 1 }
                    units.append(Data(bytes[s..<end]))
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if let s = start, s < bytes.count { units.append(Data(bytes[s...])) }
        return units
    }
}

/// H.264 sequence-parameter-set helpers.
enum H264SPS {
    /// VideoToolbox writes Constrained Baseline as profile-level-id 42c0xx (constraint_set0+1).
    /// WebRTC SDP conventionally uses 42e0xx, which also claims Extended-profile compatibility
    /// (constraint_set2). For Constrained Baseline that only additionally needs
    /// direct_8x8_inference_flag = 1, so the flag is set exactly when the SPS satisfies it.
    /// Any other NAL unit or profile is returned unchanged.
    static func withExtendedCompatibility(_ nal: Data) -> Data {
        let bytes = [UInt8](nal)
        guard bytes.count > 4, bytes[0] & 0x1F == 7, bytes[1] == 66,
              bytes[2] & 0x40 != 0, bytes[2] & 0x20 == 0,
              direct8x8Inference(bytes) == true else { return nal }
        var patched = bytes
        patched[2] |= 0x20 // a nonzero byte stays nonzero: emulation prevention is unaffected
        return Data(patched)
    }

    /// Parses a Baseline-family SPS NAL unit (header byte included) up to direct_8x8_inference_flag.
    static func direct8x8Inference(_ nal: [UInt8]) -> Bool? {
        guard nal.count > 4 else { return nil }
        let profile = nal[1]
        // High-family profiles carry chroma/scaling fields first; not needed here.
        guard ![100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) else { return nil }
        var reader = BitReader(rbsp: Array(nal[4...]))
        guard reader.ue() != nil,               // seq_parameter_set_id
              reader.ue() != nil,               // log2_max_frame_num_minus4
              let pocType = reader.ue() else { return nil }
        switch pocType {
        case 0:
            guard reader.ue() != nil else { return nil } // log2_max_pic_order_cnt_lsb_minus4
        case 1:
            guard reader.bit() != nil, reader.se() != nil, reader.se() != nil, let cycle = reader.ue() else { return nil }
            for _ in 0..<cycle { guard reader.se() != nil else { return nil } }
        default:
            break
        }
        guard reader.ue() != nil,               // max_num_ref_frames
              reader.bit() != nil,              // gaps_in_frame_num_value_allowed_flag
              reader.ue() != nil,               // pic_width_in_mbs_minus1
              reader.ue() != nil,               // pic_height_in_map_units_minus1
              let frameMbsOnly = reader.bit() else { return nil }
        if frameMbsOnly == 0 { guard reader.bit() != nil else { return nil } } // mb_adaptive_frame_field_flag
        return reader.bit().map { $0 == 1 }
    }

    /// Exp-Golomb reader over an RBSP (emulation-prevention bytes removed on init).
    struct BitReader {
        private let bytes: [UInt8]
        private var position = 0

        init(rbsp escaped: [UInt8]) {
            var out: [UInt8] = []
            out.reserveCapacity(escaped.count)
            var zeros = 0
            for byte in escaped {
                if zeros >= 2, byte == 3 { zeros = 0; continue }
                zeros = byte == 0 ? zeros + 1 : 0
                out.append(byte)
            }
            bytes = out
        }

        mutating func bit() -> UInt32? {
            guard position < bytes.count * 8 else { return nil }
            let value = (bytes[position / 8] >> (7 - UInt8(position % 8))) & 1
            position += 1
            return UInt32(value)
        }

        mutating func ue() -> UInt32? {
            var leadingZeros = 0
            while true {
                guard let b = bit() else { return nil }
                if b == 1 { break }
                leadingZeros += 1
                if leadingZeros > 31 { return nil }
            }
            var suffix: UInt32 = 0
            for _ in 0..<leadingZeros {
                guard let b = bit() else { return nil }
                suffix = suffix << 1 | b
            }
            return (UInt32(1) << UInt32(leadingZeros)) - 1 + suffix
        }

        mutating func se() -> Int32? {
            guard let k = ue() else { return nil }
            return k % 2 == 1 ? Int32((k + 1) / 2) : -Int32(k / 2)
        }
    }
}
