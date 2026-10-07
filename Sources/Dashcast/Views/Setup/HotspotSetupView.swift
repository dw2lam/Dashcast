import AppKit
import DashcastContracts
import SwiftUI

/// "Car Hotspot": the Mac-as-hotspot setup as one live checklist. The step to do now is open, the
/// rest are one line each, and every step ticks itself from what the Mac sees.
struct HotspotSetupView: View {
    static let size = CGSize(width: 460, height: 620)

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    /// A step the user opened by hand (nil = the current one).
    @State private var opened: HotspotSetup.Step?
    @State private var now = Date()
    private let polls: Bool

    /// `polls` = refresh the network every 2 s (off for snapshots, which show a fixed state).
    init(polls: Bool = true) {
        self.polls = polls
    }

    /// Opens (or brings forward) the Car Hotspot window.
    static func open(_ openWindow: OpenWindowAction) {
        openWindow(id: SceneID.hotspot)
        NSApp.activate()
    }

    var body: some View {
        let setup = model.hotspotSetup(now: now)
        let expanded = opened ?? setup.current

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "personalhotspot")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.dashAccent.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Car Hotspot")
                        .font(.title2.bold())
                    Text("Your Tesla joins this Mac’s Wi‑Fi. Each step ticks itself.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 16)

            VStack(spacing: 0) {
                ForEach(HotspotSetup.Step.allCases) { step in
                    HotspotStepSection(step: step, setup: setup, now: now, expanded: expanded == step) {
                        withAnimation(.spring(duration: 0.4, bounce: 0.12)) {
                            opened = expanded == step ? (step == setup.current ? HotspotSetup.Step?.none : setup.current) : step
                        }
                    }
                    if step != HotspotSetup.Step.allCases.last {
                        Divider().padding(.leading, 50)
                    }
                }
            }
            .background(.fill.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            Spacer(minLength: 12)

            HStack {
                ReadyStatus(sharing: setup.sharing)
                Spacer()
                Button(setup.isComplete ? "Done" : "Close") { dismissWindow(id: SceneID.hotspot) }
                    .modifier(DoneButtonStyle(prominent: setup.isComplete))
                    .keyboardShortcut(setup.isComplete ? .defaultAction : .cancelAction)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 20)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .animation(.spring(duration: 0.45, bounce: 0.12), value: setup.current)
        .animation(.spring(duration: 0.35), value: setup.done)
        .onChange(of: setup.current) { opened = nil }
        .tint(.dashAccent)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .containerBackground(.thickMaterial, for: .window)
        .task {
            guard polls else { return }
            while !Task.isCancelled {
                await model.service.refreshNetwork()
                model.trackHotspotCar()
                now = Date()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onDisappear { model.dismissHotspotCoach() }
    }
}

private struct DoneButtonStyle: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if prominent {
            content.prominentButtonStyle()
        } else {
            content.secondaryButtonStyle()
        }
    }
}

/// Whether Dashcast is listening (so it answers the car), in one quiet line.
private struct ReadyStatus: View {
    let sharing: HotspotSetup.Sharing
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.isRunning {
                Label("Dashcast is ready", systemImage: "dot.radiowaves.left.and.right")
            } else if AppModel.autoReadyEnabled, sharing != .on {
                Label("Dashcast gets ready when the hotspot turns on", systemImage: "bolt.fill")
            } else {
                Label("Dashcast isn’t started", systemImage: "pause.circle")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

// MARK: - Steps

private struct HotspotStepSection: View {
    let step: HotspotSetup.Step
    let setup: HotspotSetup
    let now: Date
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        let done = setup.isDone(step)
        let isCurrent = setup.current == step
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 12) {
                    StepMarker(number: step.number, done: done, active: isCurrent, size: 24)
                    HStack(spacing: 8) {
                        Text(step.title)
                            .font(.headline)
                            .foregroundStyle(done || isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        if step == .internet, !done {
                            Text("Optional")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if !expanded, done, let summary = setup.summary(step) {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Hide details" : "Show details")

            if expanded {
                HotspotStepDetail(step: step, setup: setup, now: now)
                    .padding(.leading, 50)
                    .padding(.trailing, 16)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background {
            if isCurrent {
                Color.dashAccent.opacity(0.06)
            }
        }
    }
}

private struct HotspotStepDetail: View {
    let step: HotspotSetup.Step
    let setup: HotspotSetup
    let now: Date
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch step {
            case .internet: internet
            case .sharing: sharing
            case .join: join
            case .check: check
            case .browser: browser
            }
        }
        .font(.callout)
    }

    // 1. Internet for this Mac

    @ViewBuilder
    private var internet: some View {
        switch setup.internet {
        case .cable(let name):
            Paragraph("Connected over \(name). Your Tesla gets internet too.")
        case .without:
            Paragraph("Dashcast works offline. Your Tesla just won’t have internet.")
            Button("Use a Cable Instead") { model.hotspotWithoutInternet = false }
                .secondaryButtonStyle()
                .controlSize(.small)
        case .onWiFi, .none:
            if setup.isDone(.internet) {
                Paragraph("Internet Sharing is on with no cable plugged in, so your Tesla won’t have internet. Dashcast works without it.")
            } else {
                Paragraph(internetAdvice)
                Waiting("Waiting for a cable…")
                HStack(spacing: 10) {
                    Button("Continue Without Internet") { model.hotspotWithoutInternet = true }
                        .secondaryButtonStyle()
                    Text("Dashcast works offline.")
                        .foregroundStyle(.secondary)
                }
                .controlSize(.small)
            }
        }
    }

    private var internetAdvice: String {
        switch setup.internet {
        case .onWiFi(phone: true):
            "Your Mac gets its internet over Wi‑Fi from your iPhone’s hotspot. The hotspot needs the Wi‑Fi, so plug your iPhone in with a cable and keep Personal Hotspot on."
        case .onWiFi(phone: false):
            "Your Mac gets its internet over Wi‑Fi. The hotspot needs the Wi‑Fi, so plug in Ethernet, or your iPhone with a cable."
        default:
            "For internet in the car too, plug your iPhone in with a cable and turn on Personal Hotspot."
        }
    }

    // 2. Internet Sharing

    @ViewBuilder
    private var sharing: some View {
        if setup.sharing == .on {
            Paragraph("Internet Sharing is on. Your Mac’s Wi‑Fi is now “\(setup.displayName)”.")
        } else {
            SharingStepContent(setup: setup, now: now)
        }
    }

    // 3. Join from your Tesla

    @ViewBuilder
    private var join: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("In your Tesla")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let password = model.knownHotspotPassword {
                Text("Controls → Wi‑Fi")
                    .foregroundStyle(.secondary)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Network").foregroundStyle(.secondary)
                        Text(setup.displayName).fontWeight(.semibold)
                    }
                    GridRow {
                        Text("Password").foregroundStyle(.secondary)
                        Text(password)
                            .font(.system(.title2, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                    }
                }
                .font(.title2)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            } else {
                (Text("Controls → Wi‑Fi → ").foregroundStyle(.secondary) + Text(setup.displayName).fontWeight(.semibold))
                    .font(.title2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("Password: the one you set")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        switch setup.join {
        case .waiting:
            Waiting("Waiting for your Tesla to join…")
        case .otherDevice(let device):
            Label("Another device joined: \(device.label)", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        case .joined(let device):
            Done(device.map { "Your Tesla joined · \($0.address)" } ?? "Your Tesla joined")
        }
    }

    // 4. Tesla's internet check

    @ViewBuilder
    private var check: some View {
        switch setup.check {
        case .answered:
            Done("Your Tesla checked for internet and Dashcast answered. It’ll stay connected without internet.")
        case .waiting(let ready):
            Paragraph("When your Tesla joins, it checks for internet. Dashcast answers, so it stays connected even with no internet.")
            if ready {
                Waiting("Dashcast is ready to answer.")
            } else if AppModel.autoReadyEnabled && setup.sharing != .on {
                Label("Dashcast gets ready on its own when the hotspot turns on.", systemImage: "bolt.fill")
                    .foregroundStyle(.secondary)
            } else {
                GetReadyButton()
            }
        case .noAnswer(ready: false):
            Caution("Your Tesla joined, but Dashcast isn’t answering yet, so the car says the internet is unreachable.")
            GetReadyButton()
        case .noAnswer(ready: true):
            Caution("No check from your Tesla yet. Turn the car’s Wi‑Fi off and on so it checks again.")
        }
    }

    // 5. Open the browser

    @ViewBuilder
    private var browser: some View {
        if setup.casting {
            Done("Connected. You’re casting.")
        } else {
            let mode = model.connectionMode
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Open the Browser and go to")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    CopyButton(text: mode.url, label: "Copy")
                        .secondaryButtonStyle()
                        .controlSize(.small)
                }
                CarAddress(mode: mode, size: 28)
                Text("Then press Tap to Start.")
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dashGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct GetReadyButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Get Ready") { model.start() }
            .prominentButtonStyle()
            .disabled(model.isTransitioning)
    }
}

struct Paragraph: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).fixedSize(horizontal: false, vertical: true)
    }
}

struct Waiting: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

private struct Done: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
        .fontWeight(.medium)
    }
}

private struct Caution: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

// MARK: - Copy

extension HotspotSetup.Step {
    var title: String {
        switch self {
        case .internet: "Internet for this Mac"
        case .sharing: "Turn on Internet Sharing"
        case .join: "Join from your Tesla"
        case .check: "Tesla’s internet check"
        case .browser: "Open the browser"
        }
    }
}

extension HotspotSetup {
    /// One line beside a finished step.
    func summary(_ step: Step) -> String? {
        guard isDone(step) else { return nil }
        switch step {
        case .internet:
            if case .cable(let name) = internet { return name }
            return "No internet for the car"
        case .sharing:
            return networkName.map { "On · \($0)" } ?? "On"
        case .join:
            if case .joined(let device?) = join { return "Joined · \(device.address)" }
            return "Joined"
        case .check:
            return "Answered"
        case .browser:
            return "Casting"
        }
    }
}

extension HotspotStatus.Device {
    /// "“iPad” · 192.168.2.4", or just the address.
    var label: String {
        name.map { "“\($0)” · \(address)" } ?? address
    }
}

// MARK: - Checklist

/// What to set in System Settings ▸ Internet Sharing, each with a live tick. `current` is the row
/// Guide Me is pointing at.
struct SharingChecklist: View {
    let items: [ChecklistItem]
    var current: ChecklistItem.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                ChecklistRow(item: item, current: item.id == current)
            }
        }
    }
}

private struct ChecklistRow: View {
    let item: ChecklistItem
    var current = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let heading = item.heading {
                Text(heading)
                    .font(.callout.weight(.semibold))
                    .padding(.top, 2)
            }
            row
                .padding(.vertical, current ? 5 : 0)
                .padding(.horizontal, current ? 7 : 0)
                .background {
                    if current {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.dashAccent.opacity(0.14))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.dashAccent.opacity(0.5), lineWidth: 1)
                            }
                    }
                }
                .padding(.horizontal, current ? -7 : 0)
        }
        .font(.callout)
        .animation(.spring(duration: 0.35), value: item.status)
        .animation(.spring(duration: 0.35), value: current)
    }

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ChecklistMark(status: item.status)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Group {
                        if item.value.isEmpty {
                            Text(item.label).fontWeight(.semibold)
                        } else {
                            Text(item.label + ": ").foregroundStyle(.secondary) + valueText
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if let copy = item.copy {
                        CopyButton(text: copy, label: "Copy")
                            .buttonStyle(.borderless)
                            .labelStyle(.iconOnly)
                            .foregroundStyle(Color.dashAccent)
                    }
                }
                if let note = item.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// A password Dashcast made is spelled out in monospace (no l/1 confusion).
    private var valueText: Text {
        if item.id == .password, item.status != .unknown {
            return Text(item.value).font(.system(.callout, design: .monospaced).weight(.semibold))
        }
        return Text(item.value).fontWeight(.semibold)
    }
}

private struct ChecklistMark: View {
    let status: ChecklistItem.Status

    var body: some View {
        Group {
            switch status {
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .todo:
                Image(systemName: "circle").foregroundStyle(.tertiary)
            case .suggestion:
                Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
            case .unknown:
                Image(systemName: "key.fill").foregroundStyle(.secondary).imageScale(.small)
            case .working:
                ProgressView().controlSize(.mini)
            }
        }
        .frame(width: 16)
        .accessibilityLabel(status == .done ? "Done" : status == .todo ? "To do" : "")
    }
}

// MARK: - Coach panel

/// Floats beside System Settings ▸ Internet Sharing: exactly what to set, ticking live. While
/// "Do It for Me" runs it shows the progress; while Guide Me runs, the step being pointed at.
struct HotspotCoachView: View {
    @Environment(AppModel.self) private var model
    var close: () -> Void = {}

    var body: some View {
        let setup = model.hotspotSetup()
        let assistant = model.sharingAssistant
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Internet Sharing")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            if assistant.isAutomating {
                Text("Dashcast is setting it up")
                    .font(.title3.weight(.semibold))
                SharingProgressList(assistant: assistant)
                Button("Stop") { assistant.stop() }
                    .secondaryButtonStyle()
            } else {
                if let handoff = assistant.handoff, assistant.isGuiding {
                    SharingHandoffNote(reason: handoff)
                }
                Text(assistant.isGuiding ? "Follow the highlight. Dashcast moves on as you click." : "Click ⓘ next to Internet Sharing, then set:")
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if assistant.isGuiding, let guidance = assistant.guidance {
                    SharingInstruction(guidance: guidance)
                }
                SharingChecklist(items: setup.checklist, current: assistant.isGuiding ? assistant.step?.checklistItem : nil)
            }
            if setup.dropsWiFi {
                Label {
                    Text(setup.internet == .onWiFi(phone: true)
                         ? "This Mac will leave your iPhone’s hotspot when sharing starts."
                         : "This Mac will leave its current Wi‑Fi when sharing starts.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
            }
        }
        .padding(18)
        .frame(width: 310)
        .dashGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .tint(.dashAccent)
        .animation(.spring(duration: 0.35), value: assistant.step)
    }
}

/// Open Internet Sharing: System Settings plus the coach panel beside it, and Guide Me's highlight.
/// It refreshes the network while it's up, closes itself the moment sharing comes on, and brings
/// Dashcast back.
@MainActor
final class HotspotCoach: SharingPresenting {
    private weak var model: AppModel?
    private let companion = SettingsCompanion()
    private let overlay = SharingGuideOverlay()
    /// Brings the Car Hotspot window back.
    var returnToWizard: (() -> Void)?
    private var sharingWasOn = false
    private var ticks = 0
    private var refreshing = false

    /// Re-reads Internet Sharing every this many ticks (1 s).
    static let refreshTicks = 20

    init(model: AppModel) {
        self.model = model
    }

    /// Shows the panel (kept as is if it's already up, so a hand-over doesn't flicker).
    func present() {
        guard let model, !companion.isShowing else { return }
        sharingWasOn = model.state.network.hotspot.sharingOn
        ticks = 0
        let view = HotspotCoachView(close: { [weak self] in self?.dismiss() })
            .environment(model)
        companion.show(view, onTick: { [weak self] in self?.tick() }, onGiveUp: { [weak self] in self?.dismiss() })
    }

    /// Closed by the user, or System Settings went away: ends whatever the assistant was doing.
    func dismiss() {
        close()
        model?.sharingAssistant.coachClosed()
    }

    private func close() {
        companion.dismiss()
        overlay.dismiss()
        ticks = 0
    }

    // MARK: SharingPresenting

    func showCoach() { present() }
    func dismissCoach() { close() }

    func point(at guidance: SharingGuidance?) {
        overlay.show(guidance)
        overlay.follow(window: companion.settingsFrame ?? SettingsWindow.frame(), visible: SettingsWindow.isFrontmost)
    }

    func bringBack() {
        NSApp.activate()
        returnToWizard?()
    }

    private func tick() {
        guard let model else { return dismiss() }
        ticks += 1
        overlay.follow(window: companion.settingsFrame, visible: companion.settingsInFront)
        // "Do It for Me" finishes (and presses Done) itself.
        if model.state.network.hotspot.sharingOn, !sharingWasOn, !model.sharingAssistant.isAutomating {
            close()
            model.sharingAssistant.stop()
            bringBack()
            return
        }
        guard ticks % Self.refreshTicks == 0, !refreshing else { return }
        refreshing = true
        Task { [weak self] in
            await model.service.refreshNetwork()
            self?.refreshing = false
        }
    }
}
