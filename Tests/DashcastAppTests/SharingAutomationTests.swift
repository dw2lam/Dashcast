import DashcastContracts
import XCTest
@testable import Dashcast

/// The Internet Sharing locators, guidance and automation, against Accessibility trees captured
/// from System Settings on macOS 27 (AXMaps/) and a scripted fake. Nothing real is touched.
///
///   sharing.txt  the Sharing pane, ⓘ sheet open (share from Wi‑Fi), older dump format
///   state-1      ⓘ sheet, share from Wi‑Fi, master switch disabled
///   state-2      share from iPhone USB chosen, Wi‑Fi not listed yet
///   state-3      the Touch ID prompt over the ⓘ sheet
///   state-4      Wi‑Fi Options… open (name, channel 11, an 8-character password)
///   state-5      "Are you sure you want to turn on Internet sharing?"
///   state-6      sharing on: everything greyed out
///   state-7      the Sharing pane, no sheet, Internet Sharing on
@MainActor
final class SharingAutomationTests: XCTestCase {
    private func screen(_ name: String, strip: Bool = false) throws -> SharingScreen {
        let app = try AXDump.load(name)
        if strip { app.removeIdentifiers() }
        return SharingScreen(app: app)
    }

    private func plan(cable: Bool = true, password: String = "maplesky47") -> SharingPlan {
        var hotspot = HotspotStatus()
        hotspot.uplinks = [HotspotStatus.Uplink(name: "iPhone USB", interface: "en9", connected: cable)]
        return SharingPlan(hotspot: hotspot, password: password)
    }

    private static let fast = SharingAutomation.Timing(poll: 0.001, element: 0.25, settle: 0, authorize: 3, launch: 0.25)

    // MARK: - Locators on the captured trees

    func testDumpsLoad() throws {
        let app = try AXDump.load("state-4")
        XCTAssertEqual(app.kids.first?.role, "AXWindow")
        XCTAssertEqual(app.kids.first?.title, "Sharing")
        // The toolbar item whose actions span several lines stays one element.
        XCTAssertNotNil(app.find { $0.role == "AXToolbar" })
    }

    func testPaneRowByIdentifier() throws {
        let pane = try screen("state-7")
        XCTAssertEqual(pane.infoButton?.frame, CGRect(x: 1071, y: 756, width: 17, height: 17))
        XCTAssertEqual(pane.rowSwitch?.isOn, true)
        XCTAssertNil(pane.details)
        XCTAssertNil(pane.options)
        XCTAssertNil(pane.alert)
        XCTAssertNil(pane.authorization)
    }

    func testPaneRowWithoutIdentifiersFallsBackToItsLabel() throws {
        let pane = try screen("state-7", strip: true)
        XCTAssertEqual(pane.infoButton?.frame, CGRect(x: 1071, y: 756, width: 17, height: 17))
        XCTAssertEqual(pane.rowSwitch?.frame, CGRect(x: 1024, y: 757, width: 36, height: 16))
    }

    func testDetailsSheetSharingFromWiFi() throws {
        for name in ["sharing", "state-1"] {
            let details = try XCTUnwrap(screen(name).details, name)
            XCTAssertEqual(details.shareFrom?.value, "Wi-Fi", name)
            XCTAssertEqual(details.masterSwitch?.isOn, false, name)
            XCTAssertFalse(details.isOn, name)
            XCTAssertEqual(details.toggles.count, 7, name)
            XCTAssertNil(details.wifiToggle, "Wi‑Fi isn't listed while it's the share-from")
            XCTAssertNil(details.wifiOptions, name)
            XCTAssertNotNil(details.done, name)
            XCTAssertNotNil(details.list, name)
        }
        XCTAssertEqual(try screen("state-1").details?.masterSwitch?.isEnabled, false)
    }

    func testDetailsAfterChoosingIPhoneUSB() throws {
        let s = try screen("state-2")
        let details = try XCTUnwrap(s.details)
        XCTAssertEqual(details.shareFrom?.value, "iPhone USB")
        XCTAssertEqual(details.shareFrom?.frame, CGRect(x: 836, y: 459, width: 119, height: 24))
        XCTAssertNil(details.wifiToggle)
        XCTAssertNil(s.authorization)
        XCTAssertNil(s.menu)
    }

    func testTouchIDPromptIsTheAuthorization() throws {
        let s = try screen("state-3")
        XCTAssertNotNil(s.authorization)
        XCTAssertNotNil(s.details, "the ⓘ sheet is still found beneath it")
        XCTAssertNil(s.alert, "its Cancel is not a confirmation")
        XCTAssertNil(s.options)
    }

    func testWiFiOptionsSheet() throws {
        let s = try screen("state-4")
        let options = try XCTUnwrap(s.options)
        XCTAssertEqual(options.nameField?.value, "Dashcast")
        XCTAssertEqual(options.channel?.value, "11")
        XCTAssertEqual(options.security?.value, "WPA2/WPA3 Personal")
        XCTAssertEqual(options.password?.value?.count, 8, "a secure field reads back as one bullet per character")
        XCTAssertNotNil(options.passwordHint)
        XCTAssertEqual(options.ok?.title, "OK")
        XCTAssertEqual(options.cancel?.title, "Cancel")
        let details = try XCTUnwrap(s.details, "the ⓘ sheet behind it, without the nested sheet's controls")
        XCTAssertEqual(details.wifiToggle?.isOn, true)
        XCTAssertEqual(details.toggles.count, 8)
        XCTAssertEqual(details.shareFrom?.value, "iPhone USB")
        XCTAssertNotNil(details.wifiOptions)
        XCTAssertEqual(details.done?.axDescription, "Done")
    }

    func testTurnOnConfirmation() throws {
        let alert = try XCTUnwrap(screen("state-5").alert)
        XCTAssertTrue(alert.isTurnOn)
        XCTAssertEqual(alert.confirm?.title, "Turn On")
        XCTAssertEqual(alert.cancel?.title, "Cancel")
    }

    func testSharingOnLocksEverything() throws {
        let details = try XCTUnwrap(screen("state-6").details)
        XCTAssertTrue(details.isOn)
        XCTAssertEqual(details.shareFrom?.isEnabled, false)
        XCTAssertEqual(details.wifiOptions?.isEnabled, false)
        XCTAssertEqual(details.wifiToggle?.isEnabled, false)
    }

    // MARK: - Guidance on the captured trees

    func testGuidanceOnEachCapturedState() throws {
        let plan = plan()
        let memory = SharingGuide.Memory()
        func next(_ name: String, _ memory: SharingGuide.Memory = SharingGuide.Memory()) throws -> SharingGuidance? {
            SharingGuide.next(try screen(name), plan: plan, memory: memory)
        }

        let pane = try XCTUnwrap(next("state-7"))
        XCTAssertEqual(pane.step, .openDetails)
        XCTAssertEqual(pane.instruction, "Click ⓘ")
        XCTAssertEqual(pane.target, CGRect(x: 1071, y: 756, width: 17, height: 17))
        XCTAssertEqual(pane.window, CGRect(x: 380, y: 276, width: 740, height: 625))
        XCTAssertNil(try next("state-7", SharingGuide.Memory(optionsKnownSet: true)), "on and known: nothing left")

        let fromWiFi = try XCTUnwrap(next("state-1"))
        XCTAssertEqual(fromWiFi.step, .shareFrom)
        XCTAssertEqual(fromWiFi.instruction, "Choose iPhone USB")
        XCTAssertEqual(fromWiFi.target, CGRect(x: 875, y: 459, width: 80, height: 24))

        let wifiMissing = try XCTUnwrap(next("state-2"))
        XCTAssertEqual(wifiMissing.step, .toWiFi)
        XCTAssertEqual(wifiMissing.target, CGRect(x: 535, y: 537, width: 430, height: 168), "points at the list to scroll")

        XCTAssertEqual(try next("state-3")?.step, .authorize)

        let options = try XCTUnwrap(next("state-4"))
        XCTAssertEqual(options.step, .channel, "the name is already Dashcast")
        XCTAssertEqual(options.instruction, "Choose 149")
        XCTAssertEqual(options.target, CGRect(x: 696, y: 542, width: 260, height: 26))

        let confirm = try XCTUnwrap(next("state-5"))
        XCTAssertEqual(confirm.step, .confirmTurnOn)
        XCTAssertEqual(confirm.target, CGRect(x: 753, y: 660, width: 112, height: 30))

        let on = try XCTUnwrap(next("state-6"))
        XCTAssertEqual(on.step, .done)
        XCTAssertEqual(on.instruction, "Click Done")
        _ = memory
    }

    func testGuidanceWithoutACablePicksThunderboltBridge() throws {
        let guidance = SharingGuide.next(try screen("state-2"), plan: plan(cable: false), memory: SharingGuide.Memory())
        XCTAssertEqual(guidance?.step, .shareFrom, "iPhone USB isn't plugged in: sharing from it never starts")
        XCTAssertEqual(guidance?.instruction, "Choose Thunderbolt Bridge")
        XCTAssertNotNil(guidance?.detail)
    }

    func testPasswordGuidanceCarriesThePassword() throws {
        let app = try AXDump.load("state-4")
        app.find { $0.identifier == "_NS:22" }?.value = "149"
        let guidance = SharingGuide.next(SharingScreen(app: app), plan: plan(), memory: SharingGuide.Memory())
        XCTAssertEqual(guidance?.step, .password, "8 bullets aren't a 10-character password")
        XCTAssertEqual(guidance?.copy, "maplesky47")
        app.find { $0.subrole == "AXSecureTextField" }?.value = String(repeating: "\u{F79A}", count: 10)
        XCTAssertEqual(SharingGuide.next(SharingScreen(app: app), plan: plan(), memory: SharingGuide.Memory())?.step, .confirmOptions)
    }

    // MARK: - Plan

    func testPlanChoices() {
        let cable = plan()
        XCTAssertEqual(cable.shareFrom, ["iPhone USB"])
        XCTAssertFalse(cable.withoutCable)
        XCTAssertTrue(cable.acceptsShareFrom("iPhone USB"))
        XCTAssertFalse(cable.acceptsShareFrom("Wi-Fi"))
        XCTAssertFalse(cable.acceptsShareFrom("Thunderbolt Bridge"))
        XCTAssertEqual(cable.shareFromChoice(among: ["Wi-Fi", "Thunderbolt Bridge", "iPhone USB"]), "iPhone USB")
        XCTAssertNil(cable.shareFromChoice(among: ["Wi-Fi", "Thunderbolt Bridge"]), "never a different port when a cable is planned")

        let none = plan(cable: false)
        XCTAssertTrue(none.withoutCable)
        XCTAssertEqual(none.preferredShareFrom, "Thunderbolt Bridge")
        XCTAssertFalse(none.acceptsShareFrom("iPhone USB"), "known to be unplugged")
        XCTAssertFalse(none.acceptsShareFrom("Wi‑Fi"), "never Wi‑Fi, however it's spelled")
        XCTAssertTrue(none.acceptsShareFrom("Ethernet Adapter (en3)"))
        XCTAssertEqual(none.shareFromChoice(among: ["Wi-Fi", "iPhone USB", "Thunderbolt Bridge"]), "Thunderbolt Bridge")
        XCTAssertEqual(none.shareFromChoice(among: ["Wi-Fi", "iPhone USB", "USB 10/100/1000 LAN"]), "USB 10/100/1000 LAN")

        XCTAssertEqual(cable.channelChoice(among: ["1", "6", "11", "36", "149"]), "149")
        XCTAssertEqual(cable.channelChoice(among: ["1", "6", "11", "36"]), "36")
        XCTAssertNil(cable.channelChoice(among: ["1", "6", "11"]))
        XCTAssertTrue(cable.acceptsChannel("44"))
        XCTAssertFalse(cable.acceptsChannel("11"))
        XCTAssertFalse(cable.acceptsChannel("Automatic"))
    }

    func testPasswordsAreEasyToTypeInTheCar() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let password = HotspotPassword.generate(using: &generator)
            XCTAssertTrue(HotspotPassword.isEasyToType(password), password)
            XCTAssertTrue(password.suffix(2).allSatisfy(\.isNumber), password)
        }
        let store = MemoryHotspotPasswordStore()
        XCTAssertNil(store.load())
        store.save("maplesky47")
        XCTAssertEqual(store.load(), "maplesky47")
    }

    func testChecklistShowsDashcastsPassword() {
        var hotspot = HotspotStage.configuredOff.status
        hotspot.networkName = "Dashcast"
        let items = ChecklistItem.items(for: hotspot, connectedUplink: HotspotStage.iPhoneUSB, sharing: .off, password: "maplesky47")
        let password = items.first { $0.id == .password }
        XCTAssertEqual(password?.value, "maplesky47")
        XCTAssertEqual(password?.copy, "maplesky47")
        XCTAssertEqual(password?.status, .todo)
        let set = ChecklistItem.items(for: hotspot, connectedUplink: HotspotStage.iPhoneUSB, sharing: .off,
                                      password: "maplesky47", passwordSet: true)
        XCTAssertEqual(set.first { $0.id == .password }?.status, .done)
    }

    func testNoCableChecklistAsksForAPortThatIsThere() {
        let unconfigured = HotspotStage.unconfigured.status   // nothing connected, share-from never set
        let item = ChecklistItem.items(for: unconfigured, connectedUplink: nil, sharing: .off).first { $0.id == .shareFrom }
        XCTAssertEqual(item?.status, .todo)
        XCTAssertEqual(item?.value, "Thunderbolt Bridge")
        var unplugged = unconfigured
        unplugged.shareFrom = HotspotStatus.Uplink(name: "iPhone USB", interface: "en9", connected: false)
        XCTAssertEqual(ChecklistItem.items(for: unplugged, connectedUplink: nil, sharing: .off).first?.status, .todo)
        unplugged.shareFrom = HotspotStatus.Uplink(name: "Thunderbolt Bridge", interface: "bridge0", connected: false)
        XCTAssertEqual(ChecklistItem.items(for: unplugged, connectedUplink: nil, sharing: .off).first?.status, .done)
    }

    // MARK: - Do It for Me, on the scripted fake

    private func run(_ fake: FakeSystemSettings, plan: SharingPlan? = nil) async -> (Result<Void, SharingAutomationError>, [SharingAutomation.Event]) {
        var events: [SharingAutomation.Event] = []
        let automation = SharingAutomation(environment: fake, plan: plan ?? self.plan(), timing: Self.fast) { events.append($0) }
        do {
            try await automation.run()
            return (.success(()), events)
        } catch let error as SharingAutomationError {
            return (.failure(error), events)
        } catch {
            XCTFail("\(error)")
            return (.failure(SharingAutomationError(step: .openPane, reason: "\(error)")), events)
        }
    }

    func testDoItForMeFromScratch() async throws {
        let fake = FakeSystemSettings()
        let (result, events) = await run(fake)
        if case .failure(let error) = result { XCTFail("\(error)") }
        XCTAssertTrue(fake.sharingOn)
        XCTAssertEqual(fake.savedShareFrom, "iPhone USB")
        XCTAssertEqual(fake.toggles.filter(\.value).map(\.key), ["Wi-Fi"], "only Wi‑Fi, the others left alone")
        XCTAssertEqual(fake.networkName, "Dashcast")
        XCTAssertEqual(fake.channel, "149")
        XCTAssertEqual(fake.password, "maplesky47")
        XCTAssertFalse(fake.detailsOpen, "Done was pressed")
        XCTAssertTrue(fake.typed.isEmpty, "AXValue took: nothing typed")
        XCTAssertTrue(events.contains(.waitingForYou(true)), "macOS asked for Touch ID after the share-from change")
        XCTAssertTrue(events.contains(.waitingForYou(false)))
        XCTAssertTrue(events.contains(.optionsSaved))
        let steps = events.compactMap { if case .step(let step) = $0 { step } else { nil } }
        XCTAssertEqual(steps, [.openPane, .openDetails, .shareFrom, .toWiFi, .wifiOptions, .networkName, .channel,
                               .password, .confirmOptions, .turnOn, .confirmTurnOn, .done])
    }

    func testSharingOnIsTurnedOffToChangeIt() async throws {
        let fake = FakeSystemSettings()
        fake.savedShareFrom = "USB 10/100/1G/2.5G LAN"
        fake.shareFrom = fake.savedShareFrom
        fake.toggles = ["Wi-Fi": true]
        fake.sharingOn = true
        let (result, events) = await run(fake)
        if case .failure(let error) = result { XCTFail("\(error)") }
        XCTAssertTrue(events.contains(.step(.turnOffToEdit)))
        XCTAssertTrue(fake.sharingOn)
        XCTAssertEqual(fake.savedShareFrom, "iPhone USB")
    }

    func testAlreadyRightIsLeftAlone() async throws {
        let fake = FakeSystemSettings()
        fake.savedShareFrom = "iPhone USB"
        fake.shareFrom = "iPhone USB"
        fake.toggles = ["Wi-Fi": true]
        fake.channel = "36"
        fake.networkName = "Dashcast"
        let (result, _) = await run(fake)
        if case .failure(let error) = result { XCTFail("\(error)") }
        XCTAssertEqual(fake.channel, "36", "a 5 GHz channel stays")
        XCTAssertTrue(fake.sharingOn)
    }

    func testNoCableSharesFromThunderboltBridge() async throws {
        let fake = FakeSystemSettings()
        let (result, _) = await run(fake, plan: plan(cable: false))
        if case .failure(let error) = result { XCTFail("\(error)") }
        XCTAssertEqual(fake.savedShareFrom, "Thunderbolt Bridge")
        XCTAssertTrue(fake.sharingOn)
    }

    func testValueThatDoesNotTakeIsTyped() async throws {
        let fake = FakeSystemSettings()
        fake.acceptsAXValue = false
        let (result, _) = await run(fake)
        if case .failure(let error) = result { XCTFail("\(error)") }
        XCTAssertEqual(fake.typed, ["Dashcast", "maplesky47"])
        XCTAssertEqual(fake.password, "maplesky47")
    }

    func testChannelsWithout149Or36AreLeftAsTheyAre() async throws {
        let fake = FakeSystemSettings()
        fake.channels = ["Automatic", "1", "6", "11"]
        let (result, _) = await run(fake)
        if case .failure(let error) = result { XCTFail("\(error)") }
        XCTAssertEqual(fake.channel, "11")
        XCTAssertNil(fake.menu, "the menu was closed again")
    }

    // MARK: Failures hand over to Guide Me at the same step

    /// Runs, expects a failure at `step`, and checks Guide Me would point at that step right now.
    private func expectHandoff(_ fake: FakeSystemSettings, plan: SharingPlan? = nil, at step: SharingStep,
                               file: StaticString = #filePath, line: UInt = #line) async -> SharingAutomationError? {
        let (result, _) = await run(fake, plan: plan)
        guard case .failure(let error) = result else {
            XCTFail("expected a failure at \(step)", file: file, line: line)
            return nil
        }
        XCTAssertEqual(error.step, step, error.reason, file: file, line: line)
        XCTAssertFalse(error.reason.isEmpty, file: file, line: line)
        XCTAssertFalse(error.reason.contains("\n"), "one line", file: file, line: line)
        let guidance = SharingGuide.next(SharingScreen(app: fake.settingsApp()), plan: plan ?? self.plan(), memory: SharingGuide.Memory())
        XCTAssertEqual(guidance?.step, step, "Guide Me picks up where it stopped", file: file, line: line)
        XCTAssertNotNil(guidance?.target, file: file, line: line)
        return error
    }

    func testMenuThatNeverOpens() async {
        let fake = FakeSystemSettings()
        fake.menuOpens = false
        let error = await expectHandoff(fake, at: .shareFrom)
        XCTAssertEqual(error?.reason, "The menu didn’t open.")
    }

    func testCancelledTouchID() async {
        let fake = FakeSystemSettings()
        fake.authCancels = true
        let error = await expectHandoff(fake, at: .shareFrom)
        XCTAssertTrue(error?.reason.contains("cancelled") == true, error?.reason ?? "")
    }

    func testTypingNeedsSystemSettingsInFront() async {
        let fake = FakeSystemSettings()
        fake.acceptsAXValue = false
        fake.frontmost = false
        let error = await expectHandoff(fake, at: .networkName)
        XCTAssertTrue(fake.typed.isEmpty, "never types into another app")
        XCTAssertTrue(error?.reason.contains("isn’t in front") == true)
    }

    func testOKGreyedOutStops() async {
        let fake = FakeSystemSettings()
        let error = await expectHandoff(fake, plan: plan(password: "short"), at: .confirmOptions)
        XCTAssertTrue(error?.reason.contains("OK is greyed out") == true)
    }

    func testNeedsAccessibilityAndAnUnlockedScreen() async {
        let untrusted = FakeSystemSettings()
        untrusted.trusted = false
        let (a, _) = await run(untrusted)
        guard case .failure(let error) = a else { return XCTFail() }
        XCTAssertEqual(error.step, .openPane)
        XCTAssertFalse(untrusted.running, "nothing opened")

        let locked = FakeSystemSettings()
        locked.locked = true
        let (b, _) = await run(locked)
        guard case .failure(let lockedError) = b else { return XCTFail() }
        XCTAssertEqual(lockedError.reason, "The screen is locked.")
    }

    // MARK: - The assistant

    func testAssistantHandsOverToGuideMe() async throws {
        let fake = FakeSystemSettings()
        fake.menuOpens = false
        let assistant = SharingAssistant(environment: fake, defaults: UserDefaults(suiteName: "SharingAutomationTests")!)
        assistant.timing = Self.fast
        assistant.automate(plan())
        XCTAssertEqual(assistant.phase, .automating)
        XCTAssertEqual(assistant.activeMode, .automatic)
        for _ in 0..<400 where assistant.phase == .automating {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(assistant.phase, .guiding)
        XCTAssertEqual(assistant.activeMode, .guided)
        XCTAssertEqual(assistant.handoff, "The menu didn’t open.")
        XCTAssertEqual(assistant.guidance?.step, .shareFrom)
        XCTAssertEqual(assistant.step?.checklistItem, .shareFrom)
        assistant.stop()
        XCTAssertEqual(assistant.phase, .idle)
        XCTAssertNil(assistant.guidance)
    }

    func testAssistantFinishes() async throws {
        let fake = FakeSystemSettings()
        let assistant = SharingAssistant(environment: fake, defaults: UserDefaults(suiteName: "SharingAutomationTests")!)
        assistant.timing = Self.fast
        var saved: SharingPlan?
        assistant.onOptionsSaved = { saved = $0 }
        assistant.automate(plan())
        for _ in 0..<400 where assistant.phase == .automating {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        guard case .finished(let at) = assistant.phase else { return XCTFail("\(assistant.phase)") }
        XCTAssertEqual(saved?.networkName, "Dashcast")
        XCTAssertFalse(assistant.hotspotLate(now: at.addingTimeInterval(5)))
        XCTAssertTrue(assistant.hotspotLate(now: at.addingTimeInterval(SharingAssistant.startGrace)))
    }

    // MARK: - Guide Me, the user following the highlight

    /// Presses whatever the guidance rings (typing where it says to type) until nothing's left.
    func testFollowingTheHighlightTurnsSharingOn() throws {
        let fake = FakeSystemSettings()
        fake.openInternetSharing()
        let plan = plan()
        var memory = SharingGuide.Memory()
        var steps: [SharingStep] = []
        for _ in 0..<60 {
            let app = try XCTUnwrap(fake.settingsApp() as? FakeNode)
            let screen = SharingScreen(app: app)
            SharingGuide.remember(screen, plan: plan, memory: &memory)
            guard let guidance = SharingGuide.next(screen, plan: plan, memory: memory) else { break }
            if steps.last != guidance.step { steps.append(guidance.step) }
            if guidance.step == .authorize { continue }   // the user touches Touch ID
            let target = try XCTUnwrap(guidance.target, "\(guidance.step)")
            let node = try XCTUnwrap(app.find { $0.frame == target && ($0.onPerform != nil || $0.onSetValue != nil) },
                                     "nothing pressable at \(target) for \(guidance.step)")
            switch guidance.step {
            case .networkName:
                _ = node.setFocused()
                _ = node.setValue(plan.networkName)
            case .password:
                _ = node.setFocused()
                _ = node.setValue(plan.password)
            default:
                XCTAssertTrue(node.press(), "\(guidance.step)")
            }
        }
        XCTAssertTrue(fake.sharingOn)
        XCTAssertFalse(fake.detailsOpen)
        XCTAssertEqual(fake.password, plan.password)
        XCTAssertTrue(memory.optionsSubmitted)
        XCTAssertEqual(steps, [.openDetails, .shareFrom, .authorize, .toWiFi, .wifiOptions, .networkName, .channel,
                               .password, .confirmOptions, .turnOn, .confirmTurnOn, .done])
    }

    // MARK: - Overlay geometry

    func testRingFollowsTheWindow() {
        // Read at the window's AX frame; the window then moved 100 right and 50 down.
        let guidance = SharingGuidance(step: .openDetails, instruction: "Click ⓘ",
                                       target: CGRect(x: 1071, y: 756, width: 17, height: 17),
                                       window: CGRect(x: 380, y: 276, width: 740, height: 625))
        // AppKit: primary screen 1200 high → the moved window's top is at 1200 - 326 = 874.
        let moved = CGRect(x: 480, y: 874 - 625, width: 740, height: 625)
        let target = SharingGuideOverlay.target(guidance, window: moved)
        XCTAssertEqual(target, CGRect(x: 1171, y: 874 - 480 - 17, width: 17, height: 17))
    }

    func testCalloutPlacement() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let size = CGSize(width: 220, height: 80)
        let left = CalloutPlacement.frame(size: size, target: CGRect(x: 900, y: 500, width: 40, height: 20), visible: screen)
        XCTAssertEqual(left.side, .left)
        XCTAssertEqual(left.frame.maxX, 900 - CalloutPlacement.gap)
        XCTAssertEqual(left.frame.midY, 510)
        XCTAssertEqual(left.arrow, 40, "points at the control's middle")

        let right = CalloutPlacement.frame(size: size, target: CGRect(x: 30, y: 500, width: 40, height: 20), visible: screen)
        XCTAssertEqual(right.side, .right)

        let below = CalloutPlacement.frame(size: CGSize(width: 1400, height: 80), target: CGRect(x: 60, y: 500, width: 40, height: 20), visible: screen)
        XCTAssertEqual(below.side, .below)

        let clamped = CalloutPlacement.frame(size: size, target: CGRect(x: 900, y: 930, width: 40, height: 10), visible: screen)
        XCTAssertLessThanOrEqual(clamped.frame.maxY, screen.maxY - CalloutPlacement.margin)
        XCTAssertGreaterThanOrEqual(clamped.arrow, 16)
        XCTAssertLessThanOrEqual(clamped.arrow, size.height - 16)
    }
}
