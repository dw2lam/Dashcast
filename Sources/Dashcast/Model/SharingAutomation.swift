import AppKit
import ApplicationServices
import Foundation

/// What the automation needs from the Mac. Live: System Settings through the Accessibility API.
/// Tests: a scripted fake System Settings.
@MainActor
protocol SharingEnvironment: AnyObject {
    /// System Settings' root element; nil while it isn't running.
    func settingsApp() -> UINode?
    func openInternetSharing()
    /// Accessibility is granted (and applied) for this copy of Dashcast.
    var isTrusted: Bool { get }
    var isScreenLocked: Bool { get }
    var isSettingsFrontmost: Bool { get }
    func activateSettings()
    /// Replaces the text of System Settings' focused field with synthetic keystrokes.
    func type(_ text: String) -> Bool
    /// Escape, to System Settings (closes an open menu).
    func pressEscape()
    func sleep(_ seconds: TimeInterval) async throws
}

/// Why "Do It for Me" stopped, and at which step (Guide Me picks up there).
struct SharingAutomationError: Error, Equatable {
    let step: SharingStep
    /// One line, shown as is.
    let reason: String
}

/// "Do It for Me": turns on Internet Sharing by pressing System Settings' controls through the
/// Accessibility API (macOS has no API for it: the NAT daemon wants a private Apple entitlement).
///
/// Every step finds its control, skips itself if it's already right, acts, then waits for System
/// Settings to show the change. Anything unexpected stops it with the step and a one-line reason.
/// While macOS asks for Touch ID or the password, the clock stops: that's the user's turn.
@MainActor
final class SharingAutomation {
    struct Timing {
        /// Between looks at the screen.
        var poll: TimeInterval = 0.15
        /// How long a control gets to appear or change.
        var element: TimeInterval = 5
        /// After setting a value, before reading it back.
        var settle: TimeInterval = 0.3
        /// How long to wait for Touch ID or the password.
        var authorize: TimeInterval = 120
        /// System Settings launching and opening the pane.
        var launch: TimeInterval = 12
    }

    enum Event: Equatable {
        case step(SharingStep)
        /// macOS is asking for Touch ID or the password (true), or stopped asking (false).
        case waitingForYou(Bool)
        /// Wi‑Fi Options… was saved with the plan's name and password.
        case optionsSaved
    }

    private let environment: SharingEnvironment
    private let plan: SharingPlan
    private let timing: Timing
    private let report: (Event) -> Void

    init(environment: SharingEnvironment, plan: SharingPlan, timing: Timing = Timing(), report: @escaping (Event) -> Void = { _ in }) {
        self.environment = environment
        self.plan = plan
        self.timing = timing
        self.report = report
    }

    private func read() -> SharingScreen { SharingScreen(app: environment.settingsApp()) }

    private func fail(_ step: SharingStep, _ reason: String) -> SharingAutomationError {
        SharingAutomationError(step: step, reason: reason)
    }

    // MARK: - The run

    func run() async throws {
        guard environment.isTrusted else { throw fail(.openPane, "Dashcast needs Accessibility to do this.") }
        guard !environment.isScreenLocked else { throw fail(.openPane, "The screen is locked.") }

        // Open Internet Sharing.
        report(.step(.openPane))
        environment.openInternetSharing()
        var screen = try await wait(.openPane, "System Settings didn’t open Internet Sharing.", timeout: timing.launch) {
            $0.details != nil || $0.infoButton != nil
        }
        screen = try await clearLeftovers(screen)

        // ⓘ
        if screen.details == nil {
            report(.step(.openDetails))
            try press(screen.infoButton, .openDetails, "Couldn’t click ⓘ next to Internet Sharing.")
            screen = try await wait(.openDetails, "Internet Sharing’s details didn’t open.") { $0.details != nil }
        }

        // macOS locks the settings while sharing is on.
        if screen.details?.isOn == true {
            report(.step(.turnOffToEdit))
            try press(screen.details?.masterSwitch, .turnOffToEdit, "Couldn’t turn off Internet Sharing to change it.")
            screen = try await wait(.turnOffToEdit, "Internet Sharing didn’t turn off.") {
                $0.alert != nil || $0.details?.isOn == false
            }
            if let alert = screen.alert, !alert.isTurnOn {
                try press(alert.confirm, .turnOffToEdit, "Couldn’t confirm turning off Internet Sharing.")
                screen = try await wait(.turnOffToEdit, "Internet Sharing didn’t turn off.") {
                    $0.alert == nil && $0.details?.isOn == false
                }
            }
        }

        try await shareFrom(screen)
        try await shareToWiFi()
        try await setOptions()
        try await turnOn()
    }

    /// A menu, a confirmation or Wi‑Fi Options… left open (by an earlier try, or the user): closed.
    private func clearLeftovers(_ screen: SharingScreen) async throws -> SharingScreen {
        var screen = screen
        if let menu = screen.menu {
            closeMenu(menu)
            screen = try await wait(.openDetails, "A menu in System Settings won’t close.") { $0.menu == nil }
        }
        if let alert = screen.alert {
            try press(alert.cancel, .openDetails, "A message in System Settings is in the way.")
            screen = try await wait(.openDetails, "A message in System Settings is in the way.") { $0.alert == nil }
        }
        if let options = screen.options {
            try press(options.cancel, .openDetails, "Wi‑Fi Options is open and won’t close.")
            screen = try await wait(.openDetails, "Wi‑Fi Options is open and won’t close.") { $0.options == nil }
        }
        return screen
    }

    private func shareFrom(_ screen: SharingScreen) async throws {
        report(.step(.shareFrom))
        guard let current = screen.details?.shareFrom else {
            throw fail(.shareFrom, "Couldn’t find “Share your connection from”.")
        }
        guard !plan.acceptsShareFrom(current.value) else { return }
        guard let choice = try await choose(.shareFrom, popup: { $0.details?.shareFrom }, pick: plan.shareFromChoice) else {
            throw fail(.shareFrom, "\(plan.preferredShareFrom) isn’t in the “Share your connection from” list.")
        }
        // macOS asks for Touch ID or the password here, then lists Wi‑Fi under "To devices using".
        _ = try await wait(.shareFrom, "macOS didn’t save “Share your connection from”. Was Touch ID or the password cancelled?") {
            SharingText.same($0.details?.shareFrom?.value, choice)
        }
    }

    private func shareToWiFi() async throws {
        report(.step(.toWiFi))
        let missing = "Wi‑Fi isn’t in the “To devices using” list."
        // Wi‑Fi joins the list once the share-from change is saved; it can be below the fold.
        var screen = read()
        if screen.details?.wifiToggle == nil {
            screen = (try? await wait(.toWiFi, missing, timeout: timing.element / 2) { $0.details?.wifiToggle != nil }) ?? read()
        }
        if screen.details?.wifiToggle == nil, let details = screen.details {
            for area in [details.list, details.sheet.first { $0.role == "AXScrollArea" }].compactMap({ $0 }) {
                area.perform("AXScrollDownByPage")
            }
            screen = try await wait(.toWiFi, missing) { $0.details?.wifiToggle != nil }
        }
        guard plan.acceptsShareFrom(screen.details?.shareFrom?.value) else {
            throw fail(.shareFrom, "macOS didn’t save “Share your connection from”. Was Touch ID or the password cancelled?")
        }
        guard let toggle = screen.details?.wifiToggle else { throw fail(.toWiFi, missing) }
        guard !toggle.isOn else { return }
        try press(toggle, .toWiFi, "Couldn’t turn on Wi‑Fi under “To devices using”.")
        _ = try await wait(.toWiFi, "Wi‑Fi didn’t turn on under “To devices using”.") { $0.details?.wifiToggle?.isOn == true }
    }

    private func setOptions() async throws {
        report(.step(.wifiOptions))
        let button = try await wait(.wifiOptions, "Couldn’t find Wi‑Fi Options….") {
            $0.details?.wifiOptions?.isEnabled == true
        }.details?.wifiOptions
        try press(button, .wifiOptions, "Couldn’t click Wi‑Fi Options….")
        _ = try await wait(.wifiOptions, "Wi‑Fi Options didn’t open.") { $0.options != nil }

        report(.step(.networkName))
        try await enterText(plan.networkName, step: .networkName, secure: false) { $0.options?.nameField }

        report(.step(.channel))
        if let channel = read().options?.channel, !plan.acceptsChannel(channel.value) {
            // Not every Mac or country offers 149 or 36: then the channel stays as it is.
            if let choice = try await choose(.channel, popup: { $0.options?.channel }, pick: plan.channelChoice) {
                _ = try await wait(.channel, "The channel didn’t change to \(choice).") {
                    SharingText.same($0.options?.channel?.value, choice)
                }
            }
        }

        report(.step(.password))
        try await enterText(plan.password, step: .password, secure: true) { $0.options?.password }

        report(.step(.confirmOptions))
        guard let ok = read().options?.ok else { throw fail(.confirmOptions, "Couldn’t find OK in Wi‑Fi Options.") }
        guard ok.isEnabled else { throw fail(.confirmOptions, "macOS didn’t accept the name or password (OK is greyed out).") }
        try press(ok, .confirmOptions, "Couldn’t click OK in Wi‑Fi Options.")
        _ = try await wait(.confirmOptions, "Wi‑Fi Options didn’t close after OK.") { $0.options == nil }
        report(.optionsSaved)
    }

    private func turnOn() async throws {
        report(.step(.turnOn))
        var screen = try await wait(.turnOn, "Internet Sharing can’t be turned on yet (its switch is greyed out).") {
            $0.details?.masterSwitch?.isEnabled == true
        }
        if screen.details?.isOn != true {
            try press(screen.details?.masterSwitch, .turnOn, "Couldn’t turn on Internet Sharing.")
            screen = try await wait(.turnOn, "Internet Sharing didn’t turn on.") {
                $0.alert != nil || $0.details?.isOn == true
            }
        }
        if let alert = screen.alert {
            report(.step(.confirmTurnOn))
            guard alert.isTurnOn else { throw fail(.confirmTurnOn, "macOS showed an unexpected message: \(alert.message ?? "")") }
            try press(alert.confirm, .confirmTurnOn, "Couldn’t click Turn On.")
            _ = try await wait(.confirmTurnOn, "Internet Sharing didn’t turn on.", timeout: max(timing.element, 15)) {
                $0.alert == nil && $0.details?.isOn == true
            }
        }

        report(.step(.done))
        try press(read().details?.done, .done, "Couldn’t click Done.")
        _ = try await wait(.done, "Internet Sharing’s details didn’t close.") { $0.details == nil }
    }

    // MARK: - Pieces

    private func press(_ node: UINode?, _ step: SharingStep, _ failure: String) throws {
        guard let node, node.isEnabled, node.press() else { throw fail(step, failure) }
    }

    /// Polls until `condition` holds. The clock stops while macOS asks for Touch ID or the password.
    @discardableResult
    private func wait(_ step: SharingStep, _ failure: String, timeout: TimeInterval? = nil,
                      until condition: (SharingScreen) -> Bool) async throws -> SharingScreen {
        let limit = timeout ?? timing.element
        var deadline = Date().addingTimeInterval(limit)
        let authorizeDeadline = Date().addingTimeInterval(timing.authorize)
        var waitingForYou = false
        defer { if waitingForYou { report(.waitingForYou(false)) } }
        while true {
            try Task.checkCancellation()
            let screen = read()
            if screen.authorization != nil {
                if !waitingForYou {
                    waitingForYou = true
                    report(.waitingForYou(true))
                }
                guard Date() < authorizeDeadline else { throw fail(step, "macOS is still waiting for Touch ID or your password.") }
                deadline = Date().addingTimeInterval(limit)
            } else {
                if waitingForYou {
                    waitingForYou = false
                    report(.waitingForYou(false))
                }
                if condition(screen) { return screen }
                if Date() >= deadline { throw fail(step, failure) }
            }
            try await environment.sleep(timing.poll)
        }
    }

    /// Opens a popup's menu and presses the item `pick` chooses. nil = nothing suitable (the menu is closed again).
    private func choose(_ step: SharingStep, popup locate: (SharingScreen) -> UINode?,
                        pick: ([String]) -> String?) async throws -> String? {
        guard let popup = locate(read()) else { throw fail(step, "Couldn’t find the menu.") }
        guard popup.isEnabled else { throw fail(step, "The menu is greyed out.") }
        guard popup.press() else { throw fail(step, "Couldn’t open the menu.") }
        let screen = try await wait(step, "The menu didn’t open.") { $0.menu != nil }
        guard let menu = screen.menu else { return nil }
        let items = SharingScreen.menuItems(menu)
        guard let choice = pick(items.compactMap(\.title)), let item = items.first(where: { $0.title == choice }) else {
            closeMenu(menu)
            _ = try? await wait(step, "The menu didn’t close.") { $0.menu == nil }
            return nil
        }
        guard item.press() else {
            closeMenu(menu)
            throw fail(step, "Couldn’t choose \(choice).")
        }
        _ = try await wait(step, "The menu didn’t close.") { $0.menu == nil }
        return choice
    }

    private func closeMenu(_ menu: UINode) {
        if !menu.perform(kAXCancelAction) { environment.pressEscape() }
    }

    /// Sets AXValue and reads it back; if it didn't take, types it (System Settings in front, the
    /// field focused). A secure field reads back as one bullet per character: the count is checked.
    private func enterText(_ text: String, step: SharingStep, secure: Bool,
                           field locate: (SharingScreen) -> UINode?) async throws {
        let what = secure ? "the password" : "the network name"
        guard let field = locate(read()) else { throw fail(step, "Couldn’t find \(secure ? "the Password field" : "the Network Name field").") }
        func matches(_ node: UINode?) -> Bool {
            guard let node else { return false }
            return secure ? node.value?.count == text.count : node.value == text
        }
        if !secure, matches(field) { return }

        _ = field.setFocused()
        if field.setValue(text) {
            try await environment.sleep(timing.settle)
            if matches(locate(read())) { return }
        }

        if !environment.isSettingsFrontmost {
            environment.activateSettings()
            try await environment.sleep(timing.settle)
        }
        guard environment.isSettingsFrontmost, !environment.isScreenLocked else {
            throw fail(step, "Couldn’t type \(what): System Settings isn’t in front.")
        }
        _ = locate(read())?.setFocused()
        try await environment.sleep(timing.poll)
        guard locate(read())?.isFocused == true else { throw fail(step, "Couldn’t click into the field for \(what).") }
        guard environment.type(text) else { throw fail(step, "Couldn’t type \(what).") }
        try await environment.sleep(timing.settle)
        guard matches(locate(read())) else { throw fail(step, "Couldn’t enter \(what).") }
    }
}

// MARK: - Live

/// The real System Settings.
@MainActor
final class LiveSharingEnvironment: SharingEnvironment {
    private let open: () -> Void
    private let source = CGEventSource(stateID: .hidSystemState)

    init(open: @escaping () -> Void) {
        self.open = open
    }

    private var settings: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: SettingsWindow.bundleIdentifier).first
    }

    func settingsApp() -> UINode? { settings.map { AXNode.application(pid: $0.processIdentifier) } }
    func openInternetSharing() { open() }
    var isTrusted: Bool { AXIsProcessTrusted() }
    var isScreenLocked: Bool { HostMonitor.sessionIsLocked() }
    var isSettingsFrontmost: Bool { SettingsWindow.isFrontmost }
    func activateSettings() { settings?.activate() }

    func type(_ text: String) -> Bool {
        guard let pid = settings?.processIdentifier, isSettingsFrontmost, !isScreenLocked else { return false }
        // Select all, then the text (a CGEvent carries up to 20 UTF-16 units).
        key(0, flags: .maskCommand, to: pid)   // A
        let units = Array(text.utf16)
        for start in stride(from: 0, to: units.count, by: 20) {
            let chunk = Array(units[start..<min(start + 20, units.count)])
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { return false }
                chunk.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                event.postToPid(pid)
            }
        }
        return true
    }

    func pressEscape() {
        guard let pid = settings?.processIdentifier, isSettingsFrontmost else { return }
        key(53, to: pid)
    }

    private func key(_ code: CGKeyCode, flags: CGEventFlags = [], to pid: pid_t) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            event.postToPid(pid)
        }
    }

    func sleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}
