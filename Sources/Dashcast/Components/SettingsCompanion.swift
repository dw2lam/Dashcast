import AppKit
import SwiftUI

// A small floating panel that sits beside the System Settings window and follows it: the
// drag-to-authorize panel (PermissionGuide) and the Internet Sharing coach (HotspotCoach), which
// also moves Guide Me's highlight along with the window.

/// Keeps a `GuidePanel` beside System Settings while it's the frontmost app, hides it otherwise, and
/// gives up when Settings closes (or never comes up) or stays in the background for a minute.
@MainActor
final class SettingsCompanion {
    /// While System Settings is in front: often enough to follow its window as it's dragged.
    static let tickInterval: TimeInterval = 1.0 / 20
    /// While it's in the background (the panel is hidden): enough to notice it closing. Coming to
    /// the front ticks at once (an activation notification), so nothing waits for this.
    static let backgroundTickInterval: TimeInterval = 0.5

    private(set) var panel: GuidePanel?
    /// Keeps the panel showing while System Settings isn't frontmost (mid-drag).
    var holdsVisible = false
    /// System Settings' window at the last tick (AppKit coordinates), and whether it was in front.
    private(set) var settingsFrame: CGRect?
    private(set) var settingsInFront = false
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var onTick: (() -> Void)?
    private var onGiveUp: (() -> Void)?
    private var shownAt = Date()
    private var settingsLastSeen: Date?
    private var settingsLastFront = Date()

    var isShowing: Bool { panel != nil }

    /// `onTick` runs on every tick, 20 times a second while System Settings is in front and twice a
    /// second otherwise (it may dismiss); `onGiveUp` when Settings has gone away.
    func show<Content: View>(_ content: Content, onTick: @escaping () -> Void = {}, onGiveUp: @escaping () -> Void) {
        dismiss()
        shownAt = Date()
        settingsLastSeen = nil
        settingsLastFront = Date()
        panel = GuidePanel(content: content)
        self.onTick = onTick
        self.onGiveUp = onGiveUp
        schedule(Self.tickInterval)
        // Any app coming to the front: System Settings (show the panel now, at full rate) or
        // another one (hide it now, and slow down).
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func schedule(_ interval: TimeInterval) {
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        holdsVisible = false
        settingsFrame = nil
        settingsInFront = false
        onTick = nil
        onGiveUp = nil
    }

    private func tick() {
        guard let panel else { return }
        let now = Date()
        settingsFrame = SettingsWindow.frame()
        settingsInFront = SettingsWindow.isFrontmost
        onTick?()
        guard self.panel === panel else { return }

        schedule(settingsInFront || holdsVisible ? Self.tickInterval : Self.backgroundTickInterval)
        guard let window = settingsFrame else {
            panel.orderOut(nil)
            // Closed (or it never came up): give up.
            let deadline: TimeInterval = settingsLastSeen == nil ? 10 : 1.5
            if now.timeIntervalSince(settingsLastSeen ?? shownAt) > deadline { giveUp() }
            return
        }
        settingsLastSeen = now
        guard settingsInFront || holdsVisible else {
            panel.orderOut(nil)
            if now.timeIntervalSince(settingsLastFront) > 60 { giveUp() }
            return
        }
        settingsLastFront = now

        let visible = NSScreen.screens.first { $0.frame.contains(CGPoint(x: window.midX, y: window.midY)) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? window
        // The panel's content can change size (the coach's progress list grows).
        let size = (panel.contentView?.fittingSize).flatMap { $0.width > 0 ? $0 : nil } ?? panel.frame.size
        let frame = PanelPlacement.frame(size: size, beside: window, visible: visible)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func giveUp() {
        let handler = onGiveUp
        dismiss()
        handler?()
    }
}

// MARK: - Placement

/// Where the panel sits beside the System Settings window. Frames are AppKit screen coordinates
/// (origin bottom-left of the primary display, y up).
enum PanelPlacement {
    static let gap: CGFloat = 14
    static let margin: CGFloat = 8
    /// Down from the window's top edge, about where a privacy pane's app list starts.
    static let topInset: CGFloat = 64

    /// A window-server rect (origin top-left of the primary display, y down) in AppKit coordinates.
    static func appKitRect(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Right of the window when it fits, else left of it, else over its lower-right corner; always
    /// inside `visible` (the screen's visible frame).
    static func frame(size: CGSize, beside window: CGRect, visible: CGRect) -> CGRect {
        var origin = CGPoint(x: window.maxX + gap, y: window.maxY - topInset - size.height)
        if origin.x + size.width > visible.maxX - margin {
            if window.minX - gap - size.width >= visible.minX + margin {
                origin.x = window.minX - gap - size.width
            } else {
                origin = CGPoint(x: window.maxX - gap - size.width, y: window.minY + gap)
            }
        }
        origin.x = max(visible.minX + margin, min(origin.x, visible.maxX - margin - size.width))
        origin.y = max(visible.minY + margin, min(origin.y, visible.maxY - margin - size.height))
        return CGRect(origin: origin, size: size)
    }
}

/// System Settings' main window, read from the window server (needs no permission).
enum SettingsWindow {
    static let bundleIdentifier = "com.apple.systempreferences"

    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier
    }

    /// Its largest on-screen window at the normal level, in AppKit coordinates.
    @MainActor
    static func frame() -> CGRect? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).map(\.processIdentifier))
        guard !pids.isEmpty, let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let frames = windows.compactMap { info -> CGRect? in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width > 320, rect.height > 240 else { return nil }
            return rect
        }
        return frames.max { $0.width * $0.height < $1.width * $1.height }
            .map { PanelPlacement.appKitRect($0, primaryScreenHeight: primary.frame.height) }
    }
}

// MARK: - Panel

/// Floating and non-activating, and never key, so System Settings stays the active app underneath.
final class GuidePanel: NSPanel {
    init<Content: View>(content: Content) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
        let hosting = FirstMouseHostingView(rootView: content)
        contentView = hosting
        setContentSize(hosting.fittingSize)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Clicks land on the first try in a window that never becomes key.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
