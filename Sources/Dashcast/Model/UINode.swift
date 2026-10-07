import AppKit
import ApplicationServices

/// One element of another app's interface, as the Accessibility API sees it. The live version wraps
/// an `AXUIElement`; tests build trees from captured System Settings dumps, so the locators in
/// SharingScreen.swift run against what macOS really shows.
///
/// Frames are in Accessibility coordinates: global, origin top-left of the primary display, y down.
protocol UINode: AnyObject {
    var role: String { get }
    var subrole: String? { get }
    var identifier: String? { get }
    var title: String? { get }
    /// AXDescription (System Settings' SwiftUI controls name themselves here, not in the title).
    var axDescription: String? { get }
    /// AXValue as text: a field's contents, a popup's selection, "0"/"1" for a switch.
    var value: String? { get }
    var isEnabled: Bool { get }
    var isFocused: Bool { get }
    var frame: CGRect { get }
    var children: [UINode] { get }

    /// Performs an AX action ("AXPress", "AXCancel", "AXScrollDownByPage"…). false = refused.
    @discardableResult func perform(_ action: String) -> Bool
    /// Sets AXValue. false = refused (it can still be refused silently: read it back).
    @discardableResult func setValue(_ value: String) -> Bool
    @discardableResult func setFocused() -> Bool
}

extension UINode {
    @discardableResult func press() -> Bool { perform(kAXPressAction) }
    @discardableResult func scrollToVisible() -> Bool { perform("AXScrollToVisible") }

    /// What a person reads on it: the title, else the description, else the value.
    var text: String? { title ?? axDescription ?? value }

    /// A switch or checkbox that's on.
    var isOn: Bool { value == "1" }

    /// Depth-first, `self` included. `skip` prunes a subtree (its root isn't visited either).
    func first(skip: (UINode) -> Bool = { _ in false }, where match: (UINode) -> Bool) -> UINode? {
        if skip(self) { return nil }
        if match(self) { return self }
        for child in children {
            if let found = child.first(skip: skip, where: match) { return found }
        }
        return nil
    }

    /// Every match, depth-first in tree order, `self` included.
    func all(skip: (UINode) -> Bool = { _ in false }, where match: (UINode) -> Bool) -> [UINode] {
        var found: [UINode] = []
        func walk(_ node: UINode) {
            if skip(node) { return }
            if match(node) { found.append(node) }
            node.children.forEach(walk)
        }
        walk(self)
        return found
    }
}

// MARK: - Live

/// A live `AXUIElement`. Each node reads its attributes once (one batched call) and its children
/// once: a tree is a snapshot, so read a fresh one from the app after every change.
final class AXNode: UINode {
    let element: AXUIElement
    private let snapshot: Snapshot

    /// Shared by every node read from one root. The messaging timeout is per element (a child
    /// doesn't inherit its parent's), so each node sets it; and once a read times out (the app is
    /// busy or hung) the rest of the snapshot reads as empty, instead of every remaining element
    /// waiting out its own timeout on the caller's (main) thread.
    private final class Snapshot {
        let timeout: Float
        var timedOut = false
        init(timeout: Float) { self.timeout = timeout }
    }

    private static let batch: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
        kAXValueAttribute, kAXEnabledAttribute, kAXFocusedAttribute, kAXPositionAttribute, kAXSizeAttribute,
    ]
    private lazy var attributes: [String: AnyObject] = {
        guard !snapshot.timedOut else { return [:] }
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, Self.batch as CFArray, [], &values)
        if error == .cannotComplete { snapshot.timedOut = true }
        guard error == .success, let list = values as? [AnyObject], list.count == Self.batch.count else { return [:] }
        var result: [String: AnyObject] = [:]
        for (name, value) in zip(Self.batch, list) {
            // Missing attributes come back as an AXValue wrapping an AXError.
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { continue }
            result[name] = value
        }
        return result
    }()

    private init(_ element: AXUIElement, snapshot: Snapshot) {
        self.element = element
        self.snapshot = snapshot
        AXUIElementSetMessagingTimeout(element, snapshot.timeout)
    }

    /// The app's root element, with a short messaging timeout so a busy app can't hang the caller.
    static func application(pid: pid_t, timeout: Float = 1) -> AXNode {
        AXNode(AXUIElementCreateApplication(pid), snapshot: Snapshot(timeout: timeout))
    }

    private func string(_ name: String) -> String? {
        switch attributes[name] {
        case let string as String: string.isEmpty ? nil : string
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    var role: String { string(kAXRoleAttribute) ?? "" }
    var subrole: String? { string(kAXSubroleAttribute) }
    var identifier: String? { string(kAXIdentifierAttribute) }
    var title: String? { string(kAXTitleAttribute) }
    var axDescription: String? { string(kAXDescriptionAttribute) }
    var value: String? { string(kAXValueAttribute) }
    var isEnabled: Bool { (attributes[kAXEnabledAttribute] as? Bool) ?? true }
    var isFocused: Bool { (attributes[kAXFocusedAttribute] as? Bool) ?? false }

    var frame: CGRect {
        var origin = CGPoint.zero, size = CGSize.zero
        if let value = attributes[kAXPositionAttribute], CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgPoint, &origin)
        }
        if let value = attributes[kAXSizeAttribute], CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: origin, size: size)
    }

    lazy var children: [UINode] = {
        guard !snapshot.timedOut else { return [] }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        if result == .cannotComplete { snapshot.timedOut = true }
        guard result == .success, let elements = value as? [AXUIElement] else { return [] }
        return elements.map { AXNode($0, snapshot: snapshot) }
    }()

    func perform(_ action: String) -> Bool {
        let result = AXUIElementPerformAction(element, action as CFString)
        // A press that opens a menu can time out while the menu tracks: it still happened.
        return result == .success || (action == kAXPressAction && result == .cannotComplete)
    }

    func setValue(_ value: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString) == .success
    }

    func setFocused() -> Bool {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }
}
