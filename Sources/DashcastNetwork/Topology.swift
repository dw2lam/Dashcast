import DashcastContracts
import Darwin
import Foundation
import SystemConfiguration

// MARK: - IPv4 helpers

enum IPv4 {
    /// Strict dotted-quad parse ("10.1.10.39" → 0x0A010A27).
    static func parse(_ string: String) -> UInt32? {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let octet = UInt32(part), octet <= 255 else { return nil }
            value = value << 8 | octet
        }
        return value
    }

    static func isValid(_ string: String) -> Bool { parse(string) != nil }

    /// Is `string` inside the subnet of `address` with dotted `netmask`?
    static func contains(_ string: String, subnetOf address: String, netmask: String) -> Bool {
        guard let a = parse(string), let b = parse(address), let mask = parse(netmask), mask != 0 else { return false }
        return a & mask == b & mask
    }

    static func contains(_ string: String, network: String, prefix: Int) -> Bool {
        guard let address = parse(string), let base = parse(network) else { return false }
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << UInt32(32 - prefix)
        return address & mask == base & mask
    }

    /// RFC 1918 — the ranges the Tesla browser refuses.
    static func isPrivate(_ string: String) -> Bool {
        contains(string, network: "10.0.0.0", prefix: 8)
            || contains(string, network: "172.16.0.0", prefix: 12)
            || contains(string, network: "192.168.0.0", prefix: 16)
    }

    static func isLinkLocal(_ string: String) -> Bool { contains(string, network: "169.254.0.0", prefix: 16) }
    static func isLoopback(_ string: String) -> Bool { contains(string, network: "127.0.0.0", prefix: 8) }

    /// iPhone Personal Hotspot hands out 172.20.10.0/28 (Wi-Fi and USB alike).
    static func isIPhoneHotspot(_ string: String) -> Bool { contains(string, network: "172.20.10.0", prefix: 24) }

    /// An address a LAN peer could plausibly reach.
    static func isUsable(_ string: String) -> Bool {
        guard let value = parse(string), value != 0 else { return false }
        return !isLinkLocal(string) && !isLoopback(string)
    }
}

// MARK: - Snapshot of the Mac's interfaces (input to the pure classifier)

enum InterfaceKind: String, Sendable {
    case wifi, ethernet, iPhoneUSB, bridge, other
}

struct InterfaceAddress: Equatable, Sendable {
    var name: String
    var address: String
    var netmask: String?
    var isUp: Bool

    init(name: String, address: String, netmask: String? = nil, isUp: Bool = true) {
        self.name = name; self.address = address; self.netmask = netmask; self.isUp = isUp
    }
}

struct InterfaceSnapshot: Equatable, Sendable {
    /// Every IPv4 address on every interface (getifaddrs).
    var addresses: [InterfaceAddress]
    /// BSD name of the primary (default-route) interface (SCDynamicStore State:/Network/Global/IPv4).
    var primaryInterface: String?
    /// Default gateway of the primary interface.
    var gateway: String?
    /// Hardware kinds by BSD name (SCNetworkInterfaceCopyAll).
    var kinds: [String: InterfaceKind]
    var displayNames: [String: String]

    init(addresses: [InterfaceAddress], primaryInterface: String? = nil, gateway: String? = nil,
         kinds: [String: InterfaceKind] = [:], displayNames: [String: String] = [:]) {
        self.addresses = addresses; self.primaryInterface = primaryInterface; self.gateway = gateway
        self.kinds = kinds; self.displayNames = displayNames
    }
}

struct TopologyResult: Equatable, Sendable {
    var topology: Topology
    /// Interface the car reaches the Mac through (bridge100 for the hotspot, en* otherwise).
    var interfaceName: String?
    var macLANAddress: String?
    /// Hotspot only: the interface carrying the Mac's own internet.
    var uplinkInterface: String?
    var uplinkDescription: String?
    var gateway: String?
    var aliasActive: Bool
    /// One-line human description of the topology.
    var detail: String
    /// A non-loopback interface whose subnet contains the service address (e.g. Internet Sharing
    /// moved onto 203.0.113.0/24 by SideDisplay). Peers then treat the address as on-link and ARP
    /// for it, and a lo0 alias never answers, so the car can't connect.
    var conflict: ServiceAddressConflict? = nil
}

struct ServiceAddressConflict: Equatable, Sendable {
    var interface: String
    var address: String
    var netmask: String
}

// MARK: - Classifier (pure)

enum TopologyClassifier {
    static func classify(_ snapshot: InterfaceSnapshot,
                         serviceAddress: String = DashcastDefaults.serviceAddress) -> TopologyResult {
        var result = classifyTopology(snapshot, serviceAddress: serviceAddress)
        result.conflict = conflict(in: snapshot, serviceAddress: serviceAddress)
        return result
    }

    static func conflict(in snapshot: InterfaceSnapshot, serviceAddress: String) -> ServiceAddressConflict? {
        snapshot.addresses
            .filter { $0.isUp && $0.name != "lo0" && $0.address != serviceAddress }
            .first { a in a.netmask.map { IPv4.contains(serviceAddress, subnetOf: a.address, netmask: $0) } ?? false }
            .map { ServiceAddressConflict(interface: $0.name, address: $0.address, netmask: $0.netmask ?? "") }
    }

    private static func classifyTopology(_ snapshot: InterfaceSnapshot, serviceAddress: String) -> TopologyResult {
        let aliasActive = snapshot.addresses.contains { $0.name == "lo0" && $0.address == serviceAddress }
        let up = snapshot.addresses.filter { $0.isUp && IPv4.isValid($0.address) }

        // A — Internet Sharing: bridge100 (bridge101… for extra shares), normally 192.168.2.1.
        // Any usable address counts: tools like SideDisplay move the share onto public-looking ranges.
        let bridges = up.filter { isSharingBridge($0.name) && IPv4.isUsable($0.address) }
        let bridge = bridges.first { $0.name == "bridge100" && $0.address == "192.168.2.1" }
            ?? bridges.sorted { $0.name < $1.name }.first
        if let bridge {
            let uplink = lanCandidate(in: snapshot, excluding: [bridge.name])
            let uplinkText = uplink.map { describe($0, in: snapshot) }
            var detail = "Mac hotspot: Internet Sharing on \(bridge.name) (\(bridge.address))"
            if let uplinkText {
                detail += ", uplink \(uplinkText)."
            } else {
                detail += ", but no uplink is connected, so the car will get no internet."
            }
            return TopologyResult(topology: .macHotspot, interfaceName: bridge.name, macLANAddress: bridge.address,
                                  uplinkInterface: uplink?.name, uplinkDescription: uplinkText,
                                  gateway: nil, aliasActive: aliasActive, detail: detail)
        }

        guard let lan = lanCandidate(in: snapshot, excluding: []) else {
            return TopologyResult(topology: .offline, interfaceName: nil, macLANAddress: nil,
                                  uplinkInterface: nil, uplinkDescription: nil, gateway: nil,
                                  aliasActive: aliasActive, detail: "Offline: no usable network address.")
        }
        let gateway = lan.name == snapshot.primaryInterface ? snapshot.gateway : nil

        // Joined an iPhone's hotspot (Wi-Fi, or USB tethering without Internet Sharing).
        if IPv4.isIPhoneHotspot(lan.address) {
            let how = kind(of: lan, in: snapshot) == .wifi ? "iPhone hotspot over Wi-Fi" : "iPhone tethering"
            return TopologyResult(topology: .phoneHotspot, interfaceName: lan.name, macLANAddress: lan.address,
                                  uplinkInterface: lan.name, uplinkDescription: nil, gateway: gateway,
                                  aliasActive: aliasActive,
                                  detail: "\(how) (\(lan.name), \(lan.address)): the car can't reach the Mac this way.")
        }

        // B — travel router / any other LAN.
        var detail = "Router/LAN via \(describe(lan, in: snapshot))"
        if let gateway { detail += ", gateway \(gateway)" }
        detail += ". The router needs a static route \(serviceAddress)/32 → \(lan.address)."
        if !IPv4.isPrivate(lan.address) { detail += " (Note: \(lan.address) isn't a private LAN address.)" }
        return TopologyResult(topology: .router, interfaceName: lan.name, macLANAddress: lan.address,
                              uplinkInterface: lan.name, uplinkDescription: nil, gateway: gateway,
                              aliasActive: aliasActive, detail: detail)
    }

    /// bridge100, bridge101… — the bridges Internet Sharing creates. (bridge0 is Thunderbolt Bridge.)
    static func isSharingBridge(_ name: String) -> Bool {
        guard name.hasPrefix("bridge"), let n = Int(name.dropFirst("bridge".count)) else { return false }
        return n >= 100
    }

    /// The physical LAN interface: the primary interface when it is an en* port, otherwise the best
    /// en* port with a usable address (VPNs like Tailscale/ZeroTier/utun are never the LAN).
    static func lanCandidate(in snapshot: InterfaceSnapshot, excluding: Set<String>) -> InterfaceAddress? {
        let candidates = snapshot.addresses.filter {
            $0.isUp && $0.name.hasPrefix("en") && !excluding.contains($0.name) && IPv4.isUsable($0.address)
        }
        if let primary = snapshot.primaryInterface, let hit = candidates.first(where: { $0.name == primary }) {
            return hit
        }
        func rank(_ a: InterfaceAddress) -> Int {
            switch kind(of: a, in: snapshot) {
            case .ethernet: return 0
            case .wifi: return 1
            case .iPhoneUSB: return 2
            default: return 3
            }
        }
        return candidates.sorted { (rank($0), $0.name) < (rank($1), $1.name) }.first
    }

    static func kind(of a: InterfaceAddress, in snapshot: InterfaceSnapshot) -> InterfaceKind {
        let known = snapshot.kinds[a.name]
        let display = snapshot.displayNames[a.name] ?? ""
        if display.localizedCaseInsensitiveContains("iPhone") { return .iPhoneUSB }
        if known == .ethernet, IPv4.isIPhoneHotspot(a.address) { return .iPhoneUSB }
        return known ?? .other
    }

    static func describe(_ a: InterfaceAddress, in snapshot: InterfaceSnapshot) -> String {
        let label: String
        switch kind(of: a, in: snapshot) {
        case .wifi: label = "Wi-Fi"
        case .ethernet: label = snapshot.displayNames[a.name] ?? "Ethernet"
        case .iPhoneUSB: label = "iPhone USB"
        case .bridge: label = "Bridge"
        case .other: label = snapshot.displayNames[a.name] ?? "Network"
        }
        return "\(label) (\(a.name), \(a.address))"
    }
}

// MARK: - Live scan (getifaddrs + SystemConfiguration)

enum InterfaceScanner {
    static func snapshot() -> InterfaceSnapshot {
        var snapshot = InterfaceSnapshot(addresses: ipv4Addresses())
        (snapshot.primaryInterface, snapshot.gateway) = primaryInterfaceAndGateway()
        (snapshot.kinds, snapshot.displayNames) = hardwareKinds()
        return snapshot
    }

    static func ipv4Addresses() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [InterfaceAddress] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let sa = entry.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let flags = Int32(entry.ifa_flags)
            result.append(InterfaceAddress(
                name: String(cString: entry.ifa_name),
                address: ipv4String(sa),
                netmask: entry.ifa_netmask.map(ipv4String),
                isUp: flags & IFF_UP != 0 && flags & IFF_RUNNING != 0))
        }
        return result
    }

    private static func ipv4String(_ sa: UnsafeMutablePointer<sockaddr>) -> String {
        var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return "" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    static func primaryInterfaceAndGateway() -> (String?, String?) {
        guard let store = SCDynamicStoreCreate(nil, "online.davidlam.dashcast" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return (nil, nil) }
        return (value["PrimaryInterface"] as? String, value["Router"] as? String)
    }

    static func hardwareKinds() -> ([String: InterfaceKind], [String: String]) {
        var kinds: [String: InterfaceKind] = [:]
        var names: [String: String] = [:]
        let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        for interface in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            let type = SCNetworkInterfaceGetInterfaceType(interface) as String?
            let display = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
            if let display { names[bsd] = display }
            if type == kSCNetworkInterfaceTypeIEEE80211 as String {
                kinds[bsd] = .wifi
            } else if type == kSCNetworkInterfaceTypeEthernet as String {
                kinds[bsd] = (display ?? "").localizedCaseInsensitiveContains("iPhone") ? .iPhoneUSB : .ethernet
            } else if bsd.hasPrefix("bridge") {
                kinds[bsd] = .bridge
            } else {
                kinds[bsd] = .other
            }
        }
        return (kinds, names)
    }
}
