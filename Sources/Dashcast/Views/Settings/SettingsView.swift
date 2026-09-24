import CoreGraphics
import DashcastContracts
import ServiceManagement
import SwiftUI

/// The standard Settings window (⌘,), toolbar-style tabs like Apple's own apps.
struct SettingsView: View {
    enum Tab: String { case general, display, network, advanced }

    @State private var tab: Tab

    init(initialTab: Tab = .general) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            DisplaySettings()
                .tabItem { Label("Display", systemImage: "display") }
                .tag(Tab.display)
            NetworkSettings()
                .tabItem { Label("Network", systemImage: "network") }
                .tag(Tab.network)
            AdvancedSettings()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
                .tag(Tab.advanced)
        }
        .frame(width: 520)
        .tint(.dashAccent)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(DefaultsKey.menuBarOnly) private var menuBarOnly = false
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle(isOn: $menuBarOnly) {
                    Text("Show only in menu bar")
                    Text("Hide the Dock icon. Dashcast stays one click away in the menu bar.")
                }
                Toggle(isOn: Binding(get: { openAtLogin }, set: setOpenAtLogin)) {
                    Text("Open at login")
                    if let loginError { Text(loginError).foregroundStyle(.red) }
                }
            }

            Section("Latency") {
                Picker("Latency", selection: $model.settings.latencyMode) {
                    ForEach(LatencyMode.allCases, id: \.self) { mode in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title)
                            Text(mode.explanation)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                        .tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            Section("In the Car") {
                Toggle(isOn: $model.settings.audioEnabled) {
                    Text("Play sound in the car")
                    Text("Your Mac’s audio comes out of the car speakers.")
                }
                Toggle(isOn: $model.settings.inputEnabled) {
                    Text("Touch control")
                    Text(model.state.accessibilityGranted
                         ? "Tap, drag and scroll on the car screen to control this Mac."
                         : "Needs Accessibility permission to move the pointer.")
                }
                if model.settings.inputEnabled && !model.state.accessibilityGranted {
                    LabeledContent("Accessibility") {
                        Button("Grant…") { model.requestAccessibility() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .task { await PermissionPoller.poll(model, interval: .seconds(2)) }
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Display

struct DisplaySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let settings = model.settings

        Form {
            Section {
                Picker("Mode", selection: $model.settings.displayMode) {
                    ForEach(DisplayMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if settings.displayMode == .mirror {
                    Picker("Show", selection: $model.settings.mirrorDisplayID) {
                        Text("Main Display").tag(CGDirectDisplayID?.none)
                        let physical = model.state.displays.filter { !$0.isVirtual }
                        if !physical.isEmpty { Divider() }
                        ForEach(physical) { display in
                            Text(display.name).tag(CGDirectDisplayID?.some(display.id))
                        }
                    }
                } else {
                    Toggle(isOn: $model.settings.hiDPI) {
                        Text("Sharper text (HiDPI)")
                        Text("Renders the car’s display at 2× so small text stays crisp.")
                    }
                }
            } footer: {
                Text(settings.displayMode == .extend
                     ? "Extend turns your Tesla into a second display. Drag windows onto it."
                     : "Mirror shows a copy of one of your displays.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Quality", selection: $model.settings.tierOverrideID) {
                    Text("Automatic").tag(String?.none)
                    Divider()
                    ForEach(Tier.all) { tier in
                        Text(tier.label).tag(String?.some(tier.id))
                    }
                }
                LabeledContent("Stream", value: tierSummary)
            } footer: {
                Text("Automatic measures what your Tesla can decode when it connects and picks the sharpest setting that stays smooth.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var tierSummary: String {
        if let id = model.settings.tierOverrideID, let tier = Tier.all.first(where: { $0.id == id }) {
            return Format.tierDetail(tier)
        }
        if let car = model.state.car { return Format.tierDetail(car.tier) }
        return "Chosen when your Tesla connects"
    }
}

// MARK: - Advanced

struct AdvancedSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(AppController.self) private var controller
    @State private var confirmingReset = false

    var body: some View {
        let state = model.state
        Form {
            Section {
                LogView(lines: state.log)
                    .frame(height: 180)
                    .listRowInsets(EdgeInsets())
            } header: {
                HStack {
                    Text("Log")
                    Spacer()
                    CopyButton(text: logText, label: "Copy Log")
                        .buttonStyle(.borderless)
                        .disabled(state.log.isEmpty)
                }
            }

            Section {
                LabeledContent {
                    Button("Open") { model.openLocalPreview() }
                } label: {
                    Text("Local preview")
                    Text(state.localURL)
                }
                LabeledContent {
                    Button("Open…") { controller.presentOnboarding() }
                } label: {
                    Text("Setup Assistant")
                    Text("Permissions, network and the address for your Tesla.")
                }
                LabeledContent("Engine", value: engineDescription)
                if let car = state.car {
                    LabeledContent("Current stream") {
                        Text("\(Format.carSummary(car)) · \(Format.fps(state.stats.fps)) fps · \(Format.ms(state.stats.latencyMs)) ms")
                            .monospacedDigit()
                    }
                }
            }

            Section {
                LabeledContent {
                    Button("Reset…", role: .destructive) { confirmingReset = true }
                } label: {
                    Text("Reset Dashcast")
                    Text("Forget all settings. Your certificate and helper stay installed.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Reset all Dashcast settings?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { model.resetAllSettings() }
        } message: {
            Text("Display, latency and menu bar preferences go back to their defaults.")
        }
    }

    private var engineDescription: String {
        switch model.backend {
        case .real: "Dashcast"
        case .mock: "Preview (DASHCAST_MOCK=1)"
        case .mockFallback: "Preview — streaming modules not built in"
        }
    }

    private var logText: String {
        model.state.log
            .map { "\($0.date.formatted(Format.logTime))  \($0.message)" }
            .joined(separator: "\n")
    }
}

/// Console-style log: chronological, monospaced, follows new lines.
struct LogView: View {
    let lines: [LogLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if lines.isEmpty {
                        Text("No messages yet.").foregroundStyle(.secondary)
                    }
                    ForEach(lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(line.date, format: Format.logTime)
                                .foregroundStyle(.tertiary)
                            Text(line.message)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .font(.system(.subheadline, design: .monospaced))
                        .id(line.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: lines.last?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }
}
