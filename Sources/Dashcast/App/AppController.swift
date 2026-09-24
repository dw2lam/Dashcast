import AppKit
import SwiftUI

/// Owns window presentation and the live Dock ⇄ menu-bar-only switch.
///
/// Menu-bar-only is a pure runtime activation-policy change (`.regular` ⇄ `.accessory`), driven by
/// KVO on the `menuBarOnly` default, so every writer (the sidebar toggle, the status menu, `defaults
/// write`) takes effect immediately with no relaunch.
@MainActor
@Observable
final class AppController {
    /// Set whenever a SwiftUI view that can see `\.openWindow` appears (main window, status item).
    @ObservationIgnored var openWindowAction: OpenWindowAction?
    @ObservationIgnored weak var mainWindow: NSWindow?

    var isOnboardingPresented = false

    @ObservationIgnored private var defaultsObservation: NSKeyValueObservation?
    @ObservationIgnored private var appliedMenuBarOnly: Bool?

    // MARK: - Activation policy

    /// Called from `applicationWillFinishLaunching`. Info.plist sets `LSUIElement`, so the app
    /// launches with no Dock tile at all and a regular launch promotes itself here, before the
    /// first activation installs the menu bar. Menu-bar-only launches therefore never flash a
    /// Dock icon, and the live toggle below still switches instantly in both directions.
    func applyLaunchPolicy() {
        let menuBarOnly = UserDefaults.standard.menuBarOnly
        NSApp.setActivationPolicy(menuBarOnly ? .accessory : .regular)
        appliedMenuBarOnly = menuBarOnly
        DebugOverrides.logPolicy("launch")
    }

    func startObservingPreferences() {
        defaultsObservation = UserDefaults.standard.observe(\.menuBarOnly, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.menuBarOnlyPreferenceChanged() }
        }
    }

    private func menuBarOnlyPreferenceChanged() {
        let wanted = UserDefaults.standard.menuBarOnly
        guard wanted != appliedMenuBarOnly else { return }
        appliedMenuBarOnly = wanted
        if wanted { enterMenuBarOnly() } else { leaveMenuBarOnly() }
    }

    private func enterMenuBarOnly() {
        let wasActive = NSApp.isActive
        let window = visibleMainWindow
        NSApp.setActivationPolicy(.accessory)
        DebugOverrides.logPolicy("menuBarOnly on")
        // Dropping to .accessory hands activation to the next app, which would bury the window
        // the user was just using. Take it back and re-front the window — but only if the user
        // was actually in Dashcast (never steal focus for a change made elsewhere).
        guard wasActive else { return }
        DispatchQueue.main.async {
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        }
    }

    private func leaveMenuBarOnly() {
        let wasActive = NSApp.isActive
        let window = visibleMainWindow
        NSApp.setActivationPolicy(.regular)
        DebugOverrides.logPolicy("menuBarOnly off")
        // An app that turns .regular while already active keeps a dead menu bar (AppKit only
        // installs the main menu on activation). Hop activation away and back to rebuild it.
        // If Dashcast wasn't active, its menu bar is installed normally on the next activation.
        guard wasActive else { return }
        reactivate {
            window?.makeKeyAndOrderFront(nil)
        }
    }

    /// Deactivate → re-activate. Yielding to the Dock is invisible (it has no windows) and,
    /// unlike hide/unhide, never flickers our own window.
    private func reactivate(then completion: @escaping @MainActor () -> Void) {
        if let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
            NSApp.yieldActivation(to: dock)
            dock.activate(from: .current, options: [])
        } else {
            NSApp.deactivate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            NSApp.activate()
            completion()
            DebugOverrides.logPolicy("reactivated")
        }
    }

    // MARK: - Windows

    private var visibleMainWindow: NSWindow? {
        guard let mainWindow, mainWindow.isVisible || mainWindow.isMiniaturized else { return nil }
        return mainWindow
    }

    func showMainWindow() {
        if let openWindowAction {
            openWindowAction(id: SceneID.main)
        } else if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
        }
        mainWindow?.deminiaturize(nil)
        NSApp.activate()
    }

    /// SwiftUI occasionally skips presenting the launch window when another app steals activation
    /// mid-launch; in a regular (Dock) launch, make sure the user gets a window.
    func ensureLaunchWindow() {
        guard !UserDefaults.standard.menuBarOnly else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.visibleMainWindow == nil, !UserDefaults.standard.menuBarOnly else { return }
            self.showMainWindow()
        }
    }

    func showOnboardingIfNeeded() {
        if !UserDefaults.standard.bool(forKey: DefaultsKey.onboardingComplete) {
            isOnboardingPresented = true
        }
    }

    func presentOnboarding() {
        isOnboardingPresented = true
        showMainWindow()
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: DefaultsKey.onboardingComplete)
        isOnboardingPresented = false
    }
}
