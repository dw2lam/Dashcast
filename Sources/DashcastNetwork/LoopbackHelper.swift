import AppKit
import DashcastContracts
import Foundation

/// Where the root helper's pieces live. Production uses the defaults; tests point every path
/// (and the command search path) into a temp directory with stub commands.
struct HelperLayout: Equatable, Sendable {
    var plistPath = "/Library/LaunchDaemons/online.davidlam.dashcast.alias.plist"
    var scriptPath = "/Library/PrivilegedHelperTools/online.davidlam.dashcast.netsetup"
    /// Root-owned directory holding the user-writable trigger file.
    var triggerDirectory = "/Library/Application Support/Dashcast"
    var triggerPath = "/Library/Application Support/Dashcast/dns-trigger"
    var tokenPath = "/var/run/online.davidlam.dashcast.pf-token"
    var statusPath = "/var/run/online.davidlam.dashcast.status"
    var natPreferences = "/Library/Preferences/SystemConfiguration/com.apple.nat"
    var searchPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    static let production = HelperLayout()
}

/// The root LaunchDaemon ("network helper") and the admin commands that install/remove it.
/// Everything here is string generation, so it is unit-testable without root.
///
/// v1: RunAtLoad `ifconfig lo0 alias`.
/// v2: runs `scriptPath`, which keeps the lo0 alias AND, while Internet Sharing's bridge100 exists
///     and Dashcast's DNS responder is listening, pf-redirects the car's DNS (port 53, any server)
///     to the responder. Re-run at boot, on SystemConfiguration changes, when the app touches the
///     trigger file, and every 60 s.
enum LoopbackHelper {
    /// Bump whenever the plist or script changes; the app offers a reinstall for older helpers.
    static let version = 2
    static let versionKey = "DASHCAST_HELPER_VERSION"
    static let label = "online.davidlam.dashcast.alias"
    static let plistPath = HelperLayout.production.plistPath
    static let pfAnchor = "com.apple/250.DashcastDNS"
    static let redirectInterface = "bridge100"
    static var address: String { DashcastDefaults.serviceAddress }

    /// Non-root processes can't bind port 53 on a specific address, so the responder listens here
    /// and pf maps the car's port-53 traffic onto it.
    static let dnsPort: UInt16 = 53530

    /// Rules for the pf anchor (the default /etc/pf.conf has `rdr-anchor "com.apple/*"`).
    static func pfRules(address: String = address, port: UInt16 = dnsPort, interface: String = redirectInterface) -> String {
        "rdr pass on \(interface) inet proto { udp tcp } from any to any port 53 -> \(address) port \(port)\n"
    }

    static func plistData(layout: HelperLayout = .production) throws -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/sh", layout.scriptPath],
            "RunAtLoad": true,
            "StartInterval": 60,
            "ThrottleInterval": 5,
            "WatchPaths": ["/Library/Preferences/SystemConfiguration", layout.triggerPath],
            "EnvironmentVariables": [versionKey: String(version)],
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// Version recorded in an installed plist (1 = the original alias-only helper, which had none).
    static func installedVersion(plist data: Data) -> Int {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let env = plist["EnvironmentVariables"] as? [String: Any],
              let text = env[versionKey] as? String, let value = Int(text) else { return 1 }
        return value
    }

    static func script(layout: HelperLayout = .production, address: String = address, port: UInt16 = dnsPort) -> String {
        let q = shellQuote
        let listening = "\(address).\(port) ".replacingOccurrences(of: ".", with: "\\.")
        return """
        #!/bin/sh
        # Dashcast network helper, run as root by launchd (\(label)).
        # dashcast-helper-version: \(version)
        #
        # 1. Keeps the service address \(address) on lo0.
        # 2. While Internet Sharing's \(redirectInterface) exists AND Dashcast's DNS responder listens on
        #    \(address):\(port), pf-redirects every DNS packet the car sends (to any server, port 53)
        #    to it (anchor \(pfAnchor)). Otherwise the redirect is removed, so the hotspot's
        #    normal DNS keeps working whenever Dashcast isn't running.
        # Runs at boot, on SystemConfiguration changes, when Dashcast touches its trigger file, and
        # every 60 s. Idempotent. Reads no input from the trigger file or anywhere user-writable.

        PATH=\(q(layout.searchPath))
        export PATH
        umask 022
        ADDR=\(q(address))
        IFACE=\(q(redirectInterface))
        ANCHOR=\(q(pfAnchor))
        TOKEN_FILE=\(q(layout.tokenPath))
        STATUS_FILE=\(q(layout.statusPath))
        RULES=\(q(pfRules(address: address, port: port).trimmingCharacters(in: .newlines)))

        # 1. lo0 alias
        if ! ifconfig lo0 | grep -q "inet $ADDR "; then
          ifconfig lo0 alias "$ADDR/32"
        fi

        bridge_up() { ifconfig "$IFACE" >/dev/null 2>&1; }
        sharing_on() { defaults read \(q(layout.natPreferences)) NAT 2>/dev/null | grep -q 'Enabled = 1'; }
        dns_listening() { netstat -an -p udp 2>/dev/null | grep -q \(q(listening)); }

        # Internet Sharing writes its preferences a moment before the bridge appears.
        if ! bridge_up && sharing_on; then
          n=0
          while [ "$n" -lt 20 ] && ! bridge_up; do sleep 1; n=$((n + 1)); done
        fi

        anchor_point=missing
        if pfctl -s nat 2>/dev/null | grep -q 'rdr-anchor "com.apple/\\*"'; then anchor_point=ok; fi

        # 2. DNS redirect
        if bridge_up && dns_listening; then
          if ! pfctl -a "$ANCHOR" -s nat 2>/dev/null | grep -q 'port \(port)'; then
            printf '%s\\n' "$RULES" | pfctl -a "$ANCHOR" -f - >/dev/null 2>&1
          fi
          token=$(cat "$TOKEN_FILE" 2>/dev/null)
          if [ -z "$token" ] || ! pfctl -s References 2>/dev/null | grep -qw "$token"; then
            token=$(pfctl -E 2>&1 | sed -n 's/^Token : *\\([0-9][0-9]*\\).*/\\1/p')
            if [ -n "$token" ]; then printf '%s\\n' "$token" > "$TOKEN_FILE"; else rm -f "$TOKEN_FILE"; fi
          fi
          redirect=on
          reason=
        else
          if pfctl -a "$ANCHOR" -s nat 2>/dev/null | grep -q .; then
            pfctl -a "$ANCHOR" -F all >/dev/null 2>&1
          fi
          token=$(cat "$TOKEN_FILE" 2>/dev/null)
          if [ -n "$token" ]; then pfctl -X "$token" >/dev/null 2>&1; fi
          rm -f "$TOKEN_FILE"
          redirect=off
          if bridge_up; then reason=dns-not-listening; else reason=no-hotspot; fi
        fi

        printf 'version=\(version)\\nredirect=%s\\nreason=%s\\nanchor=%s\\n' "$redirect" "$reason" "$anchor_point" > "$STATUS_FILE.tmp" \\
          && mv -f "$STATUS_FILE.tmp" "$STATUS_FILE"
        exit 0

        """
    }

    /// One shell command (run as root) that installs or upgrades the helper: script (root:wheel 755),
    /// trigger file (owned by `uid` so the app can poke it), plist (root:wheel 644), then
    /// (re)bootstraps and runs the script once so the alias is up before the prompt returns.
    /// Payloads travel base64-encoded inside the command: no temp file for anyone to swap.
    static func installShellCommand(plist: Data, script: Data, uid: UInt32, layout: HelperLayout = .production) -> String {
        let plistPath = shellQuote(layout.plistPath)
        let scriptPath = shellQuote(layout.scriptPath)
        let trigger = shellQuote(layout.triggerPath)
        let service = "system/\(label)"
        let scriptDirectory = shellQuote((layout.scriptPath as NSString).deletingLastPathComponent)
        let plistDirectory = shellQuote((layout.plistPath as NSString).deletingLastPathComponent)
        return [
            "/bin/mkdir -p \(plistDirectory) \(scriptDirectory) \(shellQuote(layout.triggerDirectory))",
            "/bin/echo \(shellQuote(script.base64EncodedString())) | /usr/bin/base64 -D > \(scriptPath)",
            "/usr/sbin/chown root:wheel \(scriptPath)",
            "/bin/chmod 755 \(scriptPath)",
            "/usr/bin/touch \(trigger)",
            "/usr/sbin/chown \(uid) \(trigger)",
            "/bin/chmod 644 \(trigger)",
            "/bin/echo \(shellQuote(plist.base64EncodedString())) | /usr/bin/base64 -D > \(plistPath)",
            "/usr/sbin/chown root:wheel \(plistPath)",
            "/bin/chmod 644 \(plistPath)",
            "{ /bin/launchctl bootout \(service) >/dev/null 2>&1 || true; }",
            "{ /bin/launchctl bootstrap system \(plistPath) || { /bin/sleep 1; /bin/launchctl bootstrap system \(plistPath); }; }",
            "/bin/sh \(scriptPath)",
        ].joined(separator: " && ")
    }

    /// Reverses any version of the install. Idempotent: each step tolerates "already gone".
    static func uninstallShellCommand(layout: HelperLayout = .production) -> String {
        [
            "/bin/launchctl bootout system/\(label) >/dev/null 2>&1",
            "/bin/rm -f \(shellQuote(layout.plistPath)) \(shellQuote(layout.scriptPath)) \(shellQuote(layout.triggerPath))",
            "/bin/rmdir \(shellQuote(layout.triggerDirectory)) >/dev/null 2>&1",
            "/sbin/pfctl -a \(shellQuote(pfAnchor)) -F all >/dev/null 2>&1",
            "t=$(/bin/cat \(shellQuote(layout.tokenPath)) 2>/dev/null)",
            "if [ -n \"$t\" ]; then /sbin/pfctl -X \"$t\" >/dev/null 2>&1; fi",
            "/bin/rm -f \(shellQuote(layout.tokenPath)) \(shellQuote(layout.statusPath))",
            "/sbin/ifconfig lo0 -alias \(address) >/dev/null 2>&1",
            "exit 0",
        ].joined(separator: "; ")
    }

    /// What the helper last did, from its status file (`key=value` lines).
    struct RuntimeStatus: Equatable, Sendable {
        var version: Int?
        var redirectActive: Bool
        var reason: String?
        var anchorPointPresent: Bool

        static func parse(_ text: String) -> RuntimeStatus {
            var values: [String: String] = [:]
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { values[parts[0]] = parts[1] } else if parts.count == 1 { values[parts[0]] = "" }
            }
            return RuntimeStatus(version: values["version"].flatMap { Int($0) },
                                 redirectActive: values["redirect"] == "on",
                                 reason: values["reason"].flatMap { $0.isEmpty ? nil : $0 },
                                 anchorPointPresent: values["anchor"] == "ok")
        }
    }

    /// `do shell script "…" with prompt "…" with administrator privileges`
    static func appleScriptSource(shellCommand: String, prompt: String) -> String {
        "do shell script \"\(appleScriptEscape(shellCommand))\" with prompt \"\(appleScriptEscape(prompt))\" with administrator privileges"
    }

    static func appleScriptEscape(_ string: String) -> String {
        string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Runs a shell command as root. Swappable so tests never raise a password prompt.
@MainActor
protocol PrivilegedRunner: AnyObject {
    func run(shellCommand: String, prompt: String) async throws -> String
}

/// `NSAppleScript` `do shell script … with administrator privileges`: one standard macOS admin
/// prompt, attributed to Dashcast. NSAppleScript is main-thread-only, so this blocks the main
/// thread while the password sheet is up (a one-time setup action).
@MainActor
final class AppleScriptPrivilegedRunner: PrivilegedRunner {
    func run(shellCommand: String, prompt: String) async throws -> String {
        await Task.yield() // let the UI paint its "waiting for password" state first
        let source = LoopbackHelper.appleScriptSource(shellCommand: shellCommand, prompt: prompt)
        guard let script = NSAppleScript(source: source) else {
            throw NetworkError.privilegedCommandFailed("couldn't build the AppleScript")
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = errorInfo[NSAppleScript.errorNumber] as? Int
            if number == -128 { throw NetworkError.userCancelled }
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "error \(number ?? 0)"
            throw NetworkError.privilegedCommandFailed(message)
        }
        return result.stringValue ?? ""
    }
}
