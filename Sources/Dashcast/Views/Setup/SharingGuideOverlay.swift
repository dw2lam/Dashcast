import AppKit
import Observation
import SwiftUI

/// Guide Me's highlight: a ring around the control to use and a callout beside it saying what to
/// do. Both are click-through and never take focus, so System Settings works as normal underneath;
/// they follow its window as it moves and hide while it isn't the frontmost app.
@MainActor
final class SharingGuideOverlay {
    private var ring: OverlayPanel?
    private var bubble: OverlayPanel?
    private let callout = CalloutState()
    private var guidance: SharingGuidance?

    /// Above an open popup menu, so a ring around a menu item shows.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
    /// Space between the control and the ring.
    static let ringInset: CGFloat = 6

    func show(_ guidance: SharingGuidance?) {
        self.guidance = guidance
        guard let guidance, guidance.target != nil else { return hide() }
        callout.instruction = guidance.instruction
        callout.detail = guidance.detail
        // The bubble spells the password out; the name is in the instruction already.
        callout.copy = guidance.step == .password ? guidance.copy : nil
    }

    /// Repositions on System Settings' window (AppKit coordinates); nil or `visible` false hides.
    func follow(window: CGRect?, visible: Bool) {
        guard visible, let window, let guidance, let target = Self.target(guidance, window: window) else { return hide() }
        let screen = NSScreen.screens.first { $0.frame.intersects(target) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window

        let ring = self.ring ?? OverlayPanel(content: SharingRingView())
        self.ring = ring
        let ringFrame = target.insetBy(dx: -Self.ringInset - SharingRingView.pulse, dy: -Self.ringInset - SharingRingView.pulse)
        if ring.frame != ringFrame { ring.setFrame(ringFrame, display: true) }
        if !ring.isVisible { ring.orderFrontRegardless() }

        let bubble = self.bubble ?? OverlayPanel(content: SharingCalloutView(state: callout))
        self.bubble = bubble
        let size = bubble.fittingSize
        let placement = CalloutPlacement.frame(size: size, target: ringFrame, visible: screen)
        if callout.side != placement.side { callout.side = placement.side }
        let arrow = placement.arrow
        if abs(callout.arrow - arrow) > 0.5 { callout.arrow = arrow }
        if bubble.frame != placement.frame { bubble.setFrame(placement.frame, display: true) }
        if !bubble.isVisible { bubble.orderFrontRegardless() }
    }

    func hide() {
        ring?.orderOut(nil)
        bubble?.orderOut(nil)
    }

    func dismiss() {
        hide()
        ring?.close()
        bubble?.close()
        ring = nil
        bubble = nil
        guidance = nil
    }

    /// The control in AppKit coordinates, kept at its offset from the window's top-left corner as
    /// read (Accessibility coordinates are y-down from the top of the primary display).
    static func target(_ guidance: SharingGuidance, window: CGRect) -> CGRect? {
        guard let target = guidance.target, let read = guidance.window, target.width > 0, target.height > 0 else { return nil }
        let dx = target.minX - read.minX
        let dy = target.minY - read.minY
        return CGRect(x: window.minX + dx, y: window.maxY - dy - target.height, width: target.width, height: target.height)
    }
}

// MARK: - Placement

/// Where the callout goes: left of the control (it covers the row's label, not the next control),
/// else right, below, above; always on screen. AppKit coordinates.
enum CalloutPlacement {
    enum Side: Equatable { case left, right, below, above }

    static let gap: CGFloat = 6
    static let margin: CGFloat = 8

    struct Result: Equatable {
        let frame: CGRect
        let side: Side
        /// Where along the edge facing the control the arrow points, in points from the bubble's
        /// top (left/right) or leading edge (below/above).
        let arrow: CGFloat
    }

    static func frame(size: CGSize, target: CGRect, visible: CGRect) -> Result {
        let candidates: [(Side, CGPoint)] = [
            (.left, CGPoint(x: target.minX - gap - size.width, y: target.midY - size.height / 2)),
            (.right, CGPoint(x: target.maxX + gap, y: target.midY - size.height / 2)),
            (.below, CGPoint(x: target.midX - size.width / 2, y: target.minY - gap - size.height)),
            (.above, CGPoint(x: target.midX - size.width / 2, y: target.maxY + gap)),
        ]
        let inner = visible.insetBy(dx: margin, dy: margin)
        func fits(_ side: Side, _ origin: CGPoint) -> Bool {
            switch side {
            case .left: origin.x >= inner.minX
            case .right: origin.x + size.width <= inner.maxX
            case .below: origin.y >= inner.minY
            case .above: origin.y + size.height <= inner.maxY
            }
        }
        let (side, origin) = candidates.first { fits($0.0, $0.1) } ?? candidates[0]
        var clamped = origin
        clamped.x = max(inner.minX, min(clamped.x, inner.maxX - size.width))
        clamped.y = max(inner.minY, min(clamped.y, inner.maxY - size.height))
        let frame = CGRect(origin: clamped, size: size)
        let arrow: CGFloat
        switch side {
        case .left, .right: arrow = min(max(frame.maxY - target.midY, 16), size.height - 16)
        case .below, .above: arrow = min(max(target.midX - frame.minX, 16), size.width - 16)
        }
        return Result(frame: frame, side: side, arrow: arrow)
    }
}

// MARK: - Views

@MainActor
@Observable
final class CalloutState {
    var instruction = ""
    var detail: String?
    var copy: String?
    var side: CalloutPlacement.Side = .left
    var arrow: CGFloat = 30
}

/// The ring: an accent outline with a soft glow that breathes (still with Reduce Motion).
struct SharingRingView: View {
    /// Room around the ring for the breathing.
    static let pulse: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Color.dashAccent, lineWidth: 3)
            .shadow(color: Color.dashAccent.opacity(0.7), radius: breathing ? 6 : 3)
            .padding(Self.pulse)
            .scaleEffect(breathing ? 1.04 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: breathing)
            .onAppear { if !reduceMotion { breathing = true } }
            .allowsHitTesting(false)
    }
}

/// The callout: what to do, in the accent colour, with an arrow at the control.
struct SharingCalloutView: View {
    let state: CalloutState
    static let arrowSize = CGSize(width: 9, height: 16)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.instruction)
                .font(.title3.weight(.semibold))
            if let copy = state.copy {
                Text(copy)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .textSelection(.disabled)
            }
            if let detail = state.detail {
                Text(detail)
                    .font(.callout)
                    .opacity(0.85)
            }
        }
        .foregroundStyle(.white)
        .fixedSize()
        .frame(maxWidth: 260, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.dashAccent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: arrowAlignment) { arrow }
        .padding(arrowPadding)
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .padding(10)
        .accessibilityElement(children: .combine)
    }

    private var arrowAlignment: Alignment {
        switch state.side {
        case .left: .topTrailing
        case .right: .topLeading
        case .below: .topLeading
        case .above: .bottomLeading
        }
    }

    private var arrowPadding: EdgeInsets {
        let depth = Self.arrowSize.width
        switch state.side {
        case .left: return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: depth)
        case .right: return EdgeInsets(top: 0, leading: depth, bottom: 0, trailing: 0)
        case .below: return EdgeInsets(top: depth, leading: 0, bottom: 0, trailing: 0)
        case .above: return EdgeInsets(top: 0, leading: 0, bottom: depth, trailing: 0)
        }
    }

    /// Offsets are from the bubble's top or leading edge; the window adds 10 pt of shadow room.
    private var arrow: some View {
        let size = Self.arrowSize
        let along = max(14, state.arrow - 10)
        return CalloutArrow(side: state.side)
            .fill(Color.dashAccent)
            .frame(width: state.side == .left || state.side == .right ? size.width : size.height,
                   height: state.side == .left || state.side == .right ? size.height : size.width)
            .offset(x: offsetX(along: along, size: size), y: offsetY(along: along, size: size))
    }

    private func offsetX(along: CGFloat, size: CGSize) -> CGFloat {
        switch state.side {
        case .left: size.width
        case .right: -size.width
        case .below, .above: along - size.height / 2
        }
    }

    private func offsetY(along: CGFloat, size: CGSize) -> CGFloat {
        switch state.side {
        case .left, .right: along - size.height / 2
        case .below: -size.width
        case .above: size.width
        }
    }
}

/// A triangle pointing away from the bubble, towards the control.
private struct CalloutArrow: Shape {
    let side: CalloutPlacement.Side

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch side {
        case .left:   // points right
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        case .right:  // points left
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .below:  // points up
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .above:  // points down
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Window

/// Borderless, transparent, click-through and never key: the overlay can't get in the way.
private final class OverlayPanel: NSPanel {
    private let hosting: NSView

    init<Content: View>(content: Content) {
        hosting = NSHostingView(rootView: content)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = SharingGuideOverlay.level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        contentView = hosting
    }

    var fittingSize: CGSize { hosting.fittingSize }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
