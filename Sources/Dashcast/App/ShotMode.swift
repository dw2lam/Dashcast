import AppKit
import DashcastContracts
import ObjectiveC
import SwiftUI

/// `DASHCAST_SHOT`: native macOS window screenshots of the real UI (website, docs), the ⌘⇧4 + Space
/// look: one window, real rounded corners and its drop shadow on transparency.
///
/// Run it through `scripts/shots/capture.sh`, which builds a separate "Dashcast Shots.app" (its own
/// bundle id, so its defaults, window frames and status item never touch the real app) and gives
/// it a private HiDPI virtual display to stage the windows on. Pair it with the mock backend
/// (`DASHCAST_MOCK=1 DASHCAST_MOCK_PHASE=streaming DASHCAST_MOCK_CERT=1`).
///
///   DASHCAST_SHOT=1 | main,guide,settings,menu,setup   scenes to capture, in this order (1 = all)
///   DASHCAST_SHOT_DISPLAY=<CGDirectDisplayID>          where the windows go (default: main display)
///   DASHCAST_SHOT_OUT=/dir                             PNGs plus shots.json (window frames)
///   DASHCAST_SHOT_PREFIX=dark                          file name prefix
///   DASHCAST_SHOT_TABS=network                         only these Settings tabs (default: all four)
///
/// The app never activates on its own. Each capture is one short burst: remember the frontmost
/// app, activate (so the window has its key look), `screencapture -x -l`, then hand activation
/// straight back. Everything else (switching tabs, states, sheets) happens while inactive.
@MainActor
enum ShotMode {
    static let isActive = DebugOverrides.environment["DASHCAST_SHOT"] != nil

    /// The page the setup assistant opens on; a shot sets it before presenting the sheet.
    static var setupStep = 0

    enum Scene: String, CaseIterable {
        case main, guide, settings, menu, setup
    }

    private enum Role { case main, guide, settings, menu }

    private static let environment = DebugOverrides.environment
    private static var model: AppModel!
    private static var controller: AppController!
    private static var lastForeignApp: NSRunningApplication?
    private static var inBurst = false
    private static var focusSeconds = 0.0
    private static var records: [[String: Any]] = []

    private static var scenes: [Scene] {
        let requested = (environment["DASHCAST_SHOT"] ?? "").split(separator: ",")
            .compactMap { Scene(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
        return requested.isEmpty ? Scene.allCases : requested
    }

    private static var settingsTabs: [String] {
        let all = ["General", "Display", "Network", "Advanced"]
        guard let only = environment["DASHCAST_SHOT_TABS"]?.lowercased().split(separator: ",") else { return all }
        return all.filter { only.contains(Substring($0.lowercased())) }
    }

    private static var outputDirectory: URL {
        URL(fileURLWithPath: environment["DASHCAST_SHOT_OUT"] ?? NSTemporaryDirectory() + "dashcast-shots", isDirectory: true)
    }

    private static var prefix: String { environment["DASHCAST_SHOT_PREFIX"].map { "\($0)-" } ?? "" }

    private static var stageScreen: NSScreen? {
        guard let id = environment["DASHCAST_SHOT_DISPLAY"].flatMap(UInt32.init) else { return NSScreen.screens.first }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    // MARK: - Launch

    /// From `applicationWillFinishLaunching`, instead of the normal launch policy.
    static func prepare() {
        lastForeignApp = NSWorkspace.shared.frontmostApplication
        NSApp.setActivationPolicy(.prohibited)
        DebugOverrides.applyAppearance()
        installPlacementHook()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard !inBurst else { return }
                log("activated outside a capture; handing focus back")
                handBack(to: lastForeignApp)
            }
        }
    }

    /// From `applicationDidFinishLaunching`: runs every requested scene, then quits.
    static func run(model: AppModel, controller: AppController) {
        self.model = model
        self.controller = controller
        Task { @MainActor in
            await perform()
            writeManifest()
            log(String(format: "done · %d captures · focus held %.1f s in total", records.count, focusSeconds))
            exit(0)
        }
    }

    private static func perform() async {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        model.didLaunch()
        guard stageScreen != nil else { return log("stage display not found") }
        guard let main = await window(.main, timeout: 8) else { return log("the main window never appeared") }
        await pause(1.5)
        rewriteLog()
        pinStats()

        for scene in scenes {
            switch scene {
            case .main: await mainScenes(main)
            case .guide: await guideScene()
            case .settings: await settingsScenes()
            case .menu: await menuScene()
            case .setup: await setupScenes(main)
            }
        }
    }

    // MARK: - Scenes

    private static func mainScenes(_ main: NSWindow) async {
        model.settings.displayMode = .extend
        await pause(0.8)
        await snap(main, as: "main-casting-extend")
        // Its look behind another window (the guide, Settings): no focus needed.
        await pause(0.5)
        await capture(main, as: "main-casting-extend-inactive")

        model.settings.displayMode = .mirror
        await pause(1.0)
        await snap(main, as: "main-casting-mirror")
        model.settings.displayMode = .extend

        let state = model.state
        let car = state.car
        state.car = nil
        state.phase = .waitingForCar
        await pause(1.2)
        await snap(main, as: "main-waiting")
        state.car = car
        state.phase = .streaming
        await pause(1.0)
    }

    private static func guideScene() async {
        controller.openWindowAction?(id: SceneID.guide)
        guard let guide = await window(.guide) else { return log("the Connection Guide never appeared") }
        await pause(1.2)
        await snap(guide, as: "guide")
        guide.close()
        await pause(0.4)
    }

    private static func settingsScenes() async {
        rewriteLog()
        openSettings()
        guard let settings = await window(.settings) else { return log("Settings never appeared") }
        await pause(1.0)
        for tab in settingsTabs {
            selectToolbarItem(tab, in: settings)
            await pause(1.0)
            // Network scrolls; its end shows the certificate and helper rows and ends on a clean edge.
            if tab == "Network" {
                scrollFormToEnd(in: settings)
                await pause(0.6)
            }
            await snap(settings, as: "settings-\(tab.lowercased())")
        }
        settings.close()
        await pause(0.4)
    }

    /// The status item exists only for this scene (the shots app starts with `showMenuBarIcon` off).
    /// The panel opens under it on the real menu bar and the placement hook moves it to the stage
    /// before it is ever drawn there.
    private static func menuScene() async {
        UserDefaults.standard.set(true, forKey: DefaultsKey.showMenuBarIcon)
        defer { UserDefaults.standard.set(false, forKey: DefaultsKey.showMenuBarIcon) }
        guard let button = await poll(3, statusItemButton) else { return log("status item never appeared") }
        await pause(0.8)
        await withFocus {
            var panel: NSWindow?
            for press in [{ requestExpandedInterface(button) }, { button.performClick(nil) }] {
                press()
                panel = await window(.menu, timeout: 1)
                if panel != nil { break }
            }
            guard let panel else { return log("the menu bar panel never opened") }
            _ = await until(1) { panel.isKeyWindow }
            giveGlassADesktop(panel)
            await pause(0.7)
            await capture(panel, as: "menu-casting")
            panel.orderOut(nil)
        }
        await pause(0.4)
    }

    /// First run: nothing casting, the assistant as a sheet over the main window, one page each.
    private static func setupScenes(_ main: NSWindow) async {
        await model.service.stop()
        await pause(1.2)
        await snap(main, as: "main-ready")

        for step in 0..<SetupAssistant.pageCount {
            setupStep = step
            controller.isOnboardingPresented = true
            guard let sheet = await poll(3, { main.attachedSheet }) else { return log("the setup sheet never appeared") }
            await pause(1.2)
            await withFocus {
                main.makeKeyAndOrderFront(nil)
                _ = await until(1) { sheet.isKeyWindow }
                await pause(0.35)
                // The capture of a sheet includes its parent window, as it appears on screen.
                await capture(sheet, as: "setup-\(step + 1)")
            }
            controller.isOnboardingPresented = false
            _ = await until(3) { main.attachedSheet == nil }
            await pause(0.5)
        }
        setupStep = 0
    }

    // MARK: - Capture

    private static func snap(_ window: NSWindow, as name: String) async {
        await withFocus {
            window.makeKeyAndOrderFront(nil)
            _ = await until(1) { window.isKeyWindow }
            await pause(0.35)
            await capture(window, as: name)
        }
    }

    private static func withFocus(_ body: () async -> Void) async {
        let previous = frontmostForeignApp()
        let started = Date()
        inBurst = true
        NSApp.setActivationPolicy(.accessory)
        forceActivate()
        if !(await until(1.5, { NSApp.isActive })) { log("activation was refused; capturing the inactive look") }
        await body()
        handBack(to: previous)
        _ = await until(1) { !NSApp.isActive }
        inBurst = false
        let elapsed = Date().timeIntervalSince(started)
        focusSeconds += elapsed
        log(String(format: "focus %.2f s, back to %@", elapsed, NSWorkspace.shared.frontmostApplication?.localizedName ?? "nobody"))
    }

    /// `activate(ignoringOtherApps:)` through its IMP: the cooperative `activate()` can't take focus
    /// from an app that never yielded it, and the burst hands it back within a second.
    private static func forceActivate() {
        let selector = NSSelectorFromString("activateIgnoringOtherApps:")
        guard let imp = NSApp.method(for: selector) else { return NSApp.activate() }
        typealias Activate = @convention(c) (NSApplication, Selector, Bool) -> Void
        unsafeBitCast(imp, to: Activate.self)(NSApp, selector, true)
    }

    private static func frontmostForeignApp() -> NSRunningApplication? {
        if let app = NSWorkspace.shared.frontmostApplication, app != .current { lastForeignApp = app }
        return lastForeignApp
    }

    private static func handBack(to app: NSRunningApplication?) {
        guard let app, !app.isTerminated else { return NSApp.deactivate() }
        NSApp.yieldActivation(to: app)
        app.activate(from: .current, options: [])
    }

    /// `screencapture -x -l <id>`: silent, this window alone, shadow kept (never `-o`).
    private static func capture(_ window: NSWindow, as name: String) async {
        let file = outputDirectory.appendingPathComponent("\(prefix)\(name).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", String(window.windowNumber), file.path]
        do {
            try process.run()
        } catch {
            return log("screencapture failed: \(error.localizedDescription)")
        }
        while process.isRunning { try? await Task.sleep(for: .milliseconds(15)) }

        let record: [String: Any] = [
            "name": name, "file": file.lastPathComponent, "window": window.windowNumber,
            "frame": frameRecord(window.frame), "scale": window.backingScaleFactor,
            "key": window.isKeyWindow, "active": NSApp.isActive,
        ]
        records.append(record)
        log("captured \(file.lastPathComponent) (key \(window.isKeyWindow), active \(NSApp.isActive), \(Int(window.frame.width))×\(Int(window.frame.height)))")
    }

    private static func frameRecord(_ frame: NSRect) -> [String: Double] {
        ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
    }

    private static func writeManifest() {
        let manifest: [String: Any] = ["prefix": prefix, "focusSeconds": focusSeconds, "shots": records]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: outputDirectory.appendingPathComponent("\(prefix)shots.json"))
    }

    // MARK: - Windows

    private static func role(of window: NSWindow) -> Role? {
        guard !window.isSheet else { return nil }
        let kind = String(describing: type(of: window))
        if kind.contains("MenuBarExtra") { return .menu }
        guard window.styleMask.contains(.titled), !kind.contains("StatusBar") else { return nil }
        let identifier = window.identifier?.rawValue ?? ""
        if identifier.contains("Settings") { return .settings }
        if identifier.hasPrefix(SceneID.guide) || window.title == "How to Connect" { return .guide }
        if identifier.hasPrefix(SceneID.main) || window.title == "Dashcast" { return .main }
        return nil
    }

    private static func window(_ role: Role, timeout: Double = 4) async -> NSWindow? {
        await poll(timeout) { NSApp.windows.first { $0.isVisible && self.role(of: $0) == role } }
    }

    /// Every window is moved onto the stage display before it is ordered in, and any frame AppKit
    /// or SwiftUI later proposes off the stage (the menu bar panel is positioned under the status
    /// item on the real menu bar) is redirected, so nothing ever appears on the real screens.
    /// Each role has its own spot, so no window's glass samples another.
    private static func stage(_ window: NSWindow) {
        let target = staged(window, window.frame)
        if target != window.frame { window.setFrame(target, display: false) }
    }

    private static func staged(_ window: NSWindow, _ frame: NSRect) -> NSRect {
        guard let role = role(of: window), let screen = stageScreen else { return frame }
        if window.isVisible, screen.frame.contains(frame), role != .menu { return frame }
        let visible = screen.visibleFrame
        let topLeft: NSPoint
        switch role {
        case .main: topLeft = NSPoint(x: visible.minX + visible.width * 0.07, y: visible.maxY - visible.height * 0.16)
        case .guide: topLeft = NSPoint(x: visible.minX + visible.width * 0.31, y: visible.maxY - visible.height * 0.08)
        case .settings: topLeft = NSPoint(x: visible.minX + visible.width * 0.58, y: visible.maxY - visible.height * 0.10)
        case .menu: topLeft = NSPoint(x: visible.maxX - frame.width - 10, y: visible.maxY - 6)
        }
        return NSRect(x: topLeft.x, y: topLeft.y - frame.height, width: frame.width, height: frame.height)
    }

    private static func installPlacementHook() {
        typealias Order = @convention(c) (NSWindow, Selector, NSWindow.OrderingMode, Int) -> Void
        swizzle(#selector(NSWindow.order(_:relativeTo:))) { imp, selector in
            let original = unsafeBitCast(imp, to: Order.self)
            let block: @convention(block) (NSWindow, NSWindow.OrderingMode, Int) -> Void = { window, mode, other in
                if mode != .out { MainActor.assumeIsolated { stage(window) } }
                original(window, selector, mode, other)
            }
            return block
        }
        typealias SetFrame = @convention(c) (NSWindow, Selector, NSRect, Bool) -> Void
        swizzle(#selector(NSWindow.setFrame(_:display:))) { imp, selector in
            let original = unsafeBitCast(imp, to: SetFrame.self)
            let block: @convention(block) (NSWindow, NSRect, Bool) -> Void = { window, frame, display in
                original(window, selector, MainActor.assumeIsolated { staged(window, frame) }, display)
            }
            return block
        }
        typealias SetFrameAnimated = @convention(c) (NSWindow, Selector, NSRect, Bool, Bool) -> Void
        swizzle(#selector(NSWindow.setFrame(_:display:animate:))) { imp, selector in
            let original = unsafeBitCast(imp, to: SetFrameAnimated.self)
            let block: @convention(block) (NSWindow, NSRect, Bool, Bool) -> Void = { window, frame, display, animate in
                original(window, selector, MainActor.assumeIsolated { staged(window, frame) }, display, animate)
            }
            return block
        }
        typealias SetOrigin = @convention(c) (NSWindow, Selector, NSPoint) -> Void
        swizzle(#selector(NSWindow.setFrameOrigin(_:))) { imp, selector in
            let original = unsafeBitCast(imp, to: SetOrigin.self)
            let block: @convention(block) (NSWindow, NSPoint) -> Void = { window, origin in
                let frame = MainActor.assumeIsolated { staged(window, NSRect(origin: origin, size: window.frame.size)) }
                original(window, selector, frame.origin)
            }
            return block
        }
    }

    private static func swizzle(_ selector: Selector, _ replacement: (IMP, Selector) -> Any) {
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else { return }
        method_setImplementation(method, imp_implementationWithBlock(replacement(method_getImplementation(method), selector)))
    }

    private static func openSettings() {
        if let appMenu = NSApp.mainMenu?.items.first?.submenu,
           let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }) {
            appMenu.performActionForItem(at: index)
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    private static func scrollFormToEnd(in window: NSWindow) {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, let document = scroll.documentView,
               document.frame.height > scroll.contentView.bounds.height + 1 { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let root = window.contentView, let scroll = find(root), let document = scroll.documentView else {
            return log("no scrolling form")
        }
        let clip = scroll.contentView
        let end = document.frame.height - clip.bounds.height + clip.contentInsets.bottom
        clip.scroll(to: NSPoint(x: 0, y: document.isFlipped ? end : -clip.contentInsets.bottom))
        scroll.reflectScrolledClipView(clip)
    }

    private static func selectToolbarItem(_ label: String, in window: NSWindow) {
        guard let item = window.toolbar?.items.first(where: { $0.label == label }), let action = item.action else {
            return log("no \(label) tab in \(window.toolbar?.items.map(\.label) ?? [])")
        }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    /// The panel is a clear window whose Liquid Glass samples the desktop behind it, and window
    /// captures leave that backdrop out (the glass comes out a flat mid-grey). Underlay a
    /// behind-window material, which captures do composite, so the glass has the desktop to
    /// sample, as it does on screen.
    private static func giveGlassADesktop(_ panel: NSWindow) {
        guard let host = panel.contentView, let frameView = host.superview,
              !frameView.subviews.contains(where: { $0 is NSVisualEffectView }) else { return }
        let desktop = NSVisualEffectView(frame: host.frame)
        // Chosen by eye against the dark and light stage wallpapers.
        desktop.material = panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .windowBackground : .popover
        desktop.blendingMode = .behindWindow
        desktop.state = .active
        desktop.autoresizingMask = [.width, .height]
        desktop.wantsLayer = true
        desktop.layer?.cornerRadius = 11
        desktop.layer?.cornerCurve = .continuous
        desktop.layer?.masksToBounds = true
        frameView.addSubview(desktop, positioned: .below, relativeTo: host)
    }

    /// On macOS 26+ a window-style MenuBarExtra opens as the status item's "expanded interface",
    /// which a click requests from the system (the button has no target or action to click);
    /// ask for it the same way. Earlier systems fall back to `performClick`.
    private static func requestExpandedInterface(_ button: NSStatusBarButton) {
        let selector = NSSelectorFromString("_requestExpandedInterfaceSession")
        guard let item = button.window?.value(forKey: "statusItem") as? NSStatusItem, item.responds(to: selector) else { return }
        item.perform(selector)
    }

    private static func statusItemButton() -> NSStatusBarButton? {
        func find(_ view: NSView) -> NSStatusBarButton? {
            if let button = view as? NSStatusBarButton { return button }
            return view.subviews.lazy.compactMap(find).first
        }
        return NSApp.windows.lazy
            .filter { String(describing: type(of: $0)).contains("StatusBar") }
            .compactMap { $0.contentView.flatMap(find) }
            .first
    }

    // MARK: - Content

    /// The mock's Auto latency swings between Interactive and Cinema and its frame rate wanders;
    /// hold the numbers at a typical Interactive moment on an MCU2 car so every shot agrees.
    private static func pinStats() {
        guard let mock = model.service as? PreviewService else { return }
        var stats = model.state.stats
        stats.fps = 30
        stats.latencyMs = 64
        stats.decodeMs = 3.7
        stats.rttMs = 9
        stats.effectiveLatencyMode = .interactive
        model.state.stats = stats
        mock.statsFrozen = true
    }

    /// The mock's log names itself; show what the real service writes during a session.
    private static func rewriteLog() {
        let state = model.state
        let now = Date()
        let expiry = state.network.certificateExpiry
            .map { " · certificate valid until \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
        let address = DashcastDefaults.serviceAddress
        state.log = [
            LogLine("Listening on http://localhost:\(DashcastDefaults.devPort)", date: now.addingTimeInterval(-96)),
            LogLine("Listening on http://\(address):80", date: now.addingTimeInterval(-96)),
            LogLine("Listening on https://\(DashcastDefaults.hostname) (\(address):443)\(expiry)", date: now.addingTimeInterval(-95)),
            LogLine("Car connected · MCU2 · 1280×720 H.264 30 fps (1080p decode 14.2 ms)", date: now.addingTimeInterval(-38)),
            LogLine("Capturing display 4", date: now.addingTimeInterval(-38)),
        ]
    }

    // MARK: - Helpers

    private static func poll<T>(_ timeout: Double, _ body: () -> T?) async -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = body() { return value }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return body()
    }

    private static func until(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        await poll(timeout) { condition() ? true : nil } ?? false
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func log(_ message: String) {
        print("[shots] \(message)")
        fflush(stdout)
    }
}
