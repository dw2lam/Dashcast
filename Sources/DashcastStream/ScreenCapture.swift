import CoreGraphics
import CoreMedia
import DashcastContracts
import Foundation
import ScreenCaptureKit

/// SCStream wrapper for one display. Sample handlers run on the engine's pipeline queue.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Complete frames only, with pts in server µs.
    var onVideoFrame: ((CVPixelBuffer, UInt64) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?
    var onStop: ((Error) -> Void)?

    private let queue: DispatchQueue
    private var stream: SCStream?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    static func configuration(for config: StreamConfig) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = config.width
        c.height = config.height
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(config.fps, 1)))
        c.queueDepth = 3
        c.showsCursor = true
        c.colorSpaceName = CGColorSpace.sRGB
        // A display whose aspect differs from the frame is letterboxed, not stretched.
        c.preservesAspectRatio = true
        c.capturesAudio = config.captureAudio
        c.excludesCurrentProcessAudio = true
        c.sampleRate = AudioRepacketizer.sampleRate
        c.channelCount = 2
        return c
    }

    /// The SCDisplay for `displayID`. A just-created virtual display can take a moment to
    /// show up, so this retries until `timeout`.
    static func shareableDisplay(for displayID: CGDirectDisplayID, timeout: TimeInterval = 2) async throws -> SCDisplay {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            if let display = content.displays.first(where: { $0.displayID == displayID }) { return display }
            if Date() >= deadline { throw StreamEngineError.displayNotFound(displayID) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func start(display: SCDisplay, config: StreamConfig) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: Self.configuration(for: config), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func update(_ config: StreamConfig) async throws {
        try await stream?.updateConfiguration(Self.configuration(for: config))
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        // Throws if the stream already stopped on its own; nothing to do then.
        try? await stream.stopCapture()
        try? stream.removeStreamOutput(self, type: .screen)
        try? stream.removeStreamOutput(self, type: .audio)
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            guard Self.isComplete(sampleBuffer), let pixelBuffer = sampleBuffer.imageBuffer else { return }
            onVideoFrame?(pixelBuffer, DashClock.micros(from: sampleBuffer.presentationTimeStamp))
        case .audio:
            onAudio?(sampleBuffer)
        default:
            break
        }
    }

    /// Only `.complete` frames carry new pixels (`.idle` repeats, `.blank`, etc. are skipped).
    static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}
