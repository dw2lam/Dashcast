import DashcastContracts
import Foundation
import IOKit.pwr_mgt

/// Turns how a car's session ended into what the user is told.
enum DisconnectClassifier {
    enum Ending: Equatable {
        case socket(ServerConnection.Ending)
        /// Nothing from the car for the liveness timeout.
        case timedOut
        /// The server gave up on it (e.g. WebRTC failed).
        case serverEnded
    }

    /// Close codes a browser sends when the page goes away on purpose (normal, going away).
    static let cleanCloseCodes: Set<UInt16> = [WebSocketCloseCode.normal, WebSocketCloseCode.goingAway]

    /// A socket that died without the car closing it could mean it drove off: worth asking the
    /// network whether it's still there.
    static func needsPresenceCheck(_ ending: Ending) -> Bool {
        reason(for: ending, stillOnNetwork: false) == .leftWiFi
    }

    static func reason(for ending: Ending, stillOnNetwork: Bool?) -> DisconnectReason {
        switch ending {
        case .socket(.closedByCar(let code)) where code.map(cleanCloseCodes.contains) == true:
            return .browserClosed
        case .socket(.finishedByCar):
            return .browserClosed
        case .socket(.closedByCar), .socket(.failed), .timedOut:
            return stillOnNetwork == false ? .leftWiFi : .connectionLost
        case .socket(.closedByServer), .serverEnded:
            return .connectionLost
        }
    }
}

// MARK: - Display sleep

/// Holds off idle display sleep while a car is watching.
@MainActor
public protocol DisplayAwakeHolding: AnyObject {
    func setHeld(_ held: Bool)
}

/// `PreventUserIdleDisplaySleep` power assertion. Closing the lid or locking still pauses the Mac.
@MainActor
public final class DisplayAwakeAssertion: DisplayAwakeHolding {
    private var assertion: IOPMAssertionID?

    public nonisolated init() {}

    public func setHeld(_ held: Bool) {
        if held, assertion == nil {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "Dashcast is casting to your Tesla" as CFString, &id)
            if result == kIOReturnSuccess { assertion = id }
        } else if !held, let id = assertion {
            IOPMAssertionRelease(id)
            assertion = nil
        }
    }

    isolated deinit {
        if let assertion { IOPMAssertionRelease(assertion) }
    }
}
