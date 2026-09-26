import DashcastContracts
import SwiftUI

// Plain-language strings and symbols for contract types.

enum Format {
    static func codec(_ codec: VideoCodec) -> String {
        switch codec {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .jpeg: "JPEG"
        }
    }

    static func computer(_ computer: CarComputer) -> String {
        switch computer {
        case .mcu2: "MCU2"
        case .mcu3: "MCU3"
        case .unknown: "Tesla"
        }
    }

    static func resolution(_ width: Int, _ height: Int) -> String { "\(width)×\(height)" }

    static func transport(_ transport: MediaTransport) -> String {
        switch transport {
        case .websocket: "WebCodecs"
        case .webrtc: "WebRTC"
        }
    }

    /// "MCU2 · 1280×720 · H.264 · WebCodecs"
    static func carSummary(_ car: ConnectedCar) -> String {
        "\(computer(car.computer)) · \(resolution(car.tier.width, car.tier.height)) · \(codec(car.tier.codec)) · \(transport(car.transport))"
    }

    /// "1280×720 · 30 fps · H.264 · 6 Mbps"
    static func tierDetail(_ tier: Tier) -> String {
        "\(resolution(tier.width, tier.height)) · \(tier.fps) fps · \(codec(tier.codec)) · \(mbps(Double(tier.bitrateKbps))) Mbps"
    }

    static func mbps(_ kbps: Double) -> String {
        (kbps / 1000).formatted(.number.precision(.fractionLength(kbps >= 10_000 ? 0 : 1)))
    }

    static func fps(_ fps: Double) -> String { fps.formatted(.number.precision(.fractionLength(0))) }

    static func ms(_ ms: Double?) -> String {
        guard let ms else { return "—" }
        return ms.formatted(.number.precision(.fractionLength(ms < 10 ? 1 : 0)))
    }

    static let logTime: Date.FormatStyle = .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
}

// MARK: - Connection mode

/// Both modes run entirely between this Mac and the car (the Mac answers DNS itself).
enum ConnectionMode: Equatable {
    /// The user's own domain has a certificate: `https://<hostname>`, WebCodecs. Fastest.
    case secure(hostname: String)
    /// No domain or no certificate yet: `http://<service address>`, video over WebRTC.
    case compatibility

    init(network: NetworkStatus, now: Date = Date()) {
        if let hostname = network.domain?.hostname, let expiry = network.certificateExpiry, expiry > now {
            self = .secure(hostname: hostname)
        } else {
            self = .compatibility
        }
    }

    var isSecure: Bool { self != .compatibility }

    /// The big, glanceable part of the address: the hostname, or the service address's digits.
    var address: String {
        switch self {
        case .secure(let hostname): hostname
        case .compatibility: DashcastDefaults.serviceAddress
        }
    }

    /// Shown small in front of `address` ("http://" for the bare IP; a hostname needs nothing).
    var scheme: String? {
        switch self {
        case .secure: nil
        case .compatibility: "http://"
        }
    }

    var url: String {
        switch self {
        case .secure(let hostname): "https://\(hostname)"
        case .compatibility: "http://\(DashcastDefaults.serviceAddress)"
        }
    }

    /// What to type in the car: the bare hostname in secure mode; the full URL (with http://) otherwise.
    var addressToType: String {
        switch self {
        case .secure(let hostname): hostname
        case .compatibility: "http://\(DashcastDefaults.serviceAddress)"
        }
    }

    var caption: String {
        switch self {
        case .secure: "Secure · fastest"
        case .compatibility: "Compatibility mode · no certificate"
        }
    }

    var symbol: String {
        switch self {
        case .secure: "lock.fill"
        case .compatibility: "bolt.horizontal.fill"
        }
    }

    /// The Secure mode line's address: the own domain, or a plain description until there is one.
    static func secureAddress(_ domain: OwnDomain?) -> String {
        domain?.hostname ?? "Your own domain"
    }
}

extension OwnDomain.Provider {
    var title: String {
        switch self {
        case .cloudflare: "Cloudflare (automatic)"
        case .manual: "Another provider (manual)"
        }
    }
}

// MARK: - Disconnects and the Mac's state

extension DisconnectReason {
    /// "Car left the Wi‑Fi" (menu panel, notification).
    var title: String {
        switch self {
        case .leftWiFi: "Car left the Wi‑Fi"
        case .browserClosed: "Browser closed on the car"
        case .connectionLost: "Connection lost"
        }
    }

    /// Next to the menu bar icon for a few seconds.
    var shortTitle: String {
        switch self {
        case .leftWiFi: "Left Wi‑Fi"
        case .browserClosed: "Browser closed"
        case .connectionLost: "Disconnected"
        }
    }

    var symbol: String {
        switch self {
        case .leftWiFi: "wifi.slash"
        case .browserClosed: "xmark.circle"
        case .connectionLost: "exclamationmark.triangle"
        }
    }
}

extension CarDisconnect {
    static let timeStyle: Date.FormatStyle = .dateTime.hour().minute()

    /// "Car left the Wi‑Fi · 10:42"
    var line: String { "\(reason.title) · \(date.formatted(Self.timeStyle))" }

    /// "Your Tesla left the Wi‑Fi at 10:42."
    var sentence: String {
        let time = date.formatted(Self.timeStyle)
        switch reason {
        case .leftWiFi: return "Your Tesla left the Wi‑Fi at \(time)."
        case .browserClosed: return "The browser on your Tesla closed at \(time)."
        case .connectionLost: return "The connection to your Tesla was lost at \(time)."
        }
    }
}

extension HostState {
    /// "Paused: Mac is locked" (nil while active).
    var pausedTitle: String? {
        switch self {
        case .active: nil
        case .locked: "Paused: Mac is locked"
        case .displayAsleep: "Paused: display is asleep"
        case .sleeping: "Paused: Mac is asleep"
        }
    }

    var advice: String {
        switch self {
        case .active: ""
        case .locked: "Your Tesla shows a pause message. Unlock this Mac to keep streaming."
        case .displayAsleep: "Your Tesla shows a pause message. Wake the display to keep streaming."
        case .sleeping: "Wake this Mac and your Tesla reconnects."
        }
    }

    var symbol: String {
        switch self {
        case .active: "play.fill"
        case .locked: "lock.fill"
        case .displayAsleep: "display"
        case .sleeping: "moon.zzz.fill"
        }
    }
}

extension PermissionHealth {
    /// One line for the main window's list of things to fix.
    func readinessTitle(_ pane: PermissionPane) -> String {
        let name = pane == .screenRecording ? "Screen Recording" : "Accessibility"
        switch self {
        case .notDetermined:
            return pane == .screenRecording ? "Screen Recording permission needed" : "Touch control needs Accessibility permission"
        case .denied: return "\(name) is turned off for Dashcast"
        case .needsRelaunch: return "\(name) is on. Relaunch Dashcast to use it."
        case .grantedButNotWorking: return "\(name) is allowed for an older copy of Dashcast"
        case .noDisplays: return "Screen is locked"
        case .working, .checking: return name
        }
    }

    /// The detail needs the row's width; its fix goes underneath instead of beside it.
    var explainsItself: Bool { self == .grantedButNotWorking || self == .needsRelaunch }

    /// Compact button title for tight rows.
    var shortActionTitle: String {
        switch action {
        case .grant: "Grant…"
        case .relaunch: "Relaunch"
        case .fix: "Fix…"
        case .checkAgain: "Check Again"
        case nil: ""
        }
    }
}

// MARK: - Enums

extension LatencyMode {
    var title: String {
        switch self {
        case .auto: "Auto"
        case .interactive: "Interactive"
        case .cinema: "Cinema"
        }
    }

    var explanation: String {
        switch self {
        case .auto: "Cinema while something plays, Interactive the moment you touch the screen."
        case .interactive: "Lowest delay for tapping and scrolling."
        case .cinema: "Perfect lip sync with a short buffer. Best for movies."
        }
    }
}

extension DisplayMode {
    var title: String {
        switch self {
        case .extend: "Extend"
        case .mirror: "Mirror"
        }
    }

    var symbol: String {
        switch self {
        case .extend: "rectangle.split.2x1"
        case .mirror: "rectangle.on.rectangle"
        }
    }
}

extension Topology {
    var title: String {
        switch self {
        case .macHotspot: "Mac Hotspot"
        case .router: "Travel Router"
        case .phoneHotspot: "Phone Hotspot"
        case .offline: "Not Connected"
        }
    }

    var symbol: String {
        switch self {
        case .macHotspot: "personalhotspot"
        case .router: "wifi.router"
        case .phoneHotspot: "iphone.radiowaves.left.and.right"
        case .offline: "wifi.slash"
        }
    }

    var explanation: String {
        switch self {
        case .macHotspot: "Your Tesla joins this Mac’s Wi‑Fi. Nothing else needed."
        case .router: "This Mac and your Tesla share a travel router."
        case .phoneHotspot: "This Mac is on a phone’s hotspot, which can’t reach the car."
        case .offline: "Turn on Internet Sharing so your Tesla can join this Mac."
        }
    }

    var isUsable: Bool { self == .macHotspot || self == .router }
}

// MARK: - Headline

enum CastStage: Equatable {
    case idle, waiting, casting, problem
}

/// The main window's big title and one plain-language line.
struct Headline {
    let stage: CastStage
    let title: String
    let detail: String

    @MainActor
    init(model: AppModel, readiness: [ReadinessItem]) {
        let state = model.state
        switch state.phase {
        case .idle where model.startProblem != nil:
            stage = .problem
            title = "Can’t Start Yet"
            let pane = model.startProblem ?? .screenRecording
            detail = model.permissions[pane].detail(pane)
        case .idle:
            stage = .idle
            if readiness.isEmpty {
                title = "Ready to Cast"
                detail = "Put this Mac on your Tesla’s screen."
            } else {
                title = "Almost Ready"
                detail = "Finish setting up below, then start casting."
            }
        case .waitingForCar:
            stage = .waiting
            title = "Waiting for Your Tesla…"
            if let disconnect = state.lastDisconnect {
                detail = "\(disconnect.sentence) Open the address below to reconnect."
            } else {
                detail = "Open the address below in the car’s browser."
            }
        case .streaming where state.hostState != .active:
            stage = .casting
            title = state.hostState.pausedTitle ?? "Paused"
            detail = state.hostState.advice
        case .streaming:
            stage = .casting
            title = "Casting to Your Tesla"
            if model.settings.displayMode == .extend {
                detail = "Your Tesla is a second display. Drag windows onto it."
            } else {
                let name = model.state.displays.first { $0.id == model.settings.mirrorDisplayID }?.name ?? "your main display"
                detail = "Mirroring \(name)."
            }
        case .error(let message):
            stage = .problem
            title = "Casting Stopped"
            detail = message
        }
    }

    /// Short form for the menu bar.
    @MainActor
    static func short(_ state: ServiceState) -> String {
        switch state.phase {
        case .idle: "Not casting"
        case .waitingForCar: "Waiting for your Tesla…"
        case .streaming: state.hostState.pausedTitle ?? "Casting"
        case .error: "Casting stopped"
        }
    }
}

// MARK: - Readiness

/// One thing standing between the user and casting, with the single action that fixes it.
struct ReadinessItem: Identifiable, Equatable {
    enum Action: Equatable { case permission(PermissionPane), installHelper, openInternetSharing, recheckNetwork }

    let id: String
    let symbol: String
    let tint: Color
    let title: String
    let actionTitle: String
    let action: Action

    @MainActor
    static func current(_ model: AppModel) -> [ReadinessItem] {
        let state = model.state
        let network = state.network
        var items: [ReadinessItem] = []
        let screen = model.permissions[.screenRecording]
        if screen.action != nil {
            items.append(.init(id: "screen", symbol: screen == .noDisplays ? "lock.fill" : "rectangle.dashed.badge.record",
                               tint: screen == .noDisplays ? .gray : .red,
                               title: screen.readinessTitle(.screenRecording),
                               actionTitle: screen.shortActionTitle, action: .permission(.screenRecording)))
        }
        let accessibility = model.permissions[.accessibility]
        if model.settings.inputEnabled, accessibility.isProblem {
            items.append(.init(id: "ax", symbol: "hand.tap.fill", tint: .blue,
                               title: accessibility.readinessTitle(.accessibility),
                               actionTitle: accessibility.shortActionTitle, action: .permission(.accessibility)))
        }
        if network.serviceAddressConflict != nil {
            items.append(.init(id: "conflict", symbol: "exclamationmark.triangle.fill", tint: .orange,
                               title: "SideDisplay is using the same network. Quit it, then check again.",
                               actionTitle: "Check Again", action: .recheckNetwork))
        }
        switch network.topology {
        case .offline:
            items.append(.init(id: "sharing", symbol: "personalhotspot", tint: .green,
                               title: "Internet Sharing is off",
                               actionTitle: "Turn On…", action: .openInternetSharing))
        case .phoneHotspot:
            items.append(.init(id: "phone", symbol: "iphone.radiowaves.left.and.right", tint: .orange,
                               title: "A phone hotspot can’t reach your Tesla",
                               actionTitle: "Turn On…", action: .openInternetSharing))
        case .macHotspot, .router:
            break
        }
        if !network.helperInstalled {
            items.append(.init(id: "helper", symbol: "wrench.and.screwdriver.fill", tint: .gray,
                               title: "One-time helper install needed",
                               actionTitle: "Install", action: .installHelper))
        }
        return items
    }
}
