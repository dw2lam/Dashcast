import DashcastContracts
import Foundation

/// Per-car session logic on the server queue: hello/replacement, media routing (WebSocket frames with
/// send-side dropping, or a WebRTC peer), congestion control, latency-mode policy, tier adaptation,
/// pings and stats.
///
/// Everything here runs on `queue`. Engine and peer callbacks are hopped onto it; events for the
/// service are delivered on the main queue via `onEvent`. The engine's cheap synchronous calls
/// (`requestKeyframe`, `setBitrate`, `inject`) and the peer's `send`/`setRemoteDescription`/`close`
/// are made from `queue`.
final class SessionHub: WebSocketDelegate, @unchecked Sendable {   // state confined to `queue`
    /// How the car reached us, for transport selection and WebRTC binding.
    struct HelloContext: Equatable {
        var transportCaps: TransportCaps
        /// Secure context implied by the listener (TLS or localhost), when the hello doesn't say.
        var secureFallback: Bool
        /// Address of the listener the car connected to.
        var localHost: String
    }

    enum Event {
        case hello(sessionID: UInt64, hello: ClientHello, context: HelloContext)
        case disconnected(sessionID: UInt64, reason: String)
        case tierChange(sessionID: UInt64, tier: Tier, reason: String)
        case stats(LiveStats)
        case log(String)
    }

    /// What the service decided for a session.
    struct Params: Equatable {
        var transport: MediaTransport
        var decision: TierDecision
        var tier: Tier
        var codecString: String
        var width: Int
        var height: Int
        var latencySetting: LatencyMode
        var audioEnabled: Bool
        var inputEnabled: Bool
        /// WebRTC only: ICE bind address.
        var rtcBindAddress: String?
    }

    let queue: DispatchQueue
    private let engine: StreamEngineProtocol
    private let rtcFactory: RTCPeerFactory?
    /// Delivered on the main queue.
    var onEvent: ((Event) -> Void)?

    /// More video frames than this queued on the socket → drop to the next keyframe.
    var maxVideoFramesInFlight = 2
    var helloTimeout: TimeInterval = 10
    /// No message (ping/ack/stats/pong) for this long → the car is gone.
    var livenessTimeout: TimeInterval = 10

    private var waiting: [UInt64: (connection: ServerConnection, openedAt: TimeInterval)] = [:]
    private var session: CarSession?
    private var timer: DispatchSourceTimer?
    private var tickCount = 0
    private var postedIdleStats = false

    private var latencySetting: LatencyMode = .auto
    private var inputEnabled = true

    init(queue: DispatchQueue, engine: StreamEngineProtocol, rtcFactory: RTCPeerFactory?) {
        self.queue = queue
        self.engine = engine
        self.rtcFactory = rtcFactory
    }

    static func now() -> TimeInterval { Double(DashClock.nowMicros()) / 1_000_000 }

    private func post(_ event: Event) {
        let handler = onEvent
        DispatchQueue.main.async { handler?(event) }
    }

    // MARK: Service → hub (thread-safe entry points)

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(20))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    /// Says `bye` to the car, closes every WebSocket (and peer) and stops the timer.
    func shutdown(reason: String, completion: (() -> Void)? = nil) {
        queue.async { [self] in
            if let s = session { end(s, bye: reason, code: WebSocketCloseCode.goingAway) }
            for entry in waiting.values { entry.connection.close(code: WebSocketCloseCode.goingAway, reason: reason) }
            waiting.removeAll()
            timer?.cancel()
            timer = nil
            postedIdleStats = false
            completion?()
        }
    }

    func updateSettings(latencyMode: LatencyMode, inputEnabled: Bool) {
        queue.async { [self] in
            latencySetting = latencyMode
            self.inputEnabled = inputEnabled
            guard let s = session, s.latencyOverride == nil else { return }
            if let change = s.latency.setSetting(latencyMode, now: Self.now()), s.configured { sendMode(change, to: s) }
        }
    }

    /// Stop forwarding video for this session until `activate` sends the new config.
    func beginReconfigure(sessionID: UInt64) {
        queue.async { [self] in
            guard let s = session, s.id == sessionID else { return }
            s.reconfiguring = true
        }
    }

    /// Applies the service's decision: sends `config` when the client needs one, then waits for a
    /// keyframe; for WebRTC, creates the peer (its offer follows the config).
    func activate(sessionID: UInt64, params: Params, forceConfig: Bool) {
        queue.async { [self] in
            guard let s = session, s.id == sessionID else { return }
            let now = Self.now()
            let old = s.params
            s.params = params
            s.reconfiguring = false
            s.tierChangePending = false

            if let cc = s.congestion {
                if old?.tier.bitrateKbps != params.tier.bitrateKbps { cc.setMaxKbps(params.tier.bitrateKbps) }
            } else {
                s.congestion = CongestionController(maxKbps: params.tier.bitrateKbps)
            }
            let ceiling = params.decision.isOverride ? params.tier : params.decision.autoTier
            if s.adapter == nil {
                s.adapter = TierAdapter(ladder: params.decision.ladder, current: params.tier, ceiling: ceiling,
                                        allowStepUp: !params.decision.isOverride, now: now)
            } else if old?.tier != params.tier || old?.decision != params.decision {
                s.adapter?.reset(current: params.tier, ceiling: ceiling, allowStepUp: !params.decision.isOverride, now: now)
            }
            if s.latencyOverride == nil, let change = s.latency.setSetting(params.latencySetting, now: now), s.configured {
                sendMode(change, to: s)
            }

            let needsConfig = forceConfig || !s.configured || old.map {
                $0.tier != params.tier || $0.width != params.width || $0.height != params.height
                    || $0.audioEnabled != params.audioEnabled || $0.inputEnabled != params.inputEnabled
                    || $0.transport != params.transport
            } ?? true
            guard needsConfig else { return }

            let bitrate = params.transport == .websocket ? (s.congestion?.currentKbps ?? params.tier.bitrateKbps)
                                                         : (s.rtcBitrateKbps ?? params.tier.bitrateKbps)
            s.connection.sendText(ServerMessage.config(.init(
                transport: params.transport, codecString: params.codecString,
                width: params.width, height: params.height, fps: params.tier.fps,
                bitrateKbps: bitrate, tierID: params.tier.id, latencyMode: s.latency.effective,
                audio: params.audioEnabled, inputEnabled: params.inputEnabled, serverTime: DashClock.nowMicros())))
            s.configured = true
            s.awaitingKeyframe = true
            requestKeyframe(s, force: true)
            // The engine was (re)started at the tier's nominal bitrate.
            if bitrate != params.tier.bitrateKbps { engine.setBitrate(kbps: bitrate) }

            if params.transport == .webrtc, s.peer == nil { startPeer(for: s, params: params) }
            if params.transport == .websocket, let peer = s.peer { peer.close(); s.peer = nil }
        }
    }

    /// Ends a session the service can't serve (e.g. the engine failed to start).
    func abort(sessionID: UInt64, reason: String) {
        queue.async { [self] in
            guard let s = session, s.id == sessionID else { return }
            end(s, bye: reason, code: WebSocketCloseCode.internalError)
        }
    }

    /// Tears down a session: optional `bye`, close the socket and the peer. The service is not told
    /// (callers that need it post `.disconnected` themselves).
    private func end(_ s: CarSession, bye: String?, code: UInt16) {
        if let bye { s.connection.sendText(ServerMessage.bye(bye)) }
        s.connection.close(code: code, reason: bye ?? "")
        s.peer?.close()
        s.peer = nil
        if session === s { session = nil }
    }

    // MARK: WebRTC

    private func startPeer(for s: CarSession, params: Params) {
        guard let factory = rtcFactory else {
            post(.log("WebRTC requested but no peer factory is available"))
            end(s, bye: "error", code: WebSocketCloseCode.internalError)
            post(.disconnected(sessionID: s.id, reason: "no WebRTC"))
            return
        }
        let peer = factory.makePeer(options: RTCPeerOptions(bindAddress: params.rtcBindAddress, audio: params.audioEnabled))
        let id = s.id
        peer.onEvent = { [weak self] event in
            self?.queue.async { self?.handlePeerEvent(event, sessionID: id) }
        }
        s.peer = peer
        s.peerHasAudio = params.audioEnabled
        do {
            try peer.start()
        } catch {
            post(.log("WebRTC peer failed to start: \(error)"))
            end(s, bye: "error", code: WebSocketCloseCode.internalError)
            post(.disconnected(sessionID: id, reason: "WebRTC failed to start"))
        }
    }

    private func handlePeerEvent(_ event: RTCPeerEvent, sessionID: UInt64) {
        guard let s = session, s.id == sessionID, s.peer != nil else { return }
        switch event {
        case .localDescription(_, let sdp):
            s.connection.sendText(ServerMessage.rtcOffer(sdp: sdp))
        case .connected:
            post(.log("WebRTC connected"))
            requestKeyframe(s, force: true)
        case .disconnected:
            post(.log("WebRTC disconnected"))
        case .failed(let why):
            post(.log("WebRTC failed: \(why)"))
            end(s, bye: "rtc-failed", code: WebSocketCloseCode.internalError)
            post(.disconnected(sessionID: sessionID, reason: "WebRTC failed"))
        case .keyframeRequested:
            requestKeyframe(s, force: false)
        case .bitrateEstimate(let kbps):
            guard let tier = s.params?.tier else { return }
            let clamped = min(tier.bitrateKbps, max(tier.bitrateKbps / 4, kbps))
            let last = s.rtcBitrateKbps ?? tier.bitrateKbps
            guard abs(clamped - last) >= max(50, last / 50) else { return }
            s.rtcBitrateKbps = clamped
            engine.setBitrate(kbps: clamped)
        }
    }

    // MARK: Media (engine queues → server queue)

    func ingestVideo(_ frame: EncodedVideoFrame) {
        queue.async { [weak self] in self?.sendVideo(frame) }
    }

    func ingestAudio(_ packet: AudioPacket) {
        queue.async { [weak self] in self?.sendAudio(packet) }
    }

    private func sendVideo(_ frame: EncodedVideoFrame) {
        guard let s = session, s.configured, !s.reconfiguring, let p = s.params else { return }
        guard frame.codec == p.tier.codec else { return }   // stale frame from before a codec switch

        if p.transport == .webrtc {
            guard let peer = s.peer else { return }
            peer.send(video: frame)   // RTP pacing/loss handling is the peer's job
            s.framesSinceSnapshot += 1
            s.bytesSinceSnapshot += frame.data.count
            return
        }

        let isKey = frame.isKeyframe || frame.codec == .jpeg
        let congested = s.connection.pendingVideoFrames > maxVideoFramesInFlight
        if s.awaitingKeyframe {
            guard isKey, !congested else {
                s.serverDropped += 1
                if !congested { requestKeyframe(s, force: false) }   // else: asked for on drain
                return
            }
            s.awaitingKeyframe = false
        } else if congested {
            // Socket backed up: drop from here to the next keyframe, which we ask for once it drains.
            s.serverDropped += 1
            s.awaitingKeyframe = true
            return
        }

        let seq = s.videoSeq
        let header = MediaHeader.video(frame, seq: seq).encoded()
        s.connection.sendBinary(prefix: header, payload: frame.data, kind: .video)
        s.sent.record(seq: seq, pts: frame.pts)
        s.videoSeq &+= 1
        s.framesSinceSnapshot += 1
        s.bytesSinceSnapshot += header.count + frame.data.count
    }

    private func sendAudio(_ packet: AudioPacket) {
        guard let s = session, s.configured, let p = s.params, p.audioEnabled else { return }
        if p.transport == .webrtc {
            guard let peer = s.peer, s.peerHasAudio else { return }
            peer.send(audio: packet)
        } else {
            let header = MediaHeader.audio(packet, seq: s.audioSeq).encoded()
            s.connection.sendBinary(prefix: header, payload: packet.data, kind: .audio)   // audio is never dropped
            s.audioSeq &+= 1
            s.bytesSinceSnapshot += header.count
        }
        s.bytesSinceSnapshot += packet.data.count
        s.latency.noteAudio(audible: AudioLevel.rms(s16le: packet.data) > AudioLevel.silenceThreshold, now: Self.now())
    }

    private func requestKeyframe(_ s: CarSession, force: Bool) {
        let now = Self.now()
        guard force || now - s.lastKeyframeRequestAt >= 0.25 else { return }
        s.lastKeyframeRequestAt = now
        engine.requestKeyframe()
    }

    private func sendMode(_ mode: LatencyMode, to s: CarSession) {
        s.connection.sendText(ServerMessage.mode(mode))
    }

    // MARK: WebSocketDelegate

    func webSocketDidOpen(_ connection: ServerConnection) {
        waiting[connection.id] = (connection, Self.now())
    }

    func webSocket(_ connection: ServerConnection, didReceiveText text: String) {
        let now = Self.now()
        let active = session.flatMap { $0.connection === connection ? $0 : nil }
        active?.lastInboundAt = now
        guard let message = ClientMessage.parse(text) else { return }

        switch message {
        case .hello(let hello, let transportCaps):
            if let old = session {
                if old.connection === connection {
                    // Same socket said hello again (client restart): fresh session state, keep the socket.
                    old.peer?.close()
                    old.peer = nil
                    session = nil
                } else {
                    end(old, bye: "replaced", code: WebSocketCloseCode.normal)
                }
            }
            waiting[connection.id] = nil
            session = CarSession(connection: connection, hello: hello,
                                 latency: LatencyModePolicy(setting: latencySetting), now: now)
            postedIdleStats = false
            let context = HelloContext(transportCaps: transportCaps, secureFallback: connection.impliesSecureContext,
                                       localHost: connection.localHost)
            post(.hello(sessionID: connection.id, hello: hello, context: context))
            return
        case .ping(let id, let clientTime):
            connection.sendText(ServerMessage.pong(id: id, clientTime: clientTime, serverTime: DashClock.nowMicros()))
            return
        default:
            break
        }

        guard let s = active else { return }   // pending or replaced sockets only get hello/ping
        switch message {
        case .ack(let ack):
            guard s.params?.transport == .websocket, let pts = s.sent.pts(for: ack.seq), let cc = s.congestion else { return }
            if let kbps = cc.onAck(ptsMicros: pts, recvAtMicros: ack.recvAt, now: now) { engine.setBitrate(kbps: kbps) }
        case .stats(let stats):
            s.clientStats = stats
            s.totalDropped += max(0, stats.dropped)
            guard s.configured, !s.reconfiguring, !s.tierChangePending, var adapter = s.adapter else { return }
            let decision = adapter.observe(stats, now: now)
            s.adapter = adapter
            switch decision {
            case .stepDown(let tier, let reason), .stepUp(let tier, let reason):
                s.tierChangePending = true
                post(.tierChange(sessionID: s.id, tier: tier, reason: reason))
            case nil:
                break
            }
        case .input(let event):
            if let change = s.latency.noteInput(now: now) { sendMode(change, to: s) }
            guard inputEnabled, s.params?.inputEnabled ?? inputEnabled else { return }
            engine.inject(event)
        case .keyframe:
            s.awaitingKeyframe = true
            requestKeyframe(s, force: true)
        case .setLatencyMode(let mode):
            s.latencyOverride = mode
            if let change = s.latency.setSetting(mode, now: now), s.configured { sendMode(change, to: s) }
        case .rtcAnswer(let type, let sdp):
            guard let peer = s.peer else { return }
            do {
                try peer.setRemoteDescription(type: type, sdp: sdp)
            } catch {
                post(.log("WebRTC answer rejected: \(error)"))
                end(s, bye: "rtc-failed", code: WebSocketCloseCode.internalError)
                post(.disconnected(sessionID: s.id, reason: "WebRTC answer rejected"))
            }
        case .hello, .ping, .unknown:
            break
        }
    }

    func webSocket(_ connection: ServerConnection, didReceivePong payload: Data) {
        guard let s = session, s.connection === connection else { return }
        let now = Self.now()
        s.lastInboundAt = now
        guard payload.count == 8 else { return }
        let sent = payload.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let nowMicros = DashClock.nowMicros()
        guard nowMicros >= sent else { return }
        let rtt = Double(nowMicros - sent) / 1000
        s.rttMs = s.rttMs.map { 0.75 * $0 + 0.25 * rtt } ?? rtt
    }

    func webSocketDidDrain(_ connection: ServerConnection) {
        guard let s = session, s.connection === connection, s.awaitingKeyframe, s.configured,
              connection.pendingVideoFrames <= maxVideoFramesInFlight else { return }
        requestKeyframe(s, force: false)
    }

    func webSocketDidClose(_ connection: ServerConnection, reason: String) {
        waiting[connection.id] = nil
        guard let s = session, s.connection === connection else { return }
        end(s, bye: nil, code: WebSocketCloseCode.normal)   // closes the peer
        post(.disconnected(sessionID: s.id, reason: reason))
    }

    // MARK: Timer

    private func tick() {
        tickCount &+= 1
        let now = Self.now()
        for (id, entry) in waiting where now - entry.openedAt > helloTimeout {
            waiting[id] = nil
            entry.connection.close(code: WebSocketCloseCode.policyViolation, reason: "no hello")
        }

        guard let s = session else {
            if !postedIdleStats { postedIdleStats = true; post(.stats(LiveStats())) }
            return
        }
        if now - s.lastInboundAt > livenessTimeout {
            end(s, bye: nil, code: WebSocketCloseCode.goingAway)
            post(.disconnected(sessionID: s.id, reason: "car stopped responding"))
            return
        }
        if s.configured, let change = s.latency.evaluate(now: now) { sendMode(change, to: s) }
        if now - s.lastPingAt >= 1 {
            s.lastPingAt = now
            var stamp = DashClock.nowMicros().bigEndian
            s.connection.sendPing(Data(bytes: &stamp, count: 8))
        }
        if tickCount % 2 == 0 { post(.stats(snapshot(s, now: now))) }
    }

    private func snapshot(_ s: CarSession, now: TimeInterval) -> LiveStats {
        let dt = now - s.snapshotAt
        if dt > 0.05 {
            let fps = Double(s.framesSinceSnapshot) / dt
            let kbps = Double(s.bytesSinceSnapshot) * 8 / 1000 / dt
            s.fps = s.hasRates ? 0.5 * s.fps + 0.5 * fps : fps
            s.kbps = s.hasRates ? 0.5 * s.kbps + 0.5 * kbps : kbps
            s.hasRates = true
            s.framesSinceSnapshot = 0
            s.bytesSinceSnapshot = 0
            s.snapshotAt = now
        }
        // Rounded so the UI only re-renders when something visibly changed.
        var stats = LiveStats()
        stats.fps = (s.fps * 10).rounded() / 10
        stats.bitrateKbps = s.kbps.rounded()
        stats.latencyMs = s.clientStats?.latencyMs.map { $0.rounded() }
        stats.decodeMs = s.clientStats.map { ($0.decodeMs * 10).rounded() / 10 }
        stats.rttMs = s.rttMs.map { ($0 * 10).rounded() / 10 }
        stats.dropped = s.totalDropped
        stats.effectiveLatencyMode = s.latency.effective
        return stats
    }

    // MARK: Test hooks

    struct DebugSnapshot {
        var sessionID: UInt64?
        var transport: MediaTransport?
        var bitrateKbps: Int?
        var latency: LatencyMode?
        var serverDropped: Int
        var hasPeer: Bool
    }

    func debugSnapshot() -> DebugSnapshot {
        queue.sync {
            let s = session
            let bitrate = s?.params?.transport == .webrtc ? (s?.rtcBitrateKbps ?? s?.params?.tier.bitrateKbps) : s?.congestion?.currentKbps
            return DebugSnapshot(sessionID: s?.id, transport: s?.params?.transport, bitrateKbps: bitrate,
                                 latency: s?.latency.effective, serverDropped: s?.serverDropped ?? 0, hasPeer: s?.peer != nil)
        }
    }
}

/// State of the one active car. Lives on the hub's queue.
final class CarSession {
    let id: UInt64
    let connection: ServerConnection
    let hello: ClientHello
    var params: SessionHub.Params?
    var configured = false
    var reconfiguring = false
    var tierChangePending = false
    var awaitingKeyframe = true
    var lastKeyframeRequestAt: TimeInterval = -1
    var videoSeq: UInt32 = 0
    var audioSeq: UInt32 = 0
    var congestion: CongestionController?
    var adapter: TierAdapter?
    var latency: LatencyModePolicy
    var latencyOverride: LatencyMode?
    var sent = SentFrameLog()
    var clientStats: ClientStats?
    /// Sum of the per-interval `dropped` counts since the session started.
    var totalDropped = 0
    var rttMs: Double?
    var lastInboundAt: TimeInterval
    var lastPingAt: TimeInterval = 0
    var serverDropped = 0

    var peer: RTCPeerProtocol?
    var peerHasAudio = false
    var rtcBitrateKbps: Int?

    var framesSinceSnapshot = 0
    var bytesSinceSnapshot = 0
    var snapshotAt: TimeInterval
    var fps = 0.0
    var kbps = 0.0
    var hasRates = false

    init(connection: ServerConnection, hello: ClientHello, latency: LatencyModePolicy, now: TimeInterval) {
        self.id = connection.id
        self.connection = connection
        self.hello = hello
        self.latency = latency
        self.lastInboundAt = now
        self.snapshotAt = now
    }
}

/// seq → pts for recently sent video frames (acks carry only the seq).
struct SentFrameLog {
    private var seqs: [UInt32]
    private var ptss: [UInt64]
    private var filled: [Bool]

    init(capacity: Int = 1024) {
        seqs = Array(repeating: 0, count: capacity)
        ptss = Array(repeating: 0, count: capacity)
        filled = Array(repeating: false, count: capacity)
    }

    mutating func record(seq: UInt32, pts: UInt64) {
        let i = Int(seq % UInt32(seqs.count))
        seqs[i] = seq; ptss[i] = pts; filled[i] = true
    }

    func pts(for seq: UInt32) -> UInt64? {
        let i = Int(seq % UInt32(seqs.count))
        return filled[i] && seqs[i] == seq ? ptss[i] : nil
    }
}
