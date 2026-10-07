import CoreGraphics
import DashcastContracts
import Foundation

// One step model for both ways of turning on Internet Sharing: "Do It for Me" (SharingAutomation
// presses each control) and "Guide Me" (SharingGuide points at it and waits for the user's click).

/// The steps in System Settings, in order.
enum SharingStep: Int, CaseIterable, Comparable {
    case openPane
    case openDetails
    /// Sharing is on but needs changing: macOS locks the settings while it's on.
    case turnOffToEdit
    case shareFrom
    case toWiFi
    case wifiOptions
    case networkName
    case channel
    case password
    case confirmOptions
    case turnOn
    case confirmTurnOn
    case done
    /// Not a step of its own: macOS asks for Touch ID or the password.
    case authorize

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The row of the coach panel's checklist it belongs to (nil: before the checklist starts).
    var checklistItem: ChecklistItem.ID? {
        switch self {
        case .openPane, .openDetails, .authorize: nil
        case .shareFrom: .shareFrom
        case .toWiFi: .toWiFi
        case .wifiOptions, .networkName: .networkName
        case .channel: .channel
        case .password, .confirmOptions: .password
        case .turnOffToEdit, .turnOn, .confirmTurnOn, .done: .turnOn
        }
    }

    /// The line of the "Do It for Me" progress list it belongs to.
    var stage: SharingStage {
        switch self {
        case .openPane, .openDetails, .turnOffToEdit, .authorize: .open
        case .shareFrom: .shareFrom
        case .toWiFi: .wifi
        case .wifiOptions, .networkName, .channel, .password, .confirmOptions: .options
        case .turnOn, .confirmTurnOn, .done: .turnOn
        }
    }
}

/// The lines of the "Do It for Me" progress list.
enum SharingStage: Int, CaseIterable, Comparable, Identifiable {
    case open, shareFrom, wifi, options, turnOn

    var id: Self { self }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - Plan

/// What Internet Sharing should be set to.
struct SharingPlan: Equatable {
    /// "Share your connection from", best first: the connected cables, else an always-present port.
    var shareFrom: [String]
    /// No cable is connected: sharing from a port that's always there is experimental (macOS may
    /// not start the hotspot without a live connection to share).
    var withoutCable: Bool
    /// Ports that are plugged in but disconnected right now (sharing from one never starts).
    var disconnected: [String] = []
    var networkName = HotspotSetup.suggestedName
    /// 5 GHz, best first; any channel from 36 up is fine as it is.
    var channels = ["149", "36"]
    var password: String

    /// Always there with no cable (a bridge over the Thunderbolt ports).
    static let alwaysPresent = ["Thunderbolt Bridge"]

    init(hotspot: HotspotStatus, password: String) {
        let connected = hotspot.uplinks.filter(\.connected).map(\.name)
        withoutCable = connected.isEmpty
        shareFrom = connected.isEmpty ? Self.alwaysPresent : connected
        disconnected = (hotspot.uplinks + [hotspot.shareFrom].compactMap { $0 })
            .filter { !$0.connected && !Self.isAlwaysPresent($0.name) }.map(\.name)
        self.password = password
    }

    static func isAlwaysPresent(_ name: String) -> Bool {
        alwaysPresent.contains { SharingText.same($0, name) } || SharingText.normalized(name).hasPrefix("thunderbolt bridge")
    }

    /// The first choice, for instructions ("Choose iPhone USB").
    var preferredShareFrom: String { shareFrom.first ?? Self.alwaysPresent[0] }

    /// The popup already says something that works.
    func acceptsShareFrom(_ value: String?) -> Bool {
        guard let value, !SharingText.isWiFi(value) else { return false }
        if shareFrom.contains(where: { SharingText.same($0, value) }) { return true }
        // No cable: any port that's there will do, just not one known to be unplugged.
        return withoutCable && !disconnected.contains { SharingText.same($0, value) }
    }

    /// Which of a menu's items to pick: a planned one, else (no cable) any port but Wi‑Fi.
    func shareFromChoice(among items: [String]) -> String? {
        for wanted in shareFrom {
            if let item = items.first(where: { SharingText.same($0, wanted) }) { return item }
        }
        guard withoutCable else { return nil }
        return items.first { item in !SharingText.isWiFi(item) && !disconnected.contains { SharingText.same($0, item) } }
    }

    /// A 5 GHz channel is already set.
    func acceptsChannel(_ value: String?) -> Bool {
        guard let value, let channel = Int(value.trimmingCharacters(in: .whitespaces)) else { return false }
        return channel >= 36
    }

    func channelChoice(among items: [String]) -> String? {
        for wanted in channels {
            if let item = items.first(where: { SharingText.same($0, wanted) }) { return item }
        }
        return nil
    }
}

// MARK: - Guidance

/// What to do next in System Settings, worked out from its Accessibility tree alone (pure).
struct SharingGuidance: Equatable {
    let step: SharingStep
    /// The bubble's text: "Click ⓘ", "Choose iPhone USB".
    let instruction: String
    var detail: String?
    /// Shown big in the bubble and offered as Copy in the panel (the password).
    var copy: String?
    /// The control to ring, in Accessibility coordinates. nil = nothing to point at.
    var target: CGRect?
    /// System Settings' window when this was read (the ring follows it as it moves).
    var window: CGRect?
}

enum SharingGuide {
    /// What Dashcast remembers between looks at the screen.
    struct Memory: Equatable {
        /// Wi‑Fi Options… was closed with everything filled in (OK, presumably: Cancel can't be told apart).
        var optionsSubmitted = false
        /// The network name and password are known to be set (Dashcast set them earlier).
        var optionsKnownSet = false
        /// Wi‑Fi Options… is open with the name and a password of the right length typed.
        var optionsFilled = false
    }

    /// The next thing to do. nil = nothing left in System Settings (sharing is on).
    static func next(_ screen: SharingScreen, plan: SharingPlan, memory: Memory) -> SharingGuidance? {
        guard let window = screen.window else {
            return SharingGuidance(step: .openPane, instruction: "Open Internet Sharing")
        }
        func guide(_ step: SharingStep, _ instruction: String, _ target: UINode?, detail: String? = nil,
                   copy: String? = nil) -> SharingGuidance {
            SharingGuidance(step: step, instruction: instruction, detail: detail, copy: copy, target: target?.frame,
                            window: window.frame)
        }

        if let authorization = screen.authorization {
            return guide(.authorize, "Use Touch ID or your password", authorization,
                         detail: "macOS asks before changing Internet Sharing.")
        }
        if let menu = screen.menu {
            let items = SharingScreen.menuItems(menu)
            let titles = items.compactMap(\.title)
            if screen.options != nil, let channel = plan.channelChoice(among: titles) {
                return guide(.channel, "Choose \(channel)", items.first { $0.title == channel })
            }
            if screen.details != nil, screen.options == nil, let choice = plan.shareFromChoice(among: titles) {
                return guide(.shareFrom, "Choose \(choice)", items.first { $0.title == choice })
            }
        }
        if let alert = screen.alert {
            if alert.isTurnOn {
                return guide(.confirmTurnOn, "Click Turn On", alert.confirm)
            }
            return guide(.turnOffToEdit, "Click \(alert.confirm?.text ?? "OK")", alert.confirm)
        }
        if let options = screen.options {
            if !SharingText.same(options.nameField?.value, plan.networkName) {
                return guide(.networkName, "Type \(plan.networkName)", options.nameField, detail: "The name your Tesla sees.",
                             copy: plan.networkName)
            }
            if let channel = options.channel, !plan.acceptsChannel(channel.value) {
                return guide(.channel, "Choose \(plan.channels[0])", channel, detail: "5 GHz is faster.")
            }
            if let field = options.password, field.value?.count != plan.password.count {
                return guide(.password, "Type this password:", field, detail: "You’ll type it in your Tesla too.",
                             copy: plan.password)
            }
            return guide(.confirmOptions, "Click OK", options.ok)
        }
        if let details = screen.details {
            let shareFromOK = plan.acceptsShareFrom(details.shareFrom?.value)
            let wifi = details.wifiToggle
            let wifiOn = wifi?.isOn == true
            if details.isOn {
                if !shareFromOK || !wifiOn {
                    return guide(.turnOffToEdit, "Turn off Internet Sharing", details.masterSwitch,
                                 detail: "macOS locks these settings while it’s on.")
                }
                return guide(.done, "Click Done", details.done)
            }
            if !shareFromOK {
                return guide(.shareFrom, "Choose \(plan.preferredShareFrom)", details.shareFrom,
                             detail: plan.withoutCable ? "No cable plugged in: this is experimental." : nil)
            }
            if !wifiOn {
                return guide(.toWiFi, "Turn on Wi‑Fi", wifi ?? details.list,
                             detail: wifi == nil ? "Scroll down the list to Wi‑Fi." : "Leave the others as they are.")
            }
            if !memory.optionsSubmitted, !memory.optionsKnownSet {
                return guide(.wifiOptions, "Click Wi‑Fi Options…", details.wifiOptions)
            }
            return guide(.turnOn, "Turn on Internet Sharing", details.masterSwitch)
        }
        // The Sharing pane, no sheet open.
        if let info = screen.infoButton {
            if screen.rowSwitch?.isOn == true, memory.optionsKnownSet || memory.optionsSubmitted { return nil }
            return guide(.openDetails, "Click ⓘ", info, detail: "Next to Internet Sharing.")
        }
        return SharingGuidance(step: .openPane, instruction: "Open Internet Sharing",
                               detail: "General ▸ Sharing ▸ Internet Sharing", window: window.frame)
    }

    /// Keeps `memory` current as the screen changes: notes Wi‑Fi Options… closing fully filled in.
    static func remember(_ screen: SharingScreen, plan: SharingPlan, memory: inout Memory) {
        if let options = screen.options {
            memory.optionsFilled = SharingText.same(options.nameField?.value, plan.networkName)
                && options.password?.value?.count == plan.password.count
        } else if memory.optionsFilled, screen.authorization == nil {
            memory.optionsSubmitted = true
            memory.optionsFilled = false
        }
    }
}
