import Foundation

/// Errors thrown by `NetworkManager`. Every case carries a message fit to show the user.
public enum NetworkError: LocalizedError, Equatable, Sendable {
    case noOwnDomain
    case invalidHostname(String)
    case missingCloudflareToken
    case cloudflare(String)
    case zoneNotFound(String)
    case legoNotFound
    case legoFailed(String)
    case opensslFailed(String)
    case pkcs12Rejected(String)
    case certificateNameMismatch(hostname: String, names: [String])
    case keychain(OSStatus)
    case userCancelled
    case privilegedCommandFailed(String)
    case helperDidNotApply(String)
    case invalidArgument(String)
    case sshFailed(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .noOwnDomain:
            return "Add your own domain first (Settings → Network)."
        case .invalidHostname(let reason):
            return reason
        case .missingCloudflareToken:
            return "No Cloudflare API token. Create one from the Edit zone DNS template (Zone → DNS → Edit and Zone → Zone → Read) for your domain and paste it into Dashcast."
        case .cloudflare(let message):
            return "Cloudflare API: \(message)"
        case .zoneNotFound(let hostname):
            return "None of this token's Cloudflare zones holds \(hostname). Make sure the token's Zone Resources include your domain."
        case .legoNotFound:
            return "The lego ACME client wasn't found (looked in the app bundle, /opt/homebrew/bin and /usr/local/bin). Install it with: brew install lego"
        case .legoFailed(let output):
            return "Let's Encrypt (lego) failed:\n\(output)"
        case .opensslFailed(let output):
            return "Couldn't package the certificate (openssl):\n\(output)"
        case .pkcs12Rejected(let message):
            return "The certificate couldn't be loaded: \(message)"
        case .certificateNameMismatch(let hostname, let names):
            let covered = names.isEmpty ? "no hostnames" : names.joined(separator: ", ")
            return "That certificate is for \(covered), not \(hostname)."
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
