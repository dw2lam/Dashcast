import AppKit
import Foundation
import Observation
import OSLog

/// What shows beside System Settings while turning on Internet Sharing: the coach panel, and the
/// highlight ring + callout pointing at a control. nil in tests (nothing is shown).
@MainActor
protocol SharingPresenting: AnyObject {
    func showCoach()
    func dismissCoach()
    /// Rings the guidance's target with its instruction; nil hides the highlight.
    func point(at guidance: SharingGuidance?)
    /// Brings Dashcast (the Car Hotspot window) back to the front.
    func bringBack()
}

/// Step 2 of the Car Hotspot setup, both ways: "Do It for Me" runs `SharingAutomation`; "Guide Me"
/// reads System Settings just after each click or keystroke (and every 1.5 s otherwise) and points
/// at the next control. A failed automation hands over to Guide Me at the step it stopped on, with
/// one line saying why, and brings System Settings to the front so the user's first click counts.
@MainActor
@Observable
final class SharingAssistant {
    enum Mode: String, CaseIterable, Identifiable {
        case automatic, guided
        var id: Self { self }

        var title: String {
            switch self {
            case .automatic: "Do It for Me"
            case .guided: "Guide Me"
            }
        }
    }

    enum Phase: Equatable {
        case idle
        /// "Do It for Me" is pressing System Settings' controls.
        case automating
        /// "Guide Me": the highlight follows the user's clicks.
        case guiding
        /// "Do It for Me" finished in System Settings; macOS is starting the hotspot.
        case finished(Date)
    }

    /// The mode the wizard opens in (Settings ▸ Network ▸ Guidance mode; default "Do It for Me").
    var preferredMode: Mode {
        didSet {
            guard preferredMode != oldValue, !RenderMode.offscreen else { return }
            UserDefaults.standard.set(preferredMode == .guided, forKey: DefaultsKey.hotspotGuidanceMode)
        }
    }
    private(set) var phase: Phase = .idle
    /// The step being done (automating) or pointed at (guiding).
    private(set) var step: SharingStep?
    /// macOS is asking for Touch ID or the password.
    private(set) var waitingForYou = false
    /// Why "Do It for Me" stopped (shown above the guidance that took over).
    private(set) var handoff: String?
    private(set) var guidance: SharingGuidance?
    private(set) var plan: SharingPlan?

    /// What the segmented control shows: the running mode, else the preference.
    var activeMode: Mode {
        switch phase {
        case .automating, .finished: .automatic
        case .guiding: .guided
        case .idle: preferredMode
        }
    }

    /// How long after "Do It for Me" finishes before saying the hotspot hasn't started.
    static let startGrace: TimeInterval = 15
    /// How often the guidance loop wakes to decide whether to look. Deciding is free; a look walks
    /// System Settings' Accessibility tree, which System Settings answers on its main thread, the
    /// one handling the user's clicks. So looks wait for a pause in the user's input.
    static let guideTick: TimeInterval = 0.15
    /// A click or keystroke is looked at once the user has paused this long (and the screen has
    /// settled), not while they're still clicking.
    static let inputSettle: TimeInterval = 0.3
    /// One more look this soon after a look that changed the guidance (a sheet still sliding in).
    static let followUp: TimeInterval = 0.5
    /// Between looks while Touch ID is up (it goes away without a click).
    static let touchIDInterval: TimeInterval = 0.75
    /// Between looks when input can't be seen.
    static let blindInterval: TimeInterval = 0.6
    /// Between looks while nothing's happening (the user is reading the callout).
    static let guideIdleInterval: TimeInterval = 1.5

    private static let log = Logger(subsystem: "online.davidlam.dashcast", category: "hotspot-setup")

    @ObservationIgnored let environment: SharingEnvironment
    @ObservationIgnored weak var presenter: SharingPresenting?
    @ObservationIgnored var timing = SharingAutomation.Timing()
    /// Wi‑Fi Options… was saved with the plan's name and password (by Dashcast, or by the user's OK).
    @ObservationIgnored var onOptionsSaved: ((SharingPlan) -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var memory = SharingGuide.Memory()

    init(environment: SharingEnvironment, defaults: UserDefaults = .standard) {
        self.environment = environment
        preferredMode = !RenderMode.offscreen && defaults.bool(forKey: DefaultsKey.hotspotGuidanceMode) ? .guided : .automatic
    }

    var isAutomating: Bool { phase == .automating }
    var isGuiding: Bool { phase == .guiding }

    /// "Do It for Me".
    func automate(_ plan: SharingPlan) {
        cancelTask()
        self.plan = plan
        handoff = nil
        guidance = nil
        step = .openPane
        waitingForYou = false
        memory = SharingGuide.Memory()
        presenter?.point(at: nil)
        presenter?.showCoach()
        phase = .automating
        // A stopped (or replaced) run is cancelled: from then on nothing it reports or ends with
        // touches the assistant, which may already be running the next one.
        let automation = SharingAutomation(environment: environment, plan: plan, timing: timing) { [weak self] event in
            guard !Task.isCancelled else { return }
            self?.handle(event)
        }
        task = Task { [weak self] in
            do {
                try await automation.run()
                guard !Task.isCancelled else { return }
                self?.finished()
            } catch let error as SharingAutomationError {
                guard !Task.isCancelled else { return }
                self?.handOff(error)
            } catch {
                // Cancelled (Stop): System Settings stays as it is.
            }
        }
    }

    /// "Guide Me". `optionsKnownSet`: the name and password are already Dashcast's.
    func guide(_ plan: SharingPlan, optionsKnownSet: Bool = false) {
        cancelTask()
        self.plan = plan
        handoff = nil
        waitingForYou = false
        memory = SharingGuide.Memory(optionsKnownSet: optionsKnownSet)
        presenter?.showCoach()
        startGuiding()
    }

    /// Stop: cancels "Do It for Me" (leaving System Settings as it is) or ends the guidance.
    func stop() {
        cancelTask()
        guard phase != .idle else { return }
        phase = .idle
        step = nil
        waitingForYou = false
        guidance = nil
        presenter?.point(at: nil)
        presenter?.dismissCoach()
    }

    /// The coach panel went away (closed, or System Settings quit).
    func coachClosed() {
        guard phase == .automating || phase == .guiding else { return }
        stop()
    }

    /// The live plan changed (a cable went in): guidance follows it.
    func update(_ plan: SharingPlan) {
        guard phase == .guiding, plan != self.plan else { return }
        self.plan = plan
    }

    /// After "Do It for Me": it's been long enough that a hotspot that isn't up won't come up.
    func hotspotLate(now: Date = Date()) -> Bool {
        guard case .finished(let at) = phase else { return false }
        return now.timeIntervalSince(at) >= Self.startGrace
    }

    // MARK: - Automation

    private func handle(_ event: SharingAutomation.Event) {
        switch event {
        case .step(let step):
            self.step = step
        case .waitingForYou(let waiting):
            waitingForYou = waiting
            // Touch ID or the password: their prompt needs System Settings in front to be clicked or typed in.
            if waiting { environment.activateSettings() }
            presenter?.point(at: waiting ? plan.flatMap { SharingGuide.next(SharingScreen(app: environment.settingsApp()), plan: $0, memory: memory) } : nil)
        case .optionsSaved:
            memory.optionsSubmitted = true
            if let plan { onOptionsSaved?(plan) }
        }
    }

    private func finished() {
        task = nil
        phase = .finished(Date())
        step = nil
        waitingForYou = false
        presenter?.point(at: nil)
        presenter?.dismissCoach()
        presenter?.bringBack()
    }

    private func handOff(_ error: SharingAutomationError) {
        Self.log.notice("Do It for Me stopped at \(String(describing: error.step), privacy: .public): \(error.reason, privacy: .public)")
        task = nil
        handoff = error.reason
        waitingForYou = false
        step = error.step
        giveSettingsTheFloor()
        startGuiding()
    }

    /// It's the user's turn: System Settings to the front (presses through Accessibility never
    /// bring it there, so their first click would only activate it and the highlight stays hidden
    /// while it's behind), and any menu "Do It for Me" left open closed, or it eats that click.
    private func giveSettingsTheFloor() {
        environment.activateSettings()
        Task { [weak self] in
            try? await self?.environment.sleep(0.3)
            // Only with a menu really open: Escape on the sheet itself would cancel it.
            guard let self, self.environment.isSettingsMenuOpen || SharingScreen(app: self.environment.settingsApp()).menu != nil
            else { return }
            self.environment.pressEscape()
        }
    }

    // MARK: - Guidance

    private func startGuiding() {
        phase = .guiding
        lookAgain()
        task = Task { [weak self] in
            var sinceLook: TimeInterval = 0
            var sinceChange: TimeInterval = .infinity
            while !Task.isCancelled {
                try? await self?.environment.sleep(Self.guideTick)
                guard let self, !Task.isCancelled, self.phase == .guiding else { return }
                sinceLook += Self.guideTick
                sinceChange += Self.guideTick
                guard Self.looksNow(sinceLook: sinceLook, sinceChange: sinceChange,
                                    sinceInput: self.environment.secondsSinceInput,
                                    waitingForTouchID: self.guidance?.step == .authorize) else { continue }
                sinceLook = 0
                if self.lookAgain() { sinceChange = 0 }
            }
        }
    }

    /// Whether the guidance loop walks System Settings this time round: once the user pauses after
    /// a click or keystroke it hasn't seen yet, once more just after a look changed the guidance,
    /// every `touchIDInterval` while Touch ID is up, and otherwise every `guideIdleInterval`.
    /// Never while the user is mid-click: that's when System Settings needs its main thread.
    static func looksNow(sinceLook: TimeInterval, sinceChange: TimeInterval, sinceInput: TimeInterval?,
                         waitingForTouchID: Bool) -> Bool {
        let slack = 0.001
        if sinceLook >= guideIdleInterval - slack { return true }
        guard let sinceInput else { return sinceLook >= blindInterval - slack }
        if sinceInput < sinceLook, sinceInput >= inputSettle - slack { return true }
        if sinceChange < 1, sinceLook >= followUp - slack, sinceInput >= inputSettle - slack { return true }
        return waitingForTouchID && sinceLook >= touchIDInterval - slack
    }

    /// Reads System Settings and points at what's next. Returns whether the guidance changed.
    @discardableResult
    func lookAgain() -> Bool {
        guard phase == .guiding, let plan else { return false }
        let screen = SharingScreen(app: environment.settingsApp())
        let submitted = memory.optionsSubmitted
        SharingGuide.remember(screen, plan: plan, memory: &memory)
        if memory.optionsSubmitted, !submitted { onOptionsSaved?(plan) }
        let next = environment.isTrusted ? SharingGuide.next(screen, plan: plan, memory: memory) : nil
        let changed = next != guidance
        if changed { guidance = next }
        if let next, next.step != step { step = next.step }
        presenter?.point(at: next)
        return changed
    }

    /// Snapshots: a fixed moment, with nothing running.
    func pin(_ phase: Phase, plan: SharingPlan, step: SharingStep? = nil, waitingForYou: Bool = false,
             handoff: String? = nil, guidance: SharingGuidance? = nil) {
        cancelTask()
        self.phase = phase
        self.plan = plan
        self.step = step
        self.waitingForYou = waitingForYou
        self.handoff = handoff
        self.guidance = guidance
    }

    private func cancelTask() {
        task?.cancel()
        task = nil
    }
}
