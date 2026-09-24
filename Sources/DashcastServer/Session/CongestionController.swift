import Foundation

/// Delay-based congestion control from per-frame acks (pure; time is passed in).
///
/// One-way delay = `recvAt − pts` (both server µs; any constant clock offset cancels out). The running
/// minimum over the last 10 s is the uncongested baseline; `delay − baseline` is queueing delay.
/// - Queueing delay > 40 ms and rising over the last 5 acks → bitrate × 0.85 (floor 25% of the tier).
///   A standing queue above 200 ms also counts, rising or not.
/// - Queueing delay ≤ 40 ms → additive increase of 5% of the tier bitrate per second, up to the tier.
/// - In between (queue draining) → hold.
final class CongestionController {
    struct Config {
        var windowSeconds = 10.0
        var queueThresholdMs = 40.0
        var severeQueueMs = 200.0
        var trendAcks = 5
        /// "Rising" needs a real trend (ms per ack), not float jitter on a flat queue.
        var minRiseMsPerAck = 0.5
        var decreaseFactor = 0.85
        var floorFraction = 0.25
        var increaseFractionPerSecond = 0.05
        /// Minimum spacing between decreases so the encoder change can show up in the acks.
        var decreaseHoldSeconds = 0.4
    }

    let config: Config
    private(set) var maxKbps: Int
    private(set) var targetKbps: Double
    private(set) var lastReportedKbps: Int
    private(set) var baselineMicros: Double?
    private(set) var lastQueueingMs: Double = 0

    private var minWindow: [(t: TimeInterval, d: Double)] = []   // monotonic deque (increasing d)
    private var minWindowHead = 0
    private var recentQueueing: [Double] = []
    private var lastDecreaseAt: TimeInterval?
    private var lastIncreaseAt: TimeInterval?

    init(maxKbps: Int, config: Config = Config()) {
        self.config = config
        self.maxKbps = max(1, maxKbps)
        targetKbps = Double(self.maxKbps)
        lastReportedKbps = self.maxKbps
    }

    var floorKbps: Double { Double(maxKbps) * config.floorFraction }
    var currentKbps: Int { Int(targetKbps.rounded()) }

    /// New tier: keep the path estimate, clamp the target into the new range.
    func setMaxKbps(_ kbps: Int) {
        maxKbps = max(1, kbps)
        targetKbps = min(Double(maxKbps), max(floorKbps, targetKbps))
        lastReportedKbps = currentKbps
    }

    /// Feed one ack. Returns a new bitrate when it moved enough to be worth applying.
    @discardableResult
    func onAck(ptsMicros: UInt64, recvAtMicros: Double, now: TimeInterval) -> Int? {
        let delay = recvAtMicros - Double(ptsMicros)
        // Sliding-window minimum.
        while minWindow.count > minWindowHead, minWindow[minWindow.count - 1].d >= delay { minWindow.removeLast() }
        minWindow.append((now, delay))
        while minWindowHead < minWindow.count - 1, minWindow[minWindowHead].t < now - config.windowSeconds { minWindowHead += 1 }
        if minWindowHead > 256 { minWindow.removeFirst(minWindowHead); minWindowHead = 0 }
        let baseline = minWindow[minWindowHead].d
        baselineMicros = baseline

        let queueing = (delay - baseline) / 1000
        lastQueueingMs = queueing
        recentQueueing.append(queueing)
        if recentQueueing.count > config.trendAcks { recentQueueing.removeFirst(recentQueueing.count - config.trendAcks) }

        let canDecrease = lastDecreaseAt.map { now - $0 >= config.decreaseHoldSeconds } ?? true
        if queueing > config.queueThresholdMs, canDecrease, isRising || queueing > config.severeQueueMs {
            targetKbps = max(floorKbps, targetKbps * config.decreaseFactor)
            lastDecreaseAt = now
            lastIncreaseAt = now
            recentQueueing.removeAll()
        } else if queueing <= config.queueThresholdMs {
            if let last = lastIncreaseAt {
                let dt = min(max(now - last, 0), 1)
                targetKbps = min(Double(maxKbps), targetKbps + Double(maxKbps) * config.increaseFractionPerSecond * dt)
            }
            lastIncreaseAt = now
        } else {
            lastIncreaseAt = now   // queue draining: hold, and don't bank increase time
        }
        return reportIfChanged()
    }

    /// Least-squares slope of the last `trendAcks` queueing samples exceeds `minRiseMsPerAck`…
    var isRising: Bool {
        let n = recentQueueing.count
        guard n >= config.trendAcks else { return false }
        let meanX = Double(n - 1) / 2
        let meanY = recentQueueing.reduce(0, +) / Double(n)
        var num = 0.0, den = 0.0
        for (i, y) in recentQueueing.enumerated() {
            num += (Double(i) - meanX) * (y - meanY)
            den += (Double(i) - meanX) * (Double(i) - meanX)
        }
        // …and the queue isn't already turning down (the regression lags at a peak).
        return den > 0 && num / den > config.minRiseMsPerAck && recentQueueing[n - 1] >= recentQueueing[n - 2]
    }

    private func reportIfChanged() -> Int? {
        let now = currentKbps
        let last = lastReportedKbps
        let atBound = (now == maxKbps || now == Int(floorKbps.rounded())) && now != last
        guard atBound || abs(now - last) >= max(50, last / 50) else { return nil }
        lastReportedKbps = now
        return now
    }
}
