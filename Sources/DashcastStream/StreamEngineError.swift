import CoreGraphics
import DashcastContracts
import Foundation

public enum StreamEngineError: LocalizedError, Equatable {
    case screenRecordingPermissionMissing
    case virtualDisplayUnavailable(String)
    /// The display never showed up in `SCShareableContent`.
    case displayNotFound(CGDirectDisplayID)
    case encoderUnavailable(VideoCodec, OSStatus)

    public var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionMissing:
            return "Screen Recording permission is not granted."
        case .virtualDisplayUnavailable(let reason):
            return "Could not create the virtual display: \(reason)"
        case .displayNotFound(let id):
            return "Display \(id) is not available for capture."
        case .encoderUnavailable(let codec, let status):
            return "Could not create the \(codec.rawValue) encoder (OSStatus \(status))."
        }
    }
}
