import ApplicationServices
import DashcastContracts
import XCTest
@testable import Dashcast

/// Scripted TCC list + functional check. Never touches the real ones.
@MainActor
final class FakeProbe: PermissionProbing {
    var listed: [PermissionPane: Bool] = [:]
    var result: [PermissionPane: PermissionProbeResult] = [:]
    private(set) var probes: [PermissionPane] = []

    func preflight(_ pane: PermissionPane) -> Bool { listed[pane] ?? false }
    func probe(_ pane: PermissionPane) async -> PermissionProbeResult {
        probes.append(pane)
        return result[pane] ?? .working
    }
}

final class PermissionClassificationTests: XCTestCase {
    private func classify(_ preflight: Bool, _ probe: PermissionProbeResult?, asked: Bool = false,
                          whileRunning: Bool = false, relaunched: Bool = false) -> PermissionHealth {
        PermissionHealth.classify(preflight: preflight, probe: probe, askedBefore: asked,
                                  grantedWhileRunning: whileRunning, relaunchedAfterGrant: relaunched)
    }

    func testEveryProbeResultMapsToAState() {
        XCTAssertEqual(classify(false, nil), .notDetermined)
        XCTAssertEqual(classify(false, nil, asked: true), .denied)
        XCTAssertEqual(classify(false, .working, asked: true), .denied, "the list wins when it says no")
        XCTAssertEqual(classify(true, nil), .checking)
        XCTAssertEqual(classify(true, .working), .working)
        XCTAssertEqual(classify(true, .noDisplays), .noDisplays)
        XCTAssertEqual(classify(true, .failed("x")), .grantedButNotWorking, "allowed at launch but failing: a stale grant")
        XCTAssertEqual(classify(true, .failed("x"), whileRunning: true), .needsRelaunch, "granted just now: relaunch")
        XCTAssertEqual(classify(true, .failed("x"), whileRunning: true, relaunched: true), .grantedButNotWorking,
                       "already relaunched for it: don't loop")
    }

    func testMessagesAndActions() {
        let expectations: [(PermissionHealth, PermissionHealth.Action?, String)] = [
            (.notDetermined, .grant, "Grant…"),
            (.denied, .grant, "Grant…"),
            (.needsRelaunch, .relaunch, "Relaunch Dashcast"),
            (.grantedButNotWorking, .fix, "Fix in System Settings…"),
            (.noDisplays, .checkAgain, "Check Again"),
            (.working, nil, ""),
            (.checking, nil, ""),
        ]
        for (health, action, title) in expectations {
            XCTAssertEqual(health.action, action, health.rawValue)
            XCTAssertEqual(health.actionTitle, title, health.rawValue)
            XCTAssertFalse(health.detail(.screenRecording).isEmpty)
        }
        XCTAssertEqual(PermissionHealth.grantedButNotWorking.detail(.screenRecording),
                       "macOS shows Dashcast as allowed, but that grant belongs to an older copy. In System Settings, remove Dashcast from the list (−), then add it again.")
        XCTAssertFalse(PermissionHealth.noDisplays.isProblem, "a locked screen isn't a permission problem")
        XCTAssertEqual(PermissionHealth.noDisplays.statusTitle, "Screen is locked")
        XCTAssertEqual(PermissionHealth.working.statusTitle, "Working")
        XCTAssertTrue(PermissionHealth.needsRelaunch.isProblem)
    }

    func testAccessibilityErrorsThatMeanNotEffective() {
        XCTAssertEqual(SystemPermissionProbe.classify(axResult: .success), .working)
        XCTAssertEqual(SystemPermissionProbe.classify(axResult: .noValue), .working, "nothing focused, but the API answered")
        guard case .failed = SystemPermissionProbe.classify(axResult: .apiDisabled) else { return XCTFail("apiDisabled") }
        guard case .failed = SystemPermissionProbe.classify(axResult: .cannotComplete) else { return XCTFail("cannotComplete") }
    }
}

@MainActor
final class PermissionMonitorTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "dashcast-permissions-\(UUID().uuidString)")
    }

    func testStaleGrantAtLaunch() async {
        let probe = FakeProbe()
        probe.listed[.screenRecording] = true
        probe.result[.screenRecording] = .failed("SCStreamErrorDomain -3801")
        let monitor = PermissionMonitor(probe: probe, defaults: defaults)
        let health = await monitor.refresh(.screenRecording, .force)
        XCTAssertEqual(health, .grantedButNotWorking)
    }

    func testGrantWhileRunningNeedsARelaunchOnce() async {
        let probe = FakeProbe()
        let monitor = PermissionMonitor(probe: probe, defaults: defaults)
        var health = await monitor.refresh(.screenRecording, .force)
        XCTAssertEqual(health, .notDetermined)
        XCTAssertEqual(probe.probes, [], "no functional check while the list says no")

        monitor.markAsked(.screenRecording)
        health = await monitor.refresh(.screenRecording, .listOnly)
        XCTAssertEqual(health, .denied)

        // The user drags Dashcast in and switches it on; capture doesn't work in this process yet.
        probe.listed[.screenRecording] = true
        probe.result[.screenRecording] = .failed("not yet")
        health = await monitor.refresh(.screenRecording, .listOnly)
        XCTAssertEqual(health, .needsRelaunch, "a list change triggers the check even when only polling")
        XCTAssertEqual(probe.probes, [.screenRecording])

        var relaunched = 0
        monitor.relaunch(for: .screenRecording) { relaunched += 1 }
        XCTAssertEqual(relaunched, 1)
        XCTAssertTrue(monitor.relaunchedAfterGrant(.screenRecording))

        // The relaunched process: TCC briefly says no, then yes, and capture still fails. That's a
        // stale grant, not another relaunch.
        let next = FakeProbe()
        next.result[.screenRecording] = .failed("still")
        let relaunchedMonitor = PermissionMonitor(probe: next, defaults: defaults)
        _ = await relaunchedMonitor.refresh(.screenRecording, .force)
        next.listed[.screenRecording] = true
        health = await relaunchedMonitor.refresh(.screenRecording, .stale)
        XCTAssertEqual(health, .grantedButNotWorking)

        // Fixed: working clears the flag.
        next.result[.screenRecording] = .working
        health = await relaunchedMonitor.refresh(.screenRecording, .force)
        XCTAssertEqual(health, .working)
        XCTAssertFalse(relaunchedMonitor.relaunchedAfterGrant(.screenRecording))
    }

    func testANewGrantAttemptForgetsTheOldRelaunch() async {
        let monitor = PermissionMonitor(probe: FakeProbe(), defaults: defaults)
        monitor.relaunch(for: .accessibility) {}
        XCTAssertTrue(monitor.relaunchedAfterGrant(.accessibility))
        monitor.markAsked(.accessibility)
        XCTAssertFalse(monitor.relaunchedAfterGrant(.accessibility))
    }

    func testProbeDepths() async throws {
        let probe = FakeProbe()
        probe.listed[.screenRecording] = true
        probe.result[.screenRecording] = .working
        let monitor = PermissionMonitor(probe: probe, defaults: defaults)
        _ = await monitor.refresh(.screenRecording, .listOnly)
        XCTAssertEqual(probe.probes.count, 1, "never checked: check once")
        _ = await monitor.refresh(.screenRecording, .listOnly)
        _ = await monitor.refresh(.screenRecording, .stale)
        XCTAssertEqual(probe.probes.count, 1, "working stays trusted until something changes")
        _ = await monitor.refresh(.screenRecording, .force)
        XCTAssertEqual(probe.probes.count, 2, "Start / Check Again always check")

        probe.result[.screenRecording] = .noDisplays
        let locked = await monitor.refresh(.screenRecording, .force)
        XCTAssertEqual(locked, .noDisplays)
        _ = await monitor.refresh(.screenRecording, .stale)
        XCTAssertEqual(probe.probes.count, 3, "a fresh non-working result isn't re-checked straight away")
    }

    func testPinnedStatesSurviveMeasuring() async {
        let monitor = PermissionMonitor(probe: FakeProbe(), defaults: defaults)
        monitor.pin(.grantedButNotWorking, for: .screenRecording)
        _ = await monitor.refresh(.screenRecording, .force)
        XCTAssertEqual(monitor[.screenRecording], .grantedButNotWorking)
    }

    /// The mock service never reaches TCC: its probe reads the mock's pretend grants.
    func testMockWiringNeverUsesTheLiveProbe() async {
        let fresh = AppModel(wired: Wiring.mock(settings: ServiceSettings(), scenario: .init(fresh: true)), settings: ServiceSettings())
        XCTAssertFalse(fresh.permissions.isLiveProbe)
        let health = await fresh.permissions.refresh(.screenRecording, .force)
        XCTAssertEqual(health, .notDetermined)

        let ready = AppModel(wired: Wiring.mock(settings: ServiceSettings(), scenario: .init()), settings: ServiceSettings())
        let working = await ready.permissions.refresh(.accessibility, .force)
        XCTAssertEqual(working, .working)
    }

    /// Start measures Screen Recording first and doesn't cast into a black screen.
    func testStartIsBlockedByABrokenGrant() async throws {
        let model = AppModel(wired: Wiring.mock(settings: ServiceSettings(), scenario: .init(fresh: true)), settings: ServiceSettings())
        model.start()
        let blocked = await pollUntil { model.startProblem == .screenRecording }
        XCTAssertTrue(blocked)
        XCTAssertEqual(model.state.phase, .idle)
        let headline = Headline(model: model, readiness: model.readiness)
        XCTAssertEqual(headline.title, "Can’t Start Yet")
        XCTAssertEqual(model.readiness.first?.action, .permission(.screenRecording))
        XCTAssertEqual(model.readiness.first?.title, "Screen Recording permission needed")
    }
}

@MainActor
func pollUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@MainActor
final class DisconnectAndPausePresentationTests: XCTestCase {
    func testDisconnectCopy() {
        let at = Calendar.current.date(bySettingHour: 10, minute: 42, second: 0, of: Date())!
        let time = at.formatted(CarDisconnect.timeStyle)
        XCTAssertEqual(CarDisconnect(reason: .leftWiFi, date: at).line, "Car left the Wi‑Fi · \(time)")
        XCTAssertEqual(CarDisconnect(reason: .browserClosed, date: at).line, "Browser closed on the car · \(time)")
        XCTAssertEqual(CarDisconnect(reason: .connectionLost, date: at).line, "Connection lost · \(time)")
        for reason in DisconnectReason.allCases {
            XCTAssertLessThanOrEqual(reason.shortTitle.count, 16, "fits beside the menu bar icon")
        }
    }

    func testNoticeFollowsTheDisconnect() {
        let model = AppModel(wired: Wiring.mock(settings: ServiceSettings(), scenario: .init(disconnect: .leftWiFi)),
                             settings: ServiceSettings())
        XCTAssertNil(model.menuBarNotice)
        model.disconnectChanged(notify: false)
        XCTAssertEqual(model.menuBarNotice?.reason, .leftWiFi)
        XCTAssertEqual(Headline(model: model, readiness: []).detail.hasPrefix("Your Tesla left the Wi‑Fi at"), true)

        model.state.lastDisconnect = nil   // the car reconnected
        model.disconnectChanged(notify: false)
        XCTAssertNil(model.menuBarNotice)
    }

    func testPausedWhileLocked() {
        let model = AppModel(wired: Wiring.mock(settings: ServiceSettings(), scenario: .init(phase: .streaming, host: .locked)),
                             settings: ServiceSettings())
        XCTAssertEqual(Headline(model: model, readiness: []).title, "Paused: Mac is locked")
        XCTAssertEqual(Headline.short(model.state), "Paused: Mac is locked")
        model.service.setHostState(.active)
        XCTAssertEqual(Headline.short(model.state), "Casting")
        XCTAssertEqual(HostState.sleeping.pausedTitle, "Paused: Mac is asleep")
        XCTAssertNil(HostState.active.pausedTitle)
    }

    func testAddressIsTypedNotScanned() {
        XCTAssertEqual(ConnectionMode.compatibility.address, DashcastDefaults.serviceAddress)
        XCTAssertEqual(ConnectionMode.compatibility.scheme, "http://")
        XCTAssertEqual(ConnectionMode.secure(hostname: "car.example.com").address, "car.example.com")
        XCTAssertNil(ConnectionMode.secure(hostname: "car.example.com").scheme)
    }

    func testKeepDisplayAwakeIsPersistedAndOnByDefault() {
        let defaults = UserDefaults(suiteName: "dashcast-settings-\(UUID().uuidString)")!
        XCTAssertTrue(SettingsStore.load(from: defaults).keepDisplayAwake)
        var settings = ServiceSettings()
        settings.keepDisplayAwake = false
        SettingsStore.save(settings, to: defaults)
        XCTAssertFalse(SettingsStore.load(from: defaults).keepDisplayAwake)
    }
}
