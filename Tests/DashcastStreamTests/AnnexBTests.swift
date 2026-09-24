import DashcastContracts
import XCTest
@testable import DashcastStream

final class AnnexBTests: XCTestCase {
    private let sc: [UInt8] = [0, 0, 0, 1]

    func testConvertsLengthPrefixesToStartCodes() throws {
        // Two NAL units: an IDR slice (3 bytes) and an SEI (2 bytes), 4-byte big-endian lengths.
        let avcc = Data([0, 0, 0, 3, 0x65, 0xAA, 0xBB, 0, 0, 0, 2, 0x06, 0xCC])
        let out = try XCTUnwrap(AnnexB.convert(avcc, nalLengthSize: 4))
        XCTAssertEqual([UInt8](out), sc + [0x65, 0xAA, 0xBB] + sc + [0x06, 0xCC])
    }

    func testPrependsParameterSetsOnKeyframes() throws {
        let sps = Data([0x67, 0x4D, 0x40, 0x1F])
        let pps = Data([0x68, 0xEE, 0x3C, 0x80])
        let avcc = Data([0, 0, 0, 2, 0x65, 0x88])
        let out = try XCTUnwrap(AnnexB.convert(avcc, nalLengthSize: 4, parameterSets: [sps, pps]))
        XCTAssertEqual([UInt8](out), sc + [UInt8](sps) + sc + [UInt8](pps) + sc + [0x65, 0x88])
        XCTAssertEqual(nalTypes(out, codec: .h264), [7, 8, 5])
    }

    func testHEVCParameterSetOrder() throws {
        let vps = Data([0x40, 0x01, 0x0C]), sps = Data([0x42, 0x01, 0x01]), pps = Data([0x44, 0x01, 0xC1])
        let idr = Data([0, 0, 0, 3, 0x26, 0x01, 0xAF]) // IDR_W_RADL = 19
        let out = try XCTUnwrap(AnnexB.convert(idr, nalLengthSize: 4, parameterSets: [vps, sps, pps]))
        XCTAssertEqual(nalTypes(out, codec: .hevc), [32, 33, 34, 19])
    }

    func testShortLengthPrefixes() throws {
        let avcc = Data([0, 2, 0x41, 0x9A, 0, 1, 0x41])
        let out = try XCTUnwrap(AnnexB.convert(avcc, nalLengthSize: 2))
        XCTAssertEqual([UInt8](out), sc + [0x41, 0x9A] + sc + [0x41])
    }

    func testRejectsMalformedInput() {
        XCTAssertNil(AnnexB.convert(Data([0, 0, 0, 9, 0x65, 0x00]), nalLengthSize: 4), "length past the end")
        XCTAssertNil(AnnexB.convert(Data([0, 0, 0]), nalLengthSize: 4), "truncated prefix")
        XCTAssertNil(AnnexB.convert(Data([0, 1, 0x65]), nalLengthSize: 5), "bad prefix size")
    }

    /// VideoToolbox's constrained-baseline SPS (42c0) gains constraint_set2 → 42e0 when
    /// direct_8x8_inference_flag is 1; anything else is left alone.
    func testConstrainedBaselineSPSBecomes42e0() {
        // 42c01f SPS: id 0, log2_max_frame_num-4 = 0, poc type 2, 1 ref frame, no gaps,
        // 80x45 MBs (1280x720), frame_mbs_only 1, direct_8x8_inference 1.
        var w = BitWriter()
        w.ue(0); w.ue(0); w.ue(2); w.ue(1); w.bit(0); w.ue(79); w.ue(44); w.bit(1); w.bit(1); w.bit(0); w.bit(0); w.bit(1)
        let sps = Data([0x67, 0x42, 0xC0, 0x1F] + w.bytes)
        XCTAssertEqual(H264SPS.direct8x8Inference([UInt8](sps)), true)
        XCTAssertEqual([UInt8](H264SPS.withExtendedCompatibility(sps).prefix(4)), [0x67, 0x42, 0xE0, 0x1F])
        XCTAssertEqual(H264SPS.withExtendedCompatibility(sps).dropFirst(4), sps.dropFirst(4), "only the flags byte changes")

        var noDirect = BitWriter()
        noDirect.ue(0); noDirect.ue(0); noDirect.ue(2); noDirect.ue(1); noDirect.bit(0); noDirect.ue(79); noDirect.ue(44)
        noDirect.bit(1); noDirect.bit(0); noDirect.bit(0); noDirect.bit(0); noDirect.bit(1)
        let unsafe = Data([0x67, 0x42, 0xC0, 0x1F] + noDirect.bytes)
        XCTAssertEqual(H264SPS.withExtendedCompatibility(unsafe), unsafe, "direct_8x8_inference 0: no Extended claim")

        let main = Data([0x67, 0x4D, 0x40, 0x1F] + w.bytes)
        XCTAssertEqual(H264SPS.withExtendedCompatibility(main), main)
        let pps = Data([0x68, 0xCE, 0x3C, 0x80])
        XCTAssertEqual(H264SPS.withExtendedCompatibility(pps), pps)
    }

    func testSplitsAnnexBWithMixedStartCodes() {
        let stream = Data([0, 0, 0, 1, 0x67, 0x01, 0, 0, 1, 0x68, 0x02, 0, 0, 0, 1, 0x65, 0x03, 0x00])
        XCTAssertEqual(AnnexB.nalUnits(in: stream), [Data([0x67, 0x01]), Data([0x68, 0x02]), Data([0x65, 0x03, 0x00])])
    }
}

/// Minimal Exp-Golomb writer for building test SPS payloads.
private struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var used = 8

    mutating func bit(_ b: UInt32) {
        if used == 8 { bytes.append(0); used = 0 }
        if b != 0 { bytes[bytes.count - 1] |= 0x80 >> UInt8(used) }
        used += 1
    }

    mutating func ue(_ value: UInt32) {
        let v = value + 1
        let length = 32 - v.leadingZeroBitCount
        for _ in 0..<(length - 1) { bit(0) }
        for i in stride(from: length - 1, through: 0, by: -1) { bit((v >> UInt32(i)) & 1) }
    }
}
