import AppKit
import DashcastContracts
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()
    let model = AppModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        if DebugOverrides.snapshotDirectory != nil || DebugOverrides.headless {
            NSApp.setActivationPolicy(.prohibited)   // silent: no Dock tile, no menu bar
            return
        }
        if ShotMode.isActive { return ShotMode.prepare() }
        // LSUIElement launch → promote to .regular here unless menu-bar-only is saved.
        controller.applyLaunchPolicy()
        DebugOverrides.applyAppearance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let directory = DebugOverrides.snapshotDirectory {
            Task { @MainActor in
                await SnapshotRenderer.run(into: directory)
                exit(0)
            }
            return
        }
        if DebugOverrides.headless {
            // Integration testing: run the real service with no UI. Overrides aren't persisted.
            var settings = model.service.settings
            if let mode = DebugOverrides.environment["DASHCAST_MODE"].flatMap(DisplayMode.init(rawValue:)) {
                settings.displayMode = mode
            }
            if DebugOverrides.environment["DASHCAST_AUDIO"] == "0" { settings.audioEnabled = false }
            if let tier = DebugOverrides.environment["DASHCAST_TIER"] { settings.tierOverrideID = tier }
            if let latency = DebugOverrides.environment["DASHCAST_LATENCY"].flatMap(LatencyMode.init(rawValue:)) {
                settings.latencyMode = latency
            }
            model.service.settings = settings
            let service = model.service
            Task { @MainActor in
                await service.start()
                print("[dashcast] headless settings: mode=\(service.settings.displayMode) tier=\(service.settings.tierOverrideID ?? "auto") latency=\(service.settings.latencyMode)")
                var printed = 0
                while true {   // mirror the service log to stdout for the test harness
                    let log = service.state.log
                    if printed > log.count { printed = 0 }
                    for line in log[printed...] { print("[dashcast] \(line.message)") }
                    printed = log.count
                    fflush(stdout)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            return
        }
        if ShotMode.isActive { return ShotMode.run(model: model, controller: controller) }
        controller.startObservingPreferences()
        controller.showOnboardingIfNeeded()
        controller.ensureLaunchWindow()
        model.didLaunch()
    }

    /// A streaming utility keeps running with no windows open (both modes).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock click with the window closed → bring it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { controller.showMainWindow() }
        return true
    }

    /// Stop the stream (tears down the virtual display) before quitting, but never hang the quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isRunning else { return .terminateNow }
        Task { @MainActor in
            await model.shutdown(timeout: .seconds(2))
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Launch-environment switches used for development and screenshots.
enum DebugOverrides {
    static let environment = ProcessInfo.processInfo.environment

    /// `DASHCAST_SNAPSHOT=/dir` renders every page offscreen (light + dark) to PNGs and exits.
    static var snapshotDirectory: URL? {
        environment["DASHCAST_SNAPSHOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// `DASHCAST_HEADLESS=1` starts the real service with no windows, Dock tile or menu bar item
    /// (`DASHCAST_MODE=mirror|extend`, `DASHCAST_AUDIO=0`). For end-to-end tests.
    static var headless: Bool { environment["DASHCAST_HEADLESS"] == "1" }

    /// With `DASHCAST_POLICY_LOG`, records where the titlebar controls ended up (layout checks
    /// without screenshots): window frame, then each titlebar button's frame in window coordinates.
    static func logWindowLayout(_ window: NSWindow) {
        guard environment["DASHCAST_POLICY_LOG"] != nil, let frameView = window.contentView?.superview else { return }
        var lines = ["window \(Int(window.frame.width))x\(Int(window.frame.height)) content \(Int(window.contentLayoutRect.width))x\(Int(window.contentLayoutRect.height))"]
        func walk(_ view: NSView) {
            let kind = String(describing: type(of: view))
            if !view.isHidden, view is NSButton || kind.contains("ToolbarItemViewer") {
                let rect = view.convert(view.bounds, to: nil)
                lines.append("  \(kind) x=\(Int(rect.minX)) y=\(Int(rect.minY)) w=\(Int(rect.width)) h=\(Int(rect.height))")
            }
            view.subviews.forEach(walk)
        }
        walk(frameView)
        for item in window.toolbar?.items ?? [] {
            lines.append("  toolbar item \(item.itemIdentifier.rawValue) label=\"\(item.label)\"")
        }
        append(lines.joined(separator: "\n"))
    }

    /// `DASHCAST_POLICY_LOG=/file` appends `NSApp.activationPolicy` after every change.
    static func logPolicy(_ reason: String) {
        guard environment["DASHCAST_POLICY_LOG"] != nil else { return }
        let policy: String
        switch NSApp.activationPolicy() {
        case .regular: policy = "regular"
        case .accessory: policy = "accessory"
        case .prohibited: policy = "prohibited"
        @unknown default: policy = "unknown"
        }
        append("\(reason): policy=\(policy) active=\(NSApp.isActive)")
    }

    private static func append(_ text: String) {
        guard let path = environment["DASHCAST_POLICY_LOG"] else { return }
        let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(text)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }

    /// `DASHCAST_APPEARANCE=dark|light` forces the app's appearance without touching the system setting.
    static func applyAppearance() {
        switch environment["DASHCAST_APPEARANCE"]?.lowercased() {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }
}
