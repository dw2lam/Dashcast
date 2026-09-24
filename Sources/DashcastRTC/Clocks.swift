import DashcastContracts
import Foundation

/// Maps capture time (server µs, `DashClock` base) to one RTP stream's timestamps.
///
/// Every frame's timestamp comes from its own pts, never from a running counter. RTCP sender reports
/// are anchored on the same pts (see `NTPClock`), so audio and video sync from capture time
/// whatever each path's encode/send latency.
struct RTPClock: Sendable {
    let clockRate: Int64
    /// RTP timestamp of `anchorMicros` (random per stream, RFC 3550 §5.1).
    let baseTimestamp: UInt32
    let anchorMicros: UInt64

    init(clockRate: Int64, baseTimestamp: UInt32 = .random(in: .min ... .max), anchorMicros: UInt64) {
        self.clockRate = clockRate
        self.baseTimestamp = baseTimestamp
        self.anchorMicros = anchorMicros
    }

    /// Rounded to the nearest tick, so 10 ms at 48 kHz is exactly 480 and 1/30 s at 90 kHz is 3000.
    func timestamp(forMicros micros: UInt64) -> UInt32 {
        baseTimestamp &+ UInt32(truncatingIfNeeded: ticks(forMicros: micros))
    }

    /// Inverse of `timestamp(forMicros:)` for the timestamp closest to `reference` (handles wrap).
    func micros(forTimestamp rtpTimestamp: UInt32, near reference: UInt64) -> UInt64 {
        let referenceTicks = ticks(forMicros: reference)
        let referenceTimestamp = baseTimestamp &+ UInt32(truncatingIfNeeded: referenceTicks)
        let ticks = referenceTicks + Int64(Int32(bitPattern: rtpTimestamp &- referenceTimestamp))
        let micros = Self.floorDiv(ticks * 1_000_000 + clockRate / 2, clockRate)
        return UInt64(bitPattern: Int64(bitPattern: anchorMicros) + micros)
    }

    private func ticks(forMicros micros: UInt64) -> Int64 {
        Self.floorDiv(Int64(bitPattern: micros &- anchorMicros) * clockRate + 500_000, 1_000_000)
    }

    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }
}

/// Capture time → NTP time (64-bit 32.32 fixed point since 1900) for RTCP sender reports.
/// One offset per process, so every track (and every peer) maps pts to NTP identically.
enum NTPClock {
    static let unixToNTPSeconds: Int64 = 2_208_988_800

    /// NTP µs minus host-clock µs, sampled once.
    static let offsetMicros: Int64 = {
        let host = Int64(DashClock.nowMicros())
        let unixMicros = Int64((Date().timeIntervalSince1970 * 1_000_000).rounded())
        return unixMicros + unixToNTPSeconds * 1_000_000 - host
    }()

    static func ntp(forMicros micros: UInt64) -> UInt64 {
        ntp(ntpMicros: Int64(bitPattern: micros) + offsetMicros)
    }

    static func ntp(ntpMicros: Int64) -> UInt64 {
        let clamped = UInt64(max(ntpMicros, 0))
        let seconds = clamped / 1_000_000
        let fraction = ((clamped % 1_000_000) << 32) / 1_000_000
        return (seconds << 32) | fraction
    }

    /// NTP 32.32 → server µs (inverse of `ntp(forMicros:)`; tests and diagnostics).
    static func micros(forNTP ntp: UInt64) -> UInt64 {
        let seconds = Int64(ntp >> 32)
        let fractionMicros = Int64(((ntp & 0xFFFF_FFFF) * 1_000_000 + (1 << 31)) >> 32)
        return UInt64(bitPattern: seconds * 1_000_000 + fractionMicros - offsetMicros)
    }
}
