import CDataChannel
import DashcastContracts
import Foundation
import os

/// Makes libdatachannel-backed WebRTC peers (one per car).
public final class DataChannelPeerFactory: RTCPeerFactory {
    public init() {
        LibDataChannel.bootstrap()
    }

    public func makePeer(options: RTCPeerOptions) -> RTCPeerProtocol {
        DataChannelPeer(options: options)
    }
}

public enum RTCPeerError: Error, CustomStringConvertible {
    case alreadyStarted
    case closed
    case library(String, Int32)

    public var description: String {
        switch self {
        case .alreadyStarted: return "RTC peer already started"
        case .closed: return "RTC peer is closed"
        case .library(let call, let code): return "\(call) failed (\(code))"
        }
    }
}

/// One car: the offerer, with a sendonly H.264 track (PT 102, constrained baseline, Annex B in) and a
/// sendonly Opus track (PT 111, PCM in, encoded here). ICE binds to `options.bindAddress` only and
/// has no ICE servers; the car's mDNS-hidden host candidates are reached through the peer-reflexive
/// candidate libjuice learns from the car's own connectivity checks.
///
/// RTP timestamps come from each frame's pts (90 kHz video, 48 kHz audio) on a shared anchor, and the
/// RTCP sender reports map those timestamps back to capture time (patched libdatachannel,
/// `rtcSetTrackSenderReportNtpAnchor`), so the browser lip-syncs on capture time.
///
/// Thread safety: every method may be called from any thread. libdatachannel callbacks only hop onto
/// a private serial queue, which is also where `onEvent` runs.
public final class DataChannelPeer: RTCPeerProtocol {
    public static let videoPayloadType: Int32 = 102
    public static let audioPayloadType: Int32 = 111
    public static let h264Profile = "profile-level-id=42e01f;packetization-mode=1;level-asymmetry-allowed=1"
    public static let opusProfile = "minptime=10;useinbandfec=1;stereo=1"
    static let cname = "dashcast"
    static let streamID = "dashcast"
    /// Packets kept for NACK retransmission (~0.5 s of 720p30 at 6 Mbps).
    static let nackHistory: UInt32 = 512
    /// Re-anchor the SR NTP mapping this often (keeps the patch's signed 32-bit RTP distance small).
    static let ntpReanchorMicros: UInt64 = 60_000_000

    public var onEvent: ((RTCPeerEvent) -> Void)? {
        get { handlerLock.withLock { handler } }
        set { handlerLock.withLock { handler = newValue } }
    }

    public let options: RTCPeerOptions

    private struct State {
        var started = false
        var closed = false
        var pc: Int32 = -1
        var video: Int32 = -1
        var audio: Int32 = -1
        var videoOpen = false
        var audioOpen = false
        var connected = false
        var offerSent = false
        /// Registry token (handed to libdatachannel as the user pointer's bit pattern).
        var token: Int?
    }

    private struct Handles: Sendable {
        var pc: Int32
        var video: Int32
        var audio: Int32
        var token: Int?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let handlerLock = NSLock()
    private var handler: ((RTCPeerEvent) -> Void)?
    private let events = DispatchQueue(label: "online.davidlam.dashcast.rtc.peer", qos: .userInteractive)
    /// Deletes peers whose owner dropped them without close(); the last release can happen on any
    /// thread (even a libdatachannel callback thread), where deleting synchronously isn't safe.
    private static let reaper = DispatchQueue(label: "online.davidlam.dashcast.rtc.reaper", qos: .utility)

    private let videoClock: RTPClock
    private let audioClock: RTPClock
    private let videoSSRC = UInt32.random(in: 1 ... .max)
    private let audioSSRC = UInt32.random(in: 1 ... .max)

    /// Serializes set-timestamp + send per track, and owns the per-track send state.
    private let videoLock = NSLock()
    private var videoLastAnchor: UInt64?
    private let audioLock = NSLock()
    private var audioLastAnchor: UInt64?
    private var opus: OpusEncoder?

    init(options: RTCPeerOptions) {
        self.options = options
        let anchor = DashClock.nowMicros()
        videoClock = RTPClock(clockRate: 90_000, anchorMicros: anchor)
        audioClock = RTPClock(clockRate: 48_000, anchorMicros: anchor)
        LibDataChannel.bootstrap()
    }

    deinit {
        if let handles = detach() {
            Self.reaper.async { Self.teardown(handles) }
        }
    }

    // MARK: - RTCPeerProtocol

    public func start() throws {
        let already = state.withLock { s -> RTCPeerError? in
            if s.closed { return .closed }
            if s.started { return .alreadyStarted }
            s.started = true
            return nil
        }
        if let already { throw already }

        do {
            try build()
        } catch {
            close()
            throw error
        }
    }

    public func setRemoteDescription(type: String, sdp: String) throws {
        let pc = state.withLock { $0.closed ? -1 : $0.pc }
        guard pc >= 0 else { throw RTCPeerError.closed }
        try check("rtcSetRemoteDescription", rtcSetRemoteDescription(pc, sdp, type))
    }

    public func send(video frame: EncodedVideoFrame) {
        guard frame.codec == .h264, !frame.data.isEmpty else { return }
        videoLock.lock()   // held across the send: close() waits for it before deleting the track
        defer { videoLock.unlock() }
        let track = state.withLock { s -> Int32 in s.closed || !s.videoOpen ? -1 : s.video }
        guard track >= 0 else { return }

        let timestamp = videoClock.timestamp(forMicros: frame.pts)
        reanchorIfNeeded(track: track, clock: videoClock, pts: frame.pts, last: &videoLastAnchor)
        rtcSetTrackRtpTimestamp(track, timestamp)
        frame.data.withUnsafeBytes { raw in
            _ = rtcSendMessage(track, raw.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(raw.count))
        }
    }

    public func send(audio packet: AudioPacket) {
        guard options.audio else { return }
        audioLock.lock()
        defer { audioLock.unlock() }
        let track = state.withLock { s -> Int32 in s.closed || !s.audioOpen ? -1 : s.audio }
        guard track >= 0, let opus else { return }
        for encoded in opus.encode(packet) {
            // Decoded sample n is input sample n - lookahead: stamp what the receiver will actually play.
            let playoutPTS = encoded.pts &- opus.lookaheadMicros
            reanchorIfNeeded(track: track, clock: audioClock, pts: playoutPTS, last: &audioLastAnchor)
            rtcSetTrackRtpTimestamp(track, audioClock.timestamp(forMicros: playoutPTS))
            encoded.data.withUnsafeBytes { raw in
                _ = rtcSendMessage(track, raw.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(raw.count))
            }
        }
    }

    /// Idempotent. Never call from a libdatachannel callback (this module never does: its
    /// callbacks only hop onto the event queue, where `onEvent` handlers may call close() freely).
    public func close() {
        guard let handles = detach() else { return }
        handlerLock.withLock { handler = nil }
        // Sends that read the track ids before detach() finish first; later ones see `closed`.
        videoLock.lock(); videoLock.unlock()
        audioLock.lock(); audioLock.unlock()
        Self.teardown(handles)
    }

    /// Marks the peer closed (sends and events stop immediately) and hands back what to delete.
    private func detach() -> Handles? {
        state.withLock { s -> Handles? in
            if s.closed { return nil }
            s.closed = true
            defer {
                s.pc = -1; s.video = -1; s.audio = -1; s.token = nil
                s.videoOpen = false; s.audioOpen = false
            }
            return Handles(pc: s.pc, video: s.video, audio: s.audio, token: s.token)
        }
    }

    private static func teardown(_ handles: Handles) {
        if let token = handles.token, let pointer = UnsafeMutableRawPointer(bitPattern: token) {
            PeerRegistry.shared.unregister(pointer)   // late callbacks now resolve to nothing
        }
        if handles.video >= 0 { rtcDeleteTrack(handles.video) }
        if handles.audio >= 0 { rtcDeleteTrack(handles.audio) }
        if handles.pc >= 0 { rtcDeletePeerConnection(handles.pc) }
    }

    // MARK: - Diagnostics

    /// Selected ICE pair ("local", "remote") once connected, e.g. to confirm a prflx remote.
    public func selectedCandidatePair() -> (local: String, remote: String)? {
        let pc = state.withLock { $0.closed ? -1 : $0.pc }
        guard pc >= 0 else { return nil }
        var local = [CChar](repeating: 0, count: 256)
        var remote = [CChar](repeating: 0, count: 256)
        guard rtcGetSelectedCandidatePair(pc, &local, 256, &remote, 256) >= 0 else { return nil }
        return (String(cString: local), String(cString: remote))
    }

    /// Current local SDP (complete once `.localDescription` was emitted).
    public func localDescription() -> String? {
        let pc = state.withLock { $0.closed ? -1 : $0.pc }
        guard pc >= 0 else { return nil }
        return LibDataChannel.string { rtcGetLocalDescription(pc, $0, $1) }
    }

    // MARK: - Setup

    private func build() throws {
        let pointer = PeerRegistry.shared.register(self)
        let token = Int(bitPattern: pointer)
        let closedMeanwhile = state.withLock { s -> Bool in
            if !s.closed { s.token = token }
            return s.closed
        }
        if closedMeanwhile {
            PeerRegistry.shared.unregister(pointer)
            throw RTCPeerError.closed
        }

        var config = rtcConfiguration()
        config.iceServers = nil
        config.iceServersCount = 0
        config.certificateType = RTC_CERTIFICATE_ECDSA
        config.iceTransportPolicy = RTC_TRANSPORT_POLICY_ALL
        config.enableIceTcp = false
        config.enableIceUdpMux = false
        config.disableAutoNegotiation = true   // the offer is created once, in start()
        config.forceMediaTransport = true
        config.portRangeBegin = options.portRangeBegin
        config.portRangeEnd = options.portRangeEnd
        let pc: Int32 = options.bindAddress.map { address in
            address.withCString { cAddress in
                config.bindAddress = cAddress
                return rtcCreatePeerConnection(&config)
            }
        } ?? rtcCreatePeerConnection(&config)
        try check("rtcCreatePeerConnection", pc)
        let stored = state.withLock { s -> Bool in
            if !s.closed { s.pc = pc }
            return !s.closed
        }
        guard stored else {   // close() raced start(): nobody else will delete it
            rtcDeletePeerConnection(pc)
            throw RTCPeerError.closed
        }

        rtcSetUserPointer(pc, pointer)
        rtcSetStateChangeCallback(pc) { _, newState, token in
            PeerRegistry.shared.peer(token)?.enqueue { $0.handleState(newState) }
        }
        rtcSetGatheringStateChangeCallback(pc) { _, gathering, token in
            guard gathering == RTC_GATHERING_COMPLETE else { return }
            PeerRegistry.shared.peer(token)?.enqueue { $0.emitOffer() }
        }

        let video = try addVideoTrack(pc: pc)
        guard state.withLock({ s -> Bool in
            if !s.closed { s.video = video }
            return !s.closed
        }) else {
            rtcDeleteTrack(video)
            throw RTCPeerError.closed
        }
        if options.audio {
            let encoder = try OpusEncoder()
            audioLock.withLock { opus = encoder }
            let audio = try addAudioTrack(pc: pc)
            guard state.withLock({ s -> Bool in
                if !s.closed { s.audio = audio }
                return !s.closed
            }) else {
                rtcDeleteTrack(audio)
                throw RTCPeerError.closed
            }
        }

        try check("rtcSetLocalDescription", rtcSetLocalDescription(pc, "offer"))
    }

    private func addVideoTrack(pc: Int32) throws -> Int32 {
        let track = try addTrack(pc: pc, codec: RTC_CODEC_H264, payloadType: Self.videoPayloadType,
                                 ssrc: videoSSRC, mid: "video", trackID: "dashcast-video", profile: Self.h264Profile)
        var packetizer = packetizerInit(ssrc: videoSSRC, payloadType: Self.videoPayloadType, clock: videoClock)
        packetizer.nalSeparator = RTC_NAL_SEPARATOR_START_SEQUENCE   // Annex B, 3- or 4-byte start codes
        try Self.cname.withCString { cname in
            packetizer.cname = cname
            try check("rtcSetH264Packetizer", rtcSetH264Packetizer(track, &packetizer))
        }
        try chainSenderReports(track: track, clock: videoClock)
        try check("rtcChainRtcpNackResponder", rtcChainRtcpNackResponder(track, Self.nackHistory))
        try check("rtcChainPliHandler", rtcChainPliHandler(track) { _, token in   // PLI and FIR
            PeerRegistry.shared.peer(token)?.enqueue { $0.emit(.keyframeRequested) }
        })
        try check("rtcChainRembHandler", rtcChainRembHandler(track) { _, bitrate, token in
            PeerRegistry.shared.peer(token)?.enqueue { $0.emit(.bitrateEstimate(kbps: Int(bitrate / 1000))) }
        })
        rtcSetOpenCallback(track) { _, token in
            PeerRegistry.shared.peer(token)?.enqueue { $0.trackOpened(video: true) }
        }
        return track
    }

    private func addAudioTrack(pc: Int32) throws -> Int32 {
        let track = try addTrack(pc: pc, codec: RTC_CODEC_OPUS, payloadType: Self.audioPayloadType,
                                 ssrc: audioSSRC, mid: "audio", trackID: "dashcast-audio", profile: Self.opusProfile)
        var packetizer = packetizerInit(ssrc: audioSSRC, payloadType: Self.audioPayloadType, clock: audioClock)
        try Self.cname.withCString { cname in
            packetizer.cname = cname
            try check("rtcSetOpusPacketizer", rtcSetOpusPacketizer(track, &packetizer))
        }
        try chainSenderReports(track: track, clock: audioClock)
        rtcSetOpenCallback(track) { _, token in
            PeerRegistry.shared.peer(token)?.enqueue { $0.trackOpened(video: false) }
        }
        return track
    }

    private func addTrack(pc: Int32, codec: rtcCodec, payloadType: Int32, ssrc: UInt32, mid: String,
                          trackID: String, profile: String) throws -> Int32 {
        // Same cname + msid stream on both tracks: the browser puts them in one sync group.
        try mid.withCString { cMid in
            try Self.cname.withCString { cName in
                try Self.streamID.withCString { cMsid in
                    try trackID.withCString { cTrackID in
                        try profile.withCString { cProfile in
                            var initInfo = rtcTrackInit(direction: RTC_DIRECTION_SENDONLY, codec: codec,
                                                        payloadType: payloadType, ssrc: ssrc, mid: cMid,
                                                        name: cName, msid: cMsid, trackId: cTrackID, profile: cProfile)
                            let track = rtcAddTrackEx(pc, &initInfo)
                            try check("rtcAddTrackEx(\(mid))", track)
                            return track
                        }
                    }
                }
            }
        }
    }

    private func packetizerInit(ssrc: UInt32, payloadType: Int32, clock: RTPClock) -> rtcPacketizerInit {
        var packetizer = rtcPacketizerInit()
        packetizer.ssrc = ssrc
        packetizer.payloadType = UInt8(payloadType)
        packetizer.clockRate = UInt32(clock.clockRate)
        packetizer.sequenceNumber = UInt16.random(in: 0 ... .max)
        packetizer.timestamp = clock.baseTimestamp
        packetizer.maxFragmentSize = 0   // default: fits the 1280-byte MTU
        return packetizer
    }

    private func chainSenderReports(track: Int32, clock: RTPClock) throws {
        try check("rtcChainRtcpSrReporter", rtcChainRtcpSrReporter(track))
        try check("rtcSetTrackSenderReportNtpAnchor",
                  rtcSetTrackSenderReportNtpAnchor(track, clock.baseTimestamp, NTPClock.ntp(forMicros: clock.anchorMicros)))
    }

    /// Moves the SR anchor to a recent frame now and then so the RTP→NTP distance stays small.
    private func reanchorIfNeeded(track: Int32, clock: RTPClock, pts: UInt64, last: inout UInt64?) {
        if let previous = last, pts >= previous, pts - previous < Self.ntpReanchorMicros { return }
        if last == nil, pts >= clock.anchorMicros, pts - clock.anchorMicros < Self.ntpReanchorMicros {
            last = clock.anchorMicros   // the anchor set at creation still covers this pts
            return
        }
        rtcSetTrackSenderReportNtpAnchor(track, clock.timestamp(forMicros: pts), NTPClock.ntp(forMicros: pts))
        last = pts
    }

    private func check(_ call: String, _ result: Int32) throws {
        if result < 0 {
            RTCLog.peer.warning("\(call, privacy: .public) failed: \(result)")
            throw RTCPeerError.library(call, result)
        }
    }

    // MARK: - Events (serial queue)

    private func enqueue(_ work: @escaping (DataChannelPeer) -> Void) {
        events.async { [self] in
            guard !state.withLock({ $0.closed }) else { return }
            work(self)
        }
    }

    private func emit(_ event: RTCPeerEvent) {
        handlerLock.withLock { handler }?(event)
    }

    private func emitOffer() {
        let pc = state.withLock { s -> Int32 in
            if s.offerSent || s.pc < 0 { return -1 }
            s.offerSent = true
            return s.pc
        }
        guard pc >= 0, let sdp = LibDataChannel.string({ rtcGetLocalDescription(pc, $0, $1) }) else { return }
        let type = LibDataChannel.string { rtcGetLocalDescriptionType(pc, $0, $1) } ?? "offer"
        emit(.localDescription(type: type, sdp: sdp))
    }

    private func handleState(_ newState: rtcState) {
        switch newState {
        case RTC_CONNECTED:
            let first = state.withLock { s -> Bool in
                defer { s.connected = true }
                return !s.connected
            }
            if first { emit(.connected) }
        case RTC_DISCONNECTED:
            state.withLock { $0.connected = false }
            emit(.disconnected)
        case RTC_FAILED:
            state.withLock { $0.connected = false }
            emit(.failed("ICE/DTLS connection failed"))
        case RTC_CLOSED:
            let wasConnected = state.withLock { s -> Bool in
                defer { s.connected = false }
                return s.connected
            }
            if wasConnected { emit(.disconnected) }
        default:
            break
        }
    }

    private func trackOpened(video: Bool) {
        state.withLock {
            if video { $0.videoOpen = true } else { $0.audioOpen = true }
        }
        if video {
            emit(.keyframeRequested)   // the receiver can only start decoding at an IDR
        } else {
            audioLock.withLock { opus?.reset() }
        }
    }
}
