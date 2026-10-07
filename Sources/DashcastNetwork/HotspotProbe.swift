import DashcastContracts
import Foundation

// MARK: - Internet Sharing settings (com.apple.nat.plist)

/// What System Settings ▸ Sharing ▸ Internet Sharing saved. The file is world-readable; a missing
/// key or an unexpected type reads as "not set".
struct NATPreferences: Equatable, Sendable {
    /// NAT.Enabled: the Internet Sharing switch.
    var enabled = false
    /// NAT.PrimaryInterface.Device: "Share your connection from" (en13).
    var primaryDevice: String?
    /// NAT.PrimaryInterface.PrimaryUserReadable ("iPhone USB").
    var primaryName: String?
    /// NAT.SharingDevices: "To devices using" (en0 for Wi-Fi).
    var sharingDevices: [String] = []
    /// NAT.AirPort.NetworkName.
    var networkName: String?
    /// NAT.AirPort.Channel (0 = automatic).
    var channel: Int?

    /// Binary or XML plist. nil when it isn't a plist with a NAT dictionary.
    static func parse(_ data: Data) -> NATPreferences? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let nat = root["NAT"] as? [String: Any] else { return nil }
        var prefs = NATPreferences()
        prefs.enabled = flag(nat["Enabled"]) ?? false
        if let primary = nat["PrimaryInterface"] as? [String: Any] {
            prefs.primaryDevice = nonEmpty(primary["Device"])
            prefs.primaryName = nonEmpty(primary["PrimaryUserReadable"])
        }
        prefs.sharingDevices = (nat["SharingDevices"] as? [Any])?.compactMap { nonEmpty($0) } ?? []
        if let airport = nat["AirPort"] as? [String: Any] {
            prefs.networkName = nonEmpty(airport["NetworkName"])
            prefs.channel = (airport["Channel"] as? NSNumber)?.intValue
        }
        return prefs
    }

    /// 0/1 integers and real booleans alike.
    private static func flag(_ value: Any?) -> Bool? {
        (value as? NSNumber).map { $0.intValue != 0 }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

// MARK: - bootpd leases (/var/db/dhcpd_leases)

struct DHCPLease: Equatable, Sendable {
    /// The host name the client sent, if any.
    var name: String?
    var address: String
    /// Normalised "4c:fc:aa:01:6f:1d" (bootpd writes "1,4c:fc:aa:1:6f:1d": a type prefix, unpadded octets).
    var hardwareAddress: String?
    /// When the lease runs out (bootpd's `lease=` is the expiry, epoch seconds in hex).
    var expiry: Date?
}

enum DHCPLeases {
    /// Every `{ key=value … }` block with a valid ip_address. Unknown keys are ignored.
    static func parse(_ text: String) -> [DHCPLease] {
        var leases: [DHCPLease] = []
        var fields: [String: String]?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "{" {
                fields = [:]
            } else if line == "}" {
                if let fields, let lease = lease(from: fields) { leases.append(lease) }
                fields = nil
            } else if fields != nil, let equals = line.firstIndex(of: "=") {
                fields?[String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
        }
        return leases
    }

    private static func lease(from fields: [String: String]) -> DHCPLease? {
        guard let address = fields["ip_address"], IPv4.isValid(address) else { return nil }
        let name = fields["name"].flatMap { $0.isEmpty ? nil : $0 }
        let expiry = fields["lease"].flatMap { value -> Date? in
            let hex = value.lowercased().hasPrefix("0x") ? String(value.dropFirst(2)) : value
            return UInt64(hex, radix: 16).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        }
        return DHCPLease(name: name, address: address,
                         hardwareAddress: fields["hw_address"].flatMap(normalizeHardwareAddress), expiry: expiry)
    }

    /// "1,4c:fc:aa:1:6f:1d" → "4c:fc:aa:01:6f:1d". nil unless it's six hex octets.
    static func normalizeHardwareAddress(_ raw: String) -> String? {
        let value = raw.split(separator: ",").last.map(String.init) ?? raw
        let octets = value.split(separator: ":", omittingEmptySubsequences: false)
        guard octets.count == 6 else { return nil }
        var result: [String] = []
        for octet in octets {
            guard (1...2).contains(octet.count), let byte = UInt8(octet, radix: 16) else { return nil }
            result.append(String(format: "%02x", byte))
        }
        return result.joined(separator: ":")
    }
}

// MARK: - Tesla detection

enum TeslaHardware {
    /// IEEE registrations for Tesla, Inc. (maclookup.app/vendors/tesla-inc, Oct 2026): six MA-L
    /// blocks; the car seen on the hotspot (Model 3, MCU2) was 4c:fc:aa.
    static let ouis: Set<String> = ["0c:29:8f", "4c:fc:aa", "54:f8:f0", "90:e6:43", "98:ed:5c", "d4:4f:14"]
    /// …and one MA-M block, DC:44:27:1 (the first 28 bits).
    static let mediumBlocks: [String] = ["dc:44:27:1"]

    /// The DHCP host name says Tesla ("Tesla_Model_3"), or the hardware address is Tesla's.
    static func isTesla(name: String?, hardwareAddress: String?) -> Bool {
        if let name, name.localizedCaseInsensitiveContains("tesla") { return true }
        guard let mac = hardwareAddress.flatMap(DHCPLeases.normalizeHardwareAddress) else { return false }
        return ouis.contains(String(mac.prefix(8))) || mediumBlocks.contains { mac.hasPrefix($0) }
    }
}

// MARK: - Probe (pure)

/// Builds `HotspotStatus` from the interfaces, Internet Sharing's settings, bootpd's leases and the
/// ARP table. Everything is passed in, so tests feed it fakes.
enum HotspotProbe {
    static let leasesPath = "/var/db/dhcpd_leases"
    /// Bridges assume /24 when getifaddrs gave no netmask.
    static let defaultBridgeNetmask = "255.255.255.0"

    struct Inputs {
        var snapshot: InterfaceSnapshot
        var nat: NATPreferences?
        var leases: [DHCPLease] = []
        var neighbours: [ARPTable.Entry] = []
        var now = Date()
    }

    static func status(_ inputs: Inputs) -> HotspotStatus {
        let snapshot = inputs.snapshot
        let nat = inputs.nat ?? NATPreferences()
        var status = HotspotStatus()
        let bridges = sharingBridges(in: snapshot)
        let wifi = wifiInterfaces(in: snapshot)

        status.sharingOn = !bridges.isEmpty
        status.enabledInSettings = nat.enabled
        status.sharesToWiFi = nat.sharingDevices.contains { wifi.contains($0) }
        status.networkName = nat.networkName
        status.channel = nat.channel

        // The Mac's own internet over Wi-Fi (it joined a network). While it hosts, its Wi-Fi is a
        // bridge member with no address of its own.
        let wifiAddress = snapshot.addresses.first { wifi.contains($0.name) && $0.isUp && IPv4.isUsable($0.address) }
        if let wifiAddress, !status.sharingOn {
            status.wifiIsUplink = true
            let isPrimary = wifiAddress.name == snapshot.primaryInterface
            status.wifiUplinkIsPhone = IPv4.isIPhoneHotspot(wifiAddress.address)
                || (isPrimary && (snapshot.androidMetered || IPv4.isAndroidHotspotGateway(snapshot.gateway)))
        }

        status.uplinks = uplinks(snapshot: snapshot, nat: nat, wifi: wifi)
        status.shareFrom = shareFrom(snapshot: snapshot, nat: nat, present: status.uplinks)
        status.devices = devices(leases: inputs.leases, bridges: bridges, neighbours: inputs.neighbours, now: inputs.now)
        return status
    }

    /// Leased addresses on a sharing bridge that the ARP table can't vouch for yet. Nudging them
    /// (no waiting) lets the next refresh see whoever answers.
    static func addressesToNudge(_ inputs: Inputs, limit: Int = 16) -> [String] {
        let bridges = sharingBridges(in: inputs.snapshot)
        return Array(liveLeases(inputs.leases, on: bridges, now: inputs.now)
            .filter { lease, bridge in
                !inputs.neighbours.contains { $0.address == lease.address && $0.interface == bridge.name && $0.complete }
            }
            .map(\.0.address)
            .prefix(limit))
    }

    // MARK: Pieces

    /// bridge100… up with a usable address (the same test the topology classifier uses).
    static func sharingBridges(in snapshot: InterfaceSnapshot) -> [InterfaceAddress] {
        snapshot.addresses
            .filter { $0.isUp && TopologyClassifier.isSharingBridge($0.name) && IPv4.isUsable($0.address) }
            .sorted { $0.name < $1.name }
    }

    /// BSD names SystemConfiguration calls Wi-Fi. If the hardware scan came back empty, en0.
    static func wifiInterfaces(in snapshot: InterfaceSnapshot) -> Set<String> {
        let names = Set(snapshot.kinds.filter { $0.value == .wifi }.keys)
        return names.isEmpty && snapshot.kinds.isEmpty ? ["en0"] : names
    }

    static func isConnected(_ name: String, in snapshot: InterfaceSnapshot) -> Bool {
        snapshot.addresses.contains { $0.name == name && $0.isUp && IPv4.isUsable($0.address) }
    }

    /// Never an uplink: tunnels and VPNs (utun, ZeroTier's feth, ipsec), bridges, Apple's own links.
    static let virtualPrefixes = ["utun", "feth", "ipsec", "ppp", "gif", "stf", "awdl", "llw", "ap", "anpi",
                                  "bridge", "lo", "zt", "tun", "tap", "vmenet", "nan"]

    /// Ports that are always there and only matter once something is plugged in: Apple silicon's
    /// built-in "Ethernet Adapter (en3)" functions and the Thunderbolt ports Thunderbolt Bridge owns
    /// ("Thunderbolt 1"). A Thunderbolt Ethernet adapter is "Thunderbolt Ethernet", so it stays.
    static func isAlwaysPresentPort(_ displayName: String) -> Bool {
        if displayName.hasPrefix("Ethernet Adapter (") { return true }
        let parts = displayName.split(separator: " ")
        return parts.count == 2 && parts[0] == "Thunderbolt" && parts[1].allSatisfy(\.isNumber)
    }

    /// Interfaces that could feed the hotspot: Ethernet-type ports SystemConfiguration knows (USB/
    /// Thunderbolt Ethernet, iPhone USB, Bluetooth PAN, which is Ethernet-type too), connected first,
    /// then the one Internet Sharing is set to, then iPhone, Ethernet, the rest. The configured
    /// "share from" device is listed even when it isn't plugged in, so the UI can ask for it.
    static func uplinks(snapshot: InterfaceSnapshot, nat: NATPreferences, wifi: Set<String>) -> [HotspotStatus.Uplink] {
        func excluded(_ name: String) -> Bool {
            wifi.contains(name) || nat.sharingDevices.contains(name) || virtualPrefixes.contains { name.hasPrefix($0) }
        }
        var entries: [(uplink: HotspotStatus.Uplink, rank: Int)] = []
        for (name, kind) in snapshot.kinds where !excluded(name) {
            let display = snapshot.displayNames[name] ?? name
            let rank: Int
            switch kind {
            case .iPhoneUSB: rank = 0
            case .ethernet: rank = display.localizedCaseInsensitiveContains("Bluetooth") ? 2 : 1
            case .other where display.localizedCaseInsensitiveContains("Bluetooth"): rank = 2
            default: continue
            }
            let connected = isConnected(name, in: snapshot)
            if !connected, isAlwaysPresentPort(display) { continue }
            entries.append((HotspotStatus.Uplink(name: display, interface: name, connected: connected), rank))
        }
        if let device = nat.primaryDevice, !excluded(device),
           !entries.contains(where: { $0.uplink.interface == device || (nat.primaryName != nil && $0.uplink.name == nat.primaryName) }) {
            let name = nat.primaryName ?? snapshot.displayNames[device] ?? device
            entries.append((HotspotStatus.Uplink(name: name, interface: device, connected: isConnected(device, in: snapshot)),
                            name.localizedCaseInsensitiveContains("iPhone") ? 0 : 1))
        }
        let preferred = nat.primaryDevice
        return entries.sorted { a, b in
            func key(_ e: (uplink: HotspotStatus.Uplink, rank: Int)) -> (Int, Int, Int, String) {
                (e.uplink.connected ? 0 : 1,
                 e.uplink.interface == preferred || e.uplink.name == nat.primaryName ? 0 : 1,
                 e.rank, e.uplink.interface)
            }
            return key(a) < key(b)
        }.map(\.uplink)
    }

    /// NAT.PrimaryInterface. A USB device can come back under another BSD name (en13 → en7); when
    /// the saved one is gone and a present port has the saved display name, that port is the one.
    static func shareFrom(snapshot: InterfaceSnapshot, nat: NATPreferences,
                          present: [HotspotStatus.Uplink]) -> HotspotStatus.Uplink? {
        guard var device = nat.primaryDevice else { return nil }
        let known = snapshot.kinds[device] != nil || snapshot.addresses.contains { $0.name == device }
        if !known, let name = nat.primaryName,
           let renamed = present.first(where: { $0.name == name && $0.interface != device && snapshot.kinds[$0.interface] != nil }) {
            device = renamed.interface
        }
        let name = nat.primaryName ?? snapshot.displayNames[device] ?? device
        return HotspotStatus.Uplink(name: name, interface: device, connected: isConnected(device, in: snapshot))
    }

    /// Unexpired leases inside a sharing bridge's subnet (bootpd also leases to other subnets,
    /// e.g. 192.168.64.x for virtual machines), paired with that bridge.
    static func liveLeases(_ leases: [DHCPLease], on bridges: [InterfaceAddress],
                           now: Date) -> [(DHCPLease, InterfaceAddress)] {
        var seen: Set<String> = []
        var result: [(DHCPLease, InterfaceAddress)] = []
        for lease in leases {
            if let expiry = lease.expiry, expiry <= now { continue }
            guard lease.address != "", !seen.contains(lease.address),
                  let bridge = bridges.first(where: {
                      lease.address != $0.address
                          && IPv4.contains(lease.address, subnetOf: $0.address, netmask: $0.netmask ?? defaultBridgeNetmask)
                  }) else { continue }
            seen.insert(lease.address)
            result.append((lease, bridge))
        }
        return result
    }

    /// Leased on a sharing bridge and resolved in ARP on that bridge. Teslas first.
    static func devices(leases: [DHCPLease], bridges: [InterfaceAddress], neighbours: [ARPTable.Entry],
                        now: Date) -> [HotspotStatus.Device] {
        liveLeases(leases, on: bridges, now: now)
            .filter { lease, bridge in
                neighbours.contains { $0.address == lease.address && $0.interface == bridge.name && $0.complete }
            }
            .map { lease, _ in
                HotspotStatus.Device(name: lease.name, address: lease.address,
                                     isTesla: TeslaHardware.isTesla(name: lease.name, hardwareAddress: lease.hardwareAddress))
            }
            .sorted { a, b in
                if a.isTesla != b.isTesla { return a.isTesla }
                return (IPv4.parse(a.address) ?? 0) < (IPv4.parse(b.address) ?? 0)
            }
    }
}
