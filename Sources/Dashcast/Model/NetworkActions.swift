import AppKit
import DashcastContracts

/// Network operations the UI needs that are not part of `NetworkManaging`.
///
/// The concrete `NetworkManager` (DashcastNetwork) provides them; Wiring.swift builds this adapter
/// from it, so the rest of the UI never names the concrete type. Mocks and fallbacks fill the
/// closures with system behaviour.
@MainActor
struct NetworkActions {
    /// Opens System Settings ▸ General ▸ Sharing ▸ Internet Sharing.
    var openInternetSharingSettings: () -> Void
    /// Renews the certificate if it is close to expiry (no-op otherwise).
    var renewIfNeeded: () async throws -> Void
    /// Runs the router setup on the travel router over SSH and returns its output.
    /// `macLANAddress` nil = let the implementation detect it. nil closure = copy/paste only.
    var applyRouterSetup: ((_ login: RouterLogin, _ macLANAddress: String?) async throws -> String)?

    /// Behaviour available through the protocol alone.
    static func fallback(for network: NetworkManaging) -> NetworkActions {
        NetworkActions(
            openInternetSharingSettings: { SystemSettings.open(.internetSharing) },
            renewIfNeeded: { try await network.provisionCertificate() },
            applyRouterSetup: nil
        )
    }
}

/// SSH login for the travel router (GL.iNet defaults).
struct RouterLogin: Equatable {
    var host = "192.168.8.1"
    var user = "root"
    var password = ""
}

/// Deep links into System Settings.
enum SystemSettings {
    enum Pane {
        case internetSharing, screenRecording, accessibility

        var urls: [String] {
            switch self {
            case .internetSharing:
                ["x-apple.systempreferences:com.apple.Sharing-Settings.extension?Internet",
                 "x-apple.systempreferences:com.apple.Sharing-Settings.extension",
                 "x-apple.systempreferences:com.apple.preferences.sharing?Internet"]
            case .screenRecording:
                ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
                 "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]
            case .accessibility:
                ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
                 "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]
            }
        }
    }

    static func open(_ pane: Pane) {
        for string in pane.urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }
}
