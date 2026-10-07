import AppKit
import DashcastContracts
import Observation
import SwiftUI

/// UI-side owner of the service: persists settings, runs actions, tracks in-flight work.
@MainActor
@Observable
final class AppModel {
    let service: DashcastServicing
    let networkActions: NetworkActions
    let backend: Wiring.Backend
    /// Measured Screen Recording / Accessibility health (not just what the TCC list claims).
    let permissions: PermissionMonitor

    /// Edited by the UI; persisted and pushed to the live session on every change.
    var settings: ServiceSettings {
        didSet {
            guard settings != oldValue else { return }
            SettingsStore.save(settings)
            service.settings = settings
            scheduleApply()
        }
    }

    private(set) var isTransitioning = false
    private(set) var networkActivity: NetworkActivity?
    var networkError: String?
    /// The disconnect shown beside the menu bar icon for a few seconds after it happens.
    private(set) var menuBarNotice: CarDisconnect?
    /// Why the last Start didn't go ahead (a permission that doesn't work), until the next try.
    private(set) var startProblem: PermissionPane?
    /// The car hotspot setup: the user chose to go without internet for the car (Dashcast needs none).
    var hotspotWithoutInternet: Bool {
        didSet {
            guard !RenderMode.offscreen else { return }   // snapshots never touch preferences
            UserDefaults.standard.set(hotspotWithoutInternet, forKey: DefaultsKey.hotspotWithoutInternet)
        }
    }
    /// When the Tesla was first seen on the Mac's hotspot (nil while it isn't there).
    private(set) var hotspotCarSeenAt: Date?
    /// Turning on Internet Sharing for the user ("Do It for Me") or pointing the way ("Guide Me").
    let sharingAssistant: SharingAssistant
    /// The network name Dashcast's hotspot password was saved with (nil = never, or not by Dashcast).
    private(set) var hotspotPasswordNetwork: String? {
        didSet {
            guard !RenderMode.offscreen else { return }
            UserDefaults.standard.set(hotspotPasswordNetwork, forKey: DefaultsKey.hotspotPasswordNetwork)
        }
    }

    static let menuBarNoticeDuration: Duration = .seconds(6)

    @ObservationIgnored private var applyTask: Task<Void, Never>?
    /// The drag-to-authorize panel beside System Settings (created on the first Grant…).
    @ObservationIgnored private var permissionGuide: PermissionGuide?
    @ObservationIgnored private var hostMonitor: HostMonitor?
    @ObservationIgnored private var noticedDisconnect: CarDisconnect?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    /// The Internet Sharing coach beside System Settings (created on the first Open Internet Sharing).
    @ObservationIgnored private var hotspotCoach: HotspotCoach?
    @ObservationIgnored private let hotspotPasswords: HotspotPasswordStoring
    @ObservationIgnored private var cachedHotspotPassword: String?
    /// Whether the Mac's hotspot was up at the last look (auto-ready acts on off → on only).
    @ObservationIgnored private var hotspotWasUp = false

    enum NetworkActivity: Equatable {
        case refreshing, installingHelper, removingHelper, savingDomain, savingToken, provisioning,
             importingCertificate, renewing, applyingRouter
    }

    convenience init() {
        let settings = SettingsStore.load()
        self.init(wired: Wiring.makeService(settings: settings), settings: settings)
    }

    /// `sharingEnvironment` / `hotspotPasswords`: the real System Settings and Keychain unless given
    /// (tests); snapshots and the mock service never touch the Keychain.
    init(wired: Wiring.Wired, settings: ServiceSettings, sharingEnvironment: SharingEnvironment? = nil,
         hotspotPasswords: HotspotPasswordStoring? = nil) {
        service = wired.service
        networkActions = wired.networkActions
        backend = wired.backend
        permissions = PermissionMonitor(probe: wired.permissionProbe)
        hotspotWithoutInternet = !RenderMode.offscreen && UserDefaults.standard.bool(forKey: DefaultsKey.hotspotWithoutInternet)
        hotspotPasswordNetwork = RenderMode.offscreen ? nil : UserDefaults.standard.string(forKey: DefaultsKey.hotspotPasswordNetwork)
        self.hotspotPasswords = hotspotPasswords
            ?? (RenderMode.offscreen || wired.backend != .real ? MemoryHotspotPasswordStore("maplesky47") : KeychainHotspotPasswordStore())
        let open = wired.networkActions.openInternetSharingSettings
        sharingAssistant = SharingAssistant(environment: sharingEnvironment ?? LiveSharingEnvironment(open: open))
        self.settings = settings
        service.settings = settings
        sharingAssistant.onOptionsSaved = { [weak self] plan in self?.hotspotPasswordNetwork = plan.networkName }
    }

    var state: ServiceState { service.state }

    // MARK: - Phase

    var isRunning: Bool {
        switch state.phase {
        case .waitingForCar, .streaming: true
        case .idle, .error: false
        }
    }

    var isStreaming: Bool { state.phase == .streaming }

    // MARK: - Lifecycle

    func didLaunch() {
        service.refreshPermissions()
        Task { await service.refreshNetwork() }
        let monitor = HostMonitor { [weak self] state in self?.service.setHostState(state) }
        hostMonitor = monitor
        monitor.start()
        watchDisconnects()
        hotspotWasUp = AutoReady.isHotspotUp(state.network)
        watchHotspot()
        Task { await permissions.refreshAll(.force) }
        // Coming back from System Settings: measure again.
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.permissions.refreshAll(.stale) }
            }
        }
    }

    // MARK: - Disconnect notices

    /// Re-arms after every change of `state.lastDisconnect` or the phase.
    private func watchDisconnects() {
        withObservationTracking {
            _ = state.lastDisconnect
            _ = state.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.disconnectChanged()
                // Casting stopped on an error (e.g. a revoked grant): measure again.
                if case .error = self.state.phase { await self.permissions.refreshAll(.force) }
                self.watchDisconnects()
            }
        }
    }

    func disconnectChanged(notify: Bool = UserDefaults.standard.bool(forKey: DefaultsKey.notifyOnDisconnect)) {
        let current = state.lastDisconnect
        guard current != noticedDisconnect else { return }
        noticedDisconnect = current
        noticeTask?.cancel()
        menuBarNotice = current
        guard let current else { return }
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.menuBarNoticeDuration)
            guard !Task.isCancelled else { return }
            self?.menuBarNotice = nil
        }
        if notify { DisconnectNotifier.post(current) }
    }

    // MARK: - Car hotspot

    /// Re-arms after every change of the network status (the service keeps it current).
    private func watchHotspot() {
        withObservationTracking {
            _ = state.network
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.hotspotChanged()
                self.watchHotspot()
            }
        }
    }

    /// Notes when the car turns up, and gets ready on its own when the hotspot comes up.
    func hotspotChanged() {
        trackHotspotCar()
        if sharingAssistant.isGuiding { sharingAssistant.update(sharingPlan) }
        let isUp = AutoReady.isHotspotUp(state.network)
        defer { hotspotWasUp = isUp }
        guard AutoReady.shouldStart(wasUp: hotspotWasUp, isUp: isUp, enabled: Self.autoReadyEnabled, phase: state.phase,
                                    screenRecording: permissions[.screenRecording], transitioning: isTransitioning)
        else { return }
        transition {
            // Measure first, quietly: a broken grant leaves it to the readiness list, not a "Can't Start" headline.
            let screen = await self.permissions.refresh(.screenRecording, .stale)
            guard !screen.isProblem, self.state.phase == .idle else { return }
            self.state.append("The hotspot is on: getting ready for your Tesla")
            await self.service.start()
        }
    }

    /// Keeps `hotspotCarSeenAt` in step with the car on the hotspot.
    func trackHotspotCar(now: Date = Date()) {
        if state.network.hotspot.car == nil {
            if hotspotCarSeenAt != nil { hotspotCarSeenAt = nil }
        } else if hotspotCarSeenAt == nil {
            hotspotCarSeenAt = now
        }
    }

    /// Settings ▸ Network: "Get ready automatically when the hotspot turns on" (on unless turned off).
    static var autoReadyEnabled: Bool {
        UserDefaults.standard.object(forKey: DefaultsKey.autoReadyOnHotspot) as? Bool ?? true
    }

    /// The wizard's checklist, from what the Mac sees right now.
    func hotspotSetup(now: Date = Date()) -> HotspotSetup {
        HotspotSetup(.init(network: state.network, lastConnectivityCheck: state.lastConnectivityCheck,
                           casting: state.car != nil, serviceRunning: isRunning,
                           withoutInternet: hotspotWithoutInternet, carSeenAt: hotspotCarSeenAt,
                           password: hotspotPassword, passwordSet: knownHotspotPassword != nil, now: now))
    }

    /// The hotspot password Dashcast suggests (and types, in "Do It for Me"): made once, kept in the Keychain.
    var hotspotPassword: String {
        if let cachedHotspotPassword { return cachedHotspotPassword }
        let password = hotspotPasswords.load() ?? {
            let made = HotspotPassword.generate()
            hotspotPasswords.save(made)
            return made
        }()
        cachedHotspotPassword = password
        return password
    }

    /// The hotspot's password, when Dashcast set it and the network still has the name it was set with.
    var knownHotspotPassword: String? {
        guard let network = hotspotPasswordNetwork, network == state.network.hotspot.networkName else { return nil }
        return hotspotPassword
    }

    /// What Internet Sharing should be set to, from the live network.
    var sharingPlan: SharingPlan { SharingPlan(hotspot: state.network.hotspot, password: hotspotPassword) }

    /// "Do It for Me" and Guide Me need Accessibility (measured; unknown yet counts as yes, the run checks again).
    var canDriveSystemSettings: Bool { !permissions[.accessibility].isProblem }

    /// Opens System Settings ▸ Internet Sharing with the coach panel beside it. The coach closes
    /// itself once sharing is on and brings `bringBack` (the wizard) to the front.
    func coachInternetSharing(bringBack: (() -> Void)? = nil) {
        sharingAssistant.stop()
        openInternetSharingSettings()
        coach(bringBack: bringBack).present()
    }

    /// "Guide Me": System Settings, the coach panel, and a highlight on each control in turn.
    func guideInternetSharing(bringBack: (() -> Void)? = nil) {
        openInternetSharingSettings()
        _ = coach(bringBack: bringBack)
        sharingAssistant.guide(sharingPlan, optionsKnownSet: knownHotspotPassword != nil)
    }

    /// "Do It for Me": Dashcast sets up and turns on Internet Sharing (handing over to Guide Me if it can't).
    func automateInternetSharing(bringBack: (() -> Void)? = nil) {
        _ = coach(bringBack: bringBack)
        sharingAssistant.automate(sharingPlan)
    }

    private func coach(bringBack: (() -> Void)?) -> HotspotCoach {
        let coach = hotspotCoach ?? HotspotCoach(model: self)
        hotspotCoach = coach
        coach.returnToWizard = bringBack
        sharingAssistant.presenter = coach
        return coach
    }

    func dismissHotspotCoach() {
        sharingAssistant.stop()
        hotspotCoach?.dismiss()
    }

    func toggleStreaming() {
        isRunning ? stop() : start()
    }

    /// Checks Screen Recording for real first: a stale or not-yet-applied grant would only give
    /// the car a black screen.
    func start() {
        transition {
            self.startProblem = nil
            if await self.permissions.refresh(.screenRecording, .force).isProblem {
                self.startProblem = .screenRecording
                return
            }
            await self.service.start()
        }
    }

    func stop() {
        transition { await self.service.stop() }
    }

    private func transition(_ operation: @escaping @MainActor () async -> Void) {
        guard !isTransitioning else { return }
        isTransitioning = true
        Task {
            await operation()
            isTransitioning = false
        }
    }

    /// Coalesces rapid edits (e.g. stepping through a picker) into one `applySettings()`.
    private func scheduleApply() {
        applyTask?.cancel()
        applyTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await service.applySettings()
        }
    }

    /// Stops the stream, giving up after `timeout` so quitting can never hang.
    func shutdown(timeout: Duration) async {
        final class Once { var done = false }
        let once = Once()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finish: @MainActor () -> Void = {
                guard !once.done else { return }
                once.done = true
                continuation.resume()
            }
            Task { @MainActor in
                await self.service.stop()
                finish()
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                finish()
            }
        }
    }

    // MARK: - Permissions

    func refreshPermissions() { service.refreshPermissions() }
    func requestScreenRecording() { requestPermission(.screenRecording) }
    func requestAccessibility() { requestPermission(.accessibility) }

    /// The action a permission's current health calls for.
    func fixPermission(_ pane: PermissionPane) {
        switch permissions[pane].action {
        case .grant, .fix: requestPermission(pane)
        case .relaunch: permissions.relaunch(for: pane)
        case .checkAgain: checkPermissions()
        case nil: break
        }
    }

    func checkPermissions() {
        Task {
            service.refreshPermissions()
            await permissions.refreshAll(.force)
            if startProblem.map({ !permissions[$0].isProblem }) == true { startProblem = nil }
        }
    }

    /// Opens the exact privacy pane with the drag panel beside it. The mock (and a build that isn't
    /// an app bundle, so has nothing to drag) goes through the service instead.
    private func requestPermission(_ pane: PermissionPane) {
        permissions.markAsked(pane)
        guard backend == .real, PermissionGuide.isAvailable else {
            switch pane {
            case .screenRecording: service.requestScreenRecording()
            case .accessibility: service.requestAccessibility()
            }
            return
        }
        let guide = permissionGuide ?? PermissionGuide(check: { [weak self] pane in
            guard let self else { return .checking }
            self.service.refreshPermissions()
            return await self.permissions.refresh(pane, .stale)
        }, relaunch: { [weak self] pane in
            self?.permissions.relaunch(for: pane)
        })
        permissionGuide = guide
        guide.present(pane)
    }

    // MARK: - Network

    func refreshNetwork() async {
        guard networkActivity == nil else { return }
        networkActivity = .refreshing
        await service.refreshNetwork()
        networkActivity = nil
    }

    func installHelper() { perform(.installingHelper) { try await self.service.network.installLoopbackHelper() } }
    func uninstallHelper() { perform(.removingHelper) { try await self.service.network.uninstallLoopbackHelper() } }
    func provisionCertificate() { perform(.provisioning) { try await self.service.network.provisionCertificate() } }
    func renewCertificate() { perform(.renewing) { try await self.networkActions.renewIfNeeded() } }

    func setOwnDomain(_ domain: OwnDomain?) {
        perform(.savingDomain) { try self.service.network.setOwnDomain(domain) }
    }

    func importCertificate(_ certificate: CertificateImport) {
        perform(.importingCertificate) { try await self.service.network.importCertificate(certificate) }
    }

    func saveCloudflareToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        perform(.savingToken) { try self.service.network.setCloudflareToken(trimmed) }
    }

    /// Runs the router setup over SSH. Returns the router's output, or nil (see `networkError`).
    func applyRouterSetup(_ login: RouterLogin) async -> String? {
        guard let apply = networkActions.applyRouterSetup, networkActivity == nil else { return nil }
        networkActivity = .applyingRouter
        networkError = nil
        defer { networkActivity = nil }
        do {
            return try await apply(login, state.network.macLANAddress)
        } catch {
            networkError = error.localizedDescription
            return nil
        }
    }

    func openInternetSharingSettings() { networkActions.openInternetSharingSettings() }

    var routerMacAddress: String { state.network.macLANAddress ?? "MAC-LAN-IP" }

    var routerSetupScript: String {
        service.network.routerSetupScript(macLANAddress: routerMacAddress)
    }

    private func perform(_ activity: NetworkActivity, _ operation: @escaping @MainActor () async throws -> Void) {
        guard networkActivity == nil || networkActivity == .refreshing else { return }
        networkActivity = activity
        networkError = nil
        Task {
            do {
                try await operation()
            } catch {
                networkError = error.localizedDescription
            }
            await service.refreshNetwork()
            networkActivity = nil
        }
    }

    // MARK: - Connection

    /// Secure (own domain with a certificate) or compatibility mode; decides the address the car opens.
    var connectionMode: ConnectionMode { ConnectionMode(network: state.network) }

    var readiness: [ReadinessItem] { ReadinessItem.current(self) }

    func perform(_ action: ReadinessItem.Action) {
        switch action {
        case .permission(let pane): fixPermission(pane)
        case .installHelper: installHelper()
        case .setUpHotspot: break   // opens a window: handled by the view (it has openWindow)
        case .recheckNetwork: Task { await refreshNetwork() }
        }
    }

    // MARK: - Utilities

    func copyCarURL() { Pasteboard.copy(connectionMode.url) }

    /// Forgets every preference (the live policy and settings follow via KVO/didSet). The own domain
    /// is kept, like its certificate and the helper.
    func resetAllSettings() {
        let ownDomain = state.network.domain
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        try? service.network.setOwnDomain(ownDomain)
        settings = SettingsStore.load()
    }

    func openLocalPreview() {
        guard let url = URL(string: state.localURL) else { return }
        NSWorkspace.shared.open(url)
    }
}

enum Pasteboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
