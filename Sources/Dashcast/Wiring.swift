import DashcastContracts
import Foundation

#if DASHCAST_REAL
import DashcastNetwork
import DashcastServer
import DashcastStream
#endif
#if DASHCAST_REAL && DASHCAST_RTC
import DashcastRTC
#endif

/// The one place that names concrete implementations.
///
/// - `DASHCAST_MOCK=1` (or SwiftUI previews) → `PreviewService`, a self-animating mock.
/// - Built with `-DDASHCAST_REAL` → the real `DashcastService` / `StreamEngine` / `NetworkManager`.
///   Adding `-DDASHCAST_RTC` also wires `DataChannelPeerFactory` (compatibility/HTTP mode); without
///   it the service runs secure mode only. `scripts/build-app.sh` sets each flag automatically once
///   the types exist (override with `DASHCAST_REAL=1|0`, `DASHCAST_RTC=1|0`).
/// - Otherwise (real modules not compiled in yet) → the mock, flagged in the UI as a fallback.
enum Wiring {
    enum Backend: Equatable {
        case real
        case mock
        /// Real modules weren't compiled in; the mock stands in.
        case mockFallback
    }

    struct Wired {
        let service: DashcastServicing
        let networkActions: NetworkActions
        let backend: Backend
    }

    static var mockRequested: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["DASHCAST_MOCK"] == "1" || env["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    @MainActor
    static func makeService(settings: ServiceSettings) -> Wired {
        #if DASHCAST_REAL
        if !mockRequested {
            let network = NetworkManager()
            let service = DashcastService(engine: StreamEngine(), network: network,
                                          rtc: makeRTCFactory(), settings: settings)
            return Wired(service: service, networkActions: NetworkActions(real: network), backend: .real)
        }
        #endif
        // Screenshots show what the shipping app shows.
        return mock(settings: settings, backend: ShotMode.isActive ? .real : mockRequested ? .mock : .mockFallback)
    }

    @MainActor
    static func mock(settings: ServiceSettings, scenario: PreviewService.Scenario = .fromEnvironment,
                     backend: Backend = .mock) -> Wired {
        let mock = PreviewService(settings: settings, scenario: scenario)
        return Wired(service: mock, networkActions: .mock(mock.mockNetwork), backend: backend)
    }
}

#if DASHCAST_REAL
@MainActor
private func makeRTCFactory() -> RTCPeerFactory? {
    #if DASHCAST_RTC
    DataChannelPeerFactory()
    #else
    nil
    #endif
}

extension NetworkActions {
    /// Adapter over the concrete NetworkManager's extras. If DashcastNetwork changes these
    /// signatures, this initializer is the only thing to update.
    init(real network: NetworkManager) {
        self.init(
            openInternetSharingSettings: { network.openInternetSharingSettings() },
            renewIfNeeded: { _ = try await network.renewIfNeeded() },
            applyRouterSetup: { login, macLANAddress in
                try await network.applyRouterSetup(host: login.host, user: login.user,
                                                   password: login.password, macLANAddress: macLANAddress)
            }
        )
    }
}
#endif
