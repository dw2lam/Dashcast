import AppKit
import DashcastContracts
import SwiftUI

@main
struct DashcastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(DefaultsKey.menuBarOnly) private var menuBarOnly = false
    @AppStorage(DefaultsKey.showMenuBarIcon) private var showMenuBarIcon = true

    var body: some Scene {
        Window("Dashcast", id: SceneID.main) {
            MainView()
                .environment(appDelegate.model)
                .environment(appDelegate.controller)
        }
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        // Menu-bar-only launches start with just the status item; the window opens on demand.
        .defaultLaunchBehavior(menuBarOnly || isSnapshotting ? .suppressed : .presented)
        .restorationBehavior(.disabled)
        .commands {
            DashcastCommands(model: appDelegate.model, controller: appDelegate.controller)
        }

        Window("How to Connect", id: SceneID.guide) {
            ConnectionGuide()
                .environment(appDelegate.model)
                .environment(appDelegate.controller)
        }
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Car Hotspot", id: SceneID.hotspot) {
            HotspotSetupView()
                .environment(appDelegate.model)
                .environment(appDelegate.controller)
        }
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(appDelegate.model)
                .environment(appDelegate.controller)
        }

        MenuBarExtra(isInserted: statusItemInserted) {
            MenuBarPanel()
                .environment(appDelegate.model)
                .environment(appDelegate.controller)
        } label: {
            MenuBarLabel(model: appDelegate.model, controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.window)
    }

    private var isSnapshotting: Bool { DebugOverrides.snapshotDirectory != nil }

    /// While menu-bar-only is on the status item is the app's only UI, so it is forced visible:
    /// the getter ignores the user's preference and the setter refuses to remove it.
    private var statusItemInserted: Binding<Bool> {
        Binding(
            get: { !isSnapshotting && (menuBarOnly || showMenuBarIcon) },
            set: { inserted in
                guard !menuBarOnly else { return }
                showMenuBarIcon = inserted
            }
        )
    }
}

enum SceneID {
    static let main = "main"
    static let guide = "guide"
    static let hotspot = "hotspot"
}

enum DefaultsKey {
    static let menuBarOnly = "menuBarOnly"
    static let showMenuBarIcon = "showMenuBarIcon"
    static let onboardingComplete = "onboardingComplete"
    static let notifyOnDisconnect = "notifyOnDisconnect"
    /// Start listening when the Mac's hotspot comes up (default on).
    static let autoReadyOnHotspot = "autoReadyOnHotspot"
    /// Car hotspot setup: "Continue Without Internet" was chosen.
    static let hotspotWithoutInternet = "hotspotWithoutInternet"
    /// Car hotspot setup: step 2 opens in Guide Me instead of Do It for Me.
    static let hotspotGuidanceMode = "hotspotGuidanceMode"
    /// The network name Dashcast last saved its hotspot password with (the password is in the Keychain).
    static let hotspotPasswordNetwork = "hotspotPasswordNetwork"
}

extension UserDefaults {
    /// KVO-observable mirror of the `menuBarOnly` key (property name must equal the key).
    @objc dynamic var menuBarOnly: Bool { bool(forKey: DefaultsKey.menuBarOnly) }
}
