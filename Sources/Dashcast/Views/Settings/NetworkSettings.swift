import DashcastContracts
import SwiftUI

struct NetworkSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var routerExpanded: Bool
    @State private var showingRouterLogin = false

    init(routerExpanded: Bool = false) {
        _routerExpanded = State(initialValue: routerExpanded)
    }

    var body: some View {
        let status = model.state.network
        let mode = model.connectionMode
        let activity = model.networkActivity

        Form {
            // How the car connects
            Section {
                ModeRow(title: "Secure", detail: "\(ConnectionMode.secureAddress(status.domain)) · the fastest video.",
                        symbol: "lock.fill", active: mode.isSecure)
                ModeRow(title: "Compatibility", detail: "http://\(DashcastDefaults.serviceAddress) · works with no setup.",
                        symbol: "bolt.horizontal.fill", active: !mode.isSecure)
                LabeledContent {
                    Button("Connection Methods…") {
                        openWindow(id: SceneID.guide)
                        NSApp.activate()
                    }
                } label: {
                    Text("Ways to connect")
                    Text("Mac hotspot or travel router, and which to choose.")
                }
            } header: {
                Text("How Your Tesla Connects")
            } footer: {
                Text("Dashcast picks the mode for you. Everything stays between this Mac and your Tesla; nothing streams over the internet.")
                    .foregroundStyle(.secondary)
            }

            // This Mac's network
            Section("Connection") {
                LabeledContent {
                    Text(status.interfaceName.map { "\($0) · \(status.macLANAddress ?? "—")" } ?? "")
                        .foregroundStyle(.secondary)
                } label: {
                    Label {
                        Text(status.topology.title)
                        Text(status.topology.explanation)
                    } icon: {
                        Image(systemName: status.topology.symbol)
                            .foregroundStyle(status.topology.isUsable ? Color.green : Color.orange)
                            .frame(width: 20)
                    }
                }
                if let conflict = status.serviceAddressConflict {
                    WarningRow(title: "Another app is using Dashcast’s network",
                               detail: "SideDisplay or a similar app took the same address range (\(conflict)). Quit it, then check again.")
                }
                if status.topology == .phoneHotspot {
                    WarningRow(title: "An iPhone hotspot can’t reach your Tesla",
                               detail: "iPhone keeps hotspot devices apart, and the Tesla browser won’t open private addresses. Share this Mac’s connection over Wi‑Fi instead, or use a travel router.")
                }
                LabeledContent {
                    Button("Open…") { model.openInternetSharingSettings() }
                } label: {
                    Text("Internet Sharing")
                    Text("Share your iPhone’s USB connection over Wi‑Fi, then join that network from your Tesla.")
                }
            }

            // Secure mode (optional)
            OwnDomainSections()

            // Travel router
            Section {
                DisclosureGroup("Travel router setup", isExpanded: $routerExpanded) {
                    RouterScriptView(script: model.routerSetupScript)
                    HStack {
                        Text("Run these on a GL.iNet or OpenWrt router.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        CopyButton(text: model.routerSetupScript, label: "Copy")
                        if model.networkActions.applyRouterSetup != nil {
                            Button("Apply to Router…") { showingRouterLogin = true }
                        }
                    }
                }
            }

            // Helper
            Section {
                LabeledContent {
                    if status.helperInstalled {
                        HStack(spacing: 10) {
                            ActionButton("Reinstall", busy: activity == .installingHelper) { model.installHelper() }
                            ActionButton("Uninstall", busy: activity == .removingHelper) { model.uninstallHelper() }
                        }
                    } else {
                        ActionButton("Install", busy: activity == .installingHelper) { model.installHelper() }
                    }
                } label: {
                    Text("Network helper")
                    Text(status.helperInstalled
                         ? (status.aliasActive ? "Installed and running." : "Installed, but \(DashcastDefaults.serviceAddress) isn’t active.")
                         : "Keeps \(DashcastDefaults.serviceAddress) on this Mac. Asks for your password once.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
        .task { await model.refreshNetwork() }
        .sheet(isPresented: $showingRouterLogin) { RouterLoginSheet() }
    }
}

private struct ModeRow: View {
    let title: String
    let detail: String
    let symbol: String
    let active: Bool

    var body: some View {
        LabeledContent {
            if active {
                Label("In use", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.dashAccent)
                    .labelStyle(.titleAndIcon)
            }
        } label: {
            Label {
                Text(title)
                Text(detail)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(active ? Color.dashAccent : .secondary)
                    .frame(width: 20)
            }
        }
    }
}

struct WarningRow: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }
}

struct RouterScriptView: View {
    let script: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(script)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize()
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 160)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator)
        }
    }
}

/// Collects the router's SSH login, runs the setup, and shows the router's reply.
struct RouterLoginSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var login = RouterLogin()
    @State private var output: String?

    var body: some View {
        let busy = model.networkActivity == .applyingRouter
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Router", text: $login.host, prompt: Text("192.168.8.1"))
                    TextField("User", text: $login.user, prompt: Text("root"))
                    SecureField("Password", text: $login.password, prompt: Text("Router admin password"))
                } header: {
                    Text("Apply Router Setup")
                } footer: {
                    Text("Dashcast signs in over SSH once to run the setup. The password isn’t stored.")
                        .foregroundStyle(.secondary)
                }
                if let output {
                    Section("Router Output") {
                        Text(output)
                            .font(.system(.subheadline, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } else if let error = model.networkError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .disabled(busy)

            Divider()
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                if output == nil {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Apply") { Task { output = await model.applyRouterSetup(login) } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || login.host.isEmpty || login.user.isEmpty || login.password.isEmpty)
                } else {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 440, height: 360)
    }
}
