import CoreGraphics
import Foundation
import XCTest
@testable import DashcastStream

/// Creating a display briefly rearranges the user's screens: keep this to one short-lived display.
final class VirtualDisplayTests: XCTestCase {
    /// Creates a 1280x720 HiDPI display, checks the system lists it with that mode, removes it.
    func testCreateAndDestroyHiDPIDisplay() async throws {
        try skipUnlessScreenAvailable()
        let before = Set(VirtualDisplay.activeDisplayIDs())
        let display = try VirtualDisplay(width: 1280, height: 720, hiDPI: true)
        let id = display.displayID
        XCTAssertFalse(before.contains(id))

        let online = await display.waitUntilActive(timeout: 2)
        XCTAssertTrue(online, "display \(id) never became active")
        XCTAssertTrue(VirtualDisplay.activeDisplayIDs().contains(id), "CGGetActiveDisplayList must list it")
        XCTAssertEqual(CGDisplayBounds(id).size, CGSize(width: 1280, height: 720), "point size")
        XCTAssertEqual(CGDisplayVendorNumber(id), VirtualDisplay.vendorID)
        XCTAssertEqual(CGDisplayModelNumber(id), VirtualDisplay.productID)

        // CoreGraphics caches display modes per process: if this process queried displays before the
        // display existed, CGDisplayCopyDisplayMode returns nil for it here. Check in-process when
        // available and always cross-check out of process.
        if let mode = CGDisplayCopyDisplayMode(id) {
            XCTAssertEqual(mode.width, 1280)
            XCTAssertEqual(mode.height, 720)
            XCTAssertEqual(mode.pixelWidth, 2560, "HiDPI → 2x backing")
            XCTAssertEqual(mode.pixelHeight, 1440)
        } else {
            print("CGDisplayCopyDisplayMode is nil in-process (stale per-process mode cache); using system_profiler")
        }
        let entry = try XCTUnwrap(systemProfilerEntry(named: VirtualDisplay.name), "system_profiler does not list the display")
        print("system_profiler: pixels=\(entry["_spdisplays_pixels"] ?? "?") resolution=\(entry["_spdisplays_resolution"] ?? "?")")
        XCTAssertEqual(entry["_spdisplays_pixels"] as? String, "2560 x 1440")
        XCTAssertTrue((entry["_spdisplays_resolution"] as? String)?.hasPrefix("1280 x 720") == true)

        let gone = await display.invalidate(timeout: 2)
        XCTAssertTrue(gone, "display \(id) still listed after release")
        XCTAssertFalse(VirtualDisplay.activeDisplayIDs().contains(id))
        XCTAssertNil(systemProfilerEntry(named: VirtualDisplay.name))
    }

    func testPhysicalSizeIsAbout15Inches() {
        let size = VirtualDisplay.physicalSize(width: 1920, height: 1080)
        let diagonal = (size.width * size.width + size.height * size.height).squareRoot() / 25.4
        XCTAssertEqual(diagonal, 15, accuracy: 0.1)
        XCTAssertEqual(size.width / size.height, 16.0 / 9, accuracy: 0.01)
    }

    private func systemProfilerEntry(named name: String) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPDisplaysDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gpus = json["SPDisplaysDataType"] as? [[String: Any]] else { return nil }
        for gpu in gpus {
            for display in gpu["spdisplays_ndrvs"] as? [[String: Any]] ?? [] where display["_name"] as? String == name {
                return display
            }
        }
        return nil
    }
}
