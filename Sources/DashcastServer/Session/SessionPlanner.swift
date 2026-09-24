import DashcastContracts
import Foundation

/// What the car's hello says about transports (not in `ClientCaps`; parsed from the raw JSON).
struct TransportCaps: Equatable, Sendable {
    /// `window.isSecureContext`; nil when an older client didn't say.
    var secure: Bool?
    /// `RTCPeerConnection` available.
    var webrtc: Bool?
}

/// Transport + tier for one car session.
public struct SessionPlan: Equatable, Sendable {
    public var transport: MediaTransport
    public var decision: TierDecision
    /// WebCodecs codec string for `config` (constrained baseline over WebRTC).
    public var codecString: String
    public var h264Profile: H264Profile
    public var transportReason: String
}

/// PROTOCOL.md "Transport selection":
/// 1. secure context + WebCodecs + H.264 Main/High decoder → `ws` (binary frames, tiers per bench).
/// 2. else WebRTC in the browser and a peer factory on the Mac → `webrtc`: constrained-baseline H.264,
///    1280×720@30 (1920×1080@30 when overridden to mcu2-high or above), Opus audio.
/// 3. else → `ws` with JPEG.
public enum SessionPlanner {
    static func plan(hello: ClientHello, transportCaps: TransportCaps, secureFallback: Bool,
                     rtcAvailable: Bool, overrideID: String?) -> SessionPlan {
        let caps = hello.caps
        let secure = transportCaps.secure ?? secureFallback
        let webrtc = transportCaps.webrtc ?? false
        // Baseline-only decoders can't take our Main/High streams; WebRTC (constrained baseline) can.
        let h264 = caps.h264.main || caps.h264.high

        if secure && caps.webcodecs && h264 {
            let decision = TierSelector.select(hello: hello, overrideID: overrideID)
            return SessionPlan(transport: .websocket, decision: decision, codecString: decision.tier.codecString,
                               h264Profile: .auto, transportReason: "WebCodecs")
        }
        if webrtc && rtcAvailable {
            let bench = TierSelector.autoSelect(hello)
            let overrideTier = overrideID.flatMap { id in Tier.all.first { $0.id == id } }
            let wantsHigh = overrideTier.map { (Tier.all.firstIndex(of: $0) ?? 0) >= (Tier.all.firstIndex(of: .mcu2High) ?? 0) } ?? false
            let tier: Tier = wantsHigh ? .mcu2High : .mcu2
            let why = secure ? (caps.webcodecs ? "no H.264 Main/High in WebCodecs" : "no WebCodecs") : "not a secure context"
            let decision = TierDecision(tier: tier, autoTier: .mcu2, computer: bench.computer,
                                        isOverride: overrideTier != nil, ladder: [.mcu2, .mcu2High],
                                        reason: "WebRTC (\(why))\(wantsHigh ? ", override \(overrideTier!.id)" : "")")
            return SessionPlan(transport: .webrtc, decision: decision, codecString: codecString(for: tier, transport: .webrtc),
                               h264Profile: .constrainedBaseline, transportReason: why)
        }
        let bench = TierSelector.autoSelect(hello)
        let reason = !secure ? "not a secure context, no WebRTC" : (caps.webcodecs ? "no H.264 decoder" : "no WebCodecs")
        let decision = TierDecision(tier: .mcu2Low, autoTier: .mcu2Low, computer: bench.computer, isOverride: false,
                                    ladder: [.mcu2Low], reason: "JPEG (\(reason))")
        return SessionPlan(transport: .websocket, decision: decision, codecString: Tier.mcu2Low.codecString,
                           h264Profile: .auto, transportReason: reason)
    }

    /// Codec string for `config`: the tier's own for `ws`; constrained baseline (level 3.1 / 4.0) for WebRTC.
    static func codecString(for tier: Tier, transport: MediaTransport) -> String {
        guard transport == .webrtc else { return tier.codecString }
        return tier.width * tier.height > 1280 * 720 ? "avc1.42E028" : "avc1.42E01F"
    }
}
