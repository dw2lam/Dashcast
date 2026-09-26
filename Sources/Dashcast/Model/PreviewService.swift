import CoreGraphics
import DashcastContracts
import Foundation

/// Self-animating stand-in for `DashcastService`, used with `DASHCAST_MOCK=1` and SwiftUI previews.
///
/// Environment knobs (all optional):
/// - `DASHCAST_MOCK_PHASE=waiting|streaming|error` — start in that phase.
/// - `DASHCAST_MOCK_CYCLE=1` — loop idle → waiting → streaming → error on its own.
/// - `DASHCAST_MOCK_TOPOLOGY=macHotspot|router|phoneHotspot|offline`
/// - `DASHCAST_MOCK_FRESH=1` — first-run: no permissions, helper, token or certificate.
/// - `DASHCAST_MOCK_CERT=0|1` — own domain with a certificate (Secure mode), or none.
/// - `DASHCAST_MOCK_DOMAIN=cloudflare|manual` — an own domain (car.example.com) that still needs setup.
/// - `DASHCAST_MOCK_DISCONNECT=leftWiFi|browserClosed|connectionLost` — waiting after that disconnect.
/// - `DASHCAST_MOCK_HOST=locked|displayAsleep|sleeping` — the Mac is in that state.
@MainActor
final class PreviewService: DashcastServicing {
    let state = ServiceState()
    var settings: ServiceSettings
    let mockNetwork: MockNetworkManager
    var network: NetworkManaging { mockNetwork }

    private var screenRecording: Bool
    private var accessibility: Bool
    private var connectTask: Task<Void, Never>?
    private var cycleTask: Task<Void, Never>?
    private var statsTimer: Timer?
    private var tick = 0
    /// Holds the live numbers still (screenshots).
    var statsFrozen = false

    /// What the mock pretends is going on.
    struct Scenario {
        enum Phase: String { case idle, waiting, streaming, error }
        var phase: Phase = .idle
        var topology: Topology = .macHotspot
        /// First run: no permissions, helper, token or certificate.
        var fresh = false
        var cycle = false
        /// nil = follow `fresh`. false = compatibility mode (no certificate).
        var certificate: Bool?
        /// Another interface (e.g. SideDisplay) owns the service address range.
        var conflict = false
        /// An own domain without a certificate yet (with `certificate`, the domain is Cloudflare's).
        var domain: OwnDomain.Provider?
        /// With `domain: .cloudflare`: the API token is already saved.
        var token = false
        /// The car just went away for this reason (waiting phase).
        var disconnect: DisconnectReason?
        var host: HostState = .active

        static let exampleHostname = "car.example.com"

        static var fromEnvironment: Scenario {
            let env = ProcessInfo.processInfo.environment
            return Scenario(
                phase: Phase(rawValue: env["DASHCAST_MOCK_PHASE"] ?? "") ?? .idle,
                topology: Topology(rawValue: env["DASHCAST_MOCK_TOPOLOGY"] ?? "") ?? .macHotspot,
                fresh: env["DASHCAST_MOCK_FRESH"] == "1",
                cycle: env["DASHCAST_MOCK_CYCLE"] == "1",
                certificate: env["DASHCAST_MOCK_CERT"].map { $0 == "1" },
                conflict: env["DASHCAST_MOCK_CONFLICT"] == "1",
                domain: OwnDomain.Provider(rawValue: env["DASHCAST_MOCK_DOMAIN"] ?? ""),
                disconnect: DisconnectReason(rawValue: env["DASHCAST_MOCK_DISCONNECT"] ?? ""),
                host: HostState(rawValue: env["DASHCAST_MOCK_HOST"] ?? "") ?? .active
            )
        }
    }

    init(settings: ServiceSettings, scenario: Scenario = .fromEnvironment) {
        self.settings = settings
        screenRecording = !scenario.fresh
        accessibility = !scenario.fresh
        let certificate = scenario.domain == nil && (scenario.certificate ?? !scenario.fresh)
        let provider: OwnDomain.Provider? = certificate ? .cloudflare : scenario.domain
        mockNetwork = MockNetworkManager(topology: scenario.topology, provisioned: !scenario.fresh,
                                         domain: provider.map { OwnDomain(hostname: Scenario.exampleHostname, provider: $0) },
                                         token: certificate || scenario.token, certificate: certificate,
                                         conflict: scenario.conflict)

        state.displays = [
            DisplayInfo(id: 1, name: "Built-in Retina Display", width: 3024, height: 1964, isVirtual: false),
            DisplayInfo(id: 2, name: "Studio Display", width: 5120, height: 2880, isVirtual: false),
        ]
        state.append("Dashcast 0.0.1 — mock service")
        state.append("Found 2 displays: Built-in Retina Display, Studio Display")
        refreshPermissions()
        state.network = mockNetwork.status

        switch scenario.phase {
        case .waiting:
            state.phase = .waitingForCar
        case .streaming:
            carConnected()
        case .error:
            state.phase = .error("Screen Recording permission was revoked.")
            state.append("Capture failed: Screen Recording permission was revoked.")
        case .idle:
            break
        }
        if let reason = scenario.disconnect {
            state.phase = .waitingForCar
            state.lastDisconnect = CarDisconnect(reason: reason, date: Self.sampleTime)
            state.append("Car disconnected; keeping the stream for 5 s")
        }
        state.hostState = scenario.host
        if scenario.cycle { startCycling() }
    }

    /// 10:42 today: a stable time for screenshots.
    static var sampleTime: Date {
        Calendar.current.date(bySettingHour: 10, minute: 42, second: 0, of: Date()) ?? Date()
    }

    // MARK: - DashcastServicing

    func start() async {
        guard state.phase != .streaming, state.phase != .waitingForCar else { return }
        try? await Task.sleep(for: .milliseconds(300))
        state.phase = .waitingForCar
        state.append("Listening on \(state.localURL) and \(state.carURL)")
        connectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.carConnected()
        }
    }

    func stop() async {
        connectTask?.cancel()
        statsTimer?.invalidate()
        statsTimer = nil
        guard state.phase != .idle else { return }
        try? await Task.sleep(for: .milliseconds(200))
        if state.car != nil { state.append("Car disconnected") }
        state.phase = .idle
        state.car = nil
        state.stats = LiveStats()
        state.lastDisconnect = nil
        state.append("Stopped")
    }

    func applySettings() async {
        let s = settings
        state.append("Settings: \(s.displayMode.rawValue), latency \(s.latencyMode.rawValue), tier \(s.tierOverrideID ?? "auto"), "
            + "audio \(s.audioEnabled ? "on" : "off"), touch \(s.inputEnabled ? "on" : "off"), HiDPI \(s.hiDPI ? "on" : "off")")
        if var car = state.car {
            car.tier = resolvedTier()
            state.car = car
        }
    }

    func refreshNetwork() async {
        try? await Task.sleep(for: .milliseconds(250))
        state.network = await network.currentStatus()
    }

    func refreshPermissions() {
        state.screenRecordingGranted = screenRecording
        state.accessibilityGranted = accessibility
    }

    /// Simulates the user flipping the switch in System Settings a moment later.
    func requestScreenRecording() {
        state.append("Requested Screen Recording access")
        Task {
            try? await Task.sleep(for: .seconds(2))
            screenRecording = true
        }
    }

    func setHostState(_ hostState: HostState) {
        guard state.hostState != hostState else { return }
        state.hostState = hostState
        state.append("Mac is \(hostState.rawValue)")
    }

    func requestAccessibility() {
        state.append("Requested Accessibility access")
        Task {
            try? await Task.sleep(for: .seconds(2))
            accessibility = true
        }
    }

    // MARK: - Simulation

    private func resolvedTier() -> Tier {
        if let id = settings.tierOverrideID, let tier = Tier.all.first(where: { $0.id == id }) { return tier }
        return .mcu2
    }

    private func carConnected() {
        let tier = resolvedTier()
        state.car = ConnectedCar(
            computer: .mcu2,
            userAgent: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.7103.92 Safari/537.36 Tesla/2026.32.6",
            viewport: .mock(w: 1280, h: 720, dpr: 1),
            tier: tier,
            connectedAt: Date(),
            // Secure mode streams over the WebSocket (WebCodecs); compatibility mode over WebRTC.
            transport: state.network.certificateExpiry != nil ? .websocket : .webrtc
        )
        state.phase = .streaming
        state.lastDisconnect = nil
        state.append("Car connected — MCU2, viewport 1280×720 @1x, \(Format.transport(state.car?.transport ?? .websocket))")
        state.append("Tier \(tier.id): \(tier.width)×\(tier.height) \(tier.codec.rawValue) \(tier.fps) fps, \(tier.bitrateKbps / 1000) Mbps")
        state.append(settings.displayMode == .extend ? "Virtual display “Dashcast” created (1280×720, HiDPI)" : "Mirroring Built-in Retina Display")
        startStats()
    }

    private func startStats() {
        statsTimer?.invalidate()
        tick = 0
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStats() }
        }
        RunLoop.main.add(timer, forMode: .common)   // keeps ticking while a menu is open
        statsTimer = timer
        updateStats()
    }

    private func updateStats() {
        guard let car = state.car, !statsFrozen else { return }
        tick += 1
        var s = state.stats
        let effective: LatencyMode = settings.latencyMode == .auto
            ? ((tick / 24) % 2 == 0 ? .interactive : .cinema)
            : settings.latencyMode
        let fpsTarget = Double(car.tier.fps)
        s.fps = (s.fps == 0 ? fpsTarget : s.fps + .random(in: -0.5...0.5)).clamped(fpsTarget - 2.5, fpsTarget)
        let latencyBase = effective == .cinema ? 262.0 : 64.0
        s.latencyMs = ((s.latencyMs ?? latencyBase) * 0.7 + (latencyBase + .random(in: -9...9)) * 0.3).clamped(40, 320)
        s.decodeMs = (3.6 + .random(in: -0.5...0.5)).clamped(2, 8)
        s.rttMs = (9 + .random(in: -2.5...2.5)).clamped(4, 25)
        let target = Double(car.tier.bitrateKbps) * 0.92
        s.bitrateKbps = ((s.bitrateKbps == 0 ? target : s.bitrateKbps) * 0.6 + (target + .random(in: -600...600)) * 0.4).clamped(500, 30_000)
        if Double.random(in: 0...1) < 0.02 { s.dropped += 1 }
        s.effectiveLatencyMode = effective
        state.stats = s
    }

    private func startCycling() {
        cycleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await self?.start()
                try? await Task.sleep(for: .seconds(14))
                guard let self else { return }
                self.statsTimer?.invalidate()
                self.state.phase = .error("Car browser disconnected unexpectedly.")
                self.state.append("Error: car browser disconnected unexpectedly")
                try? await Task.sleep(for: .seconds(4))
                self.state.phase = .streaming   // let stop() run its full teardown
                await self.stop()
            }
        }
    }
}

/// In-memory `NetworkManaging` for the mock service.
@MainActor
final class MockNetworkManager: NetworkManaging {
    private(set) var status: NetworkStatus
    private var token: String?

    init(topology: Topology, provisioned: Bool, domain: OwnDomain?, token: Bool, certificate: Bool, conflict: Bool = false) {
        var status = NetworkStatus()
        status.topology = topology
        switch topology {
        case .macHotspot:
            status.interfaceName = "bridge100"
            status.macLANAddress = "192.168.2.1"
            status.summary = "Internet Sharing is on."
        case .router:
            status.interfaceName = "en0"
            status.macLANAddress = "192.168.8.214"
            status.summary = "Joined “GL-SFT1200-5G”."
        case .phoneHotspot:
            status.interfaceName = "en0"
            status.macLANAddress = "172.20.10.3"
            status.summary = "Joined an iPhone hotspot (172.20.10.x)."
        case .offline:
            status.summary = "No active network."
        }
        status.internetReachable = topology != .offline
        status.helperInstalled = provisioned
        status.aliasActive = provisioned
        status.domain = domain
        status.hasCloudflareToken = token
        status.dnsRecordOK = certificate
        status.certificateExpiry = certificate ? Calendar.current.date(byAdding: .day, value: 71, to: Date()) : nil
        status.serviceAddressConflict = conflict ? "bridge100 203.0.113.1/24" : nil
        self.status = status
        self.token = token ? "mock-token" : nil
    }

    func currentStatus() async -> NetworkStatus { status }

    func installLoopbackHelper() async throws {
        try await Task.sleep(for: .seconds(1.2))
        status.helperInstalled = true
        status.aliasActive = true
    }

    func uninstallLoopbackHelper() async throws {
        try await Task.sleep(for: .seconds(0.8))
        status.helperInstalled = false
        status.aliasActive = false
    }

    func setOwnDomain(_ domain: OwnDomain?) throws {
        var normalized = domain
        if let domain {
            switch OwnDomain.normalize(domain.hostname) {
            case .success(let hostname): normalized?.hostname = hostname
            case .failure(let error): throw error
            }
        }
        if normalized?.hostname != status.domain?.hostname {
            status.certificateExpiry = nil
            status.dnsRecordOK = false
        }
        status.domain = normalized
    }

    func setCloudflareToken(_ token: String) throws {
        self.token = token
        status.hasCloudflareToken = true
    }

    func hasCloudflareToken() -> Bool { token != nil }

    func provisionCertificate() async throws {
        try await Task.sleep(for: .seconds(2))
        guard status.domain?.provider == .cloudflare else { throw MockError("Add a Cloudflare domain first.") }
        guard token != nil else { throw MockError("Add a Cloudflare API token first.") }
        guard status.internetReachable else { throw MockError("Certificates need an internet connection.") }
        status.dnsRecordOK = true
        status.certificateExpiry = Calendar.current.date(byAdding: .day, value: 90, to: Date())
    }

    func importCertificate(_ certificate: CertificateImport) async throws {
        try await Task.sleep(for: .seconds(1))
        guard status.domain != nil else { throw MockError("Add your own domain first.") }
        status.certificateExpiry = Calendar.current.date(byAdding: .day, value: 365, to: Date())
    }

    func tlsMaterial() -> TLSMaterial? { nil }

    func routerSetupScript(macLANAddress: String) -> String {
        let address = DashcastDefaults.serviceAddress
        let dns = status.domain.map { domain in
            """
            # Answer \(domain.hostname) with the service address on this LAN.
            uci add_list dhcp.@dnsmasq[0].address='/\(domain.hostname)/\(address)'
            uci add_list dhcp.@dnsmasq[0].rebind_domain='\(domain.hostname)'

            """
        } ?? ""
        return """
        # Dashcast — GL.iNet / OpenWrt setup (run over SSH as root)
        \(dns)# Route the service address to this Mac.
        uci add network route
        uci set network.@route[-1].interface='lan'
        uci set network.@route[-1].target='\(address)/32'
        uci set network.@route[-1].gateway='\(macLANAddress)'

        uci commit dhcp && uci commit network
        /etc/init.d/dnsmasq restart && /etc/init.d/network reload
        """
    }
}

extension NetworkActions {
    static func mock(_ network: MockNetworkManager) -> NetworkActions {
        var actions = NetworkActions.fallback(for: network)
        actions.applyRouterSetup = { login, _ in
            try await Task.sleep(for: .seconds(1.5))
            guard !login.password.isEmpty else { throw MockError("Permission denied (publickey,password).") }
            return "uci: ok\ndnsmasq restarted"
        }
        return actions
    }
}

struct MockError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension Viewport {
    /// `Viewport` has no public memberwise init; build one through its Codable conformance.
    static func mock(w: Double, h: Double, dpr: Double) -> Viewport {
        let json = #"{"w":\#(w),"h":\#(h),"dpr":\#(dpr)}"#
        return try! JSONDecoder().decode(Viewport.self, from: Data(json.utf8))
    }
}

extension Comparable {
    func clamped(_ lower: Self, _ upper: Self) -> Self { min(max(self, lower), upper) }
}
