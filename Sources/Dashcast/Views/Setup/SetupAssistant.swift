import DashcastContracts
import SwiftUI

/// First-run setup: three short pages with live status, progress dots and Back/Continue.
struct SetupAssistant: View {
    @Environment(AppModel.self) private var model
    @Environment(AppController.self) private var controller
    @State private var step: Int
    @State private var forward = true

    static let pageCount = 3

    init(step: Int = 0) {
        _step = State(initialValue: step)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page
                    .id(step)
                    .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            HStack {
                if step == 0 {
                    Button("Not Now") { controller.finishOnboarding() }
                        .secondaryButtonStyle()
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Back") { go(-1) }
                        .secondaryButtonStyle()
                }
                Spacer()
                ProgressDots(count: Self.pageCount, current: step)
                Spacer()
                Button(step == Self.pageCount - 1 ? "Done" : "Continue") {
                    if step == Self.pageCount - 1 { controller.finishOnboarding() } else { go(1) }
                }
                .prominentButtonStyle()
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 22)
            .padding(.top, 8)
        }
        .frame(width: 440, height: 480)
        .tint(.dashAccent)
        .task { await PermissionPoller.poll(model) }
        .task {
            while !Task.isCancelled {
                await model.refreshNetwork()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder
    private var page: some View {
        switch step {
        case 0: PermissionsPage()
        case 1: ConnectPage()
        default: TeslaPage()
        }
    }

    private func go(_ delta: Int) {
        forward = delta > 0
        withAnimation(.spring(duration: 0.45, bounce: 0.12)) {
            step = min(max(step + delta, 0), Self.pageCount - 1)
        }
    }
}

struct ProgressDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? AnyShapeStyle(Color.dashAccent) : AnyShapeStyle(.quaternary))
                    .frame(width: index == current ? 18 : 7, height: 7)
            }
        }
        .animation(.spring(duration: 0.35), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

/// Shared page layout: symbol, title, one line, then content.
private struct SetupPage<Content: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Color.dashAccent)
                .symbolRenderingMode(.hierarchical)
                .frame(height: 52)
                .padding(.top, 30)
            Text(title)
                .font(.title.bold())
                .padding(.top, 14)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.horizontal, 36)
            content
                .padding(.top, 22)
                .padding(.horizontal, 28)
            Spacer(minLength: 0)
        }
    }
}

/// A row with a status on the right: a green check when done, otherwise one button.
private struct SetupRow: View {
    let symbol: String
    let title: String
    let detail: String
    let done: Bool
    let doneLabel: String
    let actionTitle: String
    var busy = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.dashAccent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if done {
                Label(doneLabel, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(.medium))
                    .transition(.scale.combined(with: .opacity))
            } else {
                ActionButton(actionTitle, busy: busy, action: action)
                    .secondaryButtonStyle()
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .animation(.spring(duration: 0.35), value: done)
    }
}

private struct RowGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Pages

private struct PermissionsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.state
        SetupPage(symbol: "hand.raised.fill", title: "Two Quick Permissions",
                  subtitle: "So Dashcast can show your Mac in the car, and the touchscreen can control it.") {
            RowGroup {
                SetupRow(symbol: "rectangle.dashed.badge.record", title: "Screen Recording",
                         detail: "Shows your Mac on the car screen.",
                         done: state.screenRecordingGranted, doneLabel: "Allowed",
                         actionTitle: "Grant…") { model.requestScreenRecording() }
                Divider().padding(.leading, 54)
                SetupRow(symbol: "hand.tap.fill", title: "Accessibility",
                         detail: "Lets the car’s touchscreen move the pointer.",
                         done: state.accessibilityGranted, doneLabel: "Allowed",
                         actionTitle: "Grant…") { model.requestAccessibility() }
            }
        }
    }
}

private struct ConnectPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let network = model.state.network
        let sharing = network.topology == .macHotspot
        SetupPage(symbol: "personalhotspot", title: "Connect Your Mac",
                  subtitle: "Your Tesla joins this Mac’s Wi‑Fi, like a hotspot.") {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    NumberedStep(number: 1, text: "Plug your iPhone into this Mac with a USB cable.")
                    NumberedStep(number: 2, text: "Turn on Internet Sharing from iPhone USB to Wi‑Fi.")
                    NumberedStep(number: 3, text: "On your Tesla, join this Mac’s Wi‑Fi network.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                RowGroup {
                    SetupRow(symbol: "personalhotspot", title: "Internet Sharing",
                             detail: sharing ? "On — \(network.interfaceName ?? "bridge100") is up." : "Waiting for it to turn on…",
                             done: sharing, doneLabel: "On",
                             actionTitle: "Open Settings…") { model.openInternetSharingSettings() }
                    Divider().padding(.leading, 54)
                    SetupRow(symbol: "wrench.and.screwdriver.fill", title: "Network helper",
                             detail: "One-time install. Asks for your password.",
                             done: network.helperInstalled, doneLabel: "Installed",
                             actionTitle: "Install", busy: model.networkActivity == .installingHelper) { model.installHelper() }
                }

                GuideLink(title: "See other ways to connect")
            }
        }
    }
}

private struct NumberedStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.dashAccent))
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct TeslaPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let mode = model.connectionMode
        SetupPage(symbol: "car.fill", title: "On Your Tesla",
                  subtitle: "Open the browser and go to this address. Bookmark it for next time.") {
            VStack(spacing: 14) {
                QRCodeView(string: mode.url, size: 96)
                Text(mode.addressToType)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Label(mode.caption, systemImage: mode.symbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
