import AppKit
import CoreGraphics
import XCTest
@testable import Dashcast

/// Where the drag panel goes for a given System Settings window. Pure geometry: nothing is shown.
final class PanelPlacementTests: XCTestCase {
    private let panel = CGSize(width: 280, height: 250)
    /// A 1512×982 laptop screen below a 25 pt menu bar (AppKit coordinates).
    private let visible = CGRect(x: 0, y: 0, width: 1512, height: 957)

    func testRightOfTheWindowWhenThereIsRoom() {
        let window = CGRect(x: 300, y: 200, width: 715, height: 650)
        let frame = PanelPlacement.frame(size: panel, beside: window, visible: visible)
        XCTAssertEqual(frame.minX, window.maxX + PanelPlacement.gap)
        XCTAssertEqual(frame.maxY, window.maxY - PanelPlacement.topInset, "level with the top of the list")
        XCTAssertEqual(frame.size, panel)
        XCTAssertFalse(frame.intersects(window))
    }

    func testLeftWhenTheWindowHugsTheRightEdge() {
        let window = CGRect(x: 780, y: 200, width: 715, height: 650)
        let frame = PanelPlacement.frame(size: panel, beside: window, visible: visible)
        XCTAssertEqual(frame.maxX, window.minX - PanelPlacement.gap)
        XCTAssertEqual(frame.maxY, window.maxY - PanelPlacement.topInset)
        XCTAssertFalse(frame.intersects(window))
    }

    func testOverTheLowerRightCornerWhenNeitherSideFits() {
        let window = CGRect(x: 100, y: 40, width: 1300, height: 900)
        let frame = PanelPlacement.frame(size: panel, beside: window, visible: visible)
        XCTAssertEqual(frame.maxX, window.maxX - PanelPlacement.gap)
        XCTAssertEqual(frame.minY, window.minY + PanelPlacement.gap)
        XCTAssertTrue(window.contains(frame))
    }

    func testStaysOnScreenNearTheBottomAndTop() {
        let low = CGRect(x: 200, y: -500, width: 715, height: 600)   // mostly dragged off the bottom
        let lowFrame = PanelPlacement.frame(size: panel, beside: low, visible: visible)
        XCTAssertEqual(lowFrame.minY, visible.minY + PanelPlacement.margin)
        XCTAssertTrue(visible.contains(lowFrame))

        let high = CGRect(x: 200, y: 700, width: 715, height: 650)    // top edge above the menu bar
        let highFrame = PanelPlacement.frame(size: panel, beside: high, visible: visible)
        XCTAssertLessThanOrEqual(highFrame.maxY, visible.maxY - PanelPlacement.margin)
        XCTAssertTrue(visible.contains(highFrame))
    }

    /// A second display to the right of the laptop, with its own origin.
    func testSecondDisplay() {
        let external = CGRect(x: 1512, y: -200, width: 2560, height: 1415)
        let window = CGRect(x: 1700, y: 300, width: 715, height: 650)
        let frame = PanelPlacement.frame(size: panel, beside: window, visible: external)
        XCTAssertEqual(frame.minX, window.maxX + PanelPlacement.gap)
        XCTAssertTrue(external.contains(frame))
    }

    /// The window server's top-left origin → AppKit's bottom-left, against the primary display.
    func testWindowServerToAppKit() {
        let primaryHeight: CGFloat = 982
        XCTAssertEqual(PanelPlacement.appKitRect(CGRect(x: 300, y: 100, width: 715, height: 650), primaryScreenHeight: primaryHeight),
                       CGRect(x: 300, y: 232, width: 715, height: 650))
        XCTAssertEqual(PanelPlacement.appKitRect(CGRect(x: 0, y: 0, width: 100, height: 982), primaryScreenHeight: primaryHeight),
                       CGRect(x: 0, y: 0, width: 100, height: 982))
        // Above the primary display (negative window-server y) ends up above its top in AppKit.
        XCTAssertEqual(PanelPlacement.appKitRect(CGRect(x: 10, y: -1000, width: 700, height: 600), primaryScreenHeight: primaryHeight),
                       CGRect(x: 10, y: 1382, width: 700, height: 600))
    }

    func testPanesAndCopy() {
        XCTAssertEqual(PermissionPane.screenRecording.title, "Screen & System Audio Recording")
        XCTAssertTrue(PermissionPane.screenRecording.mayNeedRelaunch)
        XCTAssertFalse(PermissionPane.accessibility.mayNeedRelaunch)
        XCTAssertEqual(PermissionPane.screenRecording.settings.urls.first,
                       "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture")
        XCTAssertEqual(PermissionPane.accessibility.settings.urls.first,
                       "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")
    }
}

/// The panel itself, built offscreen and never ordered in.
final class GuidePanelTests: XCTestCase {
    @MainActor
    func testPanelIsFloatingNonActivatingAndSizedToItsContent() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let panel = GuidePanel(content: PermissionPanelView(pane: .screenRecording, relaunch: {}))
        defer { panel.close() }
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.frame.width, 280, accuracy: 1)
        XCTAssertGreaterThan(panel.frame.height, 200)
        XCTAssertLessThan(panel.frame.height, 420)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.contentView?.acceptsFirstMouse(for: nil) == true, "clicks work without making it key")

        let shorter = GuidePanel(content: PermissionPanelView(pane: .accessibility))
        defer { shorter.close() }
        XCTAssertLessThan(shorter.frame.height, panel.frame.height, "no relaunch row for Accessibility")
    }
}
