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

    static let menuBarNoticeDuration: Duration = .seconds(6)

    @ObservationIgnored private var applyTask: Task<Void, Never>?
    /// The drag-to-authorize panel beside System Settings (created on the first Grant…).
    @ObservationIgnored private var permissionGuide: PermissionGuide?
    @ObservationIgnored private var hostMonitor: HostMonitor?
    @ObservationIgnored private var noticedDisconnect: CarDisconnect?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    enum NetworkActivity: Equatable {
        case refreshing, installingHelper, removingHelper, savingDomain, savingToken, provisioning,
             importingCertificate, renewing, applyingRouter
    }

    convenience init() {
        let settings = SettingsStore.load()
        self.init(wired: Wiring.makeService(settings: settings), settings: settings)
    }

    init(wired: Wiring.Wired, settings: ServiceSettings) {
        service = wired.service
        networkActions = wired.networkActions
        backend = wired.backend
        permissions = PermissionMonitor(probe: wired.permissionProbe)
        self.settings = settings
        service.settings = settings
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
        case .openInternetSharing: openInternetSharingSettings()
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
