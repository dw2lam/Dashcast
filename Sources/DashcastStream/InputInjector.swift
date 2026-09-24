import AppKit
import ApplicationServices
import CoreGraphics
import DashcastContracts
import Foundation

/// Turns car touches into synthetic CGEvents on the captured display. Work runs on a private
/// serial queue; nothing is posted unless the Accessibility permission is granted.
final class InputInjector {
    struct Target: Equatable {
        var displayID: CGDirectDisplayID
        /// Encoded frame size; the display is letterboxed into it when aspects differ.
        var frameWidth: Int
        var frameHeight: Int
    }

    /// Called (on the injector queue) the first time an event is dropped for lack of permission.
    var onPermissionMissing: (() -> Void)?

    private let queue = DispatchQueue(label: "online.davidlam.dashcast.input", qos: .userInteractive)
    private var target: Target?
    private var buttonDown = false
    private var lastPoint = CGPoint.zero
    private var lastDown: (time: TimeInterval, point: CGPoint)?
    private var clickCount: Int64 = 1
    private var trusted = false
    private var trustCheckedAt: TimeInterval = -.infinity
    private var reportedMissingPermission = false
    private let source = CGEventSource(stateID: .hidSystemState)

    func setTarget(_ target: Target?) {
        queue.async { [self] in
            if target?.displayID != self.target?.displayID { releaseButton() }
            self.target = target
            reportedMissingPermission = false
        }
    }

    func inject(_ event: InputEvent) {
        queue.async { [self] in handle(event) }
    }

    /// Waits for queued events (tests).
    func drain() { queue.sync {} }

    // MARK: Mapping

    /// Normalized frame coordinates → global display coordinates (points), undoing SCK's
    /// centered aspect-fit letterboxing and clamping onto the display.
    static func point(x: Double, y: Double, displayBounds bounds: CGRect, frameSize: CGSize) -> CGPoint {
        var nx = x.isFinite ? x : 0.5
        var ny = y.isFinite ? y : 0.5
        if frameSize.width > 0, frameSize.height > 0, bounds.width > 0, bounds.height > 0 {
            let scale = min(frameSize.width / bounds.width, frameSize.height / bounds.height)
            let content = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let origin = CGPoint(x: (frameSize.width - content.width) / 2, y: (frameSize.height - content.height) / 2)
            nx = (nx * frameSize.width - origin.x) / content.width
            ny = (ny * frameSize.height - origin.y) / content.height
        }
        nx = min(max(nx, 0), 1)
        ny = min(max(ny, 0), 1)
        // Stay inside the last pixel column/row, or the event lands on the neighboring display.
        let px = min(bounds.minX + nx * bounds.width, bounds.maxX - 1)
        let py = min(bounds.minY + ny * bounds.height, bounds.maxY - 1)
        return CGPoint(x: px, y: py)
    }

    /// Virtual key codes for the named keys the car can send (KeyboardEvent.key names).
    static func keyCode(for name: String) -> CGKeyCode? {
        switch name.lowercased() {
        case "enter", "return": return 36
        case "tab": return 48
        case "space", " ": return 49
        case "backspace": return 51
        case "escape", "esc": return 53
        case "delete": return 117
        case "home": return 115
        case "end": return 119
        case "pageup": return 116
        case "pagedown": return 121
        case "arrowleft", "left": return 123
        case "arrowright", "right": return 124
        case "arrowdown", "down": return 125
        case "arrowup", "up": return 126
        default: return nil
        }
    }

    // MARK: Posting

    private func handle(_ event: InputEvent) {
        guard let target, isTrusted() else { return }
        let bounds = CGDisplayBounds(target.displayID)
        guard !bounds.isEmpty else { return }
        let point = Self.point(x: event.x, y: event.y, displayBounds: bounds,
                               frameSize: CGSize(width: target.frameWidth, height: target.frameHeight))

        switch event.kind {
        case .down:
            let now = ProcessInfo.processInfo.systemUptime
            if let last = lastDown, now - last.time <= NSEvent.doubleClickInterval,
               hypot(point.x - last.point.x, point.y - last.point.y) < 6 {
                clickCount = min(clickCount + 1, 3)
            } else {
                clickCount = 1
            }
            lastDown = (now, point)
            if buttonDown { mouse(.leftMouseUp, at: lastPoint, button: .left) }
            mouse(.mouseMoved, at: point, button: .left)
            mouse(.leftMouseDown, at: point, button: .left)
            buttonDown = true
        case .move:
            mouse(buttonDown ? .leftMouseDragged : .mouseMoved, at: point, button: .left)
        case .up:
            mouse(.leftMouseUp, at: point, button: .left)
            buttonDown = false
        case .rightClick:
            releaseButton()
            mouse(.mouseMoved, at: point, button: .left)
            clickCount = 1
            mouse(.rightMouseDown, at: point, button: .right)
            mouse(.rightMouseUp, at: point, button: .right)
        case .scroll:
            scroll(dx: event.dx ?? 0, dy: event.dy ?? 0, at: point)
        case .text:
            if let text = event.text, !text.isEmpty { type(text) }
        case .key:
            if let name = event.key, let code = Self.keyCode(for: name) { press(code) }
        }
    }

    private func mouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        event.flags = []
        if type == .leftMouseDown || type == .leftMouseUp || type == .rightMouseDown || type == .rightMouseUp {
            event.setIntegerValueField(.mouseEventClickState, value: clickCount)
        }
        event.post(tap: .cghidEventTap)
        lastPoint = point
    }

    /// `dx`/`dy` follow WheelEvent semantics (positive dy = scroll down), in CSS px ≈ points.
    private func scroll(dx: Double, dy: Double, at point: CGPoint) {
        if !buttonDown { mouse(.mouseMoved, at: point, button: .left) }
        let wheelY = Int32(clamping: Int((-dy).rounded()))
        let wheelX = Int32(clamping: Int((-dx).rounded()))
        guard wheelX != 0 || wheelY != 0,
              let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: wheelY, wheel2: wheelX, wheel3: 0) else { return }
        event.location = point
        event.post(tap: .cghidEventTap)
    }

    private func type(_ text: String) {
        // CGEvent carries at most 20 UTF-16 units per event.
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let chunk = Array(units[index..<min(index + 20, units.count)])
            index += chunk.count
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
                event.flags = []
                chunk.withUnsafeBufferPointer {
                    event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                }
                event.post(tap: .cghidEventTap)
            }
        }
    }

    private func press(_ code: CGKeyCode) {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: keyDown) else { continue }
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
    }

    private func releaseButton() {
        guard buttonDown else { return }
        buttonDown = false
        if isTrusted() { mouse(.leftMouseUp, at: lastPoint, button: .left) }
    }

    /// AXIsProcessTrusted, re-checked at most once a second.
    private func isTrusted() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if now - trustCheckedAt > 1 {
            trusted = AXIsProcessTrusted()
            trustCheckedAt = now
        }
        if !trusted, !reportedMissingPermission {
            reportedMissingPermission = true
            onPermissionMissing?()
        }
        return trusted
    }
}
