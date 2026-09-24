import CoreGraphics
import CVirtualDisplay
import Foundation

/// A CGVirtualDisplay sized in points (backing is 2x when `hiDPI`). The display exists as long
/// as this object holds it; macOS remembers its arrangement by vendor/product/serial.
final class VirtualDisplay {
    static let name = "Dashcast (Tesla)"
    static let vendorID: UInt32 = 0x4443  // "DC"
    static let productID: UInt32 = 0x5445 // "TE"
    static let serialNumber: UInt32 = 0x0001

    let displayID: CGDirectDisplayID
    let pointSize: CGSize
    let hiDPI: Bool

    private var display: CGVirtualDisplay?
    private let invalidated = Flag()
    private static let queue = DispatchQueue(label: "online.davidlam.dashcast.virtual-display")

    /// `onTermination` fires (on a private queue) only if the system removes the display on its own.
    init(width: Int, height: Int, hiDPI: Bool, refreshRate: Double = 60,
         onTermination: (() -> Void)? = nil) throws {
        guard width > 0, height > 0 else { throw StreamEngineError.virtualDisplayUnavailable("invalid size \(width)x\(height)") }
        let scale = hiDPI ? 2 : 1

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = Self.queue
        descriptor.name = Self.name
        descriptor.maxPixelsWide = UInt32(width * scale)
        descriptor.maxPixelsHigh = UInt32(height * scale)
        descriptor.sizeInMillimeters = Self.physicalSize(width: width, height: height)
        descriptor.vendorID = Self.vendorID
        descriptor.productID = Self.productID
        descriptor.serialNum = Self.serialNumber
        let invalidated = self.invalidated
        descriptor.terminationHandler = { _, _ in
            if !invalidated.value { onTermination?() }
        }

        guard let display = CGVirtualDisplay(descriptor: descriptor), display.displayID != kCGNullDirectDisplay else {
            throw StreamEngineError.virtualDisplayUnavailable("CGVirtualDisplay could not be created")
        }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        settings.modes = [CGVirtualDisplayMode(width: UInt32(width), height: UInt32(height), refreshRate: refreshRate)]
        guard display.apply(settings) else {
            throw StreamEngineError.virtualDisplayUnavailable("mode \(width)x\(height) was rejected")
        }

        self.display = display
        self.displayID = display.displayID
        self.pointSize = CGSize(width: width, height: height)
        self.hiDPI = hiDPI
    }

    deinit { invalidated.value = true }

    /// About a 15" diagonal at the requested aspect ratio.
    static func physicalSize(width: Int, height: Int, diagonalInches: Double = 15) -> CGSize {
        let diagonal = (Double(width * width + height * height)).squareRoot()
        let mm = diagonalInches * 25.4
        return CGSize(width: (mm * Double(width) / diagonal).rounded(), height: (mm * Double(height) / diagonal).rounded())
    }

    /// Waits until the display is active at the requested point size.
    func waitUntilActive(timeout: TimeInterval = 2) async -> Bool {
        let id = displayID, size = pointSize
        return await Self.poll(timeout: timeout) {
            Self.activeDisplayIDs().contains(id) && CGDisplayBounds(id).size == size
        }
    }

    /// Releases the display and waits until it has left the active display list.
    @discardableResult
    func invalidate(timeout: TimeInterval = 2) async -> Bool {
        invalidated.value = true
        display = nil
        let id = displayID
        return await Self.poll(timeout: timeout) { !Self.activeDisplayIDs().contains(id) }
    }

    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func poll(timeout: TimeInterval, interval: TimeInterval = 0.05, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if condition() { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }
}

/// Thread-safe Bool.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
