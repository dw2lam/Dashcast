import AppKit
import SwiftUI

/// A privacy list Dashcast has to be in.
enum PermissionPane: Equatable {
    /// ScreenCaptureKit's video and system audio.
    case screenRecording
    case accessibility

    var settings: SystemSettings.Pane {
        switch self {
        case .screenRecording: .screenRecording
        case .accessibility: .accessibility
        }
    }

    /// The list's name in System Settings.
    var title: String {
        switch self {
        case .screenRecording:
            return "Screen & System Audio Recording"
        case .accessibility:
            if #available(macOS 27, *) { return "Device Control and Data Access" }
            return "Accessibility"
        }
    }

    /// macOS reads Screen Recording once per process, so a fresh grant may only apply after a relaunch.
    var mayNeedRelaunch: Bool { self == .screenRecording }
}

/// Grant…: opens the exact privacy pane and floats Dashcast's icon beside the System Settings window,
/// ready to drag into the list. While it's up it polls for the grant, then closes itself and brings
/// Dashcast back. It hides whenever System Settings isn't the frontmost app.
@MainActor
final class PermissionGuide {
    /// Needs a real app bundle to drag (not `swift run`).
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private let check: (PermissionPane) async -> PermissionHealth
    private let relaunch: (PermissionPane) -> Void
    private let companion = SettingsCompanion()
    private var checking = false
    private var pane: PermissionPane?
    private var ticks = 0
    private var isDragging = false

    /// Polls for the grant every this many ticks (0.5 s).
    static let grantCheckTicks = 10

    /// `check` measures the permission (list + functional check); the panel closes on `.working`.
    init(check: @escaping (PermissionPane) async -> PermissionHealth, relaunch: @escaping (PermissionPane) -> Void) {
        self.check = check
        self.relaunch = relaunch
    }

    func present(_ pane: PermissionPane) {
        dismiss()
        self.pane = pane
        SystemSettings.open(pane.settings)

        let view = PermissionPanelView(
            pane: pane,
            onDragChange: { [weak self] dragging in self?.setDragging(dragging) },
            relaunch: pane.mayNeedRelaunch ? { [weak self] in self?.relaunch(pane) } : nil,
            close: { [weak self] in self?.dismiss() })
        companion.show(view, onTick: { [weak self] in self?.tick() }, onGiveUp: { [weak self] in self?.dismiss() })
    }

    func dismiss() {
        companion.dismiss()
        pane = nil
        isDragging = false
        ticks = 0
    }

    private func setDragging(_ dragging: Bool) {
        isDragging = dragging
        companion.holdsVisible = dragging
        // See-through while dragging, so the panel never sits on the drop target.
        companion.panel?.ignoresMouseEvents = dragging
        companion.panel?.alphaValue = dragging ? 0.55 : 1
    }

    private func tick() {
        guard let pane else { return }
        ticks += 1
        guard ticks % Self.grantCheckTicks == 0, !isDragging, !checking else { return }
        checking = true
        Task { [weak self] in
            guard let self else { return }
            let health = await self.check(pane)
            self.checking = false
            guard self.pane == pane, health == .working else { return }
            self.dismiss()
            NSApp.activate()
        }
    }
}

enum Relaunch {
    /// Quits (stopping any stream cleanly) and reopens this app once the process has exited.
    @MainActor
    static func now() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                             Bundle.main.bundlePath]
        guard (try? process.run()) != nil else { return }
        NSApp.terminate(nil)
    }
}

struct PermissionPanelView: View {
    let pane: PermissionPane
    var onDragChange: (Bool) -> Void = { _ in }
    var relaunch: (() -> Void)?
    var close: () -> Void = {}

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(pane.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            AppIconDragSource(onDragChange: onDragChange)
                .frame(width: 104, height: 104)
                .accessibilityLabel("Dashcast. Drag into the list.")
            Text("Drag Dashcast into the list, then switch it on.")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let relaunch {
                VStack(spacing: 6) {
                    Text("Already on? macOS applies it after a relaunch.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Relaunch Dashcast", action: relaunch)
                        .secondaryButtonStyle()
                }
            }
        }
        .padding(18)
        .frame(width: 280)
        .dashGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .tint(.dashAccent)
    }
}

/// Dashcast's icon; dragging it carries `Bundle.main.bundleURL` the way a Finder file drag does.
struct AppIconDragSource: NSViewRepresentable {
    var onDragChange: (Bool) -> Void

    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ view: DragView, context: Context) {
        view.onDragChange = onDragChange
    }

    final class DragView: NSView, NSDraggingSource {
        var onDragChange: ((Bool) -> Void)?
        private let url = Bundle.main.bundleURL
        private var mouseDownAt: NSPoint?
        private lazy var icon: NSImage = PermissionGuide.isAvailable
            ? NSWorkspace.shared.icon(forFile: url.path)
            : NSApp.applicationIconImage

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func draw(_ dirtyRect: NSRect) { icon.draw(in: bounds) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func mouseDown(with event: NSEvent) {
            mouseDownAt = convert(event.locationInWindow, from: nil)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownAt else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
            mouseDownAt = nil
            let item = NSDraggingItem(pasteboardWriter: FileDragWriter(url: url))
            item.setDraggingFrame(bounds, contents: icon)
            beginDraggingSession(with: [item], event: event, source: self).animatesToStartingPositionsOnCancelOrFail = true
        }

        override func mouseUp(with event: NSEvent) {
            mouseDownAt = nil
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .link, .generic] : []
        }

        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            onDragChange?(true)
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            onDragChange?(false)
        }
    }
}

/// A file URL plus the legacy filenames list, which is what Finder puts on the pasteboard.
private final class FileDragWriter: NSObject, NSPasteboardWriting {
    static let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    let url: URL

    init(url: URL) { self.url = url }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.fileURL, Self.filenames]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .fileURL ? url.absoluteString : [url.path]
    }
}

/// The trailing part of a permission row: Working ✓, a spinner, "Screen is locked", or the fix.
struct PermissionStatusAccessory: View {
    let pane: PermissionPane
    let health: PermissionHealth
    @Environment(AppModel.self) private var model

    var body: some View {
        switch health {
        case .working:
            Label("Working", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.medium))
                .transition(.scale.combined(with: .opacity))
        case .checking:
            ProgressView().controlSize(.small)
        case .noDisplays:
            Label(health.statusTitle, systemImage: "lock.fill")
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.medium))
                .fixedSize()
        default:
            Button(health.actionTitle) { model.fixPermission(pane) }
                .secondaryButtonStyle()
                .fixedSize()
        }
    }
}
