import AppKit
import DashcastContracts
import SwiftUI

// MARK: - Methods

enum ConnectionMethod: String, CaseIterable, Identifiable {
    case macHotspot, travelRouter, phoneHotspot

    var id: Self { self }

    init?(topology: Topology) {
        switch topology {
        case .macHotspot: self = .macHotspot
        case .router: self = .travelRouter
        case .phoneHotspot: self = .phoneHotspot
        case .offline: return nil
        }
    }

    var name: String {
        switch self {
        case .macHotspot: "Mac as Hotspot"
        case .travelRouter: "Travel Router"
        case .phoneHotspot: "Phone Hotspot for Both"
        }
    }

    var symbol: String {
        switch self {
        case .macHotspot: "personalhotspot"
        case .travelRouter: "wifi.router"
        case .phoneHotspot: "iphone.slash"
        }
    }

    var tint: Color {
        switch self {
        case .macHotspot: .dashAccent
        case .travelRouter: .teal
        case .phoneHotspot: .gray
        }
    }

    var summary: String {
        switch self {
        case .macHotspot: "No extra hardware and the lowest latency: just one Wi‑Fi hop."
        case .travelRouter: "The most reliable. Best for long sessions, or when the Mac stays on other Wi‑Fi."
        case .phoneHotspot: "Both on an iPhone or Android hotspot. This can’t work."
        }
    }

    /// Latency · Reliability · Extra hardware · Needs internet.
    var comparison: [(String, String)] {
        switch self {
        case .macHotspot: [("Latency", "Lowest"), ("Reliability", "Good"), ("Hardware", "None"), ("Internet", "Not needed")]
        case .travelRouter: [("Latency", "Low"), ("Reliability", "Best"), ("Hardware", "Travel router"), ("Internet", "Not needed")]
        case .phoneHotspot: []
        }
    }

    var isSupported: Bool { self != .phoneHotspot }
}

// MARK: - Window

/// "How to Connect": the ways to link the Mac and the car, with live progress and one-tap fixes.
struct ConnectionGuide: View {
    static let size = CGSize(width: 580, height: 660)

    private let initiallyExpanded: Set<ConnectionMethod>?
    private let scrolls: Bool

    init(expanded: Set<ConnectionMethod>? = nil, scrolls: Bool = true) {
        initiallyExpanded = expanded
        self.scrolls = scrolls
    }

    var body: some View {
        Group {
            if scrolls {
                ScrollView {
                    GuideContent(initiallyExpanded: initiallyExpanded)
                }
                .frame(width: Self.size.width, height: Self.size.height)
            } else {
                GuideContent(initiallyExpanded: initiallyExpanded)
                    .frame(width: Self.size.width)
            }
        }
        .tint(.dashAccent)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .containerBackground(.thickMaterial, for: .window)
    }
}

private struct GuideContent: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<ConnectionMethod>
    @State private var showingRouterSetup = false

    init(initiallyExpanded: Set<ConnectionMethod>?) {
        _expanded = State(initialValue: initiallyExpanded ?? [])
    }

    var body: some View {
        let current = ConnectionMethod(topology: model.state.network.topology)

        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("How to Connect")
                    .font(.largeTitle.bold())
                Text("Pick how your Tesla reaches this Mac. The first way works for most people.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 4)

            ForEach(ConnectionMethod.allCases) { method in
                MethodCard(method: method,
                           isCurrent: method == current,
                           isExpanded: expanded.contains(method),
                           toggle: { toggle(method) },
                           showRouterSetup: { showingRouterSetup = true })
            }

            ModesCard()
            TeslaCard()
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 28)
        .onAppear {
            // Open the method in use, or the recommended one.
            if expanded.isEmpty { expanded = [current ?? .macHotspot] }
        }
        .sheet(isPresented: $showingRouterSetup) { RouterSetupSheet() }
    }

    private func toggle(_ method: ConnectionMethod) {
        withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
            if expanded.contains(method) { expanded.remove(method) } else { expanded.insert(method) }
        }
    }
}

// MARK: - Method card

private struct MethodCard: View {
    let method: ConnectionMethod
    let isCurrent: Bool
    let isExpanded: Bool
    let toggle: () -> Void
    let showRouterSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                header
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Hide steps" : "Show steps")

            if isExpanded {
                Divider()
                    .padding(.vertical, 12)
                MethodSteps(method: method, showRouterSetup: showRouterSetup)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(method.isSupported ? Color.green.opacity(0.55) : Color.orange.opacity(0.6), lineWidth: 1.5)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: method.symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(method.tint.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(method.name)
                        .font(.title3.weight(.semibold))
                    if method == .macHotspot { RecommendedBadge() }
                    if !method.isSupported { NotSupportedBadge() }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                Text(method.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !method.comparison.isEmpty {
                    ComparisonChips(items: method.comparison)
                        .padding(.top, 2)
                }
                if isCurrent {
                    Label(method.isSupported ? "You’re using this" : "You’re on this now",
                          systemImage: method.isSupported ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(method.isSupported ? Color.green : Color.orange)
                        .contentTransition(.symbolEffect(.replace))
                        .padding(.top, 2)
                }
            }
        }
    }
}

private struct RecommendedBadge: View {
    var body: some View {
        Text("Recommended")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .dashGlass(in: Capsule(), tint: .dashAccent)
    }
}

private struct NotSupportedBadge: View {
    var body: some View {
        Text("Not supported")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(.fill.tertiary, in: Capsule())
    }
}

private struct ComparisonChips: View {
    let items: [(String, String)]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.0) { dimension, value in
                HStack(spacing: 4) {
                    Text(dimension).foregroundStyle(.secondary)
                    Text(value).fontWeight(.semibold)
                }
                .font(.caption)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.fill.tertiary, in: Capsule())
            }
        }
    }
}

// MARK: - Steps

private enum StepAction {
    case openSharing, installHelper, routerSetup, copyAddress
}

private struct Step: Identifiable {
    let id: Int
    let text: String
    /// nil = the app can't see this step.
    var done: Bool?
    var optional = false
    var action: StepAction?
}

private struct MethodSteps: View {
    let method: ConnectionMethod
    let showRouterSetup: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        switch method {
        case .macHotspot:
            VStack(alignment: .leading, spacing: 12) {
                StepList(steps: hotspotSteps, showRouterSetup: showRouterSetup)
                Label("While sharing, your Mac’s Wi‑Fi is busy being the hotspot; its internet comes from the iPhone cable.",
                      systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .travelRouter:
            StepList(steps: routerSteps, showRouterSetup: showRouterSetup)
        case .phoneHotspot:
            VStack(alignment: .leading, spacing: 8) {
                Text("On any phone’s hotspot, iPhone or Android, the car sends everything to the phone, which can’t pass it on to your Mac, and the Tesla browser blocks the private addresses a phone hands out. iPhones also keep hotspot devices from talking to each other.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Use **Mac as Hotspot** or a **Travel Router** instead. Your phone can still supply the internet: an iPhone over USB, an Android phone over Bluetooth tethering, or either one feeding the travel router.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
        }
    }

    private var address: String { model.connectionMode.addressToType }

    private var hotspotSteps: [Step] {
        let network = model.state.network
        let connected = model.state.car != nil
        return [
            Step(id: 1, text: "Plug your iPhone into the Mac with a USB cable and turn on **Personal Hotspot**, or share an Android phone’s internet over Bluetooth tethering. This only gives the Mac internet; Dashcast itself works offline.",
                 optional: true),
            Step(id: 2, text: "Open **System Settings → General → Sharing** and click ⓘ next to **Internet Sharing**. Share from **iPhone USB** to **Wi‑Fi**. In **Wi‑Fi Options**, set a name (like “Dashcast”), a 5 GHz channel (36 or 149) and a password, then turn Internet Sharing on.",
                 done: network.topology == .macHotspot, action: .openSharing),
            Step(id: 3, text: "Install Dashcast’s network helper once. It asks for your admin password.",
                 done: network.helperInstalled, action: .installHelper),
            Step(id: 4, text: "In your Tesla, tap **Controls → Wi‑Fi** and join your “Dashcast” network. The car remembers it.",
                 done: connected ? true : nil),
            Step(id: 5, text: "Open the **Browser**, go to **\(address)** and press **Tap to Start**. Bookmark it for next time.",
                 done: connected, action: .copyAddress),
        ]
    }

    private var routerSteps: [Step] {
        let network = model.state.network
        let connected = model.state.car != nil
        return [
            Step(id: 1, text: "Power a travel router (like a GL.iNet) from the car’s USB-C port. For internet, you can plug your iPhone into the router."),
            Step(id: 2, text: "Connect the Mac to the router. A USB-C Ethernet adapter is best, or join its Wi‑Fi.",
                 done: network.topology == .router),
            Step(id: 3, text: "Apply **Router Setup** once. It sends the Dashcast address to your Mac and adds the car name to the router’s DNS. Then reserve your Mac’s IP in the router’s admin page.",
                 action: .routerSetup),
            Step(id: 4, text: "Install Dashcast’s network helper.",
                 done: network.helperInstalled, action: .installHelper),
            Step(id: 5, text: "In your Tesla, join the router’s Wi‑Fi and open **\(address)**.",
                 done: connected, action: .copyAddress),
        ]
    }
}

private struct StepList: View {
    let steps: [Step]
    let showRouterSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(steps) { step in
                StepRow(step: step, showRouterSetup: showRouterSetup)
            }
        }
    }
}

private struct StepRow: View {
    let step: Step
    let showRouterSetup: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            StepMarker(number: step.id, done: step.done == true)
            VStack(alignment: .leading, spacing: 6) {
                (Text(AttributedString(inlineMarkdown: step.text)) + (step.optional ? Text("  Optional").font(.caption.weight(.semibold)).foregroundStyle(.secondary) : Text("")))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = step.action, step.done != true || action == .copyAddress {
                    actionButton(action)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func actionButton(_ action: StepAction) -> some View {
        Group {
            switch action {
            case .openSharing:
                Button("Open Sharing Settings") { model.openInternetSharingSettings() }
            case .installHelper:
                ActionButton("Install Helper", busy: model.networkActivity == .installingHelper) { model.installHelper() }
            case .routerSetup:
                Button("Router Setup…", action: showRouterSetup)
            case .copyAddress:
                CopyButton(text: model.connectionMode.url, label: "Copy Address")
            }
        }
        .secondaryButtonStyle()
        .controlSize(.small)
    }
}

/// A numbered circle that turns into a green check when the app sees the step is done.
private struct StepMarker: View {
    let number: Int
    let done: Bool

    var body: some View {
        ZStack {
            Circle().fill(done ? AnyShapeStyle(Color.green) : AnyShapeStyle(Color.dashAccent.opacity(0.14)))
            if done {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Text("\(number)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dashAccent)
            }
        }
        .frame(width: 22, height: 22)
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        .animation(.spring(duration: 0.35), value: done)
        .accessibilityLabel(done ? "Step \(number), done" : "Step \(number)")
    }
}

// MARK: - Shared sections

/// Secure vs Compatibility mode, with the one in use marked, and the way into Secure mode.
private struct ModesCard: View {
    @Environment(AppModel.self) private var model
    @State private var showingDomain = false

    var body: some View {
        let mode = model.connectionMode
        let domain = model.state.network.domain
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(symbol: "lock.shield", title: "Secure or Compatibility Mode")
            ModeLine(symbol: "lock.fill", title: "Secure", address: ConnectionMode.secureAddress(domain),
                     detail: "The fastest video. Needs a domain you own and a free certificate, set up once.",
                     inUse: mode.isSecure)
            ModeLine(symbol: "bolt.horizontal.fill", title: "Compatibility", address: "http://\(DashcastDefaults.serviceAddress)",
                     detail: "Works with no setup. Video uses WebRTC, with a little more delay.",
                     inUse: !mode.isSecure)
            HStack(alignment: .firstTextBaseline) {
                Text("Secure mode is optional, and Dashcast picks the mode for you. Either way, everything stays between your Mac and your Tesla.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button(domain == nil ? "Use Your Own Domain…" : "Domain Settings…") { showingDomain = true }
                    .secondaryButtonStyle()
                    .controlSize(.small)
                    .fixedSize()
            }
        }
        .padding(16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .sheet(isPresented: $showingDomain) { OwnDomainSheet() }
    }
}

private struct ModeLine: View {
    let symbol: String
    let title: String
    let address: String
    let detail: String
    let inUse: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(inUse ? Color.dashAccent : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.semibold)
                    Text(address).foregroundStyle(.secondary)
                    if inUse {
                        Label("In use", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.dashAccent)
                    }
                }
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
        }
    }
}

/// What to do in the car, whichever method you use.
private struct TeslaCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let address = model.connectionMode.addressToType
        let connected = model.state.car != nil
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(symbol: "car.fill", title: "On Your Tesla")
            StepList(steps: [
                Step(id: 1, text: "Tap **Controls → Wi‑Fi** and join your Mac’s or router’s network.", done: connected ? true : nil),
                Step(id: 2, text: "Open the **Browser** from the app launcher.", done: connected ? true : nil),
                Step(id: 3, text: "Go to **\(address)**.", done: connected, action: .copyAddress),
                Step(id: 4, text: "Press the **Tap to Start** button. That lets sound play."),
                Step(id: 5, text: "For the biggest picture, use the page’s fullscreen button."),
            ], showRouterSetup: {})
            Label("Video is for parked or passenger use.", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.orange)
        }
        .padding(16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct SectionTitle: View {
    let symbol: String
    let title: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.title3.weight(.semibold))
            .labelStyle(.titleAndIcon)
    }
}

// MARK: - Router setup

/// The router commands with Copy and Apply (over SSH).
struct RouterSetupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showingLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Router Setup")
                .font(.title2.bold())
            Text("Run these once on a GL.iNet or OpenWrt router, or let Dashcast apply them over SSH.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            RouterScriptView(script: model.routerSetupScript)
            HStack {
                CopyButton(text: model.routerSetupScript, label: "Copy Commands")
                if model.networkActions.applyRouterSetup != nil {
                    Button("Apply to Router…") { showingLogin = true }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(width: 520)
        .tint(.dashAccent)
        .sheet(isPresented: $showingLogin) { RouterLoginSheet() }
    }
}

// MARK: - Entry points

/// "How to Connect" link used on the main window and in the Setup Assistant.
struct GuideLink: View {
    var title = "How to Connect"
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: SceneID.guide)
            NSApp.activate()
        } label: {
            Label(title, systemImage: "questionmark.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Color.dashAccent)
    }
}
