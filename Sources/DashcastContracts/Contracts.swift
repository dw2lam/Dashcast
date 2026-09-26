import CoreGraphics
import CoreMedia
import Foundation
import Observation

// Shared vocabulary between modules. Keep this file the single source of truth;
// wire formats are described in PROTOCOL.md.

// MARK: - Clock

public enum DashClock {
    /// Host-time microseconds. Same base as ScreenCaptureKit sample-buffer PTS
    /// (convert those with `micros(from:)`).
    public static func nowMicros() -> UInt64 {
        micros(from: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    public static func micros(from time: CMTime) -> UInt64 {
        guard time.isValid, time.seconds.isFinite, time.seconds >= 0 else { return 0 }
        return UInt64(time.seconds * 1_000_000)
    }
}

// MARK: - Stream configuration

public enum VideoCodec: String, Codable, Sendable, CaseIterable {
    case h264, hevc, jpeg
}

public enum H264Profile: String, Codable, Sendable, CaseIterable {
    /// Main below 60 fps, High at 60 fps.
    case auto
    /// 42e01f — what browsers' WebRTC stacks always accept.
    case constrainedBaseline
    case main
    case high
}

public enum LatencyMode: String, Codable, Sendable, CaseIterable {
    case auto, interactive, cinema
}

public enum DisplayMode: String, Codable, Sendable, CaseIterable {
    case extend, mirror
}

public enum CarComputer: String, Codable, Sendable {
    case mcu2, mcu3, unknown
}

public struct Tier: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var width: Int
    public var height: Int
    public var fps: Int
    public var codec: VideoCodec
    public var bitrateKbps: Int
    /// WebCodecs codec string sent in `config` (e.g. "avc1.4D4020"); "jpeg" for JPEG.
    public var codecString: String

    public init(id: String, label: String, width: Int, height: Int, fps: Int,
                codec: VideoCodec, bitrateKbps: Int, codecString: String) {
        self.id = id; self.label = label; self.width = width; self.height = height
        self.fps = fps; self.codec = codec; self.bitrateKbps = bitrateKbps; self.codecString = codecString
    }

    /// Nominal presets. Width/height are replaced by the car's measured viewport
    /// (aspect-preserving, capped at these pixel counts) during tier selection.
    public static let mcu2Low = Tier(id: "mcu2-low", label: "MCU2 · Low", width: 960, height: 540, fps: 30,
                                     codec: .jpeg, bitrateKbps: 20_000, codecString: "jpeg")
    public static let mcu2 = Tier(id: "mcu2", label: "MCU2 · 720p30", width: 1280, height: 720, fps: 30,
                                  codec: .h264, bitrateKbps: 6_000, codecString: "avc1.4D401F")
    public static let mcu2High = Tier(id: "mcu2-high", label: "MCU2 · 1080p30", width: 1920, height: 1080, fps: 30,
                                      codec: .h264, bitrateKbps: 8_000, codecString: "avc1.4D4028")
    public static let mcu3 = Tier(id: "mcu3", label: "MCU3 · 60 fps", width: 1920, height: 1200, fps: 60,
                                  codec: .h264, bitrateKbps: 16_000, codecString: "avc1.640032")
    public static let mcu3HEVC = Tier(id: "mcu3-hevc", label: "MCU3 · HEVC 60 fps", width: 1920, height: 1200, fps: 60,
                                      codec: .hevc, bitrateKbps: 12_000, codecString: "hvc1.1.6.L123.B0")

    /// Ordered lowest → highest.
    public static let all: [Tier] = [.mcu2Low, .mcu2, .mcu2High, .mcu3, .mcu3HEVC]
}

public struct DisplayInfo: Identifiable, Hashable, Sendable {
    public var id: CGDirectDisplayID
    public var name: String
    public var width: Int
    public var height: Int
    public var isVirtual: Bool
    public init(id: CGDirectDisplayID, name: String, width: Int, height: Int, isVirtual: Bool) {
        self.id = id; self.name = name; self.width = width; self.height = height; self.isVirtual = isVirtual
    }
}

public struct StreamConfig: Equatable, Sendable {
    public var displayMode: DisplayMode
    /// Mirror mode: display to capture (nil = main display). Ignored for extend.
    public var mirrorDisplayID: CGDirectDisplayID?
    /// Encoded frame size in pixels.
    public var width: Int
    public var height: Int
    /// Extend mode: virtual display size in points (the car's CSS viewport), so UI is the same
    /// physical size as the car's own UI. Encoded size is independent (SCK scales).
    public var displayWidth: Int
    public var displayHeight: Int
    public var fps: Int
    public var codec: VideoCodec
    public var bitrateKbps: Int
    public var captureAudio: Bool
    /// Extend mode: create the virtual display as HiDPI (2x backing) so UI is readable at low encode sizes.
    public var hiDPI: Bool
    public var h264Profile: H264Profile

    public init(displayMode: DisplayMode, mirrorDisplayID: CGDirectDisplayID? = nil, width: Int, height: Int,
                displayWidth: Int? = nil, displayHeight: Int? = nil,
                fps: Int, codec: VideoCodec, bitrateKbps: Int, captureAudio: Bool, hiDPI: Bool = true,
                h264Profile: H264Profile = .auto) {
        self.displayMode = displayMode; self.mirrorDisplayID = mirrorDisplayID; self.width = width
        self.height = height; self.displayWidth = displayWidth ?? width; self.displayHeight = displayHeight ?? height; self.fps = fps; self.codec = codec; self.bitrateKbps = bitrateKbps
        self.captureAudio = captureAudio; self.hiDPI = hiDPI; self.h264Profile = h264Profile
    }
}

// MARK: - Media units

public struct EncodedVideoFrame: Sendable {
    public var pts: UInt64          // server µs (capture time)
    public var isKeyframe: Bool
    public var codec: VideoCodec
    public var data: Data           // Annex B for h264/hevc (parameter sets inline on keyframes); JPEG bytes for jpeg
    public init(pts: UInt64, isKeyframe: Bool, codec: VideoCodec, data: Data) {
        self.pts = pts; self.isKeyframe = isKeyframe; self.codec = codec; self.data = data
    }
}

public struct AudioPacket: Sendable {
    public var pts: UInt64          // server µs of the first sample
    public var data: Data           // interleaved s16le stereo @ 48 kHz
    public init(pts: UInt64, data: Data) { self.pts = pts; self.data = data }
}

// MARK: - Client → server messages (decoded JSON)

public struct ClientCaps: Codable, Sendable, Equatable {
    public struct H264: Codable, Sendable, Equatable { public var high: Bool; public var main: Bool; public var baseline: Bool }
    /// `isSecureContext` on the car (false in HTTP mode).
    public var secure: Bool?
    public var webrtc: Bool?
    public var webcodecs: Bool
    public var h264: H264
    public var hevc: Bool
    public var hwAccel: String?
    public var audioWorklet: Bool
    public var offscreenCanvas: Bool?
    public var webgl: Bool?
}

public struct ClientBench: Codable, Sendable, Equatable {
    public var h264_720p_decodeMs: Double?
    public var h264_1080p_decodeMs: Double?
    public var jpegDecodeMs: Double?
}

public struct Viewport: Codable, Sendable, Equatable {
    public var w: Double
    public var h: Double
    public var dpr: Double
}

public struct ClientHello: Codable, Sendable, Equatable {
    public var version: Int
    public var ua: String
    public var viewport: Viewport
    public var caps: ClientCaps
    public var bench: ClientBench?
}

public struct ClientStats: Codable, Sendable, Equatable {
    public var fps: Double
    public var decodeMs: Double
    public var dropped: Int
    public var queue: Int
    public var latencyMs: Double?
    public var audioBufferMs: Double?
}

public struct InputEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case down, move, up, scroll, rightClick, text, key }
    public var kind: Kind
    public var x: Double          // 0…1 across the streamed frame
    public var y: Double
    public var dx: Double?
    public var dy: Double?
    public var text: String?
    public var key: String?
    public init(kind: Kind, x: Double, y: Double, dx: Double? = nil, dy: Double? = nil, text: String? = nil, key: String? = nil) {
        self.kind = kind; self.x = x; self.y = y; self.dx = dx; self.dy = dy; self.text = text; self.key = key
    }
}

// MARK: - Stream engine (implemented in DashcastStream)

public enum EngineEvent: Sendable {
    case started(capturedDisplayID: CGDirectDisplayID)
    case stopped
    case error(String)
    /// Screen Recording / Accessibility not granted.
    case permissionMissing(String)
}

public protocol StreamEngineProtocol: AnyObject {
    /// Called on an engine-owned queue. Must return quickly.
    var onVideo: ((EncodedVideoFrame) -> Void)? { get set }
    var onAudio: ((AudioPacket) -> Void)? { get set }
    var onEvent: ((EngineEvent) -> Void)? { get set }

    func start(_ config: StreamConfig) async throws
    /// Apply a new config; cheap changes (bitrate) in place, others restart the pipeline.
    func update(_ config: StreamConfig) async throws
    func stop() async
    func requestKeyframe()
    func setBitrate(kbps: Int)
    /// Inject a touch/pointer event onto the captured display.
    func inject(_ event: InputEvent)

    func availableDisplays() -> [DisplayInfo]
    func hasScreenRecordingPermission() -> Bool
    func requestScreenRecordingPermission()
    func hasAccessibilityPermission() -> Bool
    func requestAccessibilityPermission()
}

// MARK: - WebRTC (implemented in DashcastRTC)

/// How media reaches the car. Chosen per session by the server from the client's hello.
public enum MediaTransport: String, Codable, Sendable {
    /// Binary WebSocket frames → WebCodecs (needs a secure context, i.e. HTTPS mode).
    case websocket = "ws"
    /// RTP over WebRTC (works on plain HTTP; the browser's <video> does decode + A/V sync).
    case webrtc
}

public enum RTCPeerEvent: Sendable {
    /// Complete local SDP (ICE gathering finished, no trickle). Send to the car as `rtcOffer`.
    case localDescription(type: String, sdp: String)
    case connected
    case disconnected
    case failed(String)
    /// PLI/FIR from the browser → engine.requestKeyframe().
    case keyframeRequested
    /// Receiver bandwidth estimate (REMB) when available.
    case bitrateEstimate(kbps: Int)
}

public struct RTCPeerOptions: Sendable {
    /// Local address ICE binds to. Must be serviceAddress: the car's browser rejects private-IP candidates.
    public var bindAddress: String?
    public var portRangeBegin: UInt16
    public var portRangeEnd: UInt16
    public var audio: Bool
    public init(bindAddress: String?, portRangeBegin: UInt16 = 50_000, portRangeEnd: UInt16 = 50_100, audio: Bool) {
        self.bindAddress = bindAddress; self.portRangeBegin = portRangeBegin; self.portRangeEnd = portRangeEnd; self.audio = audio
    }
}

/// One WebRTC peer = one car. Server offers (sendonly H.264 video + Opus audio), car answers.
public protocol RTCPeerProtocol: AnyObject {
    /// Called on a library-owned thread.
    var onEvent: ((RTCPeerEvent) -> Void)? { get set }
    /// Builds tracks and starts gathering; emits `.localDescription` once.
    func start() throws
    func setRemoteDescription(type: String, sdp: String) throws
    /// H.264 Annex B access unit (constrained baseline).
    func send(video frame: EncodedVideoFrame)
    /// PCM s16le stereo 48 kHz (10 ms packets); encoded to Opus internally.
    func send(audio packet: AudioPacket)
    func close()
}

public protocol RTCPeerFactory: AnyObject {
    func makePeer(options: RTCPeerOptions) -> RTCPeerProtocol
}

// MARK: - Network (implemented in DashcastNetwork)

public enum Topology: String, Codable, Sendable {
    /// Mac is the hotspot (Internet Sharing, bridge100).
    case macHotspot
    /// Mac joined a router/LAN (travel router).
    case router
    /// Mac joined a phone hotspot (172.20.10.x) — car can't reach the Mac this way.
    case phoneHotspot
    case offline
}

public struct NetworkStatus: Equatable, Sendable {
    public var topology: Topology = .offline
    public var interfaceName: String?
    public var macLANAddress: String?
    /// serviceAddress present on lo0.
    public var aliasActive: Bool = false
    public var helperInstalled: Bool = false
    /// The user's own domain (Secure mode). nil = Compatibility mode only.
    public var domain: OwnDomain?
    public var hasCloudflareToken: Bool = false
    /// The own domain resolves to the service address in public DNS (false without a domain).
    public var dnsRecordOK: Bool = false
    public var certificateExpiry: Date?
    public var internetReachable: Bool = false
    /// Set when some interface's subnet contains serviceAddress (e.g. SideDisplay's 203.0.113.0/24 sharing).
    public var serviceAddressConflict: String?
    public var summary: String = ""
    public init() {}
}

public struct TLSMaterial: Sendable {
    public var pkcs12URL: URL
    public var passphrase: String
    /// The name the certificate serves (the own domain's hostname).
    public var hostname: String
    public init(pkcs12URL: URL, passphrase: String, hostname: String) {
        self.pkcs12URL = pkcs12URL; self.passphrase = passphrase; self.hostname = hostname
    }
}

/// A name on a domain the user owns, pointed at the service address. It unlocks Secure mode
/// (HTTPS, so WebCodecs); without one the car uses `http://<serviceAddress>` and WebRTC.
public struct OwnDomain: Equatable, Sendable {
    public enum Provider: String, Codable, Sendable, CaseIterable {
        /// Dashcast publishes the A record and gets a Let's Encrypt certificate (DNS-01) itself.
        case cloudflare
        /// The user adds the A record and imports a certificate.
        case manual
    }

    public var hostname: String
    public var provider: Provider

    public init(hostname: String, provider: Provider) {
        self.hostname = hostname; self.provider = provider
    }

    public struct InvalidHostname: LocalizedError, Equatable, Sendable {
        public var reason: String
        public var errorDescription: String? { reason }
    }

    /// What the user typed → a lowercase FQDN ("https://Car.Example.com/" → "car.example.com"),
    /// or why it can't be one.
    public static func normalize(_ raw: String) -> Result<String, InvalidHostname> {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where name.hasPrefix(scheme) {
            name.removeFirst(scheme.count)
        }
        while name.hasSuffix("/") { name.removeLast() }
        if name.hasSuffix(".") { name.removeLast() }
        func invalid(_ reason: String) -> Result<String, InvalidHostname> { .failure(InvalidHostname(reason: reason)) }

        guard !name.isEmpty else { return invalid("Enter a hostname, like car.yourdomain.com.") }
        guard name.unicodeScalars.allSatisfy(\.isASCII) else {
            return invalid("Use the ASCII (xn--) form of an international name.")
        }
        guard !name.contains("/"), !name.contains(":"), !name.contains("@"), !name.contains(" ") else {
            return invalid("Enter just the hostname, like car.yourdomain.com.")
        }
        guard name.count <= 253 else { return invalid("That name is too long.") }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return invalid("Use a full name on your domain, like car.yourdomain.com.") }
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return invalid("“\(name)” has an empty or overlong part.") }
            guard label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }), label.first != "-", label.last != "-" else {
                return invalid("Only letters, digits and hyphens (not at either end of a part).")
            }
        }
        guard !labels.last!.allSatisfy(\.isNumber) else { return invalid("That’s an IP address; enter a hostname.") }
        return .success(name)
    }
}

/// A certificate for the own domain obtained elsewhere (DNS providers Dashcast can't automate).
public enum CertificateImport: Sendable {
    case pkcs12(Data, passphrase: String)
    /// PEM leaf (optionally followed by its chain) and its private key.
    case pem(certificate: Data, key: Data)
}

public enum DashcastDefaults {
    public static let serviceAddress = "203.0.113.77"
    public static let tlsPort: UInt16 = 443
    public static let devPort: UInt16 = 8080
    public static let appSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Dashcast", isDirectory: true)
    }()
}

@MainActor
public protocol NetworkManaging: AnyObject {
    func currentStatus() async -> NetworkStatus
    /// Installs a root LaunchDaemon (admin prompt) that keeps `lo0 alias <serviceAddress>/32` up.
    func installLoopbackHelper() async throws
    func uninstallLoopbackHelper() async throws
    /// Sets the own domain (nil removes it). Throws for a hostname that isn't a usable FQDN.
    func setOwnDomain(_ domain: OwnDomain?) throws
    func setCloudflareToken(_ token: String) throws
    func hasCloudflareToken() -> Bool
    /// Cloudflare domains: ensures the DNS A record and a valid Let's Encrypt certificate (DNS-01). Needs internet.
    func provisionCertificate() async throws
    /// Installs a certificate for the own domain from elsewhere. It must cover the hostname.
    func importCertificate(_ certificate: CertificateImport) async throws
    func tlsMaterial() -> TLSMaterial?
    /// OpenWrt/GL.iNet commands for topology B.
    func routerSetupScript(macLANAddress: String) -> String
    /// Local DNS responder on serviceAddress:53 (the own domain if set, Tesla/Apple connectivity-check
    /// names), so the car link works with no internet and no public DNS record.
    func startLocalServices() async
    func stopLocalServices() async
    /// Whether `address` (a car that just dropped) is still on this Mac's link, judged from the ARP
    /// table. nil = can't tell.
    func isStillOnNetwork(_ address: String) async -> Bool?
}

public extension NetworkManaging {
    func startLocalServices() async {}
    func stopLocalServices() async {}
    func isStillOnNetwork(_ address: String) async -> Bool? { nil }
}

// MARK: - Service (implemented in DashcastServer, observed by the UI)

public struct ConnectedCar: Equatable, Sendable {
    public var computer: CarComputer
    public var userAgent: String
    public var viewport: Viewport
    public var tier: Tier
    public var connectedAt: Date
    public var transport: MediaTransport
    public init(computer: CarComputer, userAgent: String, viewport: Viewport, tier: Tier, connectedAt: Date,
                transport: MediaTransport = .websocket) {
        self.computer = computer; self.userAgent = userAgent; self.viewport = viewport; self.tier = tier
        self.connectedAt = connectedAt; self.transport = transport
    }
}

public struct LiveStats: Equatable, Sendable {
    public var fps: Double = 0
    public var bitrateKbps: Double = 0
    public var latencyMs: Double?
    public var decodeMs: Double?
    public var rttMs: Double?
    public var dropped: Int = 0
    public var effectiveLatencyMode: LatencyMode = .interactive
    public init() {}
}

public enum ServicePhase: Equatable, Sendable {
    case idle
    case waitingForCar
    case streaming
    case error(String)
}

/// Why the car went away, as well as the Mac can tell.
public enum DisconnectReason: String, Sendable, CaseIterable {
    /// The socket dropped and the car is no longer on the Mac's link.
    case leftWiFi
    /// The car's browser closed the connection cleanly (tab closed, page left, browser quit).
    case browserClosed
    /// A timeout or error with the car (possibly) still around.
    case connectionLost
}

public struct CarDisconnect: Equatable, Sendable {
    public var reason: DisconnectReason
    public var date: Date
    public init(reason: DisconnectReason, date: Date) { self.reason = reason; self.date = date }
}

/// Whether this Mac can currently show the car anything. Sent to the car as `{"t":"host"}`.
public enum HostState: String, Codable, Sendable, CaseIterable {
    case active
    case locked
    case displayAsleep
    /// The whole Mac is about to sleep (sent from willSleep, before the network goes away).
    case sleeping

    /// The most important condition wins: asleep beats locked beats a dark display.
    public static func resolve(systemSleeping: Bool, locked: Bool, displayAsleep: Bool) -> HostState {
        if systemSleeping { return .sleeping }
        if locked { return .locked }
        if displayAsleep { return .displayAsleep }
        return .active
    }
}

public struct LogLine: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var date: Date
    public var message: String
    public init(_ message: String, date: Date = Date()) { self.message = message; self.date = date }
}

/// Observable state the UI renders. Mutated only by the service on the main actor.
@MainActor
@Observable
public final class ServiceState {
    public var phase: ServicePhase = .idle
    public var car: ConnectedCar?
    public var stats = LiveStats()
    public var network = NetworkStatus()
    public var screenRecordingGranted = false
    public var accessibilityGranted = false
    public var displays: [DisplayInfo] = []
    public var log: [LogLine] = []
    /// The last car disconnect, until a car connects again or casting stops.
    public var lastDisconnect: CarDisconnect?
    /// Locked, display asleep or sleeping: the car sees a "paused" message.
    public var hostState: HostState = .active

    /// URL the car should open: the own domain once it has a valid certificate, else the service address.
    public var carURL: String {
        if let hostname = network.domain?.hostname, let expiry = network.certificateExpiry, expiry > Date() {
            return "https://\(hostname)"
        }
        return "http://\(DashcastDefaults.serviceAddress)"
    }
    /// Local preview URL (plain HTTP on localhost is a secure context).
    public var localURL: String { "http://localhost:\(DashcastDefaults.devPort)" }

    public init() {}

    public func append(_ message: String) {
        log.append(LogLine(message))
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }
}

/// User settings. Persisted by the UI layer (UserDefaults); the service reads them on start/apply.
public struct ServiceSettings: Equatable, Sendable {
    public var displayMode: DisplayMode = .extend
    public var mirrorDisplayID: CGDirectDisplayID?
    public var latencyMode: LatencyMode = .auto
    /// nil = automatic tier selection.
    public var tierOverrideID: String?
    public var audioEnabled = true
    public var inputEnabled = true
    public var hiDPI = true
    /// Hold off display sleep while a car is connected (lid close and locking still pause).
    public var keepDisplayAwake = true
    public init() {}
}

@MainActor
public protocol DashcastServicing: AnyObject {
    var state: ServiceState { get }
    var settings: ServiceSettings { get set }
    /// Start listening (dev port always; TLS port when material + alias exist). Streaming begins when a car says hello.
    func start() async
    func stop() async
    /// Re-apply `settings` to the live session.
    func applySettings() async
    func refreshNetwork() async
    func refreshPermissions()
    func requestScreenRecording()
    func requestAccessibility()
    /// Tells the car (and `state.hostState`) the Mac locked, slept or woke. For `.sleeping` it
    /// returns once the message is on the wire (or after a short timeout), so the caller can let
    /// the system sleep only then.
    func setHostState(_ hostState: HostState)
    var network: NetworkManaging { get }
}
