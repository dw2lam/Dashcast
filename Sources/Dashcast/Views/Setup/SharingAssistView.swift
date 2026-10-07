import AppKit
import DashcastContracts
import SwiftUI

/// Step 2 of Car Hotspot, "Turn on Internet Sharing": "Do It for Me" (Dashcast presses the controls)
/// or "Guide Me" (it points at each one), picked with a segmented control that's remembered.
struct SharingStepContent: View {
    let setup: HotspotSetup
    var now = Date()
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let assistant = model.sharingAssistant
        Picker("Mode", selection: modeBinding) {
            ForEach(SharingAssistant.Mode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()

        switch assistant.activeMode {
        case .automatic: automatic
        case .guided: guided
        }
        if setup.dropsWiFi, !assistant.isAutomating {
            SharingCaution("This Mac will leave its current Wi‑Fi when sharing starts.")
        }
    }

    private var bringBack: () -> Void {
        { [openWindow] in HotspotSetupView.open(openWindow) }
    }

    /// Picking the other mode mid-way switches over (System Settings stays as it is).
    private var modeBinding: Binding<SharingAssistant.Mode> {
        Binding {
            model.sharingAssistant.activeMode
        } set: { mode in
            let assistant = model.sharingAssistant
            assistant.preferredMode = mode
            switch (assistant.phase, mode) {
            case (.automating, .guided):
                model.guideInternetSharing(bringBack: bringBack)
            case (.guiding, .automatic), (.finished, .guided):
                assistant.stop()
            default:
                break
            }
        }
    }

    // MARK: Do It for Me

    @ViewBuilder
    private var automatic: some View {
        let assistant = model.sharingAssistant
        switch assistant.phase {
        case .automating:
            SharingProgressList(assistant: assistant)
            HStack(spacing: 10) {
                Button("Stop") { assistant.stop() }
                    .secondaryButtonStyle()
                if !assistant.waitingForYou {
                    Text("macOS will ask you to confirm.")
                        .foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
        case .finished:
            if assistant.hotspotLate(now: now) {
                SharingCaution(lateAdvice)
                Button("Try Again") { model.automateInternetSharing(bringBack: bringBack) }
                    .secondaryButtonStyle()
                    .controlSize(.small)
            } else {
                Waiting("Turned on. Waiting for macOS to start the hotspot…")
            }
        case .idle, .guiding:
            let plan = model.sharingPlan
            Paragraph("Dashcast sets up Internet Sharing in System Settings: sharing from \(plan.preferredShareFrom) to Wi‑Fi, named “\(plan.networkName)”, with a password that’s easy to type in your Tesla.")
            if plan.withoutCable {
                SharingCaution("No cable is plugged in, so this is experimental: macOS may only start the hotspot with a connection to share.")
            }
            HStack(spacing: 12) {
                Button {
                    model.automateInternetSharing(bringBack: bringBack)
                } label: {
                    Label("Do It for Me", systemImage: "wand.and.sparkles")
                }
                .prominentButtonStyle()
                .disabled(!model.canDriveSystemSettings)
                if model.canDriveSystemSettings {
                    Text("macOS will ask you to confirm.")
                        .foregroundStyle(.secondary)
                } else {
                    NeedsAccessibility()
                }
            }
        }
    }

    private var lateAdvice: String {
        let plan = model.sharingPlan
        return plan.withoutCable
            ? "Internet Sharing is on, but the hotspot hasn’t started. macOS only starts it when the “share from” connection is plugged in: plug your iPhone in with a cable."
            : "Internet Sharing is on, but the hotspot hasn’t started. macOS only starts it when \(plan.preferredShareFrom) is plugged in and connected."
    }

    // MARK: Guide Me

    @ViewBuilder
    private var guided: some View {
        let assistant = model.sharingAssistant
        let canDrive = model.canDriveSystemSettings
        if assistant.isGuiding {
            if let handoff = assistant.handoff {
                SharingHandoffNote(reason: handoff)
            }
            // The full checklist floats beside System Settings; here, just the step at hand.
            if let guidance = assistant.guidance {
                SharingInstruction(guidance: guidance)
            } else {
                Waiting("Looking at System Settings…")
            }
            HStack(spacing: 10) {
                Button("Show Me Again") { model.guideInternetSharing(bringBack: bringBack) }
                    .secondaryButtonStyle()
                Button("Stop") { assistant.stop() }
                    .secondaryButtonStyle()
            }
            .controlSize(.small)
        } else {
            Paragraph(canDrive
                      ? "Dashcast points at each control in System Settings and moves on as you click."
                      : "Set these in System Settings. This list floats beside it.")
            SharingChecklist(items: setup.checklist)
            HStack(spacing: 12) {
                Button {
                    if canDrive {
                        model.guideInternetSharing(bringBack: bringBack)
                    } else {
                        model.coachInternetSharing(bringBack: bringBack)
                    }
                } label: {
                    Label("Open Internet Sharing", systemImage: "arrow.up.forward.app")
                }
                .prominentButtonStyle()
                if !canDrive {
                    NeedsAccessibility(hint: "Highlights need Accessibility")
                }
            }
        }
    }
}

/// "Needs Accessibility" with the grant button (the same flow as everywhere else).
private struct NeedsAccessibility: View {
    var hint = "Needs Accessibility"
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Text(hint)
                .foregroundStyle(.secondary)
            Button(model.permissions[.accessibility].actionTitle.isEmpty ? "Grant…" : model.permissions[.accessibility].actionTitle) {
                model.fixPermission(.accessibility)
            }
            .controlSize(.small)
        }
        .lineLimit(1)
    }
}

// MARK: - Pieces (shared with the coach panel)

/// "Do It for Me", one line per stage, ticking as it goes.
struct SharingProgressList: View {
    let assistant: SharingAssistant

    var body: some View {
        let current = assistant.step?.stage ?? .open
        VStack(alignment: .leading, spacing: 7) {
            ForEach(SharingStage.allCases) { stage in
                let state: ChecklistItem.Status = stage < current ? .done : stage == current ? .working : .todo
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ProgressMark(status: state)
                    Text(title(stage, current: stage == current))
                        .foregroundStyle(state == .todo ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .fontWeight(state == .working ? .semibold : .regular)
                }
                if stage == current, assistant.waitingForYou {
                    Label("Confirm with Touch ID or your password", systemImage: "touchid")
                        .foregroundStyle(Color.dashAccent)
                        .fontWeight(.medium)
                        .padding(.leading, 24)
                }
            }
        }
        .font(.callout)
        .animation(.spring(duration: 0.35), value: current)
        .animation(.spring(duration: 0.35), value: assistant.waitingForYou)
    }

    private func title(_ stage: SharingStage, current: Bool) -> String {
        switch stage {
        case .open: current ? "Opening Internet Sharing…" : "Opened Internet Sharing"
        case .shareFrom: "Sharing from \(assistant.plan?.preferredShareFrom ?? "your cable")"
        case .wifi: "Wi‑Fi on"
        case .options: "Network name and password set"
        case .turnOn: "Turned on"
        }
    }
}

private struct ProgressMark: View {
    let status: ChecklistItem.Status

    var body: some View {
        Group {
            switch status {
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .working: ProgressView().controlSize(.mini)
            default: Image(systemName: "circle").foregroundStyle(.tertiary)
            }
        }
        .frame(width: 16)
    }
}

/// Why "Do It for Me" stopped, in one line, above the guidance that took over.
struct SharingHandoffNote: View {
    let reason: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(reason).fontWeight(.medium)
                Text("Finish by hand: follow the highlight.")
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        }
        .font(.callout)
    }
}

/// The step Guide Me is pointing at, with Copy for what to type.
struct SharingInstruction: View {
    let guidance: SharingGuidance

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "hand.point.up.left.fill")
                .foregroundStyle(Color.dashAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text(guidance.instruction)
                    .fontWeight(.semibold)
                if guidance.step == .password, let copy = guidance.copy {
                    Text(copy)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                }
            }
            Spacer(minLength: 4)
            if let copy = guidance.copy {
                CopyButton(text: copy, label: "Copy")
                    .secondaryButtonStyle()
                    .controlSize(.small)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.dashAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct SharingCaution: View {
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
