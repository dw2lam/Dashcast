import Darwin
import Foundation
import SystemConfiguration

/// Notices what NWPathMonitor may not: Internet Sharing's bridge (bridge100) appearing or getting
/// its address, a USB/Thunderbolt uplink getting an address, and Internet Sharing's settings being
/// saved. Watches SCDynamicStore keys plus com.apple.nat.plist (via its directory, since the file
/// is replaced, not rewritten). Bursts are coalesced into one `onChange` on its own queue.
final class SystemNetworkWatcher: @unchecked Sendable {   // state confined to `queue`
    /// Interface list changes (a bridge or a USB adapter comes or goes) and the primary service.
    static let keys = ["State:/Network/Interface", "State:/Network/Global/IPv4"]
    /// Addresses on sharing bridges and Ethernet-style ports, and their link state (cable, Wi-Fi).
    static let patterns = [
        "^State:/Network/Interface/bridge[0-9]+/IPv4$",
        "^State:/Network/Interface/en[0-9]+/IPv4$",
        "^State:/Network/Interface/en[0-9]+/Link$",
    ]

    private let queue = DispatchQueue(label: "online.davidlam.dashcast.scwatch")
    private let onChange: @Sendable () -> Void
    private let coalesce: DispatchTimeInterval
    private let natPath: String
    private var store: SCDynamicStore?
    private var relay: Unmanaged<Relay>?
    private var directorySource: DispatchSourceFileSystemObject?
    private var natStamp: String?
    private var pending = false

    /// Bridges SCDynamicStore's C callback to the watcher without keeping it alive.
    private final class Relay {
        weak var watcher: SystemNetworkWatcher?
        init(_ watcher: SystemNetworkWatcher) { self.watcher = watcher }
    }

    /// `natPreferencesPath` is the plist file; nil skips that part (and `dynamicStore: false` the
    /// SCDynamicStore part, for tests).
    init(natPreferencesPath: String?, dynamicStore: Bool = true, coalesce: DispatchTimeInterval = .milliseconds(300),
         onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        self.coalesce = coalesce
        natPath = natPreferencesPath ?? ""
        queue.sync {
            if dynamicStore { startDynamicStore() }
            if natPreferencesPath != nil { startNATWatch() }
        }
    }

    deinit {
        if let store {
            SCDynamicStoreSetDispatchQueue(store, nil)
        }
        relay?.release()
        directorySource?.cancel()
    }

    /// The SCDynamicStore notifications are armed.
    private(set) var watchingDynamicStore = false
    /// The NAT preferences' directory is watched.
    var watchingNATPreferences: Bool { queue.sync { directorySource != nil } }

    private func startDynamicStore() {
        let relay = Unmanaged.passRetained(Relay(self))
        var context = SCDynamicStoreContext(version: 0, info: relay.toOpaque(), retain: nil, release: nil,
                                            copyDescription: nil)
        guard let store = SCDynamicStoreCreate(nil, "online.davidlam.dashcast.watch" as CFString, { _, _, info in
            guard let info else { return }
            Unmanaged<Relay>.fromOpaque(info).takeUnretainedValue().watcher?.noteChange()
        }, &context) else {
            relay.release()
            return
        }
        guard SCDynamicStoreSetNotificationKeys(store, Self.keys as CFArray, Self.patterns as CFArray),
              SCDynamicStoreSetDispatchQueue(store, queue) else {
            relay.release()
            return
        }
        self.store = store
        self.relay = relay
        watchingDynamicStore = true
    }

    private func startNATWatch() {
        let directory = (natPath as NSString).deletingLastPathComponent
        let fd = open(directory, O_EVTONLY)
        guard fd >= 0 else { return }
        natStamp = Self.stamp(natPath)
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                               queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // The directory also holds preferences.plist and friends; only the NAT file matters.
            let stamp = Self.stamp(self.natPath)
            guard stamp != self.natStamp else { return }
            self.natStamp = stamp
            self.noteChange()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        directorySource = source
    }

    /// inode + size + mtime (nil = no file).
    static func stamp(_ path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return "\(info.st_ino)-\(info.st_size)-\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
    }

    /// On `queue`. The first change in a burst schedules one callback after `coalesce`.
    private func noteChange() {
        guard !pending else { return }
        pending = true
        queue.asyncAfter(deadline: .now() + coalesce) { [weak self] in
            guard let self else { return }
            self.pending = false
            self.onChange()
        }
    }
}
