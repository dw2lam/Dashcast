import Foundation
import Network

/// Long-lived NWPathMonitor: the latest "is there a usable route" answer, plus change callbacks.
final class PathWatcher: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "online.davidlam.dashcast.path")
    private let lock = NSLock()
    private var latest: NWPath.Status?
    private var onChange: (@Sendable () -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            // The monitor only reports changes (status, interfaces, addresses); skip the initial one.
            let changed = self.latest != nil
            self.latest = path.status
            let callback = self.onChange
            self.lock.unlock()
            if changed { callback?() }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

    func setOnChange(_ callback: (@Sendable () -> Void)?) {
        lock.lock(); onChange = callback; lock.unlock()
    }

    private var status: NWPath.Status? {
        lock.lock(); defer { lock.unlock() }; return latest
    }

    /// Waits up to `timeout` for the monitor's first update.
    func isSatisfied(timeout: TimeInterval = 1.5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while status == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return status == .satisfied
    }
}
