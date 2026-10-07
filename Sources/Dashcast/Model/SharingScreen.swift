import CoreGraphics
import Foundation

/// System Settings ▸ General ▸ Sharing ▸ Internet Sharing, found in its Accessibility tree: the
/// pane's row, the ⓘ sheet, the nested Wi‑Fi Options sheet, the "Turn On" confirmation, the
/// Touch ID prompt and any open popup menu. Read fresh after every change (it's a snapshot).
///
/// Mapped from macOS 27's tree (Tests/DashcastAppTests/AXMaps). Identifiers are used where System
/// Settings sets stable ones (the pane row, the confirmation's buttons); the SwiftUI ⓘ sheet and the
/// AppKit Wi‑Fi Options sheet are found by role and by the labels beside each control (English).
struct SharingScreen {
    /// System Settings' main window (nil: not running, or no window).
    var window: UINode?
    /// The Internet Sharing row on the Sharing pane (nil while a sheet covers it).
    var infoButton: UINode?
    var rowSwitch: UINode?
    var details: Details?
    var options: Options?
    var alert: Alert?
    /// macOS asking for Touch ID or the password ("Internet Sharing is trying to modify system settings").
    var authorization: UINode?
    /// An open popup menu (share-from or channel).
    var menu: UINode?

    /// The ⓘ sheet.
    struct Details {
        let sheet: UINode
        /// "Internet Sharing: Off" / "Internet Sharing: On".
        var statusText: UINode?
        /// The master switch (disabled until there's something to share to).
        var masterSwitch: UINode?
        /// "Share your connection from".
        var shareFrom: UINode?
        /// "To devices using": one AXToggle per interface, named by its description.
        var toggles: [UINode] = []
        /// The scroll area around that list.
        var list: UINode?
        var wifiOptions: UINode?
        var done: UINode?

        /// From the status line, else the switch.
        var isOn: Bool {
            if let text = statusText?.value.map(SharingText.normalized) {
                if text.hasSuffix(": on") { return true }
                if text.hasSuffix(": off") { return false }
            }
            return masterSwitch?.isOn ?? false
        }

        var wifiToggle: UINode? { toggles.first { SharingText.isWiFi($0.axDescription) } }
    }

    /// Wi‑Fi Options… (AppKit, nested in the ⓘ sheet).
    struct Options {
        let sheet: UINode
        var nameField: UINode?
        var channel: UINode?
        var security: UINode?
        var password: UINode?
        /// "The password must contain at least 8 characters."
        var passwordHint: UINode?
        var ok: UINode?
        var cancel: UINode?
    }

    /// A confirmation ("Are you sure you want to turn on Internet sharing?" ▸ Turn On).
    struct Alert {
        let sheet: UINode
        var confirm: UINode?
        var cancel: UINode?
        var message: String?

        var isTurnOn: Bool {
            SharingText.normalized(confirm?.text ?? "") == "turn on"
                || SharingText.normalized(message ?? "").contains("turn on internet sharing")
        }
    }

    init(app: UINode?) {
        guard let app else { return }
        let windows = app.role == "AXWindow" ? [app] : app.children.filter { $0.role == "AXWindow" }
        let standard = windows.filter { $0.subrole == "AXStandardWindow" }
        guard let window = standard.first(where: { $0.identifier == "Main" }) ?? standard.first ?? windows.first else { return }
        self.window = window

        // Sheets hang off the window, nested ones off their parent sheet. Alerts and the password
        // prompt can also be windows of their own.
        var sheets: [UINode] = []
        func collect(_ node: UINode) {
            for child in node.children where child.role == "AXSheet" {
                sheets.append(child)
                collect(child)
            }
        }
        collect(window)
        sheets += windows.filter { $0 !== window && ($0.subrole == "AXDialog" || $0.subrole == "AXSystemDialog") }

        for sheet in sheets {
            if Self.isAuthorization(sheet) {
                authorization = sheet
            } else if let alert = Self.alert(in: sheet) {
                self.alert = alert
            } else if let options = Self.options(in: sheet) {
                self.options = options
            } else if let details = Self.details(in: sheet) {
                self.details = details
            }
        }

        // The pane's row only matters with no sheet over it, and finding it walks the whole pane:
        // skipped while a sheet is up (every look while guiding or automating reads a fresh tree).
        if details == nil, options == nil, alert == nil {
            let row = Self.internetSharingRow(in: window)
            infoButton = row.info
            rowSwitch = row.toggle
        }

        // An open menu belongs to the popup that opened it; else it's the app's.
        let popups = [details?.shareFrom, options?.channel, options?.security].compactMap { $0 }
        menu = popups.lazy.compactMap { $0.first(where: { $0.role == "AXMenu" }) }.first
            ?? app.children.first { $0.role == "AXMenu" }
            ?? window.children.first { $0.role == "AXMenu" }
    }

    /// The enabled items of an open menu.
    static func menuItems(_ menu: UINode) -> [UINode] {
        menu.all(where: { $0.role == "AXMenuItem" && $0.title != nil && $0.isEnabled })
    }

    // MARK: - Locators

    /// Inside a sheet, not its nested sheets.
    private static func inside(_ sheet: UINode, where match: (UINode) -> Bool) -> UINode? {
        sheet.first(skip: { $0 !== sheet && $0.role == "AXSheet" }, where: match)
    }

    private static func allInside(_ sheet: UINode, where match: (UINode) -> Bool) -> [UINode] {
        sheet.all(skip: { $0 !== sheet && $0.role == "AXSheet" }, where: match)
    }

    private static func staticText(in sheet: UINode, _ test: (String) -> Bool) -> UINode? {
        inside(sheet) { $0.role == "AXStaticText" && $0.value.map(SharingText.normalized).map(test) == true }
    }

    private static func button(in sheet: UINode, _ test: (String) -> Bool) -> UINode? {
        inside(sheet) { $0.role == "AXButton" && $0.text.map(SharingText.normalized).map(test) == true }
    }

    static func isAuthorization(_ sheet: UINode) -> Bool {
        inside(sheet) { node in
            (node.role == "AXImage" && node.identifier == "touchid")
                || (node.role == "AXButton" && SharingText.normalized(node.text ?? "").hasPrefix("use password"))
                || (node.role == "AXStaticText" && SharingText.normalized(node.value ?? "").contains("trying to modify"))
        } != nil
    }

    static func alert(in sheet: UINode) -> Alert? {
        guard let confirm = inside(sheet, where: { $0.role == "AXButton" && $0.identifier == "action-button-1" }) else { return nil }
        return Alert(sheet: sheet, confirm: confirm,
                     cancel: inside(sheet) { $0.role == "AXButton" && $0.identifier == "action-button-2" },
                     message: inside(sheet) { $0.role == "AXStaticText" && $0.value != nil }?.value)
    }

    static func options(in sheet: UINode) -> Options? {
        let password = inside(sheet) { $0.role == "AXTextField" && $0.subrole == "AXSecureTextField" }
        let nameLabel = staticText(in: sheet) { $0.hasPrefix("network name") }
        guard password != nil || nameLabel != nil else { return nil }
        let fields = allInside(sheet) { $0.role == "AXTextField" && $0.subrole != "AXSecureTextField" && $0.subrole != "AXSearchField" }
        let popups = allInside(sheet) { $0.role == "AXPopUpButton" }.sorted { $0.frame.minY < $1.frame.minY }
        return Options(
            sheet: sheet,
            nameField: beside(nameLabel, among: fields) ?? fields.first,
            channel: beside(staticText(in: sheet) { $0.hasPrefix("channel") }, among: popups) ?? popups.first,
            security: beside(staticText(in: sheet) { $0.hasPrefix("security") }, among: popups) ?? popups.dropFirst().first,
            password: password,
            passwordHint: staticText(in: sheet) { $0.contains("at least") },
            ok: button(in: sheet) { $0 == "ok" },
            cancel: button(in: sheet) { $0 == "cancel" })
    }

    static func details(in sheet: UINode) -> Details? {
        let status = staticText(in: sheet) { $0.hasPrefix("internet sharing:") }
        let fromLabel = staticText(in: sheet) { $0.hasPrefix("share your connection from") }
        guard status != nil || fromLabel != nil else { return nil }
        let popups = allInside(sheet) { $0.role == "AXPopUpButton" }
        let toggles = allInside(sheet) { $0.role == "AXCheckBox" && $0.subrole == "AXToggle" }
        return Details(
            sheet: sheet,
            statusText: status,
            masterSwitch: inside(sheet) { $0.role == "AXCheckBox" && $0.subrole == "AXSwitch" },
            shareFrom: beside(fromLabel, among: popups) ?? popups.first,
            toggles: toggles,
            list: inside(sheet) { node in node.role == "AXScrollArea" && node.children.contains { $0.role == "AXOutline" } },
            wifiOptions: button(in: sheet) { $0.hasPrefix("wi-fi options") },
            done: button(in: sheet) { $0 == "done" })
    }

    /// The control on the same row as `label` (closest vertical centre, to its right).
    static func beside(_ label: UINode?, among candidates: [UINode]) -> UINode? {
        guard let label else { return nil }
        let row = label.frame
        return candidates
            .filter { $0.frame.maxX > row.minX && abs($0.frame.midY - row.midY) < max(24, row.height) }
            .min { abs($0.frame.midY - row.midY) < abs($1.frame.midY - row.midY) }
    }

    /// The ⓘ and switch of Internet Sharing on the Sharing pane, by identifier, else by the row's text.
    static func internetSharingRow(in window: UINode) -> (info: UINode?, toggle: UINode?) {
        let skip: (UINode) -> Bool = { node in
            node !== window && (node.role == "AXSheet" || node.role == "AXToolbar"
                || (node.role == "AXOutline" && node.axDescription == "Sidebar"))
        }
        var info: UINode?
        var toggle: UINode?
        _ = window.first(skip: skip) { node in
            if node.identifier == "Internet SharingToggle.infoButton" { info = node }
            if node.identifier == "Internet SharingToggle" { toggle = node }
            return info != nil && toggle != nil
        }
        if info == nil || toggle == nil,
           let group = window.first(skip: skip, where: { node in
               node.children.contains { $0.role == "AXStaticText" && SharingText.normalized($0.value ?? "") == "internet sharing" }
           }) {
            let row = group.children
            if let start = row.firstIndex(where: { SharingText.normalized($0.value ?? "") == "internet sharing" }) {
                let rest = row[start...].dropFirst().prefix { $0.role != "AXStaticText" }
                info = info ?? rest.first { $0.role == "AXButton" }
                toggle = toggle ?? rest.first { $0.role == "AXCheckBox" }
            }
        }
        return (info, toggle)
    }
}

/// Text from System Settings, compared loosely: case, hyphen and ellipsis variants, whitespace.
enum SharingText {
    static func normalized(_ text: String) -> String {
        var text = text.lowercased()
        for dash in ["\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}"] {
            text = text.replacingOccurrences(of: dash, with: "-")
        }
        text = text.replacingOccurrences(of: "...", with: "…")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return normalized(a) == normalized(b)
    }

    static func isWiFi(_ name: String?) -> Bool {
        guard let name else { return false }
        let text = normalized(name)
        return text == "wi-fi" || text == "wifi" || text == "airport"
    }
}
