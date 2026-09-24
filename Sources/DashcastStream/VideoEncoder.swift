import CoreImage
import CoreMedia
import CoreVideo
import DashcastContracts
import Foundation
import os
import VideoToolbox

/// One VideoToolbox compression session (H.264, HEVC or JPEG). Keeps the last captured frame so a
/// keyframe can be produced even while ScreenCaptureKit is silent (static screen).
///
/// Confined to `queue`: call every method there except `requestKeyframe()`, which hops itself.
/// Encoded frames are delivered on `queue`, in order, until `invalidate()`.
final class VideoEncoder {
    struct Settings: Equatable {
        var codec: VideoCodec
        var width: Int
        var height: Int
        var fps: Int
        var bitrateKbps: Int
        /// H.264 only.
        var h264Profile: H264Profile

        init(codec: VideoCodec, width: Int, height: Int, fps: Int, bitrateKbps: Int, h264Profile: H264Profile = .auto) {
            self.codec = codec; self.width = width; self.height = height; self.fps = fps
            self.bitrateKbps = bitrateKbps; self.h264Profile = h264Profile
        }

        init(_ config: StreamConfig) {
            self.init(codec: config.codec, width: config.width, height: config.height,
                      fps: config.fps, bitrateKbps: config.bitrateKbps, h264Profile: config.h264Profile)
        }

        /// Everything except bitrate needs a new session.
        func needsNewSession(comparedTo other: Settings) -> Bool {
            codec != other.codec || width != other.width || height != other.height || fps != other.fps
                || (codec == .h264 && h264Profile != other.h264Profile)
        }

        /// VideoToolbox profile/level for H.264 and HEVC; `.auto` is Main below 60 fps, High at 60.
        var profileLevel: CFString? {
            switch codec {
            case .jpeg: return nil
            case .hevc: return kVTProfileLevel_HEVC_Main_AutoLevel
            case .h264:
                switch h264Profile {
                case .auto: return fps >= 60 ? kVTProfileLevel_H264_High_AutoLevel : kVTProfileLevel_H264_Main_AutoLevel
                case .constrainedBaseline: return kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel
                case .main: return kVTProfileLevel_H264_Main_AutoLevel
                case .high: return kVTProfileLevel_H264_High_AutoLevel
                }
            }
        }
    }

    private(set) var settings: Settings
    /// Whether the session was created with `EnableLowLatencyRateControl`.
    private(set) var usesLowLatencyRateControl = false
    /// JPEG only: true when Core Image/ImageIO is used because VideoToolbox JPEG was unavailable.
    private(set) var usesSoftwareJPEG = false
    /// Session properties the encoder refused (non-fatal; diagnostics).
    private(set) var rejectedProperties: [String] = []

    private let queue: DispatchQueue
    private let onFrame: (EncodedVideoFrame) -> Void
    private let onError: (String) -> Void
    private var session: VTCompressionSession?
    private var jpegContext: CIContext?
    private var scaler: VTPixelTransferSession?
    private var scaledPool: CVPixelBufferPool?

    private var lastPixelBuffer: CVPixelBuffer?
    private var lastSubmittedPTS: UInt64?
    private var keyframePending = false
    private var keyframeFallback: DispatchWorkItem?
    private var isInvalidated = false
    private var loggedEncodeError = false

    private static let log = Logger(subsystem: "online.davidlam.dashcast", category: "encoder")

    init(settings: Settings, queue: DispatchQueue, forceSoftwareJPEG: Bool = false,
         onFrame: @escaping (EncodedVideoFrame) -> Void, onError: @escaping (String) -> Void = { _ in }) throws {
        precondition(settings.width > 0 && settings.height > 0 && settings.fps > 0)
        self.settings = settings
        self.queue = queue
        self.onFrame = onFrame
        self.onError = onError

        if settings.codec == .jpeg, forceSoftwareJPEG {
            jpegContext = CIContext(options: [.cacheIntermediates: false])
            usesSoftwareJPEG = true
            return
        }
        do {
            try makeSession()
        } catch let error as StreamEngineError where settings.codec == .jpeg {
            Self.log.error("VideoToolbox JPEG unavailable (\(error.localizedDescription)); using Core Image")
            jpegContext = CIContext(options: [.cacheIntermediates: false])
            usesSoftwareJPEG = true
        }
    }

    deinit {
        if let session { VTCompressionSessionInvalidate(session) }
    }

    var frameInterval: TimeInterval { 1 / Double(settings.fps) }

    // MARK: Encoding

    /// Encodes a captured frame. `pts` is server µs of capture.
    func encode(_ pixelBuffer: CVPixelBuffer, pts: UInt64) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isInvalidated else { return }
        lastPixelBuffer = pixelBuffer
        submit(pixelBuffer, pts: pts)
    }

    /// Forces a keyframe on the next frame. If none arrives within about one frame interval,
    /// the last captured frame is re-encoded as a keyframe so a new viewer gets a picture now.
    func requestKeyframe() {
        queue.async { [weak self] in
            guard let self, !self.isInvalidated else { return }
            self.keyframePending = true
            self.keyframeFallback?.cancel()
            let fallback = DispatchWorkItem { [weak self] in self?.flushPendingKeyframe() }
            self.keyframeFallback = fallback
            self.queue.asyncAfter(deadline: .now() + self.frameInterval * 1.2, execute: fallback)
        }
    }

    /// Seeds the "last frame" after a rebuild, so the new session can emit a keyframe at once.
    func adoptLastFrame(_ pixelBuffer: CVPixelBuffer?) {
        dispatchPrecondition(condition: .onQueue(queue))
        if lastPixelBuffer == nil { lastPixelBuffer = pixelBuffer }
    }

    var lastFrame: CVPixelBuffer? { lastPixelBuffer }

    func setBitrate(kbps: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard kbps > 0, kbps != settings.bitrateKbps else { return }
        settings.bitrateKbps = kbps
        applyRateControl()
    }

    /// Stops output for good. Frames still in flight are dropped.
    func invalidate() {
        dispatchPrecondition(condition: .onQueue(queue))
        isInvalidated = true
        keyframeFallback?.cancel()
        keyframeFallback = nil
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        if let scaler { VTPixelTransferSessionInvalidate(scaler) }
        scaler = nil
        scaledPool = nil
        lastPixelBuffer = nil
        jpegContext = nil
    }

    private func flushPendingKeyframe() {
        guard keyframePending, !isInvalidated, let last = lastPixelBuffer else { return }
        submit(last, pts: DashClock.nowMicros())
    }

    private func submit(_ pixelBuffer: CVPixelBuffer, pts rawPTS: UInt64) {
        // VideoToolbox needs strictly increasing timestamps; a re-encoded frame is stamped "now",
        // so a capture that was already in flight could otherwise go backwards.
        let pts = max(rawPTS, (lastSubmittedPTS ?? 0) + 1)
        lastSubmittedPTS = pts
        let forceKeyframe = keyframePending
        keyframePending = false
        keyframeFallback?.cancel()
        keyframeFallback = nil

        guard let input = fitted(pixelBuffer) else { return }

        if let jpegContext {
            encodeSoftwareJPEG(input, pts: pts, context: jpegContext)
            return
        }
        guard let session else { return }
        let time = CMTime(value: CMTimeValue(pts), timescale: 1_000_000)
        let duration = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
        let properties = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let codec = settings.codec
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: input, presentationTimeStamp: time, duration: duration,
            frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, flags, sample in
            // Runs on a VideoToolbox thread; conversion is pure, delivery hops to the queue.
            guard let self else { return }
            guard status == noErr, let sample, !flags.contains(.frameDropped) else {
                if status != noErr { self.reportEncodeError(status) }
                return
            }
            let frame = Self.makeFrame(from: sample, codec: codec)
            self.queue.async {
                guard !self.isInvalidated, let frame else { return }
                self.onFrame(frame)
            }
        }
        if status != noErr { reportEncodeError(status) }
    }

    private func reportEncodeError(_ status: OSStatus) {
        queue.async { [weak self] in
            guard let self, !self.isInvalidated, !self.loggedEncodeError else { return }
            self.loggedEncodeError = true
            Self.log.error("encode failed: \(status)")
            self.onError("\(self.settings.codec.rawValue) encode failed (OSStatus \(status))")
        }
    }

    static func makeFrame(from sample: CMSampleBuffer, codec: VideoCodec) -> EncodedVideoFrame? {
        let pts = sample.presentationTimeStamp.convertScale(1_000_000, method: .roundHalfAwayFromZero)
        guard pts.isValid, pts.value >= 0 else { return nil }
        switch codec {
        case .h264, .hevc:
            let isKeyframe = AnnexB.isKeyframe(sample)
            guard let data = AnnexB.accessUnit(from: sample, codec: codec, isKeyframe: isKeyframe) else { return nil }
            return EncodedVideoFrame(pts: UInt64(pts.value), isKeyframe: isKeyframe, codec: codec, data: data)
        case .jpeg:
            guard let block = sample.dataBuffer, let data = try? block.dataBytes() else { return nil }
            return EncodedVideoFrame(pts: UInt64(pts.value), isKeyframe: true, codec: .jpeg, data: data)
        }
    }

    private func encodeSoftwareJPEG(_ pixelBuffer: CVPixelBuffer, pts: UInt64, context: CIContext) {
        let quality = Self.jpegQuality(bitrateKbps: settings.bitrateKbps, width: settings.width,
                                       height: settings.height, fps: settings.fps)
        let options = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let data = context.jpegRepresentation(of: CIImage(cvPixelBuffer: pixelBuffer),
                                                    colorSpace: colorSpace, options: options) else { return }
        onFrame(EncodedVideoFrame(pts: pts, isKeyframe: true, codec: .jpeg, data: data))
    }

    // MARK: Scaling

    /// Returns `buffer` if it already has the encode size, else a scaled copy. Only hit briefly
    /// after a resolution change (in-flight captures, or the re-encoded last frame).
    private func fitted(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        let width = settings.width, height = settings.height
        if CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height { return buffer }
        if scaler == nil {
            var session: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) == noErr else { return nil }
            scaler = session
        }
        if scaledPool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &scaledPool)
        }
        var output: CVPixelBuffer?
        guard let scaler, let scaledPool,
              CVPixelBufferPoolCreatePixelBuffer(nil, scaledPool, &output) == kCVReturnSuccess, let output,
              VTPixelTransferSessionTransferImage(scaler, from: buffer, to: output) == noErr else { return nil }
        return output
    }

    // MARK: Session setup

    private var codecType: CMVideoCodecType {
        switch settings.codec {
        case .h264: return kCMVideoCodecType_H264
        case .hevc: return kCMVideoCodecType_HEVC
        case .jpeg: return kCMVideoCodecType_JPEG
        }
    }

    private func makeSession() throws {
        var lastStatus: OSStatus = noErr
        // Low-latency rate control first (not offered for JPEG); plain session as the fallback.
        let attempts: [Bool] = settings.codec == .jpeg ? [false] : [true, false]
        for lowLatency in attempts {
            var spec: [CFString: Any] = [:]
            if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
            let sourceAttributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: settings.width,
                kCVPixelBufferHeightKey: settings.height,
            ]
            var created: VTCompressionSession?
            lastStatus = VTCompressionSessionCreate(
                allocator: nil, width: Int32(settings.width), height: Int32(settings.height), codecType: codecType,
                encoderSpecification: spec as CFDictionary, imageBufferAttributes: sourceAttributes as CFDictionary,
                compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created)
            if lastStatus == noErr, let created {
                session = created
                usesLowLatencyRateControl = lowLatency
                break
            }
        }
        guard let session else { throw StreamEngineError.encoderUnavailable(settings.codec, lastStatus) }

        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        if settings.codec != .jpeg {
            set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
            set(kVTCompressionPropertyKey_ExpectedFrameRate, settings.fps as CFNumber)
            set(kVTCompressionPropertyKey_MaxKeyFrameInterval, settings.fps * 10 as CFNumber)
            set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 10 as CFNumber)
            if let profile = settings.profileLevel { set(kVTCompressionPropertyKey_ProfileLevel, profile) }
        }
        applyRateControl()
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    private func applyRateControl() {
        switch settings.codec {
        case .jpeg:
            let quality = Self.jpegQuality(bitrateKbps: settings.bitrateKbps, width: settings.width,
                                           height: settings.height, fps: settings.fps)
            set(kVTCompressionPropertyKey_Quality, quality as CFNumber)
        case .h264, .hevc:
            let bitsPerSecond = settings.bitrateKbps * 1000
            set(kVTCompressionPropertyKey_AverageBitRate, bitsPerSecond as CFNumber)
            // Cap bursts at 1.5x the average over any 1 s window.
            let bytesPerWindow = Double(bitsPerSecond) * 1.5 / 8
            set(kVTCompressionPropertyKey_DataRateLimits, [bytesPerWindow as CFNumber, 1.0 as CFNumber] as CFArray)
        }
    }

    /// Current value of a session property (diagnostics and tests).
    func sessionProperty(_ key: CFString) -> Any? {
        guard let session else { return nil }
        var value: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &value) {
            VTSessionCopyProperty(session, key: key, allocator: nil, valueOut: UnsafeMutableRawPointer($0))
        }
        return status == noErr ? value : nil
    }

    @discardableResult
    private func set(_ key: CFString, _ value: CFTypeRef) -> Bool {
        guard let session else { return false }
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr {
            Self.log.error("\(key as String, privacy: .public) not applied: \(status)")
            if !rejectedProperties.contains(key as String) { rejectedProperties.append(key as String) }
        }
        return status == noErr
    }

    /// Maps a bitrate budget onto JPEG quality via bits per pixel (clamped 0.4…0.85).
    static func jpegQuality(bitrateKbps: Int, width: Int, height: Int, fps: Int) -> Double {
        let pixelsPerSecond = Double(max(width * height * fps, 1))
        let bitsPerPixel = Double(bitrateKbps) * 1000 / pixelsPerSecond
        // ~0.5 bpp → 0.4, ~2 bpp → 0.85 for typical desktop content.
        let quality = 0.4 + (bitsPerPixel - 0.5) * 0.3
        return min(max(quality, 0.4), 0.85)
    }
}
