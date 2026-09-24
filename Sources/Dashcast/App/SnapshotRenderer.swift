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

            // Settings tabs.
            Shot(name: "settings-general", width: 520, content: { AnyView(GeneralSettings()) }),
            Shot(name: "settings-display", width: 520, content: { AnyView(DisplaySettings()) }),
            Shot(name: "settings-display-mirror", settings: mirror, width: 520, content: { AnyView(DisplaySettings()) }),
            Shot(name: "settings-network", scenario: .init(certificate: false), size: CGSize(width: 520, height: 560),
                 content: { AnyView(NetworkSettings()) }),
            Shot(name: "settings-network-router", scenario: .init(topology: .router, conflict: true),
                 size: CGSize(width: 520, height: 560), content: { AnyView(NetworkSettings(routerExpanded: true)) }),
            Shot(name: "settings-advanced", scenario: .init(phase: .streaming), width: 520,
                 content: { AnyView(AdvancedSettings()) }),

            // Menu bar panel.
            Shot(name: "menu-idle", width: 300, content: { AnyView(MenuBarPanel()) }),
            Shot(name: "menu-casting", scenario: .init(phase: .streaming), width: 300, content: { AnyView(MenuBarPanel()) }),

            // Setup assistant.
            Shot(name: "setup-1-permissions", scenario: .init(fresh: true), size: CGSize(width: 440, height: 480),
                 content: { AnyView(SetupAssistant(step: 0)) }),
            Shot(name: "setup-2-connect", scenario: .init(topology: .offline, fresh: true), size: CGSize(width: 440, height: 480),
                 content: { AnyView(SetupAssistant(step: 1)) }),
            Shot(name: "setup-2-connect-done", size: CGSize(width: 440, height: 480),
                 content: { AnyView(SetupAssistant(step: 1)) }),
            Shot(name: "setup-3-tesla", size: CGSize(width: 440, height: 480),
                 content: { AnyView(SetupAssistant(step: 2)) }),

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
        let controller = AppController()
        let root = shot.content()
            .environment(model)
            .environment(controller)
            // Offscreen windows are never key; draw controls as they look in the active window.
            .environment(\.controlActiveState, .key)

        let hosting = NSHostingView(rootView: root)
        hosting.sceneBridgingOptions = [.toolbars]
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
