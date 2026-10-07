import CDataChannel
import Foundation
import os

enum RTCLog {
    static let library = Logger(subsystem: "online.davidlam.dashcast", category: "libdatachannel")
    static let peer = Logger(subsystem: "online.davidlam.dashcast", category: "rtc")
}

/// Process-wide libdatachannel setup: logs go to os_log at warning level and above.
///
/// The library's global state (a thread pool of ~one thread per core, usrsctp with its 10 ms timer
/// thread, DTLS/SRTP globals) is not preloaded: it starts with the first peer and is torn down
/// (`rtcCleanup`) once no peer has existed for `idleCleanupDelay`, so an idle app costs nothing.
/// Peers count themselves in (`retain`, before creating their PeerConnection) and out (`release`,
/// after deleting it). Every PeerConnection in the process must go through this: `rtcCleanup`
/// deletes whatever C-API objects still exist.
enum LibDataChannel {
    private static let once: Void = {
        rtcInitLogger(RTC_LOG_WARNING) { level, message in
            guard let message else { return }
            let text = String(cString: message)
            if level == RTC_LOG_FATAL || level == RTC_LOG_ERROR {
                RTCLog.library.error("\(text, privacy: .public)")
            } else {
                RTCLog.library.warning("\(text, privacy: .public)")
            }
        }
    }()

    static func bootstrap() { _ = once }

    // MARK: Lifetime

    /// How long the stack stays up after the last peer closed (a reconnecting car reuses it).
    static var idleCleanupDelay: TimeInterval {
        get { lifecycle.sync { cleanupDelay } }
        set { lifecycle.sync { cleanupDelay = newValue } }
    }

    /// Whether the global state is (or may still be) up. Diagnostics and tests.
    static var isRunning: Bool { lifecycle.sync { running } }

    // Confined to `lifecycle`. A cleanup runs on it too, so a `retain` waits for one in progress.
    private static let lifecycle = DispatchQueue(label: "online.davidlam.dashcast.rtc.lifecycle", qos: .utility)
    private static var cleanupDelay: TimeInterval = 15
    private static var users = 0
    private static var running = false
    private static var generation = 0

    /// A peer is about to create a PeerConnection (which starts the stack if it's down).
    static func retain() {
        bootstrap()
        lifecycle.sync {
            users += 1
            generation += 1
            running = true
        }
    }

    /// A peer deleted its PeerConnection. The last one out schedules the cleanup.
    static func release() {
        lifecycle.async {
            users = max(0, users - 1)
            guard users == 0 else { return }
            generation += 1
            let scheduled = generation
            lifecycle.asyncAfter(deadline: .now() + cleanupDelay) {
                if generation == scheduled { cleanUpIfIdle() }
            }
        }
    }

    /// Tears the stack down now if no peer exists (blocks until its threads have exited). Tests.
    static func cleanupNowIfIdle() {
        lifecycle.sync { cleanUpIfIdle() }
    }

    private static func cleanUpIfIdle() {
        dispatchPrecondition(condition: .onQueue(lifecycle))
        guard users == 0, running else { return }
        rtcCleanup()   // joins the thread pool, finishes usrsctp (waits up to 10 s)
        running = false
        RTCLog.peer.debug("libdatachannel stopped (no peers)")
    }

    /// Reads a string through libdatachannel's size-query convention (nil buffer → required size).
    static func string(_ read: (UnsafeMutablePointer<CChar>?, Int32) -> Int32) -> String? {
        let size = read(nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard read(&buffer, size) >= 0 else { return nil }
        return String(cString: buffer)
    }
}

/// C callbacks receive an opaque token, never a Swift object pointer: libdatachannel doesn't wait
/// for in-flight callbacks when a peer is deleted, so they resolve the token here (weakly) and a
/// late callback for a closed peer finds nothing.
final class PeerRegistry: @unchecked Sendable {
    static let shared = PeerRegistry()

    private struct Entry { weak var peer: DataChannelPeer? }
    private let lock = OSAllocatedUnfairLock(initialState: (next: 1, entries: [Int: Entry]()))

    func register(_ peer: DataChannelPeer) -> UnsafeMutableRawPointer {
        let token = lock.withLock { state -> Int in
            let token = state.next
            state.next += 1
            state.entries[token] = Entry(peer: peer)
            return token
        }
        return UnsafeMutableRawPointer(bitPattern: token)!
    }

    func unregister(_ pointer: UnsafeMutableRawPointer) {
        let token = Int(bitPattern: pointer)
        _ = lock.withLock { $0.entries.removeValue(forKey: token) }
    }

    func peer(_ pointer: UnsafeMutableRawPointer?) -> DataChannelPeer? {
        guard let pointer else { return nil }
        let token = Int(bitPattern: pointer)
        return lock.withLock { $0.entries[token]?.peer }
    }
}
