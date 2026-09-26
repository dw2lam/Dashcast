import AppKit
import ApplicationServices
import DashcastContracts
import Observation
import ScreenCaptureKit

/// What a permission actually does right now. `CGPreflightScreenCaptureAccess` and
/// `AXIsProcessTrusted` only read the TCC list, which keeps saying yes for a grant that belongs to
/// an older build (ad-hoc signatures change on every update) and before a relaunch applies it.
enum PermissionHealth: String, Equatable, CaseIterable {
    /// Not in the list and never asked for.
    case notDetermined
    /// Asked for, still off.
    case denied
    /// Turned on while Dashcast was running; macOS applies it after a relaunch.
    case needsRelaunch
    /// Listed as on, but the functional check fails: the grant belongs to an older copy.
    case grantedButNotWorking
    case working
    /// Screen locked or asleep: nothing to capture, which says nothing about the permission.
    case noDisplays
    /// The functional check hasn't answered yet.
    case checking

    enum Action: Equatable { case grant, relaunch, fix, checkAgain }

    /// The one thing to do about it (nil = nothing to do).
    var action: Action? {
        switch self {
        case .notDetermined, .denied: .grant
        case .needsRelaunch: .relaunch
        case .grantedButNotWorking: .fix
        case .noDisplays: .checkAgain
        case .working, .checking: nil
        }
    }

    var actionTitle: String {
        switch action {
        case .grant: "Grant…"
        case .relaunch: "Relaunch Dashcast"
        case .fix: "Fix in System Settings…"
        case .checkAgain: "Check Again"
        case nil: ""
        }
    }

    /// Blocks casting (a locked screen doesn't: the car shows a pause).
    var isProblem: Bool {
        switch self {
        case .notDetermined, .denied, .needsRelaunch, .grantedButNotWorking: true
        case .working, .noDisplays, .checking: false
        }
    }

    /// Short status for a row's trailing edge.
    var statusTitle: String {
        switch self {
        case .working: "Working"
        case .noDisplays: "Screen is locked"
        case .checking: "Checking…"
        case .notDetermined: "Not allowed yet"
        case .denied: "Off"
        case .needsRelaunch: "Needs a relaunch"
        case .grantedButNotWorking: "Not working"
        }
    }

    func detail(_ pane: PermissionPane) -> String {
        switch self {
        case .notDetermined: pane == .screenRecording ? "Shows your Mac on the car screen." : "Lets the car’s touchscreen move the pointer."
        case .denied: "Turned off for Dashcast in System Settings → Privacy & Security → \(pane.title)."
        case .needsRelaunch: "Allowed. macOS applies it once Dashcast relaunches."
        case .grantedButNotWorking: "macOS shows Dashcast as allowed, but that grant belongs to an older copy. In System Settings, remove Dashcast from the list (−), then add it again."
        case .working: pane == .screenRecording ? "Your Mac can be shown in the car." : "The car’s touchscreen can move the pointer."
        case .noDisplays: "The screen is locked or asleep, so there’s nothing to check. That’s not a permission problem."
        case .checking: "Checking that it really works…"
        }
    }

    /// Measured, not trusted: the state for one permission.
    /// - Parameters:
    ///   - preflight: what the TCC list says.
    ///   - probe: the functional check (nil = not run yet).
    ///   - askedBefore: Dashcast has opened this pane before (tells "never asked" from "off").
    ///   - grantedWhileRunning: the list flipped to allowed during this process.
    ///   - relaunchedAfterGrant: we already relaunched for this grant, so a relaunch won't fix it.
    static func classify(preflight: Bool, probe: PermissionProbeResult?, askedBefore: Bool,
                         grantedWhileRunning: Bool, relaunchedAfterGrant: Bool) -> PermissionHealth {
        guard preflight else { return askedBefore ? .denied : .notDetermined }
        switch probe {
        case nil: return .checking
        case .working: return .working
        case .noDisplays: return .noDisplays
        case .failed:
            return grantedWhileRunning && !relaunchedAfterGrant ? .needsRelaunch : .grantedButNotWorking
        }
    }
}

enum PermissionProbeResult: Equatable {
    case working
    case failed(String)
    case noDisplays
}

/// Reads the TCC list and exercises the permission for real.
@MainActor
protocol PermissionProbing: AnyObject {
    func preflight(_ pane: PermissionPane) -> Bool
    func probe(_ pane: PermissionPane) async -> PermissionProbeResult
}

/// The real checks: one small screenshot through ScreenCaptureKit, one Accessibility query. Only
/// run when the list already says yes, so they never raise a system prompt of their own.
@MainActor
final class SystemPermissionProbe: PermissionProbing {
    static let timeout: Duration = .seconds(3)

    func preflight(_ pane: PermissionPane) -> Bool {
        switch pane {
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .accessibility: AXIsProcessTrusted()
        }
    }

    func probe(_ pane: PermissionPane) async -> PermissionProbeResult {
        switch pane {
        case .screenRecording: await probeScreen()
        case .accessibility: Self.probeAccessibility()
        }
    }

    private func probeScreen() async -> PermissionProbeResult {
        if HostMonitor.sessionIsLocked() || CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return .noDisplays }
        let captured = await Self.within(Self.timeout) { () async throws -> Int in
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return 0 }
            let configuration = SCStreamConfiguration()
            configuration.width = 64
            configuration.height = 40
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration)
            return image.width * image.height
        }
        switch captured {
        case nil: return .failed("ScreenCaptureKit didn’t answer")
        case .success(0): return CGDisplayIsAsleep(CGMainDisplayID()) != 0 ? .noDisplays : .failed("no display to capture")
        case .success: return .working
        case .failure(let error): return .failed(error.localizedDescription)
        }
    }

    /// A real Accessibility call: the list can say yes while the API stays disabled for this binary.
    nonisolated static func probeAccessibility() -> PermissionProbeResult {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value)
        return classify(axResult: result)
    }

    nonisolated static func classify(axResult: AXError) -> PermissionProbeResult {
        switch axResult {
        case .apiDisabled, .cannotComplete: .failed("Accessibility API unavailable (\(axResult.rawValue))")
        default: .working   // .success, or .noValue when nothing is focused: the API answered
        }
    }

    /// The operation's result, or nil if it takes longer than `limit` (ScreenCaptureKit calls
    /// can't be cancelled, so the slow one is left to finish on its own).
    static func within<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async -> Result<T, Error>? {
        await withCheckedContinuation { continuation in
            let once = Once()
            let finish: @Sendable (Result<T, Error>?) -> Void = { result in
                if once.fire() { continuation.resume(returning: result) }
            }
            Task.detached {
                do { finish(.success(try await operation())) } catch { finish(.failure(error)) }
            }
            Task.detached {
                try? await Task.sleep(for: limit)
                finish(nil)
            }
        }
    }
}

/// The mock service's pretend permissions: never touches TCC (snapshots, previews, `DASHCAST_MOCK`).
@MainActor
final class ServiceStatePermissionProbe: PermissionProbing {
    private weak var service: DashcastServicing?

    init(service: DashcastServicing) { self.service = service }

    func preflight(_ pane: PermissionPane) -> Bool {
        guard let state = service?.state else { return false }
        switch pane {
        case .screenRecording: return state.screenRecordingGranted
        case .accessibility: return state.accessibilityGranted
        }
    }

    func probe(_ pane: PermissionPane) async -> PermissionProbeResult { .working }
}

/// Health of both permissions, re-measured at launch, on activation, while the drag panel is up,
/// before Start, and on Check Again.
@MainActor
@Observable
final class PermissionMonitor {
    private(set) var health: [PermissionPane: PermissionHealth] = [.screenRecording: .checking, .accessibility: .checking]

    @ObservationIgnored private let probe: PermissionProbing
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var lastPreflight: [PermissionPane: Bool] = [:]
    @ObservationIgnored private var grantedWhileRunning: Set<PermissionPane> = []
    @ObservationIgnored private var lastProbe: [PermissionPane: (result: PermissionProbeResult, at: ContinuousClock.Instant)] = [:]
    @ObservationIgnored private var probing: Set<PermissionPane> = []
    @ObservationIgnored private var pinned: [PermissionPane: PermissionHealth] = [:]

    /// A failed or locked result is re-checked at most this often (a screenshot per check).
    static let reprobeInterval: Duration = .seconds(2)

    init(probe: PermissionProbing, defaults: UserDefaults = .standard) {
        self.probe = probe
        self.defaults = defaults
    }

    subscript(pane: PermissionPane) -> PermissionHealth { health[pane] ?? .checking }

    var isLiveProbe: Bool { probe is SystemPermissionProbe }

    // MARK: Persisted flags

    private static func key(_ name: String, _ pane: PermissionPane) -> String {
        "permissions.\(name).\(pane == .screenRecording ? "screen" : "accessibility")"
    }

    /// Dashcast opened this pane for a (new) grant: remember it was asked for, and that any
    /// earlier relaunch was for an earlier grant.
    func markAsked(_ pane: PermissionPane) {
        defaults.set(true, forKey: Self.key("asked", pane))
        defaults.removeObject(forKey: Self.key("relaunched", pane))
    }

    private func askedBefore(_ pane: PermissionPane) -> Bool { defaults.bool(forKey: Self.key("asked", pane)) }

    func relaunchedAfterGrant(_ pane: PermissionPane) -> Bool { defaults.bool(forKey: Self.key("relaunched", pane)) }

    /// Remembers that the relaunch has been done, then relaunches.
    func relaunch(for pane: PermissionPane, relaunch: (@MainActor () -> Void)? = nil) {
        defaults.set(true, forKey: Self.key("relaunched", pane))
        (relaunch ?? { Relaunch.now() })()
    }

    // MARK: Measuring

    enum Depth {
        /// Re-read the list; check for real only if it changed or was never checked (view polling).
        case listOnly
        /// Also re-check a failing or locked result that's a couple of seconds old (activation, drag panel).
        case stale
        /// Check for real now (launch, Start, Check Again).
        case force
    }

    /// Re-reads the list and, when it says yes, runs the functional check as `depth` asks.
    @discardableResult
    func refresh(_ pane: PermissionPane, _ depth: Depth = .stale) async -> PermissionHealth {
        let preflight = probe.preflight(pane)
        let previous = lastPreflight[pane]
        lastPreflight[pane] = preflight
        if previous == false, preflight { grantedWhileRunning.insert(pane) }
        if !preflight {
            lastProbe[pane] = nil
            grantedWhileRunning.remove(pane)
        }

        var result = lastProbe[pane]?.result
        if preflight, !probing.contains(pane), needsProbe(pane, depth, listChanged: previous != preflight) {
            probing.insert(pane)
            if result == nil { set(pane, classify(pane, preflight: true, probe: nil)) }
            let measured = await probe.probe(pane)
            probing.remove(pane)
            lastProbe[pane] = (measured, .now)
            result = measured
        }
        if result == .working { defaults.removeObject(forKey: Self.key("relaunched", pane)) }
        let state = classify(pane, preflight: preflight, probe: preflight ? result : nil)
        set(pane, state)
        return state
    }

    func refreshAll(_ depth: Depth = .stale) async {
        await refresh(.screenRecording, depth)
        await refresh(.accessibility, depth)
    }

    private func needsProbe(_ pane: PermissionPane, _ depth: Depth, listChanged: Bool) -> Bool {
        guard depth != .force, !listChanged, let last = lastProbe[pane] else { return true }
        guard depth == .stale, last.result != .working else { return false }
        return ContinuousClock.now - last.at >= Self.reprobeInterval
    }

    private func classify(_ pane: PermissionPane, preflight: Bool, probe: PermissionProbeResult?) -> PermissionHealth {
        PermissionHealth.classify(preflight: preflight, probe: probe, askedBefore: askedBefore(pane),
                                  grantedWhileRunning: grantedWhileRunning.contains(pane),
                                  relaunchedAfterGrant: relaunchedAfterGrant(pane))
    }

    private func set(_ pane: PermissionPane, _ state: PermissionHealth) {
        let state = pinned[pane] ?? state
        if health[pane] != state { health[pane] = state }
    }

    /// Screenshots: show a state and keep it, whatever the (mock) measurements say.
    func pin(_ state: PermissionHealth, for pane: PermissionPane) {
        pinned[pane] = state
        set(pane, state)
    }
}

/// Lets exactly one of several racing callbacks through.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
