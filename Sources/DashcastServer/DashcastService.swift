import DashcastContracts
import Foundation
import Network

/// Listener addresses and timings. Defaults are production values; tests override them.
public struct ServerOptions: Sendable {
    /// Always-on plain HTTP listener (localhost is a secure context, so WebCodecs works).
    public var devHost = "127.0.0.1"
    /// 0 = pick a free port (see `DashcastService.devPort`).
    public var devPort: UInt16 = DashcastDefaults.devPort
    /// Production TLS listener, started when the network layer has certificate material.
    public var tlsHost = DashcastDefaults.serviceAddress
    public var tlsPort: UInt16 = DashcastDefaults.tlsPort
    /// Plain HTTP on the service address: Tesla/Apple connectivity probes + 301 to https.
    /// nil disables it.
    public var plainHTTPPort: UInt16? = 80
    public var plainHTTPHost = DashcastDefaults.serviceAddress
    /// How long the engine (and the virtual display) survives a car disconnect.
    public var reconnectGracePeriod: TimeInterval = 5
    /// Directory containing the built client's index.html; nil = automatic lookup.
    public var clientDirectory: URL?
    /// Extra hostnames accepted in Host/Origin (besides localhost, loopback, the service address and
    /// the certificate's hostname).
    public var extraAllowedHosts: [String] = []

    public init() {}
}

@MainActor
public final class DashcastService: DashcastServicing {
    public let state = ServiceState()
    public var settings: ServiceSettings
    public let network: NetworkManaging
    public let engine: StreamEngineProtocol
    /// WebRTC peers for cars without WebCodecs (HTTP mode). nil → those cars get JPEG over the socket.
    public let rtc: RTCPeerFactory?
    public let options: ServerOptions
    private let displayAwake: DisplayAwakeHolding

    /// Bound ports (nil while not listening).
    public private(set) var devPort: UInt16?
    public private(set) var tlsPort: UInt16?
    public private(set) var plainHTTPPort: UInt16?

    private let queue = DispatchQueue(label: "online.davidlam.dashcast.server", qos: .userInteractive)
    private let server: HTTPServer
    private let hub: SessionHub

    private var running = false
    private var engineRunning = false
    private var currentConfig: StreamConfig?
    private var active: ActiveCar?
    private var graceTask: Task<Void, Never>?
    private var opTail: Task<Void, Never>?
    private var tlsFileStamp: String?
    /// The certificate's hostname while the https listener runs.
    private var tlsHostname: String?
    private var lastListenerProblem: [String: String] = [:]
    /// Last logged mode (true = HTTPS) so a refresh doesn't repeat it.
    private var loggedHTTPMode: Bool?

    private struct ActiveCar {
        var id: UInt64
        var hello: ClientHello
        var context: SessionHub.HelloContext
        var plan: SessionPlan
        var tier: Tier
        var overrideID: String?
        var connectedAt: Date
    }

    public init(engine: StreamEngineProtocol, network: NetworkManaging, rtc: RTCPeerFactory? = nil,
                settings: ServiceSettings = .init(), options: ServerOptions = .init(),
                displayAwake: DisplayAwakeHolding = DisplayAwakeAssertion()) {
        self.engine = engine
        self.network = network
        self.rtc = rtc
        self.settings = settings
        self.options = options
        self.displayAwake = displayAwake
        var hosts: Set<String> = ["localhost", "127.0.0.1", "::1",
                                  DashcastDefaults.serviceAddress, options.tlsHost, options.devHost]
        hosts.formUnion(options.extraAllowedHosts.map { $0.lowercased() })
        server = HTTPServer(queue: queue, pages: ClientPageProvider(directory: options.clientDirectory),
                            allowedHosts: hosts)
        hub = SessionHub(queue: queue, engine: engine, rtcFactory: rtc)
        server.webSocketDelegate = hub
        server.log = { [weak self] message in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.log(message) } }
        }
        hub.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    // MARK: DashcastServicing

    public func start() async {
        guard !running else { return }
        running = true
        installEngineCallbacks()
        refreshPermissions()
        hub.start()
        await network.startLocalServices()

        switch await startListener(name: "dev", role: .app, host: options.devHost, port: options.devPort, tls: nil) {
        case .success(let port):
            devPort = port
            log("Listening on http://localhost:\(port)")
        case .failure(let error):
            log("Couldn't listen on \(options.devHost):\(options.devPort): \(error)")
        }
        state.phase = devPort != nil ? .waitingForCar : .error("Port \(options.devPort) is unavailable")
        await refreshNetwork()
    }

    public func stop() async {
        guard running else { return }
        running = false
        graceTask?.cancel()
        graceTask = nil
        active = nil
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            hub.shutdown(reason: "stopped") { done.resume() }
        }
        await onQueue { $0.stopAll() }
        await network.stopLocalServices()
        devPort = nil
        tlsPort = nil
        plainHTTPPort = nil
        tlsFileStamp = nil
        tlsHostname = nil
        await onQueue { $0.publicHostname = nil }
        loggedHTTPMode = nil
        lastListenerProblem = [:]
        await enqueue { [self] in
            if engineRunning {
                await engine.stop()
                engineRunning = false
                currentConfig = nil
            }
        }.value
        state.car = nil
        state.stats = LiveStats()
        state.phase = .idle
        state.lastDisconnect = nil
        updateDisplayAwake()
        log("Stopped")
    }

    public func applySettings() async {
        hub.updateSettings(latencyMode: settings.latencyMode, inputEnabled: settings.inputEnabled)
        updateDisplayAwake()
        guard running, let car = active else { return }
        var tier = car.tier
        if settings.tierOverrideID != car.overrideID {
            let plan = makePlan(hello: car.hello, context: car.context)
            active?.plan = plan
            active?.overrideID = settings.tierOverrideID
            tier = plan.decision.tier
            log("Tier \(plan.decision.isOverride ? "override" : "auto"): \(tier.label)")
        }
        await enqueue { [self] in await configure(sessionID: car.id, tier: tier, isNewCar: false) }.value
    }

    public func refreshNetwork() async {
        state.network = await network.currentStatus()
        guard running else { return }
        await ensureServiceListeners()
    }

    public func refreshPermissions() {
        state.screenRecordingGranted = engine.hasScreenRecordingPermission()
        state.accessibilityGranted = engine.hasAccessibilityPermission()
        state.displays = engine.availableDisplays()
    }

    public func requestScreenRecording() {
        engine.requestScreenRecordingPermission()
        refreshPermissions()
    }

    public func requestAccessibility() {
        engine.requestAccessibilityPermission()
        refreshPermissions()
    }

    public func setHostState(_ hostState: HostState) {
        guard state.hostState != hostState else { return }
        state.hostState = hostState
        log(Self.hostLogLine(hostState))
        guard hostState == .sleeping else {
            hub.setHostState(hostState)
            return
        }
        // willSleep: the network is about to go; hold the caller until the car has been told.
        let sent = DispatchSemaphore(value: 0)
        hub.setHostState(hostState) { sent.signal() }
        _ = sent.wait(timeout: .now() + Self.sleepNoticeTimeout)
    }

    static let sleepNoticeTimeout: TimeInterval = 0.5

    static func hostLogLine(_ state: HostState) -> String {
        switch state {
        case .active: "Mac is active again; the car resumes"
        case .locked: "Mac locked; the car shows a paused message"
        case .displayAsleep: "Display asleep; the car shows a paused message"
        case .sleeping: "Mac is going to sleep; told the car"
        }
    }

    /// While a car is connected (and the setting is on), idle display sleep is held off.
    private func updateDisplayAwake() {
        displayAwake.setHeld(running && state.car != nil && settings.keepDisplayAwake)
    }

    // MARK: Listeners

    private func startListener(name: String, role: ServerConnection.Role, host: String, port: UInt16,
                               tls: TLSIdentity?) async -> Result<UInt16, Error> {
        await withCheckedContinuation { (done: CheckedContinuation<Result<UInt16, Error>, Never>) in
            let server = self.server
            queue.async {
                server.startListener(name: name, role: role, host: host, port: port, tls: tls) { done.resume(returning: $0) }
            }
        }
    }

    private func onQueue<T>(_ body: @escaping (HTTPServer) -> T) async -> T {
        await withCheckedContinuation { (done: CheckedContinuation<T, Never>) in
            let server = self.server
            queue.async { done.resume(returning: body(server)) }
        }
    }

    /// (Re)starts the plain :80 and TLS :443 listeners on the service address, then picks HTTP or HTTPS
    /// mode. Binding fails while the loopback alias is down; that's logged once and retried on the next
    /// refresh.
    private func ensureServiceListeners() async {
        await ensurePlainListener()
        await ensureTLSListener()
        await updateHTTPMode()
        if state.phase == .error("Port \(options.devPort) is unavailable"), tlsPort != nil || plainHTTPPort != nil {
            state.phase = .waitingForCar
        }
    }

    private func ensurePlainListener() async {
        guard let port = options.plainHTTPPort, !(await onQueue { $0.isListening("http") }) else { return }
        switch await startListener(name: "http", role: .plain, host: options.plainHTTPHost, port: port, tls: nil) {
        case .success(let bound):
            plainHTTPPort = bound
            lastListenerProblem["http"] = nil
            loggedHTTPMode = nil
            log("Listening on http://\(options.plainHTTPHost):\(bound)")
        case .failure(let error):
            plainHTTPPort = nil
            noteListenerProblem("http", "Can't listen on \(options.plainHTTPHost):\(port) yet (\(Self.describe(error))); will retry")
        }
    }

    private func ensureTLSListener() async {
        guard let material = network.tlsMaterial() else {
            if await onQueue({ $0.isListening("tls") }) {
                await onQueue { $0.stopListener("tls") }
                tlsPort = nil
                tlsFileStamp = nil
                tlsHostname = nil
                log("TLS certificate removed; stopped the https listener")
            }
            return
        }
        let stamp = TLSIdentity.fileStamp(for: material.pkcs12URL)
        let listening = await onQueue { $0.isListening("tls") }
        if listening, stamp == tlsFileStamp, material.hostname == tlsHostname { return }

        let identity: TLSIdentity
        do {
            identity = try TLSIdentity.load(material)
        } catch {
            noteListenerProblem("tls", "TLS certificate unusable: \(error)")
            return
        }
        switch await startListener(name: "tls", role: .app, host: options.tlsHost, port: options.tlsPort, tls: identity) {
        case .success(let bound):
            tlsPort = bound
            tlsFileStamp = stamp
            if tlsHostname != material.hostname { loggedHTTPMode = nil }
            tlsHostname = material.hostname
            lastListenerProblem["tls"] = nil
            let expiry = identity.expiry.map { " · certificate valid until \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
            log("Listening on https://\(material.hostname) (\(options.tlsHost):\(bound))\(expiry)\(listening ? " · reloaded certificate" : "")")
        case .failure(let error):
            tlsPort = nil
            tlsFileStamp = nil
            tlsHostname = nil
            noteListenerProblem("tls", "Can't listen on \(options.tlsHost):\(options.tlsPort) yet (\(Self.describe(error))); will retry")
        }
    }

    /// HTTP mode (no https listener): :80 serves the page and /ws (media over WebRTC, or JPEG).
    /// HTTPS mode: :80 redirects to https. Connectivity probes are answered either way.
    private func updateHTTPMode() async {
        let hostname = await onQueue { $0.isListening("tls") } ? tlsHostname : nil
        await onQueue { server in
            server.publicHostname = hostname
            server.plainServesApp = hostname == nil
        }
        let tlsUp = hostname != nil
        guard plainHTTPPort != nil, loggedHTTPMode != tlsUp else { return }
        loggedHTTPMode = tlsUp
        log(hostname.map { "HTTPS mode: http://\(options.plainHTTPHost) redirects to https://\($0)" }
            ?? "HTTP mode: serving the car at http://\(options.plainHTTPHost) (no certificate)")
    }

    private func noteListenerProblem(_ name: String, _ message: String) {
        guard lastListenerProblem[name] != message else { return }
        lastListenerProblem[name] = message
        log(message)
    }

    static func describe(_ error: Error) -> String {
        if let nw = error as? NWError, case .posix(let code) = nw {
            switch code {
            case .EADDRNOTAVAIL: return "address not on this Mac — is the loopback alias up?"
            case .EADDRINUSE: return "port in use"
            case .EACCES: return "permission denied"
            default: return "\(code)"
            }
        }
        return "\(error)"
    }

    // MARK: Engine

    private func installEngineCallbacks() {
        let hub = self.hub
        engine.onVideo = { frame in hub.ingestVideo(frame) }
        engine.onAudio = { packet in hub.ingestAudio(packet) }
        engine.onEvent = { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handleEngineEvent(event) } }
        }
    }

    private func handleEngineEvent(_ event: EngineEvent) {
        switch event {
        case .started(let displayID):
            log("Capturing display \(displayID)")
            state.displays = engine.availableDisplays()
        case .stopped:
            if engineRunning && running { log("Capture stopped") }
            state.displays = engine.availableDisplays()
        case .error(let message):
            log("Stream error: \(message)")
            if active != nil { state.phase = .error(message) }
        case .permissionMissing(let message):
            // Never leave the car on a frozen or black picture: stop casting and say why.
            log("Permission needed: \(message)")
            refreshPermissions()
            guard running else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.stop()
                self.state.phase = .error(message)
            }
        }
    }

    /// Serializes engine lifecycle work (start/update/stop are async and must not interleave).
    @discardableResult
    private func enqueue(_ op: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = opTail
        let task = Task { @MainActor in
            await previous?.value
            await op()
        }
        opTail = task
        return task
    }

    // MARK: Hub events

    private func handle(_ event: SessionHub.Event) {
        switch event {
        case .hello(let id, let hello, let context): carSaidHello(id: id, hello: hello, context: context)
        case .disconnected(let id, let reason, let ending, let address):
            carDisconnected(id: id, reason: reason, ending: ending, carAddress: address)
        case .tierChange(let id, let tier, let reason): tierChangeRequested(id: id, tier: tier, reason: reason)
        case .stats(let stats): if state.stats != stats { state.stats = stats }
        case .log(let message): log(message)
        }
    }

    private func makePlan(hello: ClientHello, context: SessionHub.HelloContext) -> SessionPlan {
        SessionPlanner.plan(hello: hello, transportCaps: context.transportCaps, secureFallback: context.secureFallback,
                            rtcAvailable: rtc != nil, overrideID: settings.tierOverrideID)
    }

    private func carSaidHello(id: UInt64, hello: ClientHello, context: SessionHub.HelloContext) {
        guard running else { return }
        graceTask?.cancel()
        graceTask = nil
        state.lastDisconnect = nil
        if active != nil { log("New car session replaces the previous one") }
        let plan = makePlan(hello: hello, context: context)
        active = ActiveCar(id: id, hello: hello, context: context, plan: plan, tier: plan.decision.tier,
                           overrideID: settings.tierOverrideID, connectedAt: Date())
        enqueue { [self] in await configure(sessionID: id, tier: plan.decision.tier, isNewCar: true) }
    }

    private func tierChangeRequested(id: UInt64, tier: Tier, reason: String) {
        guard let car = active, car.id == id, car.tier != tier else { return }
        let direction = (Tier.all.firstIndex(of: tier) ?? 0) < (Tier.all.firstIndex(of: car.tier) ?? 0) ? "down" : "up"
        log("Stepping \(direction) to \(tier.label) (\(reason))")
        enqueue { [self] in await configure(sessionID: id, tier: tier, isNewCar: false) }
    }

    private func carDisconnected(id: UInt64, reason: String, ending: DisconnectClassifier.Ending, carAddress: String?) {
        guard let car = active, car.id == id else { return }
        active = nil
        state.car = nil
        state.stats = LiveStats()
        updateDisplayAwake()
        guard running else { return }
        state.phase = .waitingForCar
        let grace = options.reconnectGracePeriod
        log("Car disconnected (\(reason)); keeping the stream for \(Self.seconds(grace)) s")
        Task { @MainActor [weak self] in
            await self?.explainDisconnect(ending: ending, carAddress: carAddress, at: Date())
        }
        graceTask?.cancel()
        graceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(grace, 0) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.active == nil else { return }
            self.enqueue { [self] in
                guard self.active == nil, self.engineRunning else { return }
                await self.engine.stop()
                self.engineRunning = false
                self.currentConfig = nil
                self.log("No car reconnected; stream stopped")
            }
        }
    }

    /// Works out why the car left (asking the network when the socket just died) and shows it
    /// unless a car has connected again meanwhile.
    private func explainDisconnect(ending: DisconnectClassifier.Ending, carAddress: String?, at date: Date) async {
        var stillOnNetwork: Bool?
        if DisconnectClassifier.needsPresenceCheck(ending), let carAddress {
            stillOnNetwork = await network.isStillOnNetwork(carAddress)
        }
        guard running, active == nil else { return }
        let reason = DisconnectClassifier.reason(for: ending, stillOnNetwork: stillOnNetwork)
        state.lastDisconnect = CarDisconnect(reason: reason, date: date)
    }

    private func makeConfig(for car: ActiveCar, tier: Tier) -> StreamConfig {
        let size = TierSelector.encodeSize(tier: tier, viewport: car.hello.viewport)
        let display = TierSelector.displaySize(viewport: car.hello.viewport)
        return StreamConfig(displayMode: settings.displayMode, mirrorDisplayID: settings.mirrorDisplayID,
                            width: size.width, height: size.height,
                            displayWidth: display.width, displayHeight: display.height,
                            fps: tier.fps, codec: tier.codec, bitrateKbps: tier.bitrateKbps,
                            captureAudio: settings.audioEnabled, hiDPI: settings.hiDPI,
                            h264Profile: car.plan.h264Profile)
    }

    /// Starts or updates the engine for the active car, then tells the hub to send `config`.
    private func configure(sessionID: UInt64, tier: Tier, isNewCar: Bool) async {
        guard running, let car = active, car.id == sessionID else { return }
        let config = makeConfig(for: car, tier: tier)
        let needsEngine = !engineRunning || config != currentConfig
        if needsEngine {
            hub.beginReconfigure(sessionID: sessionID)
            do {
                if engineRunning {
                    try await engine.update(config)
                } else {
                    try await engine.start(config)
                    engineRunning = true
                }
                currentConfig = config
            } catch {
                log("Couldn't \(engineRunning ? "reconfigure" : "start") the stream: \(error.localizedDescription)")
                state.phase = .error(error.localizedDescription)
                hub.abort(sessionID: sessionID, reason: "error")
                if active?.id == sessionID { active = nil; state.car = nil }
                return
            }
        }
        // A newer car may have said hello while the engine was starting; its own op takes over.
        guard running, active?.id == sessionID else { return }
        active?.tier = tier
        guard let car = active else { return }
        let transport = car.plan.transport
        hub.activate(sessionID: sessionID, params: SessionHub.Params(
            transport: transport, decision: car.plan.decision, tier: tier,
            codecString: SessionPlanner.codecString(for: tier, transport: transport),
            width: config.width, height: config.height,
            latencySetting: settings.latencyMode, audioEnabled: settings.audioEnabled,
            inputEnabled: settings.inputEnabled,
            rtcBindAddress: transport == .webrtc ? car.context.localHost : nil), forceConfig: isNewCar || needsEngine)

        state.car = ConnectedCar(computer: car.plan.decision.computer, userAgent: car.hello.ua, viewport: car.hello.viewport,
                                 tier: tier, connectedAt: car.connectedAt, transport: transport)
        state.phase = .streaming
        state.lastDisconnect = nil
        updateDisplayAwake()
        let media = transport == .webrtc ? "H.264 over WebRTC" : tier.codec.label
        let summary = "\(car.plan.decision.computer.label) · \(config.width)×\(config.height) \(media) \(tier.fps) fps"
        if isNewCar {
            log("Car connected · \(summary) (\(car.plan.decision.reason))")
        } else if needsEngine {
            log("Stream reconfigured · \(summary)")
        }
    }

    // MARK: Helpers

    private func log(_ message: String) {
        state.append(message)
    }

    private static func seconds(_ t: TimeInterval) -> String {
        t == t.rounded() ? String(Int(t)) : String(format: "%.1f", t)
    }

    /// Test hook: transport, bitrate target, effective latency mode, server-side drops.
    func debugSessionSnapshot() -> SessionHub.DebugSnapshot {
        hub.debugSnapshot()
    }
}
