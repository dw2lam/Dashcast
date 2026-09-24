import Foundation

/// Errors thrown by `NetworkManager`. Every case carries a message fit to show the user.
public enum NetworkError: LocalizedError, Equatable, Sendable {
    case missingCloudflareToken
    case cloudflare(String)
    case zoneNotFound(String)
    case legoNotFound
    case legoFailed(String)
    case opensslFailed(String)
    case pkcs12Rejected(String)
    case keychain(OSStatus)
    case userCancelled
    case privilegedCommandFailed(String)
    case helperDidNotApply(String)
    case invalidArgument(String)
    case sshFailed(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .missingCloudflareToken:
            return "No Cloudflare API token. Create one with Zone → DNS → Edit (and Zone → Zone → Read) on davidlam.online and paste it into Dashcast."
        case .cloudflare(let message):
            return "Cloudflare API: \(message)"
        case .zoneNotFound(let zone):
            return "Cloudflare zone \(zone) not found. Make sure the API token's Zone Resources include \(zone)."
        case .legoNotFound:
            return "The lego ACME client wasn't found (looked in the app bundle, /opt/homebrew/bin and /usr/local/bin). Install it with: brew install lego"
        case .legoFailed(let output):
            return "Let's Encrypt (lego) failed:\n\(output)"
        case .opensslFailed(let output):
            return "Couldn't package the certificate (openssl):\n\(output)"
        case .pkcs12Rejected(let message):
            return "The packaged certificate couldn't be loaded: \(message)"
        case .keychain(let status):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(text)"
        case .userCancelled:
            return "Cancelled."
        case .privilegedCommandFailed(let message):
            return "The administrator command failed: \(message)"
        case .helperDidNotApply(let message):
            return message
        case .invalidArgument(let message):
            return message
        case .sshFailed(let output):
            return "SSH to the router failed:\n\(output)"
        case .timedOut(let what):
            return "\(what) timed out."
        }
    }
}
