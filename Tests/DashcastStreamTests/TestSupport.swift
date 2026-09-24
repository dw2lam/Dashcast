import CoreMedia
import CoreVideo
import DashcastContracts
import Foundation
import VideoToolbox
import XCTest
@testable import DashcastStream

/// Thread-safe collector for callback output.
final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [T] = []
    var items: [T] { lock.withLock { _items } }
    var count: Int { lock.withLock { _items.count } }
    func append(_ item: T) { lock.withLock { _items.append(item) } }
}

enum TestMedia {
    /// NV12 (420v) frame with a moving gradient and box, so every frame differs.
    static func pixelBuffer(width: Int, height: Int, frame: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            attributes as CFDictionary, &buffer)
        let pb = buffer!
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let boxX = (frame * 16) % max(width - 128, 1), boxY = (frame * 9) % max(height - 128, 1)
        for row in 0..<height {
            for col in 0..<width {
                let inBox = col >= boxX && col < boxX + 128 && row >= boxY && row < boxY + 128
                y[row * yStride + col] = inBox ? 235 : UInt8(16 + ((col + row + frame * 4) % 200))
            }
        }
        let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        for row in 0..<height / 2 {
            for col in 0..<width / 2 {
                uv[row * uvStride + col * 2] = UInt8(64 + (col + frame) % 128)
                uv[row * uvStride + col * 2 + 1] = UInt8(64 + (row + frame) % 128)
            }
        }
        return pb
    }

    static func meanLuma(_ pb: CVPixelBuffer, columns: Range<Int>? = nil) -> Double {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let height = CVPixelBufferGetHeightOfPlane(pb, 0)
        let cols = columns ?? 0..<CVPixelBufferGetWidthOfPlane(pb, 0)
        let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        var sum = 0
        for row in 0..<height { for col in cols { sum += Int(y[row * stride + col]) } }
        return Double(sum) / Double(cols.count * height)
    }

    /// Mean absolute luma difference between two same-sized NV12 buffers.
    static func lumaDifference(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(a, 0), height = CVPixelBufferGetHeightOfPlane(a, 0)
        let pa = CVPixelBufferGetBaseAddressOfPlane(a, 0)!.assumingMemoryBound(to: UInt8.self)
        let pb = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
        let sa = CVPixelBufferGetBytesPerRowOfPlane(a, 0), sb = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
        var sum = 0
        for row in 0..<height { for col in 0..<width { sum += abs(Int(pa[row * sa + col]) - Int(pb[row * sb + col])) } }
        return Double(sum) / Double(width * height)
    }
}

/// NAL unit types of an Annex B access unit.
func nalTypes(_ data: Data, codec: VideoCodec) -> [Int] {
    AnnexB.nalUnits(in: data).compactMap { nal in
        guard let first = nal.first else { return nil }
        return codec == .hevc ? Int((first >> 1) & 0x3F) : Int(first & 0x1F)
    }
}

enum DecodeError: Error { case noParameterSets, formatDescription(OSStatus), session(OSStatus), decode(OSStatus), noImage }

/// Decodes a sequence of Annex B access units (the first must be a keyframe) with
/// VTDecompressionSession and returns the decoded images in order.
func decodeAnnexB(_ accessUnits: [Data], codec: VideoCodec) throws -> [CVPixelBuffer] {
    let first = AnnexB.nalUnits(in: accessUnits[0])
    let types = nalTypes(accessUnits[0], codec: codec)
    let wanted = codec == .hevc ? [32, 33, 34] : [7, 8]
    let sets = wanted.compactMap { t in types.firstIndex(of: t).map { first[$0] } }
    guard sets.count == wanted.count else { throw DecodeError.noParameterSets }

    var format: CMFormatDescription?
    // Stable copies: small Data values are stored inline, so their bytes can't be pointed at.
    let buffers = sets.map { set -> UnsafeMutablePointer<UInt8> in
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
        set.copyBytes(to: p, count: set.count)
        return p
    }
    defer { buffers.forEach { $0.deallocate() } }
    let status: OSStatus = {
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        if codec == .hevc {
            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
        }
        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
            parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
    }()
    guard status == noErr, let format else { throw DecodeError.formatDescription(status) }

    var session: VTDecompressionSession?
    let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    let s = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                         imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                         decompressionSessionOut: &session)
    guard s == noErr, let session else { throw DecodeError.session(s) }
    defer { VTDecompressionSessionInvalidate(session) }

    let images = Recorder<CVPixelBuffer>()
    let failures = Recorder<OSStatus>()
    for (index, unit) in accessUnits.enumerated() {
        let parameterTypes = Set(wanted)
        var avcc = Data()
        for (nal, type) in zip(AnnexB.nalUnits(in: unit), nalTypes(unit, codec: codec)) where !parameterTypes.contains(type) {
            var length = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &length, count: 4))
            avcc.append(nal)
        }
        var block: CMBlockBuffer?
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: avcc.count, alignment: 1)
        avcc.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: avcc.count)
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: bytes, blockLength: avcc.count,
                                           blockAllocator: kCFAllocatorMalloc, customBlockSource: nil, offsetToData: 0,
                                           dataLength: avcc.count, flags: 0, blockBufferOut: &block)
        var sample: CMSampleBuffer?
        var size = avcc.count
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30),
                                        decodeTimeStamp: .invalid)
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                  sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &size, sampleBufferOut: &sample)
        let d = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample!, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            if status != noErr { failures.append(status) }
            if let image { images.append(image) }
        }
        if d != noErr { throw DecodeError.decode(d) }
    }
    VTDecompressionSessionWaitForAsynchronousFrames(session)
    if let failure = failures.items.first { throw DecodeError.decode(failure) }
    guard images.count == accessUnits.count else { throw DecodeError.noImage }
    return images.items
}

/// Polls `condition` until it holds or `timeout` passes.
@discardableResult
func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return true
}

/// Capture and virtual displays need an unlocked session with an awake display; skip otherwise
/// (e.g. overnight runs while the Mac is locked) instead of failing on an environment condition.
func skipUnlessScreenAvailable() throws {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
    if (session["CGSSessionScreenIsLocked"] as? Bool) == true || (session["CGSSessionScreenIsLocked"] as? Int) == 1 {
        throw XCTSkip("screen is locked")
    }
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    if count == 0 { throw XCTSkip("no active display (display asleep)") }
}
