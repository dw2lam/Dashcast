import DashcastContracts
import Foundation

/// The "Set Up Car Hotspot" checklist, worked out from live state alone (pure, so it's testable).
///
/// Five steps, each ticking itself: internet for this Mac (optional), Internet Sharing on, the
/// Tesla joined, its connectivity check answered, the browser connected. A later step being done
/// proves the earlier ones (a car can only join a hotspot that's on), so the list never shows a
/// gap. The first step that isn't done is the current one.
struct HotspotSetup: Equatable {
    enum Step: Int, CaseIterable, Identifiable, Comparable {
        case internet, sharing, join, check, browser

        var id: Self { self }
        var number: Int { rawValue + 1 }

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Where this Mac's own internet comes from while its Wi‑Fi is the hotspot.
    enum Internet: Equatable {
        /// An iPhone (USB), Ethernet or Bluetooth connection is up: the car gets internet too.
        case cable(name: String)
        /// The user chose to go without (Dashcast itself needs none).
        case without
        /// The Mac's internet is the Wi‑Fi the hotspot needs; `phone` = it's an iPhone's hotspot.
        case onWiFi(phone: Bool)
        /// No internet at all right now.
        case none
    }

    enum Sharing: Equatable {
        case off
        /// The switch is on in System Settings; the bridge isn't up yet.
        case starting
        case on
    }

    enum Join: Equatable {
        case waiting
        /// Something that isn't a Tesla joined (or a Tesla we can't recognise).
        case otherDevice(HotspotStatus.Device)
        /// nil device = we know the car is there (it checked in or connected) without seeing it.
        case joined(HotspotStatus.Device?)
    }

    enum Check: Equatable {
        /// Nothing heard yet. `ready` = Dashcast is listening, so it will answer.
        case waiting(ready: Bool)
        /// The car joined a while ago and never checked with Dashcast.
        case noAnswer(ready: Bool)
        case answered
    }

    struct Inputs: Equatable {
        var network = NetworkStatus()
        var lastConnectivityCheck: Date?
        /// The car's browser is connected (`state.car != nil`).
        var casting = false
        /// The service is listening (waiting or streaming).
        var serviceRunning = false
        /// The user picked "Continue Without Internet".
        var withoutInternet = false
        /// When the Tesla was first seen on the hotspot (for the "no check yet" hint).
        var carSeenAt: Date?
        /// The password Dashcast suggests for the hotspot (nil: the user picks one).
        var password: String?
        /// Dashcast saved `password` in Wi‑Fi Options… and the network name still matches.
        var passwordSet = false
        var now = Date()
    }

    /// How long after the car joins a missing connectivity check counts as a problem.
    static let checkGrace: TimeInterval = 20
    /// A check older than this only counts while the car is still on the hotspot.
    static let checkFreshness: TimeInterval = 10 * 60
    static let suggestedName = "Dashcast"
    static let suggestedChannels = "149 (or 36)"

    let internet: Internet
    let sharing: Sharing
    let join: Join
    let check: Check
    let casting: Bool
    let checklist: [ChecklistItem]
    let done: Set<Step>
    /// The step to work on; nil once everything is done.
    let current: Step?
    /// The hotspot's network name, as set (nil until it's been set once).
    let networkName: String?
    /// Turning on sharing will drop this Mac's Wi‑Fi connection (and its internet with it).
    let dropsWiFi: Bool

    init(_ inputs: Inputs) {
        let hotspot = inputs.network.hotspot
        let connectedUplink = hotspot.uplinks.first { $0.connected }
        networkName = hotspot.networkName.flatMap { $0.isEmpty ? nil : $0 }
        casting = inputs.casting

        // Sharing
        if hotspot.sharingOn || inputs.network.topology == .macHotspot {
            sharing = .on
        } else if hotspot.enabledInSettings {
            sharing = .starting
        } else {
            sharing = .off
        }

        // The car and its connectivity check
        let car = hotspot.car
        let checkFresh = inputs.lastConnectivityCheck.map { check in
            car != nil || inputs.now.timeIntervalSince(check) < Self.checkFreshness
        } ?? false
        if let car {
            join = .joined(car)
        } else if checkFresh || inputs.casting {
            join = .joined(nil)
        } else if let other = hotspot.devices.first {
            join = .otherDevice(other)
        } else {
            join = .waiting
        }
        if checkFresh || inputs.casting {
            check = .answered
        } else if car != nil, let seen = inputs.carSeenAt, inputs.now.timeIntervalSince(seen) >= Self.checkGrace {
            check = .noAnswer(ready: inputs.serviceRunning)
        } else {
            check = .waiting(ready: inputs.serviceRunning)
        }

        // Internet for this Mac
        if let connectedUplink {
            internet = .cable(name: connectedUplink.name)
        } else if inputs.withoutInternet {
            internet = .without
        } else if hotspot.wifiIsUplink {
            internet = .onWiFi(phone: hotspot.wifiUplinkIsPhone)
        } else {
            internet = .none
        }
        dropsWiFi = hotspot.wifiIsUplink && sharing != .on

        checklist = ChecklistItem.items(for: hotspot, connectedUplink: connectedUplink, sharing: sharing,
                                        password: inputs.password, passwordSet: inputs.passwordSet)

        // Done, back to front: each later step proves the ones before it.
        var done: Set<Step> = []
        if inputs.casting { done.insert(.browser) }
        if check == .answered || done.contains(.browser) { done.insert(.check) }
        if case .joined = join { done.insert(.join) }
        if done.contains(.check) { done.insert(.join) }
        if sharing == .on || done.contains(.join) { done.insert(.sharing) }
        switch internet {
        case .cable, .without: done.insert(.internet)
        case .onWiFi, .none: if done.contains(.sharing) { done.insert(.internet) }
        }
        self.done = done
        current = Step.allCases.first { !done.contains($0) }
    }

    func isDone(_ step: Step) -> Bool { done.contains(step) }

    /// How often the open Car Hotspot window re-reads the network. Every 2 s while the hotspot is up
    /// and the car steps aren't done (a car joining shows only in bootpd's leases and the ARP table,
    /// which nothing reports), while System Settings is being set up, or while "Do It for Me" waits
    /// for the hotspot to start ("it hasn't started" ticks on `now`); otherwise every 10 s, as a
    /// safety net: Internet Sharing and the cables are watched and pushed as they change.
    static func pollInterval(_ setup: HotspotSetup, assistant: SharingAssistant.Phase) -> TimeInterval {
        switch assistant {
        case .automating, .guiding: return 2
        case .finished where setup.sharing != .on: return 2
        case .idle, .finished: return setup.sharing != .off && !setup.isComplete ? 2 : 10
        }
    }

    var isComplete: Bool { current == nil }

    /// What to type in the car's Wi‑Fi list.
    var displayName: String { networkName ?? Self.suggestedName }
}

// MARK: - Internet Sharing checklist

/// One setting in System Settings ▸ Sharing ▸ Internet Sharing, ticked from the live configuration.
struct ChecklistItem: Identifiable, Equatable {
    enum ID: String { case shareFrom, toWiFi, networkName, channel, password, turnOn }

    enum Status: Equatable {
        case done
        case todo
        /// Recommended, not required (the channel).
        case suggestion
        /// Dashcast can't see it (the password).
        case unknown
        /// Happening now (sharing is starting up).
        case working
    }

    let id: ID
    /// What System Settings calls it.
    let label: String
    /// What to pick.
    let value: String
    var note: String?
    let status: Status
    /// Offered as a Copy button.
    var copy: String?
    /// A line above this item that leads into a group ("In Wi‑Fi Options…").
    var heading: String?

    static func items(for hotspot: HotspotStatus, connectedUplink: HotspotStatus.Uplink?,
                      sharing: HotspotSetup.Sharing, password: String? = nil, passwordSet: Bool = false) -> [ChecklistItem] {
        var items: [ChecklistItem] = []

        // Share your connection from
        if let connectedUplink {
            let matches = hotspot.shareFrom?.interface == connectedUplink.interface
            items.append(.init(id: .shareFrom, label: "Share your connection from", value: connectedUplink.name,
                               note: matches ? nil : hotspot.shareFrom.map { "Now set to \($0.name)." },
                               status: matches ? .done : .todo))
        } else {
            // No cable: nothing to share, so any port that's there will do (macOS never starts the
            // hotspot sharing from one that's unplugged). An always-present one is experimental.
            let plan = SharingPlan(hotspot: hotspot, password: "")
            let current = hotspot.shareFrom.map(\.name)
            let fine = plan.acceptsShareFrom(current)
            items.append(.init(id: .shareFrom, label: "Share your connection from",
                               value: fine ? current ?? "" : plan.preferredShareFrom,
                               note: fine ? nil : "No cable plugged in, so this is experimental.",
                               status: fine ? .done : .todo))
        }

        items.append(.init(id: .toWiFi, label: "To devices using", value: "Wi‑Fi",
                           status: hotspot.sharesToWiFi ? .done : .todo))

        let name = hotspot.networkName.flatMap { $0.isEmpty ? nil : $0 }
        items.append(.init(id: .networkName, label: "Network Name", value: name ?? HotspotSetup.suggestedName,
                           note: name != nil && name != HotspotSetup.suggestedName ? "Any name works." : nil,
                           status: name != nil ? .done : .todo, copy: name == nil ? HotspotSetup.suggestedName : nil,
                           heading: "Click Wi‑Fi Options…"))

        let channel = hotspot.channel ?? 0
        let fiveGHz = channel >= 36
        items.append(.init(id: .channel, label: "Channel", value: fiveGHz ? "\(channel)" : HotspotSetup.suggestedChannels,
                           note: fiveGHz ? nil : "5 GHz is faster. Optional.",
                           status: fiveGHz ? .done : .suggestion))

        if let password {
            items.append(.init(id: .password, label: "Password", value: password,
                               note: passwordSet ? nil : "You’ll type it in your Tesla too.",
                               status: passwordSet ? .done : .todo, copy: passwordSet ? nil : password))
        } else {
            items.append(.init(id: .password, label: "Password", value: "One you’ll type in the car", status: .unknown))
        }

        let turnOn: Status
        switch sharing {
        case .on: turnOn = .done
        case .starting: turnOn = .working
        case .off: turnOn = .todo
        }
        items.append(.init(id: .turnOn, label: "Then turn on Internet Sharing", value: "", status: turnOn))
        return items
    }
}

// MARK: - Getting ready on its own

/// When the Mac's hotspot comes up and Dashcast is idle, start listening so the car's connectivity
/// check is answered whatever order things happen in. Only on the off → on transition, so a Stop
/// while the hotspot stays on is respected.
enum AutoReady {
    static func isHotspotUp(_ network: NetworkStatus) -> Bool {
        network.hotspot.sharingOn || network.topology == .macHotspot
    }

    static func shouldStart(wasUp: Bool, isUp: Bool, enabled: Bool, phase: ServicePhase,
                            screenRecording: PermissionHealth, transitioning: Bool) -> Bool {
        guard enabled, !wasUp, isUp, phase == .idle, !transitioning else { return false }
        // A broken grant would only give the car a black screen; the readiness list shows the fix.
        return !screenRecording.isProblem
    }
}
