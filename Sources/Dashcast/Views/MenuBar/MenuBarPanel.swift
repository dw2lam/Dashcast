import AppKit
import DashcastContracts
import SwiftUI

/// Template symbol in the menu bar; the car fills in and gains waves while casting.
struct MenuBarLabel: View {
    let model: AppModel
    let controller: AppController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel("Dashcast — \(Headline.short(model.state.phase))")
            .onAppear {
                // A menu-bar-only launch never shows the main window, so capture openWindow here too.
                if controller.openWindowAction == nil { controller.openWindowAction = openWindow }
            }
    }

    private var symbol: String {
        switch model.state.phase {
        case .idle: "car"
        case .waitingForCar: "car.front.waves.up"
        case .streaming: "car.front.waves.up.fill"
        case .error: "car.side.and.exclamationmark"
        }
    }
}

/// Control Center–style panel: one big cast tile, the two display modes, latency, and a footer.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(AppController.self) private var controller
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        let state = model.state

        VStack(alignment: .leading, spacing: 10) {
            GlassGroup(spacing: 8) {
                VStack(spacing: 10) {
                    CastTile()
                    HStack(spacing: 10) {
                        ForEach(DisplayMode.allCases, id: \.self) { mode in
                            ModeTile(mode: mode, selected: model.settings.displayMode == mode) {
                                model.settings.displayMode = mode
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Latency")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Latency", selection: $model.settings.latencyMode) {
                    ForEach(LatencyMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.top, 4)

            if model.isStreaming, let car = state.car {
                Text("\(Format.computer(car.computer)) · \(Format.resolution(car.tier.width, car.tier.height)) · \(Format.fps(state.stats.fps)) fps · \(Format.ms(state.stats.latencyMs)) ms · \(Format.transport(car.transport))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            Divider()
                .padding(.top, 2)

            VStack(spacing: 0) {
                PanelRow(title: "How to Connect…") {
                    dismiss()
                    openWindow(id: SceneID.guide)
                    NSApp.activate()
                }
                PanelRow(title: "Open Dashcast…") {
                    dismiss()
                    controller.openWindowAction = openWindow
                    controller.showMainWindow()
                }
                PanelRow(title: "Settings…") {
                    dismiss()
                    openSettings()
                    NSApp.activate()
                }
                Divider().padding(.vertical, 4)
                PanelRow(title: "Quit Dashcast") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
        .tint(.dashAccent)
        .animation(.spring(duration: 0.4), value: model.isStreaming)
    }
}

/// A full-width, menu-style text row with a hover highlight (like the bottom of the Wi‑Fi panel).
struct PanelRow: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(hovering ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The big "Cast to Tesla" toggle tile.
struct CastTile: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let on = model.isRunning
        Button {
            model.toggleStreaming()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "car.front.waves.up.fill" : "car.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(on ? AnyShapeStyle(Color.dashAccent) : AnyShapeStyle(.fill.secondary)))
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Cast to Tesla")
                        .font(.headline)
                    Text(Headline.short(model.state.phase))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(model.isTransitioning)
        .dashGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: true)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct ModeTile: View {
    let mode: DisplayMode
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(selected ? Color.dashAccent : Color.primary)
                    .frame(height: 22)
                Text(mode.title)
                    .font(.callout.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .dashGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                   tint: selected ? Color.dashAccent.opacity(0.16) : nil, interactive: true)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Main menu

struct DashcastCommands: Commands {
    let model: AppModel
    let controller: AppController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Setup Assistant…") { controller.presentOnboarding() }
        }
        CommandMenu("Cast") {
            CastMenuItems(model: model)
        }
    }
}

private struct CastMenuItems: View {
    let model: AppModel

    var body: some View {
        @Bindable var model = model

        Button(model.isRunning ? "Stop Casting" : "Start Casting") { model.toggleStreaming() }
            .keyboardShortcut("r")
            .disabled(model.isTransitioning)

        Divider()

        Picker("Display", selection: $model.settings.displayMode) {
            ForEach(DisplayMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }
        Picker("Latency", selection: $model.settings.latencyMode) {
            ForEach(LatencyMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }

        Divider()

        Button("Copy Car Address") { model.copyCarURL() }
            .keyboardShortcut("c", modifiers: [.command, .shift])
    }
}
