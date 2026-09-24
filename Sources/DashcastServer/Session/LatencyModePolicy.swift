import DashcastContracts
import Foundation

/// Picks the effective latency mode (interactive/cinema) (pure; time is passed in).
///
/// Fixed settings apply immediately. `auto` wants cinema while audio is audible and there has been
/// no input for 3 s, interactive otherwise; a change must be wanted for 2 s before it happens, except
/// that input switches to interactive at once (a touch should never wait for hysteresis).
struct LatencyModePolicy {
    var inputQuietSeconds = 3.0
    /// Audio counts as playing if an audible packet arrived this recently.
    var audioRecentSeconds = 0.5
    var hysteresisSeconds = 2.0

    private(set) var setting: LatencyMode
    private(set) var effective: LatencyMode
    private var lastAudibleAt: TimeInterval?
    private var lastInputAt: TimeInterval?
    private var pendingSince: TimeInterval?

    init(setting: LatencyMode) {
        self.setting = setting
        effective = setting == .cinema ? .cinema : .interactive
    }

    /// Returns the new effective mode if it changed.
    mutating func setSetting(_ mode: LatencyMode, now: TimeInterval) -> LatencyMode? {
        setting = mode
        pendingSince = nil
        switch mode {
        case .interactive, .cinema: return apply(mode)
        case .auto: return evaluate(now: now)
        }
    }

    mutating func noteAudio(audible: Bool, now: TimeInterval) {
        if audible { lastAudibleAt = now }
    }

    mutating func noteInput(now: TimeInterval) -> LatencyMode? {
        lastInputAt = now
        guard setting == .auto else { return nil }
        pendingSince = nil
        return apply(.interactive)
    }

    func desired(now: TimeInterval) -> LatencyMode {
        switch setting {
        case .interactive: return .interactive
        case .cinema: return .cinema
        case .auto:
            let audioPlaying = lastAudibleAt.map { now - $0 < audioRecentSeconds } ?? false
            let inputQuiet = lastInputAt.map { now - $0 >= inputQuietSeconds } ?? true
            return audioPlaying && inputQuiet ? .cinema : .interactive
        }
    }

    mutating func evaluate(now: TimeInterval) -> LatencyMode? {
        let want = desired(now: now)
        guard setting == .auto else { return apply(want) }
        guard want != effective else { pendingSince = nil; return nil }
        if pendingSince == nil { pendingSince = now }
        guard let since = pendingSince, now - since >= hysteresisSeconds else { return nil }
        pendingSince = nil
        return apply(want)
    }

    private mutating func apply(_ mode: LatencyMode) -> LatencyMode? {
        guard mode != effective else { return nil }
        effective = mode
        return mode
    }
}
