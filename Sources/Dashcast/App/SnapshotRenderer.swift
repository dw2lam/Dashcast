import AppKit
import DashcastContracts
import SwiftUI

/// `DASHCAST_SNAPSHOT=/dir`: renders every screen against the mock service, in light and dark, into
/// PNGs — entirely offscreen (windows are never ordered in; the app runs with `.prohibited`
/// policy), so it never touches the screen. Used for design review.
///
/// Limitation: Liquid Glass and materials are composited by the window server, so offscreen they
/// can't render. Snapshot mode (`RenderMode.offscreen`) swaps glass for flat stand-ins with the
/// same geometry; judge layout, type and copy here, glass on a real window.
@MainActor
enum SnapshotRenderer {
    struct Shot {
        let name: String
        var scenario = PreviewService.Scenario()
        var settings = ServiceSettings()
        /// nil = the view's fitting size at `width`.
        var size: CGSize?
        var width: CGFloat = 460
        /// Host in a titled window (toolbar, traffic lights) vs. bare content.
        var windowed = false
        /// Puts the model in the state the shot shows before it renders.
        var prepare: @MainActor (AppModel) -> Void = { _ in }
        let content: () -> AnyView
    }

    static var shots: [Shot] {
        let main = { AnyView(MainView()) }
        var mirror = ServiceSettings()
        mirror.displayMode = .mirror
        return [
            // Main window, every state.
            Shot(name: "main-ready", size: MainView.size, windowed: true, content: main),
            Shot(name: "main-needs-setup", scenario: .init(topology: .offline, fresh: true),
                 size: MainView.size, windowed: true, content: main),
            Shot(name: "main-waiting-secure", scenario: .init(phase: .waiting), size: MainView.size, windowed: true, content: main),
            Shot(name: "main-waiting-compat", scenario: .init(phase: .waiting, certificate: false),
                 size: MainView.size, windowed: true, content: main),
            Shot(name: "main-casting", scenario: .init(phase: .streaming), size: MainView.size, windowed: true, content: main),
            Shot(name: "main-casting-mirror", scenario: .init(phase: .streaming), settings: mirror,
                 size: MainView.size, windowed: true, content: main),
            Shot(name: "main-error", scenario: .init(phase: .error), size: MainView.size, windowed: true, content: main),
            Shot(name: "main-conflict", scenario: .init(topology: .phoneHotspot, conflict: true),
                 size: MainView.size, windowed: true, content: main),
            Shot(name: "main-waiting-disconnected", scenario: .init(certificate: false, disconnect: .leftWiFi),
                 size: MainView.size, windowed: true, content: main),
            Shot(name: "main-paused-locked", scenario: .init(phase: .streaming, host: .locked),
                 size: MainView.size, windowed: true, content: main),

            // Settings tabs.
            Shot(name: "settings-general", size: CGSize(width: 520, height: 930), content: { AnyView(GeneralSettings()) }),
            Shot(name: "settings-display", width: 520, content: { AnyView(DisplaySettings()) }),
            Shot(name: "settings-display-mirror", settings: mirror, width: 520, content: { AnyView(DisplaySettings()) }),
            Shot(name: "settings-network", scenario: .init(certificate: false), size: CGSize(width: 520, height: 560),
                 content: { AnyView(NetworkSettings()) }),
            Shot(name: "settings-network-router", scenario: .init(topology: .router, conflict: true),
                 size: CGSize(width: 520, height: 560), content: { AnyView(NetworkSettings(routerExpanded: true)) }),
            Shot(name: "settings-advanced", scenario: .init(phase: .streaming), width: 520,
                 content: { AnyView(AdvancedSettings()) }),

            // Secure mode on the user's own domain (Settings → Network's sections, unscrolled).
            Shot(name: "domain-none", scenario: .init(certificate: false), size: CGSize(width: 520, height: 300),
                 content: { AnyView(DomainSectionsSnapshot()) }),
            Shot(name: "domain-cloudflare", scenario: .init(domain: .cloudflare), size: CGSize(width: 520, height: 620),
                 content: { AnyView(DomainSectionsSnapshot()) }),
            Shot(name: "domain-cloudflare-token", scenario: .init(domain: .cloudflare, token: true), size: CGSize(width: 520, height: 420),
                 content: { AnyView(DomainSectionsSnapshot()) }),
            Shot(name: "domain-manual", scenario: .init(domain: .manual), size: CGSize(width: 520, height: 470),
                 content: { AnyView(DomainSectionsSnapshot()) }),
            Shot(name: "domain-secure", size: CGSize(width: 520, height: 420), content: { AnyView(DomainSectionsSnapshot()) }),
            Shot(name: "domain-sheet", scenario: .init(certificate: false), size: CGSize(width: 520, height: 600),
                 content: { AnyView(OwnDomainSheet()) }),

            // The drag-to-authorize panel that floats beside System Settings.
            Shot(name: "permission-panel-screen", width: 300,
                 content: { AnyView(PermissionPanelView(pane: .screenRecording, relaunch: {}).padding(10)) }),
            Shot(name: "permission-panel-accessibility", width: 300,
                 content: { AnyView(PermissionPanelView(pane: .accessibility).padding(10)) }),

            // Car hotspot setup: the wizard at every step, and the coach beside System Settings.
            ] + hotspotShots + [

            // Menu bar panel.
            Shot(name: "menu-idle", width: 300, content: { AnyView(MenuBarPanel()) }),
            Shot(name: "menu-needs-hotspot", scenario: .init(topology: .offline), width: 300, content: { AnyView(MenuBarPanel()) }),
            Shot(name: "menu-casting", scenario: .init(phase: .streaming), width: 300, content: { AnyView(MenuBarPanel()) }),
            Shot(name: "menu-disconnected", scenario: .init(certificate: false, disconnect: .leftWiFi), width: 300,
                 content: { AnyView(MenuBarPanel()) }),
            Shot(name: "menu-paused", scenario: .init(phase: .streaming, host: .locked), width: 300,
                 content: { AnyView(MenuBarPanel()) }),
            Shot(name: "menubar-notice", scenario: .init(disconnect: .leftWiFi), width: 150,
                 prepare: { $0.disconnectChanged(notify: false) }, content: { AnyView(MenuBarLabelSample()) }),
            Shot(name: "menubar-notice-browser", scenario: .init(disconnect: .browserClosed), width: 150,
                 prepare: { $0.disconnectChanged(notify: false) }, content: { AnyView(MenuBarLabelSample()) }),

            // Setup assistant.
            Shot(name: "setup-1-permissions", scenario: .init(fresh: true), size: CGSize(width: 440, height: 480),
                 content: { AnyView(SetupAssistant(step: 0)) }),
            // Measured permission health, one state each (Screen Recording; Accessibility working).
            ] + PermissionHealth.allCases.filter { $0 != .checking }.map { health in
                Shot(name: "setup-1-\(health.rawValue)", size: CGSize(width: 440, height: 480),
                     prepare: { $0.permissions.pin(health, for: .screenRecording); $0.permissions.pin(.working, for: .accessibility) },
                     content: { AnyView(SetupAssistant(step: 0)) })
            } + [
            Shot(name: "main-permission-stale", size: MainView.size, windowed: true,
                 prepare: { $0.permissions.pin(.grantedButNotWorking, for: .screenRecording); $0.permissions.pin(.working, for: .accessibility) },
                 content: main),
            Shot(name: "main-permission-relaunch", size: MainView.size, windowed: true,
                 prepare: { $0.permissions.pin(.needsRelaunch, for: .screenRecording); $0.permissions.pin(.denied, for: .accessibility) },
                 content: main),
            Shot(name: "settings-general-permissions", size: CGSize(width: 520, height: 930),
                 prepare: { $0.permissions.pin(.grantedButNotWorking, for: .screenRecording); $0.permissions.pin(.denied, for: .accessibility) },
                 content: { AnyView(GeneralSettings()) }),
            Shot(name: "setup-2-connect", scenario: .init(topology: .offline, fresh: true), size: CGSize(width: 440, height: 480),
                 content: { AnyView(SetupAssistant(step: 1)) }),
            Shot(name: "setup-2-connect-done", size: CGSize(width: 440, height: 480),
                 content: { AnyView(SetupAssistant(step: 1)) }),
            Shot(name: "setup-3-secure", scenario: .init(certificate: false), size: CGSize(width: 440, height: 480),
                 content: { AnyView(SetupAssistant(step: 2)) }),
            Shot(name: "setup-3-secure-done", size: CGSize(width: 440, height: 480),
                 content: { AnyView(SetupAssistant(step: 2)) }),
            Shot(name: "setup-4-tesla", scenario: .init(certificate: false), size: CGSize(width: 440, height: 480),
                 content: { AnyView(SetupAssistant(step: 3)) }),

            // Connection guide: each method expanded, the real window, and live checks while casting.
            Shot(name: "guide-a-hotspot", scenario: .init(topology: .offline, fresh: true), width: 580,
                 content: { AnyView(ConnectionGuide(expanded: [.macHotspot], scrolls: false)) }),
            Shot(name: "guide-a-hotspot-casting", scenario: .init(phase: .streaming), width: 580,
                 content: { AnyView(ConnectionGuide(expanded: [.macHotspot], scrolls: false)) }),
            Shot(name: "guide-b-router", scenario: .init(topology: .router, certificate: false), width: 580,
                 content: { AnyView(ConnectionGuide(expanded: [.travelRouter], scrolls: false)) }),
            Shot(name: "guide-c-phone", scenario: .init(topology: .phoneHotspot), width: 580,
                 content: { AnyView(ConnectionGuide(expanded: [.phoneHotspot], scrolls: false)) }),
            Shot(name: "guide-window", scenario: .init(topology: .offline, fresh: true), size: ConnectionGuide.size, windowed: true,
                 content: { AnyView(ConnectionGuide()) }),
            Shot(name: "router-setup", scenario: .init(topology: .router), width: 520,
                 content: { AnyView(RouterSetupSheet()) }),

            Shot(name: "router-login", scenario: .init(topology: .router), size: CGSize(width: 440, height: 360),
                 content: { AnyView(RouterLoginSheet()) }),
        ]
    }

    private static var hotspotShots: [Shot] {
        let wizard = { AnyView(HotspotSetupView(polls: false)) }
        let coach = { AnyView(HotspotCoachView().padding(10)) }
        /// The Tesla joined half a minute ago and never checked in.
        let joinedAWhileAgo: @MainActor (AppModel) -> Void = { $0.trackHotspotCar(now: Date().addingTimeInterval(-30)) }
        /// "Do It for Me" couldn't type the password; Guide Me points at the field.
        let guidingPassword: @MainActor (AppModel) -> Void = { model in
            let plan = model.sharingPlan
            model.sharingAssistant.pin(.guiding, plan: plan, step: .password,
                                       handoff: "Couldn’t type the password: System Settings isn’t in front.",
                                       guidance: SharingGuidance(step: .password, instruction: "Type this password:", copy: plan.password))
        }
        func shot(_ name: String, _ stage: HotspotStage, phase: PreviewService.Scenario.Phase = .idle,
                  prepare: @escaping @MainActor (AppModel) -> Void = { _ in }) -> Shot {
            Shot(name: "hotspot-\(name)", scenario: .init(phase: phase, hotspot: stage), size: HotspotSetupView.size,
                 windowed: true, prepare: prepare, content: wizard)
        }
        return [
            shot("1-phone-wifi", .phoneWiFi),
            shot("1-no-internet", .unconfigured),
            shot("1-without-internet", .unconfigured, prepare: { $0.hotspotWithoutInternet = true }),
            shot("2-phone-without-internet", .phoneWiFi, prepare: { $0.hotspotWithoutInternet = true }),
            shot("2-partial", .partial),
            shot("2-configured-off", .configuredOff),
            shot("2-starting", .starting),
            shot("3-waiting", .on, phase: .waiting),
            shot("3-other-device", .otherDevice, phase: .waiting),
            shot("4-no-answer-idle", .carJoined, prepare: joinedAWhileAgo),
            shot("4-no-answer-ready", .carJoined, phase: .waiting, prepare: joinedAWhileAgo),
            shot("5-checked", .checked, phase: .waiting),
            shot("6-connected", .connected),
            // Step 2's two modes, and a run of each.
            shot("2-auto-no-accessibility", .partial, prepare: { $0.permissions.pin(.denied, for: .accessibility) }),
            shot("2-auto-no-cable", .unconfigured, prepare: { $0.hotspotWithoutInternet = true }),
            shot("2-auto-running", .partial, prepare: { $0.sharingAssistant.pin(.automating, plan: $0.sharingPlan, step: .toWiFi) }),
            shot("2-auto-touch-id", .partial, prepare: { $0.sharingAssistant.pin(.automating, plan: $0.sharingPlan, step: .shareFrom, waitingForYou: true) }),
            shot("2-auto-late", .starting, prepare: { $0.sharingAssistant.pin(.finished(Date().addingTimeInterval(-60)), plan: $0.sharingPlan) }),
            shot("2-guide-idle", .partial, prepare: { $0.sharingAssistant.preferredMode = .guided }),
            shot("2-guide-no-accessibility", .partial, prepare: {
                $0.sharingAssistant.preferredMode = .guided
                $0.permissions.pin(.denied, for: .accessibility)
            }),
            shot("2-guide-handoff", .partial, prepare: guidingPassword),
            shot("3-password", .on, phase: .waiting, prepare: { $0.sharingAssistant.onOptionsSaved?($0.sharingPlan) }),
            Shot(name: "hotspot-coach-automating", scenario: .init(hotspot: .partial), width: 330,
                 prepare: { $0.sharingAssistant.pin(.automating, plan: $0.sharingPlan, step: .channel) }, content: coach),
            Shot(name: "hotspot-coach-guiding", scenario: .init(hotspot: .partial), width: 330, prepare: guidingPassword, content: coach),
            Shot(name: "hotspot-overlay-share-from", size: GuideOverlaySample.size,
                 content: { AnyView(GuideOverlaySample(password: false)) }),
            Shot(name: "hotspot-overlay-password", size: GuideOverlaySample.size,
                 content: { AnyView(GuideOverlaySample(password: true)) }),
            Shot(name: "hotspot-coach-phone-wifi", scenario: .init(hotspot: .phoneWiFi), width: 330, content: coach),
            Shot(name: "hotspot-coach-partial", scenario: .init(hotspot: .partial), width: 330, content: coach),
            Shot(name: "hotspot-coach-starting", scenario: .init(hotspot: .starting), width: 330, content: coach),
        ]
    }

    static func run(into directory: URL) async {
        RenderMode.offscreen = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let only = ProcessInfo.processInfo.environment["DASHCAST_SNAPSHOT_ONLY"]
        for shot in shots where only.map({ shot.name.hasPrefix($0) }) ?? true {
            for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                guard let appearance = NSAppearance(named: name) else { continue }
                let url = directory.appendingPathComponent("\(shot.name)-\(suffix).png")
                if let png = await render(shot, appearance: appearance) {
                    try? png.write(to: url)
                    print("wrote \(url.path)")
                } else {
                    print("failed \(shot.name)-\(suffix)")
                }
            }
        }
    }

    private static func render(_ shot: Shot, appearance: NSAppearance) async -> Data? {
        let model = AppModel(wired: Wiring.mock(settings: shot.settings, scenario: shot.scenario), settings: shot.settings)
        shot.prepare(model)
        let controller = AppController()
        let root = shot.content()
            .environment(model)
            .environment(controller)
            // Offscreen windows are never key; draw controls as they look in the active window.
            .environment(\.controlActiveState, .key)

        let hosting = NSHostingView(rootView: root)
        hosting.sceneBridgingOptions = [.toolbars]
        // A fixed-size shot stays that size (a scroll-disabled Form reports a huge ideal height offscreen).
        if shot.size != nil, !shot.windowed { hosting.sizingOptions = [] }
        var size = shot.size ?? CGSize(width: shot.width, height: 600)
        if shot.size == nil {
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            size = CGSize(width: shot.width, height: max(120, hosting.fittingSize.height))
        }
        let style: NSWindow.StyleMask = shot.windowed
            ? [.titled, .closable, .miniaturizable, .fullSizeContentView]
            : [.borderless]
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.title = "Dashcast"
        window.titlebarAppearsTransparent = true
        window.contentView = hosting
        defer { window.close() }

        // Let SwiftUI lay out, run onAppear/tasks and settle animations.
        for _ in 0..<4 {
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(200))
        }

        // The theme frame includes the titlebar, traffic lights and toolbar.
        let target: NSView = (shot.windowed ? hosting.superview : nil) ?? hosting
        target.layoutSubtreeIfNeeded()
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return nil }
        appearance.performAsCurrentDrawingAppearance {
            target.cacheDisplay(in: target.bounds, to: rep)
        }
        return flatten(rep, appearance: appearance)
    }

    /// Composites the (partly transparent) capture over the window background colour.
    private static func flatten(_ rep: NSBitmapImageRep, appearance: NSAppearance) -> Data? {
        let size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        guard let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: output) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
        }
        rep.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1,
                 respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return output.representation(using: .png, properties: [:])
    }
}

/// The own-domain sections on their own (Settings → Network shows them among its other sections).
private struct DomainSectionsSnapshot: View {
    var body: some View {
        Form { OwnDomainSections() }
            .formStyle(.grouped)
    }
}

/// Guide Me's ring and callout over a sketch of the Internet Sharing sheet (the real overlay is two
/// click-through windows over System Settings).
private struct GuideOverlaySample: View {
    let password: Bool
    static let size = CGSize(width: 640, height: 300)

    private let callout = CalloutState()

    var body: some View {
        let field = password ? CGRect(x: 380, y: 170, width: 200, height: 24) : CGRect(x: 470, y: 120, width: 110, height: 24)
        let ring = field.insetBy(dx: -SharingGuideOverlay.ringInset - SharingRingView.pulse,
                                 dy: -SharingGuideOverlay.ringInset - SharingRingView.pulse)
        // Placement works y-up (AppKit); this canvas is y-down.
        let flip = { (r: CGRect) in CGRect(x: r.minX, y: Self.size.height - r.maxY, width: r.width, height: r.height) }
        let state = callout
        state.instruction = password ? "Type this password:" : "Choose iPhone USB"
        state.copy = password ? "maplesky47" : nil
        state.detail = password ? "You’ll type it in your Tesla too." : nil
        let size = NSHostingView(rootView: SharingCalloutView(state: state)).fittingSize
        let placement = CalloutPlacement.frame(size: size, target: flip(ring), visible: CGRect(origin: .zero, size: Self.size))
        state.side = placement.side
        state.arrow = placement.arrow
        let bubble = flip(placement.frame)

        return ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator) }
                .frame(width: 600, height: 260)
                .offset(x: 20, y: 20)
            sketchRow("Share your connection from", value: "Wi-Fi", popup: true, y: 120)
            sketchRow("Password:", value: password ? "" : "••••••••", popup: false, y: 170)
            SharingRingView()
                .frame(width: ring.width, height: ring.height)
                .offset(x: ring.minX, y: ring.minY)
            SharingCalloutView(state: state)
                .frame(width: bubble.width, height: bubble.height)
                .offset(x: bubble.minX, y: bubble.minY)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private func sketchRow(_ label: String, value: String, popup: Bool, y: CGFloat) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value + (popup ? "  ⌄" : ""))
                .padding(.horizontal, 8)
                .frame(width: popup ? 110 : 200, height: 24, alignment: popup ? .trailing : .leading)
                .background(Color(nsColor: popup ? .controlColor : .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }
        }
        .frame(width: 540, height: 24)
        .offset(x: 40, y: y)
    }
}

/// The status item's label as a bar-height strip.
private struct MenuBarLabelSample: View {
    @Environment(AppModel.self) private var model
    @Environment(AppController.self) private var controller

    var body: some View {
        MenuBarLabel(model: model, controller: controller)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
