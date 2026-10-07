import DashcastContracts
import Security
import XCTest
@testable import Dashcast

/// The Car Hotspot checklist, worked out from live state. Pure: nothing is shown.
final class HotspotSetupTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func inputs(_ stage: HotspotStage, check: TimeInterval? = nil, casting: Bool = false, running: Bool = false,
                        withoutInternet: Bool = false, carSeen: TimeInterval? = nil) -> HotspotSetup.Inputs {
        var network = NetworkStatus()
        network.topology = stage.topology
        network.hotspot = stage.status
        return .init(network: network, lastConnectivityCheck: check.map { now.addingTimeInterval(-$0) }, casting: casting,
                     serviceRunning: running, withoutInternet: withoutInternet,
                     carSeenAt: carSeen.map { now.addingTimeInterval(-$0) }, now: now)
    }

    private func setup(_ stage: HotspotStage, check: TimeInterval? = nil, casting: Bool = false, running: Bool = false,
                       withoutInternet: Bool = false, carSeen: TimeInterval? = nil) -> HotspotSetup {
        HotspotSetup(inputs(stage, check: check, casting: casting, running: running,
                            withoutInternet: withoutInternet, carSeen: carSeen))
    }

    // MARK: Internet for this Mac

    func testMacOnAPhonesWiFiNeedsACableFirst() {
        let s = setup(.phoneWiFi)
        XCTAssertEqual(s.internet, .onWiFi(phone: true))
        XCTAssertEqual(s.current, .internet)
        XCTAssertTrue(s.done.isEmpty)
        XCTAssertTrue(s.dropsWiFi, "sharing would take the Wi‑Fi the Mac's internet uses")
    }

    func testContinueWithoutInternetMovesOnAndIsRemembered() {
        let s = setup(.phoneWiFi, withoutInternet: true)
        XCTAssertEqual(s.internet, .without)
        XCTAssertEqual(s.current, .sharing)
        XCTAssertEqual(s.summary(.internet), "No internet for the car")
    }

    func testACableTicksTheInternetStep() {
        let s = setup(.partial)
        XCTAssertEqual(s.internet, .cable(name: "iPhone USB"))
        XCTAssertTrue(s.isDone(.internet))
        XCTAssertEqual(s.current, .sharing)
        XCTAssertFalse(s.dropsWiFi)
        XCTAssertEqual(s.summary(.internet), "iPhone USB")
    }

    func testNoInternetAtAllStillAsks() {
        let s = setup(.unconfigured)
        XCTAssertEqual(s.internet, .none)
        XCTAssertEqual(s.current, .internet)
    }

    func testSharingOnWithoutACableCountsAsDecided() {
        var input = inputs(.on)
        input.network.hotspot.uplinks = []
        let s = HotspotSetup(input)
        XCTAssertTrue(s.isDone(.internet))
        XCTAssertEqual(s.summary(.internet), "No internet for the car")
        XCTAssertEqual(s.current, .join)
    }

    // MARK: Internet Sharing

    func testChecklistTicksWhatIsSet() {
        let partial = Dictionary(uniqueKeysWithValues: setup(.partial).checklist.map { ($0.id, $0) })
        XCTAssertEqual(partial[.shareFrom]?.status, .done)
        XCTAssertEqual(partial[.shareFrom]?.value, "iPhone USB")
        XCTAssertEqual(partial[.toWiFi]?.status, .todo)
        XCTAssertEqual(partial[.networkName]?.status, .todo)
        XCTAssertEqual(partial[.networkName]?.copy, "Dashcast")
        XCTAssertEqual(partial[.channel]?.status, .suggestion, "the channel is a recommendation, never a blocker")
        XCTAssertEqual(partial[.password]?.status, .unknown, "the password can't be read")
        XCTAssertEqual(partial[.turnOn]?.status, .todo)

        let configured = Dictionary(uniqueKeysWithValues: setup(.configuredOff).checklist.map { ($0.id, $0) })
        for id: ChecklistItem.ID in [.shareFrom, .toWiFi, .networkName, .channel] {
            XCTAssertEqual(configured[id]?.status, .done, id.rawValue)
        }
        XCTAssertEqual(configured[.turnOn]?.status, .todo)
        XCTAssertEqual(setup(.starting).checklist.last?.status, .working)
        XCTAssertEqual(setup(.starting).sharing, .starting)
        XCTAssertEqual(setup(.starting).current, .sharing)
    }

    func testShareFromTheWrongInterfaceIsNotTicked() {
        var input = inputs(.configuredOff)
        input.network.hotspot.shareFrom = HotspotStatus.Uplink(name: "Ethernet", interface: "en0", connected: false)
        let item = HotspotSetup(input).checklist.first { $0.id == .shareFrom }
        XCTAssertEqual(item?.status, .todo)
        XCTAssertEqual(item?.value, "iPhone USB")
        XCTAssertEqual(item?.note, "Now set to Ethernet.")
    }

    func testAnyNetworkNameIsFine() {
        var input = inputs(.configuredOff)
        input.network.hotspot.networkName = "David’s MacBook"
        let s = HotspotSetup(input)
        XCTAssertEqual(s.checklist.first { $0.id == .networkName }?.status, .done)
        XCTAssertEqual(s.displayName, "David’s MacBook")
    }

    func testSharingOnMovesToJoin() {
        let s = setup(.on, running: true)
        XCTAssertEqual(s.sharing, .on)
        XCTAssertEqual(s.done, [.internet, .sharing])
        XCTAssertEqual(s.current, .join)
        XCTAssertEqual(s.join, .waiting)
        XCTAssertEqual(s.check, .waiting(ready: true))
        XCTAssertEqual(s.summary(.sharing), "On · Dashcast")
    }

    // MARK: The car

    func testAnotherDeviceIsMentionedButDoesNotTick() {
        let s = setup(.otherDevice)
        XCTAssertEqual(s.join, .otherDevice(HotspotStage.iPad))
        XCTAssertEqual(s.current, .join)
        XCTAssertEqual(HotspotStage.iPad.label, "“iPad” · 192.168.2.4")
    }

    func testTeslaJoinedWaitsForItsCheck() {
        let s = setup(.carJoined, running: true, carSeen: 5)
        XCTAssertEqual(s.join, .joined(HotspotStage.tesla))
        XCTAssertEqual(s.current, .check)
        XCTAssertEqual(s.check, .waiting(ready: true))
        XCTAssertEqual(s.summary(.join), "Joined · 192.168.2.3")
    }

    func testNoCheckAfterTheGraceSaysWhy() {
        let late = HotspotSetup.checkGrace + 1
        XCTAssertEqual(setup(.carJoined, running: false, carSeen: late).check, .noAnswer(ready: false))
        XCTAssertEqual(setup(.carJoined, running: true, carSeen: late).check, .noAnswer(ready: true))
        XCTAssertEqual(setup(.carJoined, running: false, carSeen: HotspotSetup.checkGrace - 1).check, .waiting(ready: false))
    }

    func testAnsweredCheckTicksAndOpensTheBrowserStep() {
        let s = setup(.checked, check: 3, running: true, carSeen: 5)
        XCTAssertEqual(s.check, .answered)
        XCTAssertEqual(s.current, .browser)
        XCTAssertEqual(s.done, [.internet, .sharing, .join, .check])
    }

    func testAFreshCheckProvesTheCarJoinedEvenUnrecognised() {
        var input = inputs(.on, check: 30, running: true)
        input.network.hotspot.devices = [HotspotStage.iPad]
        let s = HotspotSetup(input)
        XCTAssertEqual(s.join, .joined(nil))
        XCTAssertEqual(s.check, .answered)
    }

    func testAnOldCheckOnlyCountsWhileTheCarIsThere() {
        let old = HotspotSetup.checkFreshness + 60
        XCTAssertEqual(setup(.on, check: old).check, .waiting(ready: false))
        XCTAssertEqual(setup(.carJoined, check: old, carSeen: 5).check, .answered)
    }

    func testCastingFinishesEverything() {
        let s = setup(.connected, casting: true, running: true)
        XCTAssertTrue(s.isComplete)
        XCTAssertNil(s.current)
        XCTAssertEqual(s.summary(.browser), "Casting")
    }

    /// A later step proves the earlier ones: connected over a hotspot the Mac can't see described.
    func testLaterStepsImplyEarlierOnes() {
        let s = setup(.unconfigured, casting: true)
        XCTAssertEqual(s.done, Set(HotspotSetup.Step.allCases))
    }

    // MARK: Auto-ready

    func testAutoReadyOnlyOnTheOffToOnTransition() {
        XCTAssertTrue(AutoReady.shouldStart(wasUp: false, isUp: true, enabled: true, phase: .idle,
                                            screenRecording: .working, transitioning: false))
        XCTAssertFalse(AutoReady.shouldStart(wasUp: true, isUp: true, enabled: true, phase: .idle,
                                             screenRecording: .working, transitioning: false), "a Stop while it's on stays stopped")
        XCTAssertFalse(AutoReady.shouldStart(wasUp: false, isUp: false, enabled: true, phase: .idle,
                                             screenRecording: .working, transitioning: false))
        XCTAssertFalse(AutoReady.shouldStart(wasUp: false, isUp: true, enabled: false, phase: .idle,
                                             screenRecording: .working, transitioning: false), "setting off")
        XCTAssertFalse(AutoReady.shouldStart(wasUp: false, isUp: true, enabled: true, phase: .waitingForCar,
                                             screenRecording: .working, transitioning: false), "already running")
        XCTAssertFalse(AutoReady.shouldStart(wasUp: false, isUp: true, enabled: true, phase: .idle,
                                             screenRecording: .working, transitioning: true))
        for broken: PermissionHealth in [.notDetermined, .denied, .needsRelaunch, .grantedButNotWorking] {
            XCTAssertFalse(AutoReady.shouldStart(wasUp: false, isUp: true, enabled: true, phase: .idle,
                                                 screenRecording: broken, transitioning: false), broken.rawValue)
        }
        XCTAssertTrue(AutoReady.shouldStart(wasUp: false, isUp: true, enabled: true, phase: .idle,
                                            screenRecording: .checking, transitioning: false), "measured again before starting")
    }

    func testHotspotUpFromEitherSignal() {
        var network = NetworkStatus()
        XCTAssertFalse(AutoReady.isHotspotUp(network))
        network.hotspot.sharingOn = true
        XCTAssertTrue(AutoReady.isHotspotUp(network))
        network = NetworkStatus()
        network.topology = .macHotspot
        XCTAssertTrue(AutoReady.isHotspotUp(network))
    }

    // MARK: The app model

    @MainActor
    func testReadinessOffersOneSetUpRow() {
        for (topology, stage) in [(Topology.offline, HotspotStage.unconfigured), (.phoneHotspot, .phoneWiFi)] {
            let model = AppModel(wired: Wiring.mock(settings: ServiceSettings(), scenario: .init(topology: topology, hotspot: stage)),
                                 settings: ServiceSettings())
            let rows = model.readiness.filter { $0.action == .setUpHotspot }
            XCTAssertEqual(rows.count, 1, "\(topology)")
            XCTAssertEqual(rows.first?.title, "Set up the car hotspot")
            XCTAssertEqual(rows.first?.actionTitle, "Set Up…")
        }
        let ready = AppModel(wired: Wiring.mock(settings: ServiceSettings(), scenario: .init(hotspot: .on)), settings: ServiceSettings())
        XCTAssertFalse(ready.readiness.contains { $0.action == .setUpHotspot })
    }

    // MARK: The hotspot password

    @MainActor
    func testThePasswordIsMadeOnceAndKept() {
        RenderMode.offscreen = true   // no preferences written
        defer { RenderMode.offscreen = false }
        let store = ScriptedPasswordStore()
        let first = model(store).hotspotPassword
        XCTAssertTrue(HotspotPassword.isEasyToType(first))
        XCTAssertEqual(store.saved, [first])
        XCTAssertEqual(model(store).hotspotPassword, first, "the next launch reads it back, never a new one")
        XCTAssertEqual(store.saved, [first])
    }

    /// A locked or refused Keychain read is not "no password yet": the saved one is never replaced.
    @MainActor
    func testAnUnreadablePasswordIsNeverReplaced() {
        RenderMode.offscreen = true
        defer { RenderMode.offscreen = false }
        let store = ScriptedPasswordStore()
        store.unreadable = true
        let model = model(store)
        let suggested = model.hotspotPassword
        XCTAssertTrue(HotspotPassword.isEasyToType(suggested))
        XCTAssertEqual(model.hotspotPassword, suggested, "one suggestion per launch")
        XCTAssertEqual(store.saved, [], "the saved one stays")
        XCTAssertNil(model.knownHotspotPassword, "Dashcast can't say what it is")

        // Do It for Me (or the user's OK) sets the suggestion: it's the hotspot's now, and kept.
        model.sharingAssistant.onOptionsSaved?(model.sharingPlan)
        XCTAssertEqual(store.saved, [suggested])
        XCTAssertEqual(model.knownHotspotPassword, suggested)
    }

    @MainActor
    private func model(_ store: HotspotPasswordStoring) -> AppModel {
        AppModel(wired: Wiring.mock(settings: ServiceSettings(), scenario: .init(hotspot: .on)), settings: ServiceSettings(),
                 hotspotPasswords: store)
    }

    // MARK: Polling

    func testTheWindowPollsOnlyWhatNothingReports() {
        XCTAssertEqual(HotspotSetup.pollInterval(setup(.unconfigured), assistant: .idle), 10, "cables and sharing are watched")
        XCTAssertEqual(HotspotSetup.pollInterval(setup(.configuredOff), assistant: .guiding), 2, "setting it up")
        XCTAssertEqual(HotspotSetup.pollInterval(setup(.configuredOff), assistant: .finished(now)), 2, "“hasn’t started” ticks on time")
        XCTAssertEqual(HotspotSetup.pollInterval(setup(.on, running: true), assistant: .idle), 2, "a car joining is only seen by looking")
        XCTAssertEqual(HotspotSetup.pollInterval(setup(.carJoined, carSeen: 5), assistant: .idle), 2)
        XCTAssertEqual(HotspotSetup.pollInterval(setup(.connected, check: 5, casting: true), assistant: .idle), 10, "all done")
        XCTAssertEqual(HotspotSetup.pollInterval(setup(.connected, check: 5, casting: true), assistant: .finished(now)), 10,
                       "a finished Do It for Me doesn't keep it fast")
    }

    /// The coach closes when sharing comes on, also after Guide Me had it turned off to change it.
    func testTheCoachClosesWhenSharingComesOnAgain() {
        var wasOn = true   // opened with sharing on
        XCTAssertFalse(HotspotCoach.sharingCameOn(true, wasOn: &wasOn, automating: false))
        XCTAssertFalse(HotspotCoach.sharingCameOn(false, wasOn: &wasOn, automating: false), "turned off to edit")
        XCTAssertFalse(HotspotCoach.sharingCameOn(true, wasOn: &wasOn, automating: true), "Do It for Me finishes itself")
        XCTAssertTrue(HotspotCoach.sharingCameOn(true, wasOn: &wasOn, automating: false), "on again")
    }

    @MainActor
    func testCarSeenAtFollowsTheHotspot() {
        let model = AppModel(wired: Wiring.mock(settings: ServiceSettings(), scenario: .init(hotspot: .carJoined)),
                             settings: ServiceSettings())
        model.trackHotspotCar(now: now)
        XCTAssertEqual(model.hotspotCarSeenAt, now)
        model.trackHotspotCar(now: now.addingTimeInterval(10))
        XCTAssertEqual(model.hotspotCarSeenAt, now, "the first sighting sticks")
        model.state.network.hotspot.devices = []
        model.trackHotspotCar()
        XCTAssertNil(model.hotspotCarSeenAt)
    }
}

/// The Keychain as the tests need it: empty, or there but unreadable (locked, or access refused).
final class ScriptedPasswordStore: HotspotPasswordStoring {
    var unreadable = false
    private(set) var saved: [String] = []

    func load() throws -> String? {
        if unreadable { throw HotspotPasswordUnreadable(status: errSecInteractionNotAllowed) }
        return saved.last
    }

    func save(_ password: String) -> Bool {
        saved.append(password)
        return true
    }
}
