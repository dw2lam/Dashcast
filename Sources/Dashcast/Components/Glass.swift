import AppKit
import SwiftUI

// MARK: - Brand

extension Color {
    /// `accent-blue` #0872FE from Design/icon/BRAND.md (final light-glass), lifted a notch in dark mode.
    static let dashAccent = Color(nsColor: NSColor(name: "dashAccent") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x3A / 255, green: 0x92 / 255, blue: 0xFF / 255, alpha: 1)
            : NSColor(srgbRed: 0x08 / 255, green: 0x72 / 255, blue: 0xFE / 255, alpha: 1)
    })
    /// `accent-azure` #15ABFE, the gradient midpoint.
    static let dashAccentMid = Color(red: 0x15 / 255, green: 0xAB / 255, blue: 0xFE / 255)
    /// `accent-cyan` #18D3FD, the end of the brand mark gradient.
    static let dashAccentEnd = Color(red: 0x18 / 255, green: 0xD3 / 255, blue: 0xFD / 255)

    /// The icon's mark gradient, left → right.
    static let dashGradient = LinearGradient(colors: [.dashAccent, .dashAccentMid, .dashAccentEnd],
                                             startPoint: .leading, endPoint: .trailing)
}

// MARK: - Rendering mode

enum RenderMode {
    /// Offscreen snapshots can't composite Liquid Glass or materials (the window server does that),
    /// so snapshot mode swaps in flat stand-ins with the same geometry.
    @MainActor static var offscreen = false

    @MainActor static var usesLiquidGlass: Bool {
        if #available(macOS 26, *) { return !offscreen }
        return false
    }
}

// MARK: - Glass surfaces

extension View {
    /// Liquid Glass on macOS 26+; a standard material with a hairline before; a flat stand-in offscreen.
    @ViewBuilder
    func dashGlass<S: InsettableShape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *), !RenderMode.offscreen {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else if RenderMode.offscreen {
            background {
                ZStack {
                    shape.fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
                    if let tint { shape.fill(tint) }
                    shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                }
            }
        } else {
            background {
                ZStack {
                    shape.fill(.regularMaterial)
                    if let tint { shape.fill(tint.opacity(0.9)) }
                    shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
            }
        }
    }

    /// Stable identity for glass morphs (no-op before macOS 26).
    @ViewBuilder
    func dashGlassID(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26, *), !RenderMode.offscreen {
            glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    /// Primary call-to-action: Liquid Glass prominent on macOS 26+, bordered prominent before.
    @ViewBuilder
    func prominentButtonStyle() -> some View {
        if #available(macOS 26, *), !RenderMode.offscreen {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// Secondary action: Liquid Glass on macOS 26+, bordered before.
    @ViewBuilder
    func secondaryButtonStyle() -> some View {
        if #available(macOS 26, *), !RenderMode.offscreen {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// The biggest control size the OS offers.
    @ViewBuilder
    func heroControlSize() -> some View {
        if #available(macOS 26, *) {
            controlSize(.extraLarge)
        } else {
            controlSize(.large)
        }
    }
}

/// `GlassEffectContainer` on macOS 26+ (shapes blend and morph, and render in one pass).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *), !RenderMode.offscreen {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
