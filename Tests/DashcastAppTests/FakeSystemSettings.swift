import AppKit
@testable import Dashcast

// Fakes for the Internet Sharing automation: Accessibility trees loaded from the dumps captured on
// macOS 27 (AXMaps/), and a scripted System Settings that changes as its controls are pressed.

/// A node in a fake Accessibility tree.
final class FakeNode: UINode {
    var role: String
    var subrole: String?
    var identifier: String?
    var title: String?
    var axDescription: String?
    var value: String?
    var isEnabled = true
    var isFocused = false
    var frame = CGRect.zero
    var kids: [FakeNode] = []
    var children: [UINode] { kids }
    /// The actions the dump listed.
    var actions: [String] = []
    var onPerform: ((String) -> Bool)?
    var onSetValue: ((String) -> Bool)?
    var onFocus: (() -> Bool)?

    init(_ role: String, subrole: String? = nil, identifier: String? = nil, title: String? = nil,
         description: String? = nil, value: String? = nil, enabled: Bool = true, focused: Bool = false,
         frame: CGRect = .zero, children: [FakeNode] = [], press: (() -> Void)? = nil) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
        axDescription = description
        self.value = value
        isEnabled = enabled
        isFocused = focused
        self.frame = frame
        kids = children
        if let press {
            onPerform = { action in
                guard action == "AXPress" else { return false }
                press()
                return true
            }
        }
    }

    func perform(_ action: String) -> Bool { onPerform?(action) ?? actions.contains(action) }
    func setValue(_ value: String) -> Bool { onSetValue?(value) ?? false }
    func setFocused() -> Bool { onFocus?() ?? false }

    /// The first node anywhere below (or at) this one.
    func find(_ match: (FakeNode) -> Bool) -> FakeNode? {
        if match(self) { return self }
        for kid in kids {
            if let found = kid.find(match) { return found }
        }
        return nil
    }

    func removeIdentifiers() {
        identifier = nil
        kids.forEach { $0.removeIdentifiers() }
    }
}

// MARK: - Dumps

/// Loads the dumps in AXMaps/: one element per line, two spaces of indent per level,
/// `Role Key=value … (x,y wxh)` in Accessibility coordinates. A value can contain spaces; a line
/// that doesn't start with a role continues the one before (one toolbar item has newlines in it).
enum AXDump {
    static let keys = ["Subrole", "Title", "Description", "Identifier", "Value", "Help", "PlaceholderValue", "Enabled", "actions"]

    static func load(_ name: String) throws -> FakeNode {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "AXMaps") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return parse(try String(contentsOf: url, encoding: .utf8))
    }

    /// An application element holding the dump's top-level elements (its windows).
    static func parse(_ text: String) -> FakeNode {
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("AX") || trimmed.hasPrefix("? ") || lines.isEmpty {
                lines.append(line)
            } else {
                lines[lines.count - 1] += "\n" + line
            }
        }
        let root = FakeNode("AXApplication")
        var stack: [(depth: Int, node: FakeNode)] = [(-1, root)]
        for line in lines {
            let depth = line.prefix { $0 == " " }.count / 2
            let node = element(String(line.drop { $0 == " " }))
            while let last = stack.last, last.depth >= depth { stack.removeLast() }
            stack.last?.node.kids.append(node)
            stack.append((depth, node))
        }
        return root
    }

    private static func element(_ line: String) -> FakeNode {
        var body = line
        var frame = CGRect.zero
        if let match = body.range(of: #"\((-?\d+),(-?\d+) (-?\d+)x(-?\d+)\)\s*$"#, options: .regularExpression) {
            let numbers = body[match].split { !"-0123456789".contains($0) }.compactMap { Double($0) }
            if numbers.count == 4 { frame = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]) }
            body = String(body[..<match.lowerBound])
        }
        let role = String(body.prefix { $0 != " " })
        let node = FakeNode(role, frame: frame)
        let rest = String(body.dropFirst(role.count))
        // " Key=" boundaries, in order.
        let pattern = " (" + keys.joined(separator: "|") + ")="
        let regex = try! NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: rest, range: NSRange(rest.startIndex..., in: rest))
        for (index, match) in matches.enumerated() {
            let key = String(rest[Range(match.range(at: 1), in: rest)!])
            let start = Range(match.range, in: rest)!.upperBound
            let end = index + 1 < matches.count ? Range(matches[index + 1].range, in: rest)!.lowerBound : rest.endIndex
            let value = String(rest[start..<end]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "Subrole": node.subrole = value
            case "Title": node.title = value
            case "Description": node.axDescription = value
            case "Identifier": node.identifier = value
            case "Value": node.value = value.isEmpty ? nil : value
            case "Enabled": node.isEnabled = value != "0"
            case "actions": node.actions = value.components(separatedBy: ",")
            default: break
            }
        }
        return node
    }
}

// MARK: - Scripted System Settings

/// System Settings ▸ Internet Sharing as a state machine, laid out like the captured macOS 27 tree:
/// pressing a control changes the state, and every look builds a fresh tree from it.
@MainActor
final class FakeSystemSettings: SharingEnvironment {
    enum Menu { case shareFrom, channel }
    enum Field { case name, password }

    // What it shows.
    var running = false
    var detailsOpen = false
    var optionsOpen = false
    var confirmOpen = false
    var menu: Menu?
    var sharingOn = false
    /// The popup's value, and the setting macOS has saved (the "To devices using" list leaves it out).
    var shareFrom = "Wi-Fi"
    var savedShareFrom = "Wi-Fi"
    var ports = ["USB 10/100/1G/2.5G LAN", "Thunderbolt Bridge", "Ethernet Adapter (en3)", "iPhone USB", "Wi-Fi"]
    var toggles: [String: Bool] = [:]
    var networkName = "Jane’s MacBook Pro"
    var channel = "11"
    var channels = ["Automatic", "1", "6", "11", "36", "149"]
    var password = "oldpass1"
    var nameField = ""
    var passwordField = ""
    var focused: Field?
    /// Looks left before the Touch ID prompt is answered.
    var authLooks = 0

    // Knobs.
    var asksToAuthorize = true
    var authLooksPerPrompt = 3
    /// The user cancels the Touch ID prompt.
    var authCancels = false
    var menuOpens = true
    /// Fields take AXValue (else it's accepted and ignored: the fallback types).
    var acceptsAXValue = true
    var frontmost = true
    var trusted = true
    var locked = false
    /// Wi‑Fi joins "To devices using" only this many looks after the share-from change is saved.
    var wifiHiddenLooks = 0
    /// Runs as the automation (or guidance) starts each wait: e.g. the user pressing Stop then.
    var onSleep: (() -> Void)?

    // What happened.
    private(set) var typed: [String] = []
    private(set) var looks = 0
    private var wifiHidden = false

    /// Everything a press, a value or a keystroke can change.
    var settings: String {
        "\(detailsOpen) \(optionsOpen) \(confirmOpen) \(String(describing: menu)) \(sharingOn) \(shareFrom) \(savedShareFrom) "
            + "\(toggles.sorted { $0.key < $1.key }) \(networkName) \(channel) \(password) \(nameField) \(passwordField) "
            + "\(String(describing: focused)) \(typed)"
    }

    static let window = CGRect(x: 380, y: 276, width: 740, height: 625)

    // MARK: SharingEnvironment

    func settingsApp() -> UINode? {
        guard running else { return nil }
        looks += 1
        if authLooks > 0 {
            authLooks -= 1
            if authLooks == 0 {
                if authCancels { shareFrom = savedShareFrom } else { savedShareFrom = shareFrom }
            }
        }
        wifiHidden = !SharingText.isWiFi(savedShareFrom) && wifiHiddenLooks > 0
        if wifiHidden { wifiHiddenLooks -= 1 }
        return tree()
    }

    func openInternetSharing() { running = true }
    var isTrusted: Bool { trusted }
    var isScreenLocked: Bool { locked }
    var isSettingsFrontmost: Bool { frontmost }
    /// How often Dashcast brought System Settings to the front.
    var activations = 0
    /// Activating brings it to the front (false: something else keeps the focus).
    var activationWorks = true
    /// A menu is on screen that the tree doesn't show (opened by a press, not yet in the tree).
    var hiddenMenuOpen = false
    var escapes = 0
    func activateSettings() {
        activations += 1
        if activationWorks { frontmost = true }
    }
    func pressEscape() {
        guard frontmost else { return }
        escapes += 1
        menu = nil
        hiddenMenuOpen = false
    }
    var isSettingsMenuOpen: Bool { menu != nil || hiddenMenuOpen }
    func sleep(_ seconds: TimeInterval) async throws {
        onSleep?()
        try await Task.sleep(nanoseconds: 500_000)
    }

    func type(_ text: String) -> Bool {
        guard frontmost else { return false }
        typed.append(text)
        switch focused {
        case .name: nameField = text
        case .password: passwordField = text
        case nil: return false
        }
        return true
    }

    // MARK: Behaviour

    private var canTurnOn: Bool { !SharingText.isWiFi(savedShareFrom) && toggles["Wi-Fi"] == true }
    private var authorizing: Bool { authLooks > 0 }

    private func choose(_ item: String, in which: Menu) {
        menu = nil
        switch which {
        case .shareFrom:
            guard item != shareFrom else { return }
            shareFrom = item
            if asksToAuthorize { authLooks = authLooksPerPrompt } else { savedShareFrom = item }
        case .channel:
            channel = item
        }
    }

    private func pressMaster() {
        if sharingOn {
            sharingOn = false
        } else if canTurnOn {
            confirmOpen = true
        }
    }

    private func field(_ which: Field) -> (FakeNode) -> Void {
        { [unowned self] node in
            node.isFocused = focused == which
            node.onFocus = { [unowned self] in focused = which; return true }
            node.onSetValue = { [unowned self] text in
                guard acceptsAXValue else { return true }
                switch which {
                case .name: nameField = text
                case .password: passwordField = text
                }
                return true
            }
        }
    }

    // MARK: Tree

    private func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }

    private func tree() -> FakeNode {
        let window = FakeNode("AXWindow", subrole: "AXStandardWindow", identifier: "Main", title: "Sharing", frame: Self.window)
        window.kids.append(FakeNode("AXGroup", subrole: "AXHostingView", frame: Self.window, children: [
            FakeNode("AXOutline", identifier: "com.apple.settings.sidebar.collectionView", description: "Sidebar", frame: r(380, 374, 232, 527), children: [
                FakeNode("AXButton", identifier: "com.apple.settings.general", description: "General", frame: r(397, 640, 78, 24)),
            ]),
            FakeNode("AXGroup", frame: r(632, 633, 468, 158), children: [
                FakeNode("AXStaticText", value: "Internet Sharing", frame: r(642, 749, 139, 32)),
                FakeNode("AXButton", identifier: "Internet SharingToggle.infoButton", description: "Show Detail",
                         frame: r(1071, 756, 17, 17)) { [unowned self] in detailsOpen = true },
                FakeNode("AXCheckBox", subrole: "AXSwitch", identifier: "Internet SharingToggle", value: sharingOn ? "1" : "0",
                         frame: r(1024, 757, 36, 16)) { [unowned self] in pressMaster() },
            ]),
        ]))
        if detailsOpen { window.kids.append(details()) }
        return FakeNode("AXApplication", children: [window])
    }

    private func details() -> FakeNode {
        let sheet = FakeNode("AXSheet", frame: r(515, 331, 470, 514))
        let popup = FakeNode("AXPopUpButton", value: shareFrom, enabled: !sharingOn, frame: r(836, 447, 119, 24)) { [unowned self] in
            if menuOpens { menu = .shareFrom }
        }
        if menu == .shareFrom { popup.kids.append(menuNode(ports, below: popup.frame, which: .shareFrom)) }

        let listed = ports.filter { $0 != savedShareFrom && !(wifiHidden && SharingText.isWiFi($0)) }
        let rows = listed.enumerated().map { index, port in
            let y = 525.0 + Double(index) * 24
            return FakeNode("AXRow", subrole: "AXOutlineRow", frame: r(535, y, 430, 24), children: [
                FakeNode("AXStaticText", value: port, enabled: !sharingOn, frame: r(545, y + 4, 120, 16)),
                FakeNode("AXCheckBox", subrole: "AXToggle", description: port, value: toggles[port] == true ? "1" : "0",
                         enabled: !sharingOn, frame: r(919, y + 4, 36, 16)) { [unowned self] in toggles[port] = !(toggles[port] ?? false) },
            ])
        }
        var content: [FakeNode] = [
            FakeNode("AXGroup", frame: r(535, 351, 430, 80), children: [
                FakeNode("AXStaticText", value: "Internet Sharing: \(sharingOn ? "On" : "Off")", frame: r(587, 361, 124, 16)),
                FakeNode("AXCheckBox", subrole: "AXSwitch", value: sharingOn ? "1" : "0", enabled: canTurnOn || sharingOn,
                         frame: r(911, 360, 44, 20)) { [unowned self] in pressMaster() },
            ]),
            FakeNode("AXGroup", frame: r(535, 441, 430, 37), children: [
                FakeNode("AXStaticText", value: "Share your connection from", frame: r(545, 451, 168, 16)),
                popup,
            ]),
            FakeNode("AXGroup", frame: r(535, 488, 430, 229), children: [
                FakeNode("AXStaticText", value: "To devices using", frame: r(545, 498, 101, 16)),
                FakeNode("AXScrollArea", frame: r(535, 525, 430, Double(rows.count) * 24), children: [
                    FakeNode("AXOutline", frame: r(535, 525, 430, Double(rows.count) * 24), children: rows),
                ]),
            ]),
        ]
        if toggles["Wi-Fi"] == true, !SharingText.isWiFi(savedShareFrom) {
            content.append(FakeNode("AXButton", description: "Wi-Fi Options…", enabled: !sharingOn, frame: r(847, 727, 118, 24)) { [unowned self] in
                optionsOpen = true
                nameField = networkName
                passwordField = password
            })
        }
        sheet.kids = [FakeNode("AXGroup", subrole: "AXHostingView", frame: sheet.frame, children: [
            FakeNode("AXScrollArea", frame: r(515, 331, 470, 448), children: content),
            FakeNode("AXButton", description: "Help", frame: r(535, 801, 24, 24)),
            FakeNode("AXButton", description: "Done", frame: r(901, 800, 64, 24)) { [unowned self] in
                if !optionsOpen, !confirmOpen, !authorizing { detailsOpen = false }
            },
        ])]
        if optionsOpen { sheet.kids.append(options()) }
        if authorizing { sheet.kids.append(authorization()) }
        if confirmOpen { sheet.kids.append(confirm()) }
        return sheet
    }

    private func options() -> FakeNode {
        let name = FakeNode("AXTextField", identifier: "_NS:103", value: nameField.isEmpty ? nil : nameField, frame: r(697, 511, 259, 23))
        field(.name)(name)
        let secure = FakeNode("AXTextField", subrole: "AXSecureTextField", identifier: "_NS:217",
                              value: passwordField.isEmpty ? nil : String(repeating: "\u{F79A}", count: passwordField.count),
                              frame: r(697, 614, 259, 26))
        field(.password)(secure)
        let channelPopup = FakeNode("AXPopUpButton", identifier: "_NS:22", value: channel, frame: r(696, 542, 260, 26)) { [unowned self] in
            if menuOpens { menu = .channel }
        }
        if menu == .channel { channelPopup.kids.append(menuNode(channels, below: channelPopup.frame, which: .channel)) }
        return FakeNode("AXSheet", frame: r(525, 409, 450, 359), children: [
            FakeNode("AXButton", identifier: "_NS:133", title: "OK", enabled: passwordField.count >= 8, frame: r(884, 724, 72, 26)) { [unowned self] in
                networkName = nameField
                password = passwordField
                optionsOpen = false
            },
            FakeNode("AXButton", identifier: "_NS:8", title: "Cancel", frame: r(802, 724, 72, 26)) { [unowned self] in optionsOpen = false },
            FakeNode("AXStaticText", identifier: "_NS:163", value: "Configure an internet-sharing network.", frame: r(630, 428, 326, 19)),
            FakeNode("AXStaticText", identifier: "_NS:115", value: "Network Name:", frame: r(595, 514, 95, 18)),
            name,
            channelPopup,
            FakeNode("AXStaticText", identifier: "_NS:37", value: "Channel:", frame: r(634, 548, 55, 18)),
            FakeNode("AXPopUpButton", identifier: "_NS:277", value: "WPA2/WPA3 Personal", frame: r(696, 580, 260, 26)),
            FakeNode("AXStaticText", identifier: "_NS:289", value: "Security:", frame: r(634, 586, 56, 18)),
            FakeNode("AXStaticText", identifier: "_NS:228", value: "Password:", frame: r(627, 617, 64, 21)),
            secure,
            FakeNode("AXStaticText", identifier: "_NS:257", value: "The password must contain at least 8 characters.", frame: r(697, 646, 259, 15)),
            FakeNode("AXCheckBox", identifier: "_NS:304", title: "Show password", value: "0", frame: r(697, 668, 119, 18)),
        ])
    }

    private func menuNode(_ items: [String], below popup: CGRect, which: Menu) -> FakeNode {
        let menu = FakeNode("AXMenu", frame: r(popup.minX, popup.maxY, popup.width + 40, Double(items.count) * 22))
        menu.kids = items.enumerated().map { index, item in
            FakeNode("AXMenuItem", title: item, frame: r(popup.minX, popup.maxY + Double(index) * 22, popup.width + 40, 22)) { [unowned self] in
                choose(item, in: which)
            }
        }
        menu.onPerform = { [unowned self] action in
            guard action == "AXCancel" else { return false }
            self.menu = nil
            return true
        }
        return menu
    }

    private func authorization() -> FakeNode {
        FakeNode("AXSheet", frame: r(620, 460, 260, 257), children: [
            FakeNode("AXGroup", subrole: "AXHostingView", frame: r(620, 460, 260, 257), children: [
                FakeNode("AXImage", identifier: "touchid", description: "Touch Id", frame: r(649, 490, 34, 33)),
                FakeNode("AXStaticText", value: "Internet Sharing is trying to modify system settings.", frame: r(644, 545, 181, 32)),
                FakeNode("AXButton", description: "Use Password…", frame: r(636, 637, 228, 28)),
                FakeNode("AXButton", description: "Cancel", frame: r(636, 673, 228, 28)),
            ]),
        ])
    }

    private func confirm() -> FakeNode {
        FakeNode("AXSheet", frame: r(620, 471, 260, 234), children: [
            FakeNode("AXStaticText", identifier: "_NS:74", value: "Are you sure you want to turn on Internet sharing?", frame: r(641, 490, 218, 34)),
            FakeNode("AXButton", identifier: "action-button-2", title: "Cancel", frame: r(635, 660, 112, 30)) { [unowned self] in confirmOpen = false },
            FakeNode("AXButton", identifier: "action-button-1", title: "Turn On", frame: r(753, 660, 112, 30)) { [unowned self] in
                confirmOpen = false
                sharingOn = true
            },
        ])
    }
}
