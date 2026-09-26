import AppKit
import ApplicationServices
import CoreGraphics
import DashcastContracts
import Foundation
import os
import ScreenCaptureKit

/// Capture → encode pipeline for one display, the virtual display (extend mode) and input injection.
///
/// Threading: `start`/`update`/`stop` run one at a time, in call order. Capture handlers, encoding
/// and all callbacks (`onVideo`/`onAudio`/`onEvent`) run on one serial pipeline queue; input
/// injection has its own queue. Nothing runs while the screen is static.
///
/// Events: `.started` after every (re)start of the capture, `.stopped` after `stop()` or after a
/// failure tore the pipeline down (preceded by `.error`), `.permissionMissing` when Screen
/// Recording blocks `start` (which also throws) or Accessibility blocks an injected event.
public final class StreamEngine: StreamEngineProtocol {
    public var onVideo: ((EncodedVideoFrame) -> Void)? {
        get { lock.withLock { _onVideo } }
        set { lock.withLock { _onVideo = newValue } }
    }

    public var onAudio: ((AudioPacket) -> Void)? {
        get { lock.withLock { _onAudio } }
        set { lock.withLock { _onAudio = newValue } }
    }

    public var onEvent: ((EngineEvent) -> Void)? {
        get { lock.withLock { _onEvent } }
        set { lock.withLock { _onEvent = newValue } }
    }

    // Guarded by `lock`.
    private let lock = NSLock()
    private var _onVideo: ((EncodedVideoFrame) -> Void)?
    private var _onAudio: ((AudioPacket) -> Void)?
    private var _onEvent: ((EngineEvent) -> Void)?
    private var _config: StreamConfig?
    private var _capturedDisplayID: CGDirectDisplayID?
    private var _virtualDisplayID: CGDirectDisplayID?

    // Confined to `queue`.
    private let queue = DispatchQueue(label: "online.davidlam.dashcast.pipeline", qos: .userInteractive)
    private var encoder: VideoEncoder?
    private var audio: AudioSampleBufferConverter?

    // Touched only inside `operations`.
    private let operations = OperationChain()
    private var capture: ScreenCapture?
    private var virtualDisplay: VirtualDisplay?
    private var generation = 0

    private let injector = InputInjector()
    private static let log = Logger(subsystem: "online.davidlam.dashcast", category: "engine")

    public init() {
        injector.onPermissionMissing = { [weak self] in
            self?.emit(.permissionMissing("Accessibility access is needed to control the Mac from the car."))
        }
    }

    deinit {
        // Dropping the engine releases the stream, the session and the virtual display with it.
        injector.setTarget(nil)
    }

    // MARK: Lifecycle

    /// Starts capturing. If already running, behaves like `update(_:)`.
    public func start(_ config: StreamConfig) async throws {
        try await operations.run { try await self.apply(config) }
    }

    /// Bitrate-only changes are applied in place; size/fps/codec rebuild the encoder and reconfigure
    /// the stream; a different display (or virtual-display size/HiDPI) restarts the capture.
    /// No-op while stopped (`start` takes its own config).
    public func update(_ config: StreamConfig) async throws {
        try await operations.run {
            guard self.capture != nil else { return }
            try await self.apply(config)
        }
    }

    public func stop() async {
        _ = try? await operations.run {
            if await self.teardown() { self.emit(.stopped) }
        }
    }

    public func requestKeyframe() {
        queue.async { self.encoder?.requestKeyframe() }
    }

    public func setBitrate(kbps: Int) {
        guard kbps > 0 else { return }
        lock.withLock { _config?.bitrateKbps = kbps }
        queue.async { self.encoder?.setBitrate(kbps: kbps) }
    }

    public func inject(_ event: InputEvent) {
        injector.inject(event)
    }

    private func apply(_ new: StreamConfig) async throws {
        guard let old = lock.withLock({ _config }), let capture else {
            try await startPipeline(new)
            return
        }
        if needsNewSource(old: old, new: new) {
            await teardown()
            do {
                try await startPipeline(new)
            } catch {
                emit(.stopped) // the old pipeline is gone and the new one never started
                throw error
            }
            return
        }
        if old.width != new.width || old.height != new.height || old.fps != new.fps || old.captureAudio != new.captureAudio {
            try await capture.update(new)
        }
        let settings = VideoEncoder.Settings(new)
        try queue.sync {
            if let encoder, !encoder.settings.needsNewSession(comparedTo: settings) {
                encoder.setBitrate(kbps: new.bitrateKbps)
            } else {
                let replacement = try makeEncoder(settings)
                // A static screen sends no new frames: re-encode the last one at the new size.
                replacement.adoptLastFrame(encoder?.lastFrame)
                encoder?.invalidate()
                encoder = replacement
                replacement.requestKeyframe()
            }
            if !new.captureAudio { audio?.reset() }
        }
        let displayID = lock.withLock { () -> CGDirectDisplayID? in
            _config = new
            return _capturedDisplayID
        }
        if let displayID {
            injector.setTarget(.init(displayID: displayID, frameWidth: new.width, frameHeight: new.height))
        }
    }

    private func needsNewSource(old: StreamConfig, new: StreamConfig) -> Bool {
        guard old.displayMode == new.displayMode else { return true }
        switch new.displayMode {
        case .extend:
            return old.displayWidth != new.displayWidth || old.displayHeight != new.displayHeight || old.hiDPI != new.hiDPI
        case .mirror:
            return lock.withLock { _capturedDisplayID } != (new.mirrorDisplayID ?? CGMainDisplayID())
        }
    }

    private func startPipeline(_ config: StreamConfig) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            emit(.permissionMissing("Screen Recording access is needed to stream the display."))
            throw StreamEngineError.screenRecordingPermissionMissing
        }
        generation += 1
        let generation = self.generation
        do {
            let displayID: CGDirectDisplayID
            switch config.displayMode {
            case .extend:
                let display = try VirtualDisplay(width: config.displayWidth, height: config.displayHeight,
                                                 hiDPI: config.hiDPI) { [weak self] in
                    self?.pipelineFailed(generation, "The virtual display was removed by the system.")
                }
                virtualDisplay = display
                lock.withLock { _virtualDisplayID = display.displayID }
                guard await display.waitUntilActive() else {
                    throw StreamEngineError.virtualDisplayUnavailable("display \(display.displayID) did not come online")
                }
                displayID = display.displayID
            case .mirror:
                displayID = config.mirrorDisplayID ?? CGMainDisplayID()
            }

            let shareable = try await ScreenCapture.shareableDisplay(for: displayID)
            let encoder = try makeEncoder(VideoEncoder.Settings(config))
            let audio = AudioSampleBufferConverter { [weak self] packet in self?.deliverAudio(packet) }
            queue.sync {
                self.encoder = encoder
                self.audio = audio
            }

            let capture = ScreenCapture(queue: queue)
            capture.onVideoFrame = { [weak self] buffer, pts in self?.encoder?.encode(buffer, pts: pts) }
            capture.onAudio = { [weak self] sample in self?.audio?.process(sample) }
            capture.onStop = { [weak self] error in
                if Self.isPermissionError(error) {
                    self?.pipelineFailed(generation, .permissionMissing("Screen Recording stopped working, so casting stopped. Check it in Settings → General."))
                } else {
                    self?.pipelineFailed(generation, "Screen capture stopped: \(error.localizedDescription)")
                }
            }
            self.capture = capture
            try await capture.start(display: shareable, config: config)

            lock.withLock {
                _config = config
                _capturedDisplayID = displayID
            }
            injector.setTarget(.init(displayID: displayID, frameWidth: config.width, frameHeight: config.height))
            Self.log.info("started: display \(displayID) \(config.width)x\(config.height)@\(config.fps) \(config.codec.rawValue)")
            emit(.started(capturedDisplayID: displayID))
        } catch {
            await teardown()
            if Self.isPermissionError(error) {
                emit(.permissionMissing("Screen Recording access is needed to stream the display."))
                throw StreamEngineError.screenRecordingPermissionMissing
            }
            throw error
        }
    }

    /// Stops capture, invalidates the session and releases the virtual display. Returns whether
    /// anything was running.
    @discardableResult
    private func teardown() async -> Bool {
        let wasRunning = capture != nil || virtualDisplay != nil || lock.withLock { _config != nil }
        injector.setTarget(nil)
        if let capture { await capture.stop() }
        capture = nil
        queue.sync {
            encoder?.invalidate()
            encoder = nil
            audio = nil
        }
        if let virtualDisplay, !(await virtualDisplay.invalidate()) {
            Self.log.error("virtual display \(virtualDisplay.displayID) still listed after release")
        }
        virtualDisplay = nil
        lock.withLock {
            _config = nil
            _capturedDisplayID = nil
            _virtualDisplayID = nil
        }
        return wasRunning
    }

    /// Asynchronous failure (stream died, display vanished): report and tear down, unless the
    /// pipeline it belongs to is already gone.
    private func pipelineFailed(_ generation: Int, _ message: String) {
        pipelineFailed(generation, .error(message))
    }

    /// `event` is `.error` or `.permissionMissing`.
    private func pipelineFailed(_ generation: Int, _ event: EngineEvent) {
        Task.detached { [weak self] in
            guard let self else { return }
            _ = try? await self.operations.run {
                guard self.generation == generation, self.capture != nil || self.virtualDisplay != nil else { return }
                Self.log.error("\(String(describing: event), privacy: .public)")
                self.emit(event)
                await self.teardown()
                self.emit(.stopped)
            }
        }
    }

    private func makeEncoder(_ settings: VideoEncoder.Settings) throws -> VideoEncoder {
        try VideoEncoder(settings: settings, queue: queue,
                         onFrame: { [weak self] frame in self?.deliverVideo(frame) },
                         onError: { [weak self] message in self?.emit(.error(message)) })
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SCStreamErrorDomain && error.code == SCStreamError.Code.userDeclined.rawValue
    }

    // MARK: Delivery (pipeline queue)

    private func deliverVideo(_ frame: EncodedVideoFrame) {
        lock.withLock { _onVideo }?(frame)
    }

    private func deliverAudio(_ packet: AudioPacket) {
        lock.withLock { _onAudio }?(packet)
    }

    private func emit(_ event: EngineEvent) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.withLock { self._onEvent }?(event)
        }
    }

    // MARK: Displays and permissions

    public func availableDisplays() -> [DisplayInfo] {
        let virtualID = lock.withLock { _virtualDisplayID }
        let names = Self.screenNames()
        return VirtualDisplay.activeDisplayIDs().map { id in
            let bounds = CGDisplayBounds(id)
            let isVirtual = id == virtualID
                || (CGDisplayVendorNumber(id) == VirtualDisplay.vendorID && CGDisplayModelNumber(id) == VirtualDisplay.productID)
            let name = isVirtual ? VirtualDisplay.name
                : names[id] ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)")
            return DisplayInfo(id: id, name: name, width: Int(bounds.width), height: Int(bounds.height), isVirtual: isVirtual)
        }
    }

    /// NSScreen names by display ID. AppKit is only consulted on the main thread.
    private static func screenNames() -> [CGDirectDisplayID: String] {
        guard Thread.isMainThread else { return [:] }
        return MainActor.assumeIsolated {
            var names: [CGDirectDisplayID: String] = [:]
            for screen in NSScreen.screens {
                if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                    names[CGDirectDisplayID(number.uint32Value)] = screen.localizedName
                }
            }
            return names
        }
    }

    public func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    public func requestScreenRecordingPermission() {
        _ = CGRequestScreenCaptureAccess()
    }

    public func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    public func requestAccessibilityPermission() {
        // kAXTrustedCheckOptionPrompt
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}

/// Runs async operations one at a time, in call order.
final class OperationChain: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func run<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        let task: Task<T, Error> = lock.withLock {
            let previous = tail
            let task = Task.detached { () async throws -> T in
                await previous?.value
                return try await operation()
            }
            tail = Task.detached { _ = try? await task.value }
            return task
        }
        return try await task.value
    }
}
