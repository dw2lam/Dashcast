import DashcastContracts
import Foundation

/// Result of picking a tier for a car.
public struct TierDecision: Equatable, Sendable {
    /// Tier to stream at (override or auto pick).
    public var tier: Tier
    /// What automatic selection chose; live step-ups never go above this.
    public var autoTier: Tier
    public var computer: CarComputer
    /// True when `tier` came from `settings.tierOverrideID`.
    public var isOverride: Bool
    /// Tiers this client can decode, lowest → highest.
    public var ladder: [Tier]
    public var reason: String
}

public struct PixelSize: Equatable, Sendable, CustomStringConvertible {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    public var description: String { "\(width)×\(height)" }
}

/// Pure tier selection + frame sizing.
public enum TierSelector {
    // Bench thresholds (mean ms/frame).
    static let slow720pMs = 20.0
    static let weak1080pMs = 12.0
    static let weak720pWhenNo1080pMs = 8.0
    static let strong1080pMs = 6.0
    /// 1080p has 2.25× the pixels of 720p; used to estimate a missing 1080p bench.
    static let pixelRatio1080to720 = 2.25

    public static func select(hello: ClientHello, overrideID: String?) -> TierDecision {
        let auto = autoSelect(hello)
        let ladder = self.ladder(for: hello.caps)
        if let overrideID, let tier = Tier.all.first(where: { $0.id == overrideID }) {
            return TierDecision(tier: tier, autoTier: auto.tier, computer: auto.computer, isOverride: true,
                                ladder: ladder.contains(tier) ? ladder : (ladder + [tier]).sorted(by: tierOrder),
                                reason: "override \(tier.id) (auto would pick \(auto.tier.id): \(auto.reason))")
        }
        return TierDecision(tier: auto.tier, autoTier: auto.tier, computer: auto.computer, isOverride: false,
                            ladder: ladder, reason: auto.reason)
    }

    static func autoSelect(_ hello: ClientHello) -> (tier: Tier, computer: CarComputer, reason: String) {
        let caps = hello.caps
        let d720 = hello.bench?.h264_720p_decodeMs
        let d1080 = hello.bench?.h264_1080p_decodeMs
        let benchMissing = d720 == nil && d1080 == nil

        func computer(for tier: Tier) -> CarComputer {
            if benchMissing { return .unknown }
            return (tier == .mcu3 || tier == .mcu3HEVC) ? .mcu3 : .mcu2
        }
        func pick(_ tier: Tier, _ reason: String) -> (Tier, CarComputer, String) { (tier, computer(for: tier), reason) }

        // The H.264 tiers use Main (mcu2*) and High (mcu3) profiles; baseline-only can't decode them.
        guard caps.webcodecs, caps.h264.main || caps.h264.high else {
            return pick(.mcu2Low, caps.webcodecs ? "no H.264 Main/High decoder" : "no WebCodecs")
        }
        if benchMissing { return pick(.mcu2, "no decode bench") }
        if let d720, d720 > slow720pMs { return pick(.mcu2Low, "720p decode \(fmt(d720)) ms is too slow for H.264") }

        let measured1080 = d1080
        let est1080 = measured1080 ?? d720.map { $0 * pixelRatio1080to720 }
        guard let e1080 = est1080 else { return pick(.mcu2, "no usable bench") }

        if let m1080 = measured1080, m1080 <= strong1080pMs, caps.h264.high {
            if caps.hevc { return pick(.mcu3HEVC, "1080p decode \(fmt(m1080)) ms, HEVC") }
            return pick(.mcu3, "1080p decode \(fmt(m1080)) ms")
        }
        if measured1080 == nil, let d720, d720 > weak720pWhenNo1080pMs {
            return pick(.mcu2, "720p decode \(fmt(d720)) ms, no 1080p bench")
        }
        if e1080 <= weak1080pMs {
            let label = measured1080 == nil ? "est. 1080p decode" : "1080p decode"
            return pick(.mcu2High, "\(label) \(fmt(e1080)) ms")
        }
        return pick(.mcu2, "1080p decode \(fmt(e1080)) ms")
    }

    /// Tiers the client can decode, lowest → highest.
    public static func ladder(for caps: ClientCaps) -> [Tier] {
        var tiers: [Tier] = [.mcu2Low]
        let h264 = caps.webcodecs && (caps.h264.main || caps.h264.high)
        if h264 { tiers += [.mcu2, .mcu2High] }
        if caps.webcodecs && caps.h264.high { tiers.append(.mcu3) }
        if caps.webcodecs && caps.hevc { tiers.append(.mcu3HEVC) }
        return tiers
    }

    static func tierOrder(_ a: Tier, _ b: Tier) -> Bool {
        (Tier.all.firstIndex(of: a) ?? 0) < (Tier.all.firstIndex(of: b) ?? 0)
    }

    /// Encoded size: the tier's pixel budget fitted to the viewport's aspect, never larger than the
    /// viewport's device pixels, rounded down to even numbers, and within the tier's macroblock count
    /// (so e.g. a 1280×720 budget stays inside H.264 level 3.1's 3600 MBs: 1280×800 → 1206×752).
    public static func encodeSize(tier: Tier, viewport: Viewport) -> PixelSize {
        let dpr = viewport.dpr.isFinite && viewport.dpr > 0 ? viewport.dpr : 1
        var deviceW = max(viewport.w, 1) * dpr
        var deviceH = max(viewport.h, 1) * dpr
        if !deviceW.isFinite || !deviceH.isFinite { deviceW = Double(tier.width); deviceH = Double(tier.height) }
        let aspect = deviceW / deviceH
        let budget = Double(tier.width * tier.height)
        let scale = min(1, (budget / (deviceW * deviceH)).squareRoot())
        func even(_ v: Double) -> Int { max(2, Int(v.rounded(.down)) & ~1) }
        var w = even(deviceW * scale)
        var h = even(deviceH * scale)
        if tier.codec != .jpeg {
            let budgetMBs = macroblocks(tier.width, tier.height)
            while macroblocks(w, h) > budgetMBs, w > 16, h > 16 {
                if aspect >= 1 { w -= 2; h = even(Double(w) / aspect) } else { h -= 2; w = even(Double(h) * aspect) }
            }
        }
        return PixelSize(width: w, height: h)
    }

    static func macroblocks(_ w: Int, _ h: Int) -> Int { ((w + 15) / 16) * ((h + 15) / 16) }

    /// Virtual display size in points: the car's CSS viewport, at least 800×480.
    public static func displaySize(viewport: Viewport) -> PixelSize {
        let w = viewport.w.isFinite ? Int(viewport.w.rounded()) : 0
        let h = viewport.h.isFinite ? Int(viewport.h.rounded()) : 0
        return PixelSize(width: max(800, w), height: max(480, h))
    }

    static func fmt(_ v: Double) -> String { String(format: "%.1f", v) }
}

extension CarComputer {
    var label: String {
        switch self {
        case .mcu2: return "MCU2"
        case .mcu3: return "MCU3"
        case .unknown: return "Unknown MCU"
        }
    }
}

extension VideoCodec {
    var label: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .jpeg: return "JPEG"
        }
    }
}
