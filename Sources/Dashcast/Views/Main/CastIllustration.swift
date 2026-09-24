import SwiftUI

/// Mac → signal → car screen. Idle is calm, waiting sends pulses down a dotted path, and casting
/// bridges the two glass tiles with a tinted glass link so they melt into one shape.
struct CastIllustration: View {
    let stage: CastStage
    @Namespace private var glass

    private let tileHeight: CGFloat = 78
    private let linkWidth: CGFloat = 92

    var body: some View {
        GlassGroup(spacing: 14) {
            HStack(spacing: 0) {
                macTile
                link
                carTile
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var macTile: some View {
        Image(systemName: "laptopcomputer")
            .font(.system(size: 30, weight: .regular))
            .foregroundStyle(.primary)
            .frame(width: tileHeight, height: tileHeight)
            .dashGlass(in: Circle())
            .dashGlassID("mac", in: glass)
    }

    private var carTile: some View {
        Image(systemName: stage == .casting ? "macwindow" : "car.fill")
            .font(.system(size: 28, weight: .regular))
            .foregroundStyle(stage == .casting ? AnyShapeStyle(Color.dashAccent) : AnyShapeStyle(.secondary))
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.pulse, options: .repeating, isActive: stage == .waiting)
            .frame(width: 124, height: tileHeight)
            .dashGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .dashGlassID("car", in: glass)
    }

    @ViewBuilder
    private var link: some View {
        if stage == .casting {
            // A tinted glass bridge; with the container's spacing it fuses both tiles into one shape.
            Capsule()
                .fill(Color.dashGradient)
                .frame(width: linkWidth - 20, height: 4)
                .frame(width: linkWidth, height: 22)
                .dashGlass(in: Capsule(), tint: .dashAccent.opacity(0.18))
                .dashGlassID("link", in: glass)
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
        } else {
            SignalDots(animating: stage == .waiting, tint: stage == .problem ? .red : .secondary)
                .frame(width: linkWidth, height: 22)
                .transition(.opacity)
        }
    }

    private var accessibilityText: String {
        switch stage {
        case .idle: "Mac and Tesla, not connected"
        case .waiting: "Looking for your Tesla"
        case .casting: "Mac connected to Tesla"
        case .problem: "Connection problem"
        }
    }
}

/// A dotted path whose dots travel from the Mac toward the car while `animating`.
struct SignalDots: View {
    let animating: Bool
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animating || reduceMotion)) { timeline in
            Canvas { context, size in
                let spacing: CGFloat = 11
                let radius: CGFloat = 2.2
                let count = Int(size.width / spacing)
                let t = animating && !reduceMotion ? timeline.date.timeIntervalSinceReferenceDate : 0
                for i in 0..<count {
                    let x = CGFloat(i) * spacing + spacing / 2
                    // A soft pulse that travels left → right every 1.4 s.
                    let phase = (t / 1.4).truncatingRemainder(dividingBy: 1)
                    let distance = abs(Double(i) / Double(max(count - 1, 1)) - phase)
                    let glow = animating ? max(0, 1 - distance * 4) : 0
                    let dot = Path(ellipseIn: CGRect(x: x - radius, y: size.height / 2 - radius,
                                                     width: radius * 2, height: radius * 2))
                    context.fill(dot, with: .color(tint.opacity(0.35)))
                    if glow > 0 {
                        context.fill(dot, with: .color(Color.dashAccent.opacity(glow)))
                    }
                }
            }
        }
    }
}
