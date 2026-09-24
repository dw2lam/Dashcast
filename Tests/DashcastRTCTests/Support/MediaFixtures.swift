import DashcastContracts
import Foundation
import XCTest

/// Real H.264 for the interop tests: libx264 constrained baseline, Annex B, split into access units
/// on AUD (the AUD itself dropped, so units look like VideoToolbox output: SPS+PPS+IDR on keyframes).
enum H264Fixture {
    struct AccessUnit {
        var data: Data
        var isKeyframe: Bool
    }

    static let width = 1280
    static let height = 720
    static let fps = 30

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: [AccessUnit]?

    /// 10 s of `testsrc2` at 1280x720@30, 6 Mbps, IDR every second. Generated once per machine.
    static func accessUnits() throws -> [AccessUnit] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dashcast-rtc-720p30-baseline-v1.h264")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: {
                FileManager.default.isExecutableFile(atPath: $0)
            }) else {
                throw XCTSkip("ffmpeg (with libx264) not installed")
            }
            let partial = url.appendingPathExtension("partial")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = [
                "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", "testsrc2=size=\(width)x\(height):rate=\(fps)", "-t", "10",
                "-c:v", "libx264", "-profile:v", "baseline", "-level", "3.1", "-bf", "0",
                "-g", "\(fps)", "-keyint_min", "\(fps)", "-sc_threshold", "0",
                "-b:v", "6M", "-maxrate", "6M", "-bufsize", "2M", "-pix_fmt", "yuv420p",
                "-x264-params", "aud=1", "-bsf:v", "h264_mp4toannexb", "-f", "h264", partial.path,
            ]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw XCTSkip("ffmpeg failed (\(process.terminationStatus)) generating the H.264 fixture")
            }
            try FileManager.default.moveItem(at: partial, to: url)
        }
        let units = split(try Data(contentsOf: url))
        cached = units
        return units
    }

    /// NAL units of an Annex B buffer: (start of the NAL header, end) ranges.
    static func nalRanges(_ data: Data) -> [(header: Int, start: Int, end: Int)] {
        let bytes = [UInt8](data)
        var starts: [(prefix: Int, header: Int)] = []
        var i = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    starts.append((i, i + 3)); i += 3; continue
                }
                if i + 4 <= bytes.count, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                    starts.append((i, i + 4)); i += 4; continue
                }
            }
            i += 1
        }
        return starts.enumerated().map { index, s in
            let end = index + 1 < starts.count ? starts[index + 1].prefix : bytes.count
            return (s.header, s.prefix, end)
        }
    }

    static func split(_ stream: Data) -> [AccessUnit] {
        let bytes = [UInt8](stream)
        var units: [AccessUnit] = []
        var current = Data()
        var keyframe = false
        for nal in nalRanges(stream) {
            let type = bytes[nal.header] & 0x1F
            if type == 9 {   // AUD: next access unit
                if !current.isEmpty { units.append(AccessUnit(data: current, isKeyframe: keyframe)) }
                current = Data()
                keyframe = false
                continue
            }
            if type == 5 { keyframe = true }
            current.append(contentsOf: [0, 0, 0, 1])
            current.append(contentsOf: bytes[nal.header ..< nal.end])
        }
        if !current.isEmpty { units.append(AccessUnit(data: current, isKeyframe: keyframe)) }
        return units
    }
}

/// Synthetic PCM (a sine; never played anywhere).
enum SinePCM {
    /// 10 ms of s16le stereo at 48 kHz, continuing the phase of packet `index`.
    /// `rightFrequency` (default: same as left) makes the channels distinguishable.
    static func packet(index: Int, frequency: Double = 440, rightFrequency: Double? = nil,
                       amplitude: Double = 0.2) -> Data {
        let frames = 480
        var samples = [Int16](repeating: 0, count: frames * 2)
        for i in 0 ..< frames {
            let n = Double(index * frames + i)
            let scale = amplitude * Double(Int16.max)
            samples[2 * i] = Int16(sin(2 * .pi * frequency * n / 48_000) * scale)
            samples[2 * i + 1] = Int16(sin(2 * .pi * (rightFrequency ?? frequency) * n / 48_000) * scale)
        }
        return samples.withUnsafeBytes { Data($0) }
    }
}

/// Paces the fixture into a sink in real time (30 fps video, 10 ms audio), pts on `DashClock`.
final class MediaFeeder: @unchecked Sendable {
    struct Totals {
        var videoFrames = 0
        var audioPackets = 0
        /// Thread CPU spent inside the sink's send calls.
        var sendCPUNanos: UInt64 = 0
        var videoBytes = 0
    }

    let units: [H264Fixture.AccessUnit]
    private let lock = NSLock()
    private var running = false
    private var thread: Thread?
    private var totalsStorage = Totals()
    private var sentVideoPTS: [UInt64] = []
    private var sentAudioPTS: [UInt64] = []
    private var forceKeyframe = false

    var sendVideo: (EncodedVideoFrame) -> Void = { _ in }
    /// PCM for 10 ms packet n.
    var makeAudio: (Int) -> Data = { SinePCM.packet(index: $0) }
    var sendAudio: (AudioPacket) -> Void = { _ in }

    init(units: [H264Fixture.AccessUnit]) { self.units = units }

    var totals: Totals { lock.withLock { totalsStorage } }
    var videoPTS: [UInt64] { lock.withLock { sentVideoPTS } }
    var audioPTS: [UInt64] { lock.withLock { sentAudioPTS } }

    /// Jump to the next IDR in the fixture (what the engine does on requestKeyframe()).
    func requestKeyframe() { lock.withLock { forceKeyframe = true } }

    func start() {
        lock.withLock { running = true }
        let thread = Thread { [self] in run() }
        thread.qualityOfService = .userInteractive
        thread.name = "MediaFeeder"
        self.thread = thread
        thread.start()
    }

    func stop() {
        lock.withLock { running = false }
        while thread?.isFinished == false { usleep(1_000) }
    }

    private func run() {
        let start = DashClock.nowMicros()
        var videoIndex = 0
        var unitIndex = 0
        var audioIndex = 0
        while lock.withLock({ running }) {
            let now = DashClock.nowMicros()
            let nextVideo = start + UInt64(videoIndex) * 1_000_000 / UInt64(H264Fixture.fps)
            let nextAudio = start + UInt64(audioIndex) * 10_000
            if now >= nextAudio {
                let packet = AudioPacket(pts: nextAudio, data: makeAudio(audioIndex))
                let cpu = Self.threadCPUNanos()
                sendAudio(packet)
                let spent = Self.threadCPUNanos() - cpu
                lock.withLock {
                    totalsStorage.audioPackets += 1
                    totalsStorage.sendCPUNanos += spent
                    sentAudioPTS.append(nextAudio)
                }
                audioIndex += 1
                continue
            }
            if now >= nextVideo {
                if lock.withLock({ forceKeyframe }) {
                    lock.withLock { forceKeyframe = false }
                    repeat { unitIndex = (unitIndex + 1) % units.count } while !units[unitIndex].isKeyframe
                }
                let unit = units[unitIndex]
                let frame = EncodedVideoFrame(pts: nextVideo, isKeyframe: unit.isKeyframe, codec: .h264, data: unit.data)
                let cpu = Self.threadCPUNanos()
                sendVideo(frame)
                let spent = Self.threadCPUNanos() - cpu
                lock.withLock {
                    totalsStorage.videoFrames += 1
                    totalsStorage.videoBytes += unit.data.count
                    totalsStorage.sendCPUNanos += spent
                    sentVideoPTS.append(nextVideo)
                }
                videoIndex += 1
                unitIndex = (unitIndex + 1) % units.count
                continue
            }
            let wait = min(nextVideo, nextAudio) - now
            usleep(useconds_t(min(wait, 2_000)))
        }
    }

    static func threadCPUNanos() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
    }
}

/// Process CPU time (user + system), for "% of one core" over a window.
enum ProcessCPU {
    static func nanos() -> UInt64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func ns(_ t: timeval) -> UInt64 { UInt64(t.tv_sec) * 1_000_000_000 + UInt64(t.tv_usec) * 1_000 }
        return ns(usage.ru_utime) + ns(usage.ru_stime)
    }
}

/// Thread-safe event recorder for RTCPeerEvent streams.
final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RTCPeerEvent] = []
    private let condition = NSCondition()

    func record(_ event: RTCPeerEvent) {
        condition.lock()
        events.append(event)
        condition.broadcast()
        condition.unlock()
    }

    var all: [RTCPeerEvent] {
        condition.lock()
        defer { condition.unlock() }
        return events
    }

    /// Waits until `predicate` holds over the recorded events (or times out).
    @discardableResult
    func wait(timeout: TimeInterval, _ predicate: ([RTCPeerEvent]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !predicate(events) {
            if !condition.wait(until: deadline) { return predicate(events) }
        }
        return true
    }

    var offer: String? { Self.offer(in: all) }
    var keyframeRequests: Int { Self.keyframeRequests(in: all) }
    var connected: Bool { Self.connected(in: all) }

    // Predicates for `wait` (which holds the lock: never call the instance accessors from it).
    static func offer(in events: [RTCPeerEvent]) -> String? {
        for case .localDescription(_, let sdp) in events { return sdp }
        return nil
    }

    static func keyframeRequests(in events: [RTCPeerEvent]) -> Int {
        events.filter { if case .keyframeRequested = $0 { return true } else { return false } }.count
    }

    static func connected(in events: [RTCPeerEvent]) -> Bool {
        events.contains { if case .connected = $0 { return true } else { return false } }
    }
}
