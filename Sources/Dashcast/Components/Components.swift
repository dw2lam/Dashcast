import AppKit
import SwiftUI

/// "Allowed" / "Installed" style status: a coloured symbol and secondary text.
struct StatusLabel: View {
    enum Kind { case ok, warning, error, neutral }
    let text: String
    let kind: Kind

    init(_ text: String, _ kind: Kind) {
        self.text = text
        self.kind = kind
    }

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .foregroundStyle(.secondary)
    }

    private var symbol: String {
        switch kind {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .error: "xmark.circle.fill"
        case .neutral: "circle.dashed"
        }
    }

    private var color: Color {
        switch kind {
        case .ok: .green
        case .warning: .orange
        case .error: .red
        case .neutral: .secondary
        }
    }
}

extension AttributedString {
    /// Inline markdown (bold) without auto-links, so addresses read the same in both modes.
    init(inlineMarkdown markdown: String) {
        self = (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
        for run in runs where run.link != nil {
            self[run.range].link = nil
        }
    }
}

/// Button that swaps its title for a small spinner while `busy`.
struct ActionButton: View {
    let title: String
    var busy = false
    let action: () -> Void

    init(_ title: String, busy: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.busy = busy
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .opacity(busy ? 0 : 1)
                .overlay { if busy { ProgressView().controlSize(.small) } }
        }
        .disabled(busy)
    }
}

struct CopyButton: View {
    let text: String
    var label = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            Pasteboard.copy(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .help("Copy to the clipboard")
    }
}

/// Hands the hosting NSWindow to `onWindow` once the view is in a window.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowReportingView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

/// Re-reads permission state every second while the calling view is on screen.
enum PermissionPoller {
    @MainActor
    static func poll(_ model: AppModel, interval: Duration = .seconds(1)) async {
        while !Task.isCancelled {
            model.refreshPermissions()
            try? await Task.sleep(for: interval)
        }
    }
}
