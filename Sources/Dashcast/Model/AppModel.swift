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

    @ObservationIgnored private var applyTask: Task<Void, Never>?

    enum NetworkActivity: Equatable {
        case refreshing, installingHelper, removingHelper, savingToken, provisioning, renewing, applyingRouter
    }

    convenience init() {
        let settings = SettingsStore.load()
        self.init(wired: Wiring.makeService(settings: settings), settings: settings)
    }

    init(wired: Wiring.Wired, settings: ServiceSettings) {
        service = wired.service
        networkActions = wired.networkActions
        backend = wired.backend
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
    }

    func toggleStreaming() {
        isRunning ? stop() : start()
    }

    func start() {
        transition { await self.service.start() }
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
    func requestScreenRecording() { service.requestScreenRecording() }
    func requestAccessibility() { service.requestAccessibility() }

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

    /// Secure (certificate present) or compatibility mode; decides the address the car opens.
    var connectionMode: ConnectionMode { ConnectionMode(network: state.network) }

    var readiness: [ReadinessItem] { ReadinessItem.current(self) }

    func perform(_ action: ReadinessItem.Action) {
        switch action {
        case .grantScreenRecording: requestScreenRecording()
        case .grantAccessibility: requestAccessibility()
        case .installHelper: installHelper()
        case .openInternetSharing: openInternetSharingSettings()
        case .recheckNetwork: Task { await refreshNetwork() }
        }
    }

    // MARK: - Utilities

    func copyCarURL() { Pasteboard.copy(connectionMode.url) }

    /// Forgets every preference (the live policy and settings follow via KVO/didSet).
    func resetAllSettings() {
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
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
