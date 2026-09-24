import AppKit
import DashcastContracts
import SwiftUI

/// The whole app in one compact window: an illustration of the link, one sentence of status,
/// one button, and only the details the current moment needs.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppController.self) private var controller
    @Environment(\.openWindow) private var openWindow

    /// Content size; with the ~52 pt toolbar the window is about 460 × 580.
    static let size = CGSize(width: 460, height: 528)

    var body: some View {
        @Bindable var controller = controller
        let readiness = model.readiness
        let headline = Headline(model: model, readiness: readiness)

        VStack(spacing: 0) {
            Spacer(minLength: 4)

            CastIllustration(stage: headline.stage)

            VStack(spacing: 6) {
                Text(headline.title)
                    .font(.largeTitle.bold())
                    .contentTransition(.opacity)
                Text(headline.detail)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 22)

            CastButton()
                .padding(.top, 20)

            VStack(spacing: 14) {
                switch headline.stage {
                case .waiting:
                    AddressCard(mode: model.connectionMode)
                        .transition(.blurReplace)
                case .casting:
                    CastingDetails()
                        .transition(.blurReplace)
                case .idle, .problem:
                    EmptyView()
                }
                if !readiness.isEmpty {
                    ReadinessList(items: readiness)
                        .transition(.blurReplace)
                }
                if headline.stage == .idle || headline.stage == .waiting {
                    GuideLink()
                }
            }
            .padding(.top, 22)

            Spacer(minLength: 16)
        }
        .padding(.horizontal, 32)
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(.spring(duration: 0.5, bounce: 0.2), value: headline.stage)
        .animation(.spring(duration: 0.4), value: readiness.map(\.id))
        .tint(.dashAccent)
        .toolbar {
            // With the title removed nothing pushes items right; a flexible spacer puts Settings
            // top-right (macOS 26+; earlier systems keep it beside the window controls).
            if #available(macOS 26, *) {
                ToolbarSpacer(.flexible)
            }
            ToolbarItemGroup(placement: .automatic) {
                GuideToolbarButton()
                SettingsButton()
            }
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .containerBackground(.thickMaterial, for: .window)
        .background(WindowAccessor { window in
            controller.mainWindow = window
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { DebugOverrides.logWindowLayout(window) }
        })
        .onAppear { controller.openWindowAction = openWindow }
        .task { await PermissionPoller.poll(model, interval: .seconds(2)) }
        .sheet(isPresented: $controller.isOnboardingPresented) {
            SetupAssistant(step: ShotMode.setupStep)
        }
    }
}

/// Opens the Connection Guide window.
struct GuideToolbarButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: SceneID.guide)
            NSApp.activate()
        } label: {
            Label("How to Connect", systemImage: "questionmark.circle")
        }
        .help("How to connect your Tesla")
    }
}

/// Opens Settings and brings it forward (also from menu-bar-only mode).
struct SettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            openSettings()
            NSApp.activate()
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
        .help("Settings (⌘,)")
    }
}

// MARK: - Primary action

struct CastButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let running = model.isRunning
        Button {
            model.toggleStreaming()
        } label: {
            Label(running ? "Stop" : "Start Casting", systemImage: running ? "stop.fill" : "play.fill")
                .font(.title3.weight(.semibold))
                .frame(minWidth: 190)
                .contentTransition(.symbolEffect(.replace))
        }
        .prominentButtonStyle()
        .heroControlSize()
        .tint(.dashAccent)
        .disabled(model.isTransitioning)
        .keyboardShortcut(.defaultAction)
    }
}

// MARK: - Waiting

/// "On your Tesla's browser, go to …" with the address (click to copy) and a QR code.
struct AddressCard: View {
    let mode: ConnectionMode
    @State private var copied = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("On your Tesla’s browser, go to")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    Pasteboard.copy(mode.url)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Text(mode.addressToType)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .buttonStyle(.plain)
                .help("Click to copy")
                Label(copied ? "Copied" : mode.caption, systemImage: copied ? "checkmark" : mode.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            Spacer(minLength: 0)
            QRCodeView(string: mode.url, size: 64)
        }
        .padding(16)
        .dashGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

// MARK: - Casting

struct CastingDetails: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let state = model.state
        VStack(spacing: 16) {
            GlassGroup(spacing: 6) {
                HStack(spacing: 8) {
                    if let car = state.car {
                        StatCapsule(text: "\(Format.computer(car.computer)) · \(Format.resolution(car.tier.width, car.tier.height))")
                    }
                    StatCapsule(text: "\(Format.fps(state.stats.fps)) fps")
                    StatCapsule(text: "\(Format.ms(state.stats.latencyMs)) ms")
                    if let car = state.car {
                        StatCapsule(text: Format.transport(car.transport))
                            .help(car.transport == .webrtc ? "Video over WebRTC (compatibility mode)" : "Video over WebCodecs (secure mode)")
                    }
                }
            }
            Picker("Display", selection: $model.settings.displayMode) {
                ForEach(DisplayMode.allCases, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .frame(width: 240)
        }
    }
}

struct StatCapsule: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(.default, value: text)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .dashGlass(in: Capsule())
    }
}

// MARK: - Readiness

/// Only shown while something is missing; each row has exactly one fix.
struct ReadinessList: View {
    let items: [ReadinessItem]
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                HStack(spacing: 12) {
                    Image(systemName: item.symbol)
                        .font(.title3)
                        .foregroundStyle(item.tint)
                        .frame(width: 26)
                    Text(item.title)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    ActionButton(item.actionTitle, busy: item.action == .installHelper && model.networkActivity == .installingHelper) {
                        model.perform(item.action)
                    }
                    .secondaryButtonStyle()
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                if item.id != items.last?.id {
                    Divider().padding(.leading, 52)
                }
            }
        }
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
