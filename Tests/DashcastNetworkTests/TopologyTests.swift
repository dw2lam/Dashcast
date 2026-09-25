import DashcastContracts
import XCTest
@testable import DashcastNetwork

final class TopologyTests: XCTestCase {
    private let lo = InterfaceAddress(name: "lo0", address: "127.0.0.1", netmask: "255.0.0.0")
    private let alias = InterfaceAddress(name: "lo0", address: svc, netmask: "255.255.255.255")
    private let tailscale = InterfaceAddress(name: "utun4", address: "100.107.116.23")
    private let zerotier = InterfaceAddress(name: "feth2326", address: "10.147.15.122", netmask: "255.255.255.0")

    // A — Mac is the hotspot (Internet Sharing), uplink = iPhone over USB.
    func testMacHotspotWithIPhoneUSBUplink() {
        let snapshot = InterfaceSnapshot(
            addresses: [lo, tailscale,
                        InterfaceAddress(name: "bridge100", address: "192.168.2.1", netmask: "255.255.255.0"),
                        InterfaceAddress(name: "en7", address: "172.20.10.2", netmask: "255.255.255.240")],
            primaryInterface: "en7", gateway: "172.20.10.1",
            kinds: ["en0": .wifi, "en7": .ethernet], displayNames: ["en7": "iPhone USB", "en0": "Wi-Fi"])
        let result = TopologyClassifier.classify(snapshot)
        XCTAssertEqual(result.topology, .macHotspot)
        XCTAssertEqual(result.interfaceName, "bridge100")
        XCTAssertEqual(result.macLANAddress, "192.168.2.1")
        XCTAssertEqual(result.uplinkInterface, "en7")
        XCTAssertEqual(result.uplinkDescription, "iPhone USB (en7, 172.20.10.2)")
        XCTAssertFalse(result.aliasActive)
        XCTAssertTrue(result.detail.contains("Internet Sharing on bridge100"), result.detail)
    }

    func testMacHotspotWithEthernetUplinkAndAlias() {
        let snapshot = InterfaceSnapshot(
            addresses: [lo, alias,
                        InterfaceAddress(name: "bridge100", address: "192.168.2.1"),
                        InterfaceAddress(name: "en5", address: "192.168.1.50")],
            primaryInterface: "en5", kinds: ["en5": .ethernet], displayNames: ["en5": "USB 10/100/1000 LAN"])
        let result = TopologyClassifier.classify(snapshot)
        XCTAssertEqual(result.topology, .macHotspot)
        XCTAssertEqual(result.uplinkDescription, "USB 10/100/1000 LAN (en5, 192.168.1.50)")
        XCTAssertTrue(result.aliasActive)
    }

    /// SideDisplay-style Internet Sharing on 203.0.113.1/24: still the Mac hotspot, but the subnet
    /// contains the service address, which must be flagged (the car would ARP for it and fail).
    func testHotspotOnServiceSubnetIsDetectedAndFlagged() throws {
        let snapshot = InterfaceSnapshot(
            addresses: [lo, alias,
                        InterfaceAddress(name: "bridge100", address: "203.0.113.1", netmask: "255.255.255.0"),
                        InterfaceAddress(name: "en7", address: "172.20.10.2", netmask: "255.255.255.240")],
            primaryInterface: "en7", kinds: ["en7": .ethernet], displayNames: ["en7": "iPhone USB"])
        let result = TopologyClassifier.classify(snapshot)
        XCTAssertEqual(result.topology, .macHotspot)
        XCTAssertEqual(result.macLANAddress, "203.0.113.1")
        let conflict = try XCTUnwrap(result.conflict)
        XCTAssertEqual(conflict, ServiceAddressConflict(interface: "bridge100", address: "203.0.113.1", netmask: "255.255.255.0"))

        var status = NetworkStatus()
        status.topology = .macHotspot
        let summary = NetworkManager.summary(status, topology: result, now: Date())
        XCTAssertTrue(summary.contains("Conflict: bridge100 is on 203.0.113.1/255.255.255.0"), summary)
        XCTAssertTrue(summary.contains("192.168.2.x"), summary)
    }

    func testNoConflictOnNormalNetworks() {
        let normal = InterfaceSnapshot(
            addresses: [lo, alias, InterfaceAddress(name: "bridge100", address: "192.168.2.1", netmask: "255.255.255.0"),
                        InterfaceAddress(name: "en0", address: "10.1.10.39", netmask: "255.255.254.0")])
        XCTAssertNil(TopologyClassifier.classify(normal).conflict)
        XCTAssertTrue(IPv4.contains("203.0.113.77", subnetOf: "203.0.113.1", netmask: "255.255.255.0"))
        XCTAssertFalse(IPv4.contains("203.0.113.77", subnetOf: "203.0.113.1", netmask: "255.255.255.192"))
    }

    func testMacHotspotWithoutUplinkStillHotspot() {
        let snapshot = InterfaceSnapshot(addresses: [lo, InterfaceAddress(name: "bridge100", address: "192.168.2.1")])
        let result = TopologyClassifier.classify(snapshot)
        XCTAssertEqual(result.topology, .macHotspot)
        XCTAssertNil(result.uplinkInterface)
        XCTAssertTrue(result.detail.contains("no uplink"), result.detail)
    }

    func testDownBridgeIsNotAHotspot() {
        let snapshot = InterfaceSnapshot(
            addresses: [InterfaceAddress(name: "bridge100", address: "192.168.2.1", isUp: false),
                        InterfaceAddress(name: "en0", address: "192.168.8.20")],
            primaryInterface: "en0", kinds: ["en0": .wifi])
        XCTAssertEqual(TopologyClassifier.classify(snapshot).topology, .router)
    }

    func testThunderboltBridge0IsNotInternetSharing() {
        XCTAssertFalse(TopologyClassifier.isSharingBridge("bridge0"))
        XCTAssertTrue(TopologyClassifier.isSharingBridge("bridge100"))
        XCTAssertTrue(TopologyClassifier.isSharingBridge("bridge101"))
        XCTAssertFalse(TopologyClassifier.isSharingBridge("bridgeX"))
    }

    // Joined an iPhone's hotspot over Wi-Fi.
    func testPhoneHotspotOverWiFi() {
        let snapshot = InterfaceSnapshot(
            addresses: [lo, InterfaceAddress(name: "en0", address: "172.20.10.3", netmask: "255.255.255.240")],
            primaryInterface: "en0", gateway: "172.20.10.1", kinds: ["en0": .wifi])
        let result = TopologyClassifier.classify(snapshot)
        XCTAssertEqual(result.topology, .phoneHotspot)
        XCTAssertEqual(result.interfaceName, "en0")
        XCTAssertEqual(result.macLANAddress, "172.20.10.3")
        XCTAssertTrue(result.detail.hasPrefix("iPhone hotspot over Wi-Fi"), result.detail)
    }

    // Joined an Android hotspot: the lease carries ANDROID_METERED (newer Android randomises the subnet).
    func testAndroidHotspotByDHCPVendorOption() {
        let snapshot = InterfaceSnapshot(
            addresses: [lo, InterfaceAddress(name: "en0", address: "192.168.212.57", netmask: "255.255.255.0")],
            primaryInterface: "en0", gateway: "192.168.212.200", kinds: ["en0": .wifi], androidMetered: true)
        let result = TopologyClassifier.classify(snapshot)
        XCTAssertEqual(result.topology, .phoneHotspot)
        XCTAssertEqual(result.macLANAddress, "192.168.212.57")
        XCTAssertTrue(result.detail.hasPrefix("Android hotspot over Wi-Fi"), result.detail)
    }

    // Older Android hotspots always use 192.168.43.1 as the gateway.
    func testAndroidHotspotByClassicGateway() {
        let snapshot = InterfaceSnapshot(
            addresses: [lo, InterfaceAddress(name: "en0", address: "192.168.43.20", netmask: "255.255.255.0")],
            primaryInterface: "en0", gateway: "192.168.43.1", kinds: ["en0": .wifi])
        XCTAssertEqual(TopologyClassifier.classify(snapshot).topology, .phoneHotspot)
    }

    // A GL.iNet travel router is still B, and Android metering on a non-primary port doesn't count.
    func testTravelRouterIsNotMistakenForAndroid() {
        let router = InterfaceSnapshot(
            addresses: [lo, InterfaceAddress(name: "en0", address: "192.168.8.123")],
            primaryInterface: "en0", gateway: "192.168.8.1", kinds: ["en0": .wifi])
        XCTAssertEqual(TopologyClassifier.classify(router).topology, .router)
        XCTAssertFalse(IPv4.isAndroidHotspotGateway("192.168.8.1"))
    }

    // B — travel router: private LAN address on the primary interface. VPNs are ignored.
    func testRouterIgnoresVPNInterfaces() {
        let snapshot = InterfaceSnapshot(
            addresses: [lo, tailscale, zerotier, InterfaceAddress(name: "en0", address: "192.168.8.123")],
            primaryInterface: "en0", gateway: "192.168.8.1", kinds: ["en0": .wifi])
        let result = TopologyClassifier.classify(snapshot)
        XCTAssertEqual(result.topology, .router)
        XCTAssertEqual(result.interfaceName, "en0")
        XCTAssertEqual(result.macLANAddress, "192.168.8.123")
        XCTAssertEqual(result.gateway, "192.168.8.1")
        XCTAssertTrue(result.detail.contains("static route \(svc)/32 → 192.168.8.123"), result.detail)
    }

    func testRouterWhenPrimaryIsAFullTunnelVPN() {
        let snapshot = InterfaceSnapshot(
            addresses: [lo, tailscale, InterfaceAddress(name: "en0", address: "10.1.10.39")],
            primaryInterface: "utun4", kinds: ["en0": .wifi])
        let result = TopologyClassifier.classify(snapshot)
        XCTAssertEqual(result.topology, .router)
        XCTAssertEqual(result.interfaceName, "en0")
        XCTAssertNil(result.gateway) // gateway belongs to the VPN, not the LAN
    }

    func testPrefersPrimaryAmongSeveralLANPorts() {
        let snapshot = InterfaceSnapshot(
            addresses: [InterfaceAddress(name: "en5", address: "10.0.0.5"), InterfaceAddress(name: "en0", address: "192.168.8.50")],
            primaryInterface: "en0", kinds: ["en0": .wifi, "en5": .ethernet])
        XCTAssertEqual(TopologyClassifier.classify(snapshot).interfaceName, "en0")
    }

    // Offline: nothing usable (only loopback, link-local, VPN).
    func testOffline() {
        let snapshot = InterfaceSnapshot(
            addresses: [lo, tailscale, InterfaceAddress(name: "en0", address: "169.254.10.20")],
            primaryInterface: nil, kinds: ["en0": .wifi])
        let result = TopologyClassifier.classify(snapshot)
        XCTAssertEqual(result.topology, .offline)
        XCTAssertNil(result.interfaceName)
        XCTAssertNil(result.macLANAddress)
    }

    func testOfflineEmpty() {
        XCTAssertEqual(TopologyClassifier.classify(InterfaceSnapshot(addresses: [])).topology, .offline)
    }

    func testAliasDetection() {
        XCTAssertTrue(TopologyClassifier.classify(InterfaceSnapshot(addresses: [lo, alias])).aliasActive)
        XCTAssertFalse(TopologyClassifier.classify(InterfaceSnapshot(addresses: [lo])).aliasActive)
        // The service address on some other interface is not the loopback alias.
        let elsewhere = InterfaceAddress(name: "en0", address: svc)
        XCTAssertFalse(TopologyClassifier.classify(InterfaceSnapshot(addresses: [lo, elsewhere])).aliasActive)
    }

    func testIPv4Helpers() {
        XCTAssertEqual(IPv4.parse("10.1.10.39"), 0x0A010A27)
        XCTAssertNil(IPv4.parse("10.1.10"))
        XCTAssertNil(IPv4.parse("256.1.1.1"))
        XCTAssertNil(IPv4.parse("1.2.3.4; reboot"))
        XCTAssertNil(IPv4.parse(" 1.2.3.4"))
        XCTAssertTrue(IPv4.isPrivate("172.31.255.255"))
        XCTAssertFalse(IPv4.isPrivate("172.32.0.1"))
        XCTAssertFalse(IPv4.isPrivate(svc))   // the whole point: not RFC 1918
        XCTAssertFalse(IPv4.isPrivate("100.107.116.23"))
        XCTAssertTrue(IPv4.isIPhoneHotspot("172.20.10.14"))
        XCTAssertFalse(IPv4.isUsable("169.254.1.1"))
        XCTAssertFalse(IPv4.isUsable("127.0.0.1"))
        XCTAssertFalse(IPv4.isUsable("0.0.0.0"))
    }

    func testExplainCoversEveryTopology() {
        for topology in [Topology.macHotspot, .router, .phoneHotspot, .offline] {
            XCTAssertFalse(NetworkManager.explain(topology).isEmpty)
        }
        let phone = NetworkManager.explain(.phoneHotspot)
        XCTAssertTrue(phone.contains("isolates"), phone)
        XCTAssertTrue(phone.contains("Android"), phone)
        XCTAssertTrue(phone.contains("Internet Sharing"), phone)
        XCTAssertTrue(NetworkManager.explain(.router).contains("\(svc)/32"))
    }

    /// The real scanner returns something coherent on this Mac (no assumptions about topology).
    func testLiveScannerSmoke() {
        let snapshot = InterfaceScanner.snapshot()
        XCTAssertTrue(snapshot.addresses.contains { $0.name == "lo0" && $0.address == "127.0.0.1" })
        _ = TopologyClassifier.classify(snapshot)
    }
}
