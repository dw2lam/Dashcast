import DashcastContracts
import Foundation

/// Topology B: a GL.iNet / OpenWrt travel router between the Mac and the car.
enum RouterSetup {
    static let routeSection = "dashcast_car"

    /// The static route, plus, when the user has their own domain, a local answer for it (and a
    /// DNS-rebind exception, since its record points at an address the router treats as local).
    static func script(macLANAddress rawAddress: String,
                       serviceAddress: String = DashcastDefaults.serviceAddress,
                       hostname: String?) -> String {
        let mac = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard IPv4.isValid(mac) else {
            let shown = mac.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == ":" }
            return """
            #!/bin/sh
            # Dashcast router setup: the Mac's LAN address is missing or invalid ("\(shown)").
            # Connect the Mac to the travel router first, then generate this script again.
            echo "Dashcast: not a valid IPv4 address for the Mac: \(shown)" >&2
            exit 1

            """
        }
        let hostname = hostname.flatMap { try? OwnDomain.normalize($0).get() }
        let carURL = hostname.map { "https://\($0)" } ?? "http://\(serviceAddress)"
        let steps = hostname.map { hostname in
            """
            #   2. Stops dnsmasq's DNS-rebind protection from dropping answers for \(hostname).
            #   3. Answers \(hostname) -> \(serviceAddress) from the router itself, so the car
            #      finds the Mac with no internet and no public DNS record.
            """
        } ?? """
            #   (No own domain is set in Dashcast, so the router's DNS is left alone; the car
            #   opens \(carURL) directly.)
            """
        let dnsSection = hostname.map { hostname in
            """

            # --- 2. DNS rebind protection ---------------------------------------------------
            # Allow local-looking answers for \(hostname) only (protection stays on for
            # everything else). del_list first so re-running doesn't add a duplicate entry.
            uci -q del_list dhcp.@dnsmasq[0].rebind_domain='\(hostname)' || true
            uci add_list dhcp.@dnsmasq[0].rebind_domain='\(hostname)'
            # Alternative: switch rebind protection off entirely.
            #   uci set dhcp.@dnsmasq[0].rebind_protection='0'

            # --- 3. Local answer for \(hostname) (works offline) ---------------------------
            # Drop any earlier Dashcast entry (e.g. an old address) before adding the current one.
            for entry in $(uci -q get dhcp.@dnsmasq[0].address); do
              case "$entry" in /\(hostname)/*) uci del_list dhcp.@dnsmasq[0].address="$entry" ;; esac
            done
            uci add_list dhcp.@dnsmasq[0].address='/\(hostname)/\(serviceAddress)'
            # Optional: also fake Tesla's connectivity check through Dashcast (only while the Mac runs
            # Dashcast; otherwise the car would think this Wi-Fi has no internet):
            #   uci add_list dhcp.@dnsmasq[0].address='/connman.vn.tesla.services/\(serviceAddress)'
            uci commit dhcp
            /etc/init.d/dnsmasq restart

            # GL.iNet firmware 4.x also has "DNS Rebinding Attack Protection" under
            # Network -> DNS. If \(hostname) still doesn't resolve for the car, turn it off there.

            """
        } ?? ""
        return """
        #!/bin/sh
        # Dashcast: travel-router setup (topology B) for GL.iNet / OpenWrt.
        #
        # What this does:
        #   1. Adds a static route \(serviceAddress)/32 -> \(mac) (this Mac), so the car can
        #      reach \(carURL) through the router. Tesla's browser refuses
        #      private IPs, so Dashcast serves from \(serviceAddress) on the Mac's loopback.
        \(steps)
        #
        # Run it on the router (Dashcast's "Apply over SSH" does exactly this):
        #   ssh root@192.168.8.1 'sh -s' < dashcast-router.sh
        # It's safe to run again: it replaces its own route instead of adding a duplicate.
        #
        # IMPORTANT: reserve the Mac's DHCP lease so \(mac) never changes.
        #   GL.iNet admin UI (http://192.168.8.1) -> Clients -> this Mac -> Reserve IP
        #   (firmware 3.x: More Settings -> LAN IP -> Static IP Address Binding).
        #   If the Mac ever gets a different address, run this script again.

        set -e
        MAC_IP='\(mac)'

        # --- 1. Static route \(serviceAddress)/32 -> Mac ---------------------------------
        uci -q delete network.\(routeSection) || true
        uci add network route >/dev/null
        uci rename network.@route[-1]='\(routeSection)'
        uci set network.\(routeSection).interface='lan'
        uci set network.\(routeSection).target='\(serviceAddress)'
        uci set network.\(routeSection).netmask='255.255.255.255'
        uci set network.\(routeSection).gateway="$MAC_IP"
        uci commit network
        /etc/init.d/network reload
        \(dnsSection)
        sleep 2
        echo "Dashcast: route \(serviceAddress)/32 via $MAC_IP installed."
        ip route get \(serviceAddress) 2>/dev/null || true

        """
    }

    // MARK: SSH

    struct SSHInvocation: Equatable {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
    }

    static let passwordEnvironmentKey = "DASHCAST_SSH_PASSWORD"

    /// The askpass helper prints the password from the environment. The password itself is never
    /// written to disk or passed on a command line.
    static let askpassScript = "#!/bin/sh\nprintf '%s\\n' \"$\(passwordEnvironmentKey)\"\n"

    static func validateHost(_ host: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]")
        guard !host.isEmpty, !host.hasPrefix("-"), host.unicodeScalars.allSatisfy(allowed.contains) else {
            throw NetworkError.invalidArgument("Router address \"\(host)\" isn't a valid host name or IP.")
        }
    }

    static func validateUser(_ user: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !user.isEmpty, !user.hasPrefix("-"), user.unicodeScalars.allSatisfy(allowed.contains) else {
            throw NetworkError.invalidArgument("Router user \"\(user)\" isn't a valid user name.")
        }
    }

    /// `/usr/bin/ssh` with a forced askpass, password auth only, and trust-on-first-use host keys.
    /// The script goes to `sh -s` on stdin.
    static func sshInvocation(host: String, user: String, password: String, askpassPath: String,
                              baseEnvironment: [String: String]) throws -> SSHInvocation {
        try validateHost(host)
        try validateUser(user)
        let arguments = [
            "-T",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-o", "PubkeyAuthentication=no",
            "-o", "PreferredAuthentications=keyboard-interactive,password",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "-l", user,
            host,
            "sh -s",
        ]
        var environment = baseEnvironment
        environment.removeValue(forKey: "SSH_AUTH_SOCK")
        environment["SSH_ASKPASS"] = askpassPath
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
        environment[passwordEnvironmentKey] = password
        return SSHInvocation(executable: "/usr/bin/ssh", arguments: arguments, environment: environment)
    }

    /// Writes the askpass helper (0700) into a fresh private temp directory. Caller deletes the directory.
    static func writeAskpass() throws -> (directory: URL, script: URL) {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("dashcast-askpass-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let script = directory.appendingPathComponent("askpass.sh")
        try Data(askpassScript.utf8).write(to: script)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return (directory, script)
    }
}
