// A private HiDPI stage for window screenshots: a CGVirtualDisplay nobody can see, with its own
// desktop picture. macOS arranges it beside the built-in display; nothing is ever shown on it
// except the windows being captured.
//
//   vdisplay [--width 2560] [--height 1600] [--wallpaper file]
//       Creates the display, prints `display <id> <x> <y> <w> <h> scale <s>`, then reads commands
//       on stdin:
//         wallpaper <file>   set this display's desktop picture
//         quit               (or EOF) remove the display and exit
//
// Built by scripts/shots/capture.sh (swiftc -parse-as-library + Sources/CVirtualDisplay's header).

import AppKit
import CoreGraphics

@main
@MainActor
enum VDisplay {
    static var width = 2560
    static var height = 1600
    static var display: CGVirtualDisplay?
    static var displayID: CGDirectDisplayID = 0

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        var wallpaper: String?
        var arguments = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = arguments.next() {
            switch argument {
            case "--width": width = Int(arguments.next() ?? "") ?? width
            case "--height": height = Int(arguments.next() ?? "") ?? height
            case "--wallpaper": wallpaper = arguments.next()
            default: print("error unknown argument \(argument)"); exit(2)
            }
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        create()

        Task { @MainActor in
            let deadline = Date().addingTimeInterval(5)
            while !(activeDisplays().contains(displayID) && CGDisplayBounds(displayID).size == CGSize(width: width, height: height)
                    && screen() != nil) {
                if Date() > deadline { print("error display \(displayID) never became active at \(width)x\(height)"); exit(1) }
                try? await Task.sleep(for: .milliseconds(50))
            }
            try? await Task.sleep(for: .milliseconds(500))
            if let wallpaper { setWallpaper(wallpaper) }
            let frame = CGDisplayBounds(displayID)
            print("display \(displayID) \(Int(frame.minX)) \(Int(frame.minY)) \(Int(frame.width)) \(Int(frame.height)) scale \(screen()?.backingScaleFactor ?? 0)")
        }

        Thread.detachNewThread {
            while let line = readLine() {
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                switch parts.first {
                case "wallpaper" where parts.count == 2:
                    Task { @MainActor in setWallpaper(parts[1]) }
                case "quit":
                    exit(0)
                default:
                    print("error unknown command \(line)")
                }
            }
            exit(0)
        }

        app.run()
    }

    static func create() {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue(label: "shots.virtual-display")
        descriptor.name = "Dashcast Shots"
        descriptor.maxPixelsWide = UInt32(width * 2)
        descriptor.maxPixelsHigh = UInt32(height * 2)
        let diagonal = Double(width * width + height * height).squareRoot()
        descriptor.sizeInMillimeters = CGSize(width: 27 * 25.4 * Double(width) / diagonal,
                                              height: 27 * 25.4 * Double(height) / diagonal)
        descriptor.vendorID = 0x4443   // "DC", like the app's own display
        descriptor.productID = 0x5348  // "SH": a different identity from the app's Tesla display
        descriptor.serialNum = 0x0002
        descriptor.terminationHandler = { _, _ in
            print("terminated")
            exit(1)
        }
        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            print("error could not create the virtual display")
            exit(1)
        }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [CGVirtualDisplayMode(width: UInt32(width), height: UInt32(height), refreshRate: 60)]
        guard display.apply(settings) else {
            print("error mode \(width)x\(height) HiDPI was rejected")
            exit(1)
        }
        self.display = display
        displayID = display.displayID
    }

    static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    static func screen() -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    static func setWallpaper(_ path: String) {
        guard let screen = screen() else { return print("error no NSScreen for display \(displayID)") }
        do {
            try NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: true,
            ])
            print("wallpaper ok")
        } catch {
            print("error wallpaper \(error.localizedDescription)")
        }
    }
}
