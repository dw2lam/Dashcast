import AppKit
import CoreGraphics
import DashcastContracts
import UserNotifications

/// Watches for the screen locking, the displays sleeping and the whole Mac sleeping, and reports
/// the combined `HostState` whenever it changes.
@MainActor
final class HostMonitor {
    private let report: (HostState) -> Void
    private var locked = HostMonitor.sessionIsLocked()
    private var displayAsleep = false
    private var systemSleeping = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(report: @escaping (HostState) -> Void) {
        self.report = report
    }

    var state: HostState {
        HostState.resolve(systemSleeping: systemSleeping, locked: locked, displayAsleep: displayAsleep)
    }

    func start() {
        guard observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, "com.apple.screenIsLocked") { $0.locked = true }
        observe(distributed, "com.apple.screenIsUnlocked") { $0.locked = false }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification.rawValue) { $0.displayAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification.rawValue) { $0.displayAsleep = false }
        // Delivered synchronously on the main thread, and sleep waits for the handler: the car is
        // told before the network goes away.
        observe(workspace, NSWorkspace.willSleepNotification.rawValue) { $0.systemSleeping = true }
        observe(workspace, NSWorkspace.didWakeNotification.rawValue) { monitor in
            monitor.systemSleeping = false
            monitor.locked = Self.sessionIsLocked()
        }
        report(state)
    }

    private func observe(_ center: NotificationCenter, _ name: String, _ update: @escaping (HostMonitor) -> Void) {
        let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: nil) { [weak self] _ in
            let apply = {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let before = self.state
                    update(self)
                    if self.state != before { self.report(self.state) }
                }
            }
            if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
        }
        observers.append((center, token))
    }

    static func sessionIsLocked() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true || (session["CGSSessionScreenIsLocked"] as? Int) == 1
    }
}

/// The optional "your Tesla disconnected" notification (Settings → General, off by default).
enum DisconnectNotifier {
    /// Notifications need a real app bundle (not `swift run`).
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Asked when the user turns the option on, never before.
    static func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
    }

    static func post(_ disconnect: CarDisconnect) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "Your Tesla disconnected"
        content.body = disconnect.line
        content.threadIdentifier = "disconnect"
        let request = UNNotificationRequest(identifier: "disconnect", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
