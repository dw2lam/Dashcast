import CoreGraphics
import DashcastContracts
import XCTest
@testable import DashcastStream

final class InputInjectorTests: XCTestCase {
    func testMappingWithMatchingAspect() {
        let bounds = CGRect(x: -1280, y: 0, width: 1280, height: 720)
        let frame = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(InputInjector.point(x: 0, y: 0, displayBounds: bounds, frameSize: frame), CGPoint(x: -1280, y: 0))
        XCTAssertEqual(InputInjector.point(x: 0.5, y: 0.5, displayBounds: bounds, frameSize: frame), CGPoint(x: -640, y: 360))
        XCTAssertEqual(InputInjector.point(x: 1, y: 1, displayBounds: bounds, frameSize: frame), CGPoint(x: -1, y: 719),
                       "clamped inside the display")
        XCTAssertEqual(InputInjector.point(x: 2, y: -1, displayBounds: bounds, frameSize: frame), CGPoint(x: -1, y: 0))
    }

    /// Mirror of a 16:10 display into a 16:9 frame is pillarboxed; touches in the bars clamp to the edge.
    func testMappingUndoesLetterbox() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let frame = CGSize(width: 1280, height: 720)
        // Content is 1152x720 centered → bars of 64 px each side.
        let left = InputInjector.point(x: 64.0 / 1280, y: 0.5, displayBounds: bounds, frameSize: frame)
        XCTAssertEqual(left.x, 0, accuracy: 0.001)
        XCTAssertEqual(left.y, 500, accuracy: 0.001)
        let center = InputInjector.point(x: 0.5, y: 0.25, displayBounds: bounds, frameSize: frame)
        XCTAssertEqual(center.x, 800, accuracy: 0.001)
        XCTAssertEqual(center.y, 250, accuracy: 0.001)
        let inBar = InputInjector.point(x: 0.01, y: 0.5, displayBounds: bounds, frameSize: frame)
        XCTAssertEqual(inBar.x, 0, accuracy: 0.001)
    }

    func testNamedKeys() {
        XCTAssertEqual(InputInjector.keyCode(for: "Enter"), 36)
        XCTAssertEqual(InputInjector.keyCode(for: "Backspace"), 51)
        XCTAssertEqual(InputInjector.keyCode(for: "Tab"), 48)
        XCTAssertEqual(InputInjector.keyCode(for: "Escape"), 53)
        XCTAssertEqual(InputInjector.keyCode(for: "ArrowLeft"), 123)
        XCTAssertEqual(InputInjector.keyCode(for: "ArrowRight"), 124)
        XCTAssertEqual(InputInjector.keyCode(for: "ArrowDown"), 125)
        XCTAssertEqual(InputInjector.keyCode(for: "ArrowUp"), 126)
        XCTAssertNil(InputInjector.keyCode(for: "F13"))
    }

    /// Moves the real cursor onto a virtual display and back. Opt-in: DASHCAST_LIVE_INPUT=1.
    func testLiveCursorMoveOnVirtualDisplay() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DASHCAST_LIVE_INPUT"] == "1", "set DASHCAST_LIVE_INPUT=1")
        try XCTSkipUnless(AXIsProcessTrusted(), "Accessibility not granted")
        let original = CGEvent(source: nil)?.location ?? .zero
        let display = try VirtualDisplay(width: 1280, height: 720, hiDPI: true)
        let online = await display.waitUntilActive()
        XCTAssertTrue(online)
        let injector = InputInjector()
        injector.setTarget(.init(displayID: display.displayID, frameWidth: 1280, frameHeight: 720))
        injector.inject(InputEvent(kind: .move, x: 0.25, y: 0.75))
        injector.drain()
        try await Task.sleep(nanoseconds: 100_000_000)
        let bounds = CGDisplayBounds(display.displayID)
        let location = try XCTUnwrap(CGEvent(source: nil)?.location)
        XCTAssertEqual(location.x, bounds.minX + 320, accuracy: 1)
        XCTAssertEqual(location.y, bounds.minY + 540, accuracy: 1)
        CGWarpMouseCursorPosition(original)
        await display.invalidate()
    }
}
