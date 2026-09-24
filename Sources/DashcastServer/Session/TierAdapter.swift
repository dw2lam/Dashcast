import DashcastContracts
import Foundation

/// Live tier adaptation from client `stats` (pure; time is passed in).
///
/// - Step down one tier when decode time exceeds 80% of the frame interval (two consecutive
///   1 s samples, so one keyframe spike doesn't trigger it) or when the dropped-frame counter keeps
///   rising for 3 s.
/// - Step up (never above `ceiling`, the initial auto pick, and never with an override) after 20 s of
///   healthy stats with decode under 40% of the frame interval. A step-up that has to be undone
///   within 30 s doubles the next wait (up to 16×) so a marginal car doesn't oscillate.
struct TierAdapter {
    enum Decision: Equatable {
        case stepDown(Tier, reason: String)
        case stepUp(Tier, reason: String)
    }

    var downDecodeFraction = 0.8
    var upDecodeFraction = 0.4
    var slowSamplesToStepDown = 2
    var dropStreakSeconds = 3.0
    var healthySeconds = 20.0
    /// Ignore stats right after a reconfigure while the decoder warms up.
    var settleSeconds = 4.0

    private(set) var ladder: [Tier]
    private(set) var current: Tier
    private(set) var ceiling: Tier
    private(set) var allowStepUp: Bool

    private var settleUntil: TimeInterval
    private var slowSamples = 0
    private var lastSampleAt: TimeInterval?
    private var dropStreakStart: TimeInterval?
    private var healthySince: TimeInterval?
    private var lastStepUpAt: TimeInterval?
    private(set) var stepUpBackoff = 1.0

    init(ladder: [Tier], current: Tier, ceiling: Tier, allowStepUp: Bool, now: TimeInterval) {
        self.ladder = ladder.isEmpty ? [current] : ladder
        self.current = current
        self.ceiling = ceiling
        self.allowStepUp = allowStepUp
        settleUntil = now + settleSeconds
    }

    /// Called when the stream was reconfigured (by us or by settings).
    mutating func reset(current: Tier, ceiling: Tier? = nil, allowStepUp: Bool? = nil, now: TimeInterval) {
        self.current = current
        if let ceiling { self.ceiling = ceiling }
        if let allowStepUp { self.allowStepUp = allowStepUp }
        if !ladder.contains(current) { ladder = (ladder + [current]).sorted(by: TierSelector.tierOrder) }
        settleUntil = now + settleSeconds
        slowSamples = 0
        dropStreakStart = nil
        healthySince = nil
    }

    mutating func observe(_ stats: ClientStats, now: TimeInterval) -> Decision? {
        let intervalMs = 1000.0 / Double(max(current.fps, 1))

        // `dropped` counts frames dropped during the last 1 s stats interval (PROTOCOL.md).
        let dropsRising = stats.dropped > 0
        let previousSampleAt = lastSampleAt
        lastSampleAt = now
        if let prev = previousSampleAt, now - prev > 3 {   // gap in stats: start over
            slowSamples = 0; dropStreakStart = nil; healthySince = nil
        }

        guard now >= settleUntil else { return nil }

        if dropsRising {
            if dropStreakStart == nil { dropStreakStart = previousSampleAt ?? now }
        } else {
            dropStreakStart = nil
        }
        slowSamples = stats.decodeMs > downDecodeFraction * intervalMs ? slowSamples + 1 : 0

        let dropStreak = dropStreakStart.map { now - $0 } ?? 0
        if slowSamples >= slowSamplesToStepDown || dropStreak >= dropStreakSeconds - 0.05 {
            guard let lower = neighbor(-1) else { return nil }
            let reason = slowSamples >= slowSamplesToStepDown
                ? "decode \(TierSelector.fmt(stats.decodeMs)) ms > \(TierSelector.fmt(downDecodeFraction * intervalMs)) ms"
                : "dropped frames rising for \(Int(dropStreak.rounded())) s"
            if let up = lastStepUpAt, now - up < 30 { stepUpBackoff = min(stepUpBackoff * 2, 16) }
            reset(current: lower, now: now)
            return .stepDown(lower, reason: reason)
        }

        let healthy = stats.decodeMs < upDecodeFraction * intervalMs && !dropsRising
        guard allowStepUp, healthy else { healthySince = nil; return nil }
        if healthySince == nil { healthySince = now }
        guard let since = healthySince, now - since >= healthySeconds * stepUpBackoff,
              let ceilingIndex = ladder.firstIndex(of: ceiling),
              let currentIndex = ladder.firstIndex(of: current), currentIndex < ceilingIndex,
              let higher = neighbor(+1) else { return nil }
        lastStepUpAt = now
        let seconds = Int((now - since).rounded())
        reset(current: higher, now: now)
        return .stepUp(higher, reason: "healthy for \(seconds) s")
    }

    private func neighbor(_ delta: Int) -> Tier? {
        guard let i = ladder.firstIndex(of: current) else { return nil }
        let j = i + delta
        return ladder.indices.contains(j) ? ladder[j] : nil
    }
}
