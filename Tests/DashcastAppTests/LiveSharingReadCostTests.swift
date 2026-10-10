import AppKit
import XCTest
@testable import Dashcast

/// Opt-in (`DASHCAST_LIVE_AX=1`, System Settings open on Sharing): times one `SharingScreen` read
/// of the real app, the way Guide Me and Do It for Me read it. Read-only: presses nothing.
final class LiveSharingReadCostTests: XCTestCase {
    func testReadCost() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DASHCAST_LIVE_AX"] == "1", "opt-in")
        let app = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first)
        var times: [Double] = []
        var counted = 0
        for _ in 0..<20 {
            let start = CFAbsoluteTimeGetCurrent()
            let node = AXNode.application(pid: app.processIdentifier)
            let screen = SharingScreen(app: node)
            times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            XCTAssertNotNil(screen.window)
            counted = AXNode.readCount
            AXNode.readCount = 0
        }
        times.sort()
        print(String(format: "[live-ax] SharingScreen read: p50 %.1f ms, p90 %.1f ms, %d elements read", times[10], times[18], counted))
    }
}
