import CDataChannel
import Foundation
import os

enum RTCLog {
    static let library = Logger(subsystem: "online.davidlam.dashcast", category: "libdatachannel")
    static let peer = Logger(subsystem: "online.davidlam.dashcast", category: "rtc")
}

/// Process-wide libdatachannel setup: logs go to os_log at warning level and above.
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
        rtcPreload()   // thread pool + SCTP/SRTP globals now, not on the first car's connect
    }()

    static func bootstrap() { _ = once }

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
