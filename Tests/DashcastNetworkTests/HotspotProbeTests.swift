import DashcastContracts
import Foundation
import XCTest
@testable import DashcastNetwork

final class HotspotProbeTests: XCTestCase {
    // MARK: Fixtures

    /// This Mac's real com.apple.nat.plist (sharing off, last shared from iPhone USB).
    static let natOffXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \t<key>NAT</key>
    \t<dict>
    \t\t<key>AirPort</key>
    \t\t<dict>
    \t\t\t<key>40BitEncrypt</key><integer>1</integer>
    \t\t\t<key>Channel</key><integer>0</integer>
    \t\t\t<key>Enabled</key><integer>0</integer>
    \t\t\t<key>NetworkName</key><string>David's MacBook Pro</string>
    \t\t\t<key>NetworkPassword</key><data></data>
    \t\t</dict>
    \t\t<key>Enabled</key><integer>0</integer>
    \t\t<key>NatPortMapDisabled</key><false/>
    \t\t<key>PrimaryInterface</key>
    \t\t<dict>
    \t\t\t<key>Device</key><string>en13</string>
    \t\t\t<key>Enabled</key><integer>0</integer>
    \t\t\t<key>HardwareKey</key><string></string>
    \t\t\t<key>PrimaryUserReadable</key><string>iPhone USB</string>
    \t\t</dict>
    \t\t<key>PrimaryService</key><string>3350B9B7-2B0A-AE97-BCC9-8DE7CFE61D32</string>
    \t\t<key>SharingDevices</key><array/>
    \t</dict>
    </dict>
    </plist>
    """

    /// The same Mac with sharing on, iPhone USB → Wi-Fi, on channel 36 (booleans this time).
    static var natOnToWiFi: Data {
        let plist: [String: Any] = ["NAT": [
            "AirPort": ["40BitEncrypt": 1, "Channel": 36, "Enabled": 1, "NetworkName": "David's MacBook Pro",
                        "NetworkPassword": Data()],
            "Enabled": true,
            "NatPortMapDisabled": false,
            "PrimaryInterface": ["Device": "en13", "Enabled": 1, "HardwareKey": "", "PrimaryUserReadable": "iPhone USB"],
            "PrimaryService": "3350B9B7-2B0A-AE97-BCC9-8DE7CFE61D32",
            "SharingDevices": ["en0"],
        ]]
        return try! PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    static let leases = """
    {
    \tname=Tesla_Model_3
    \tip_address=192.168.2.3
    \thw_address=1,4c:fc:aa:1:6f:1d
    \tidentifier=1,4c:fc:aa:1:6f:1d
    \tlease=0x6ac1e599
    }
    {
    \tname=Davids-iPhone
    \tip_address=192.168.2.2
    \thw_address=1,c6:c1:7d:c1:9a:a5
    \tidentifier=1,c6:c1:7d:c1:9a:a5
    \tlease=0x6ac1f16a
    }
    {
    \tname=David-PC
    \tip_address=192.168.64.6
    \thw_address=1,96:7b:18:b7:94:35
    \tidentifier=1,96:7b:18:b7:94:35
    \tlease=0x6ac1f16a
    }
    {
    \tip_address=192.168.2.9
    \thw_address=1,98:ed:5c:0:0:1
    \tidentifier=1,98:ed:5c:0:0:1
    \tlease=0x6ac1f16a
    }
    {
    \tname=Old-Laptop
    \tip_address=192.168.2.7
    \thw_address=1,2:de:90:60:8a:b4
    \tlease=0x6a2dc962
    }
    """

    /// Between the expired Old-Laptop lease and every other one.
    static let leaseNow = Date(timeIntervalSince1970: 0x6ac1e000)

    /// This Mac's hardware as SCNetworkInterfaceCopyAll reports it, plus an iPhone USB on en13.
    static func snapshot(addresses: [InterfaceAddress], iPhonePresent: Bool = false) -> InterfaceSnapshot {
        var kinds: [String: InterfaceKind] = ["en0": .wifi, "en1": .ethernet, "en2": .ethernet, "en6": .ethernet,
                                              "en3": .ethernet, "en4": .ethernet, "en5": .ethernet, "bridge0": .bridge]
        var names = ["en0": "Wi-Fi", "en1": "Thunderbolt 1", "en2": "Thunderbolt 3", "en6": "Thunderbolt 2",
                     "en3": "Ethernet Adapter (en3)", "en4": "Ethernet Adapter (en4)", "en5": "Ethernet Adapter (en5)",
                     "bridge0": "Thunderbolt Bridge"]
        if iPhonePresent { kinds["en13"] = .iPhoneUSB; names["en13"] = "iPhone USB" }
        return InterfaceSnapshot(addresses: addresses, kinds: kinds, displayNames: names)
    }

    static let lo = InterfaceAddress(name: "lo0", address: "127.0.0.1", netmask: "255.0.0.0")
    static let bridge = InterfaceAddress(name: "bridge100", address: "192.168.2.1", netmask: "255.255.255.0")
    static let iPhoneUSB = InterfaceAddress(name: "en13", address: "172.20.10.4", netmask: "255.255.255.240")

    // MARK: NAT preferences

    func testParsesThisMacsNATPreferences() throws {
        let nat = try XCTUnwrap(NATPreferences.parse(Data(Self.natOffXML.utf8)))
        XCTAssertEqual(nat, NATPreferences(enabled: false, primaryDevice: "en13", primaryName: "iPhone USB",
                                           sharingDevices: [], networkName: "David's MacBook Pro", channel: 0))
    }

    func testParsesSharingToWiFiFromBinaryPlist() throws {
        let nat = try XCTUnwrap(NATPreferences.parse(Self.natOnToWiFi))
        XCTAssertTrue(nat.enabled)
        XCTAssertEqual(nat.sharingDevices, ["en0"])
        XCTAssertEqual(nat.channel, 36)
    }

    func testNATPreferencesAreDefensive() throws {
        XCTAssertNil(NATPreferences.parse(Data("not a plist".utf8)))
        XCTAssertNil(NATPreferences.parse(try PropertyListSerialization.data(fromPropertyList: ["Other": 1], format: .xml, options: 0)))
        let odd: [String: Any] = ["NAT": ["Enabled": "yes", "PrimaryInterface": "en13", "SharingDevices": ["en0", 7, ""],
                                          "AirPort": ["NetworkName": "", "Channel": "six"]]]
        let nat = try XCTUnwrap(NATPreferences.parse(try PropertyListSerialization.data(fromPropertyList: odd, format: .xml, options: 0)))
        XCTAssertEqual(nat, NATPreferences(sharingDevices: ["en0"]), "wrong types read as unset")
    }

    // MARK: Leases + Tesla

    func testParsesLeases() {
        let leases = DHCPLeases.parse(Self.leases)
        XCTAssertEqual(leases.count, 5)
        XCTAssertEqual(leases[0], DHCPLease(name: "Tesla_Model_3", address: "192.168.2.3", hardwareAddress: "4c:fc:aa:01:6f:1d",
                                            expiry: Date(timeIntervalSince1970: 0x6ac1e599)))
        XCTAssertNil(leases[3].name)
        XCTAssertEqual(leases[3].hardwareAddress, "98:ed:5c:00:00:01")
        XCTAssertEqual(DHCPLeases.parse("{\nname=x\n}\n{\nip_address=999.1.1.1\n}\ngarbage"), [], "no valid address, no lease")
    }

    func testHardwareAddressNormalisation() {
        XCTAssertEqual(DHCPLeases.normalizeHardwareAddress("1,4c:fc:aa:1:6f:1d"), "4c:fc:aa:01:6f:1d")
        XCTAssertEqual(DHCPLeases.normalizeHardwareAddress("72:3:2b:d6:20:70"), "72:03:2b:d6:20:70")
        XCTAssertNil(DHCPLeases.normalizeHardwareAddress("1,4c:fc:aa:1:6f"))
        XCTAssertNil(DHCPLeases.normalizeHardwareAddress("1,4c:fc:aa:1:6f:zz"))
    }

    func testTeslaDetection() {
        XCTAssertTrue(TeslaHardware.isTesla(name: "Tesla_Model_3", hardwareAddress: nil))
        XCTAssertTrue(TeslaHardware.isTesla(name: "my-TESLA", hardwareAddress: "1,2:0:0:0:0:1"))
        XCTAssertTrue(TeslaHardware.isTesla(name: nil, hardwareAddress: "1,4c:fc:aa:1:6f:1d"))
        XCTAssertTrue(TeslaHardware.isTesla(name: "android-1234", hardwareAddress: "98:ED:5C:12:34:56"))
        XCTAssertTrue(TeslaHardware.isTesla(name: nil, hardwareAddress: "dc:44:27:1a:00:01"), "MA-M block")
        XCTAssertFalse(TeslaHardware.isTesla(name: nil, hardwareAddress: "dc:44:27:2a:00:01"), "outside the MA-M block")
        XCTAssertFalse(TeslaHardware.isTesla(name: "Davids-iPhone", hardwareAddress: "1,c6:c1:7d:c1:9a:a5"))
        XCTAssertFalse(TeslaHardware.isTesla(name: nil, hardwareAddress: nil))
    }

    // MARK: Status

    func testDevicesOnTheHotspot() {
        let snapshot = Self.snapshot(addresses: [Self.lo, Self.bridge, Self.iPhoneUSB], iPhonePresent: true)
        let neighbours: [ARPTable.Entry] = [
            .init(address: "192.168.2.2", interface: "bridge100", complete: true),
            .init(address: "192.168.2.3", interface: "bridge100", complete: true),
            .init(address: "192.168.2.7", interface: "bridge100", complete: true),    // expired lease
            .init(address: "192.168.2.9", interface: "bridge100", complete: false),   // not answering
            .init(address: "192.168.64.6", interface: "bridge101", complete: true),   // VM subnet
        ]
        let inputs = HotspotProbe.Inputs(snapshot: snapshot, nat: NATPreferences.parse(Self.natOnToWiFi),
                                         leases: DHCPLeases.parse(Self.leases), neighbours: neighbours, now: Self.leaseNow)
        let status = HotspotProbe.status(inputs)
        XCTAssertEqual(status.devices, [
            .init(name: "Tesla_Model_3", address: "192.168.2.3", isTesla: true),
            .init(name: "Davids-iPhone", address: "192.168.2.2", isTesla: false),
        ])
        XCTAssertEqual(status.car?.address, "192.168.2.3")
        XCTAssertEqual(HotspotProbe.addressesToNudge(inputs), ["192.168.2.9"],
                       "only unexpired leases on the bridge's subnet that ARP can't vouch for")
    }

    func testNoBridgeNoDevices() {
        let inputs = HotspotProbe.Inputs(snapshot: Self.snapshot(addresses: [Self.lo]), nat: nil,
                                         leases: DHCPLeases.parse(Self.leases),
                                         neighbours: [.init(address: "192.168.2.3", interface: "bridge100", complete: true)],
                                         now: Self.leaseNow)
        XCTAssertEqual(HotspotProbe.status(inputs).devices, [])
        XCTAssertEqual(HotspotProbe.addressesToNudge(inputs), [])
    }

    /// Tonight's failure: the Mac's internet was the iPhone's hotspot over Wi-Fi, sharing off,
    /// iPhone USB not plugged in.
    func testWiFiUplinkIsAPhoneAndIPhoneUSBIsMissing() {
        let wifi = InterfaceAddress(name: "en0", address: "172.20.10.2", netmask: "255.255.255.240")
        var snapshot = Self.snapshot(addresses: [Self.lo, wifi])
        snapshot.primaryInterface = "en0"
        snapshot.gateway = "172.20.10.1"
        let status = HotspotProbe.status(.init(snapshot: snapshot, nat: NATPreferences.parse(Data(Self.natOffXML.utf8))))
        XCTAssertFalse(status.sharingOn)
        XCTAssertFalse(status.enabledInSettings)
        XCTAssertFalse(status.sharesToWiFi)
        XCTAssertTrue(status.wifiIsUplink)
        XCTAssertTrue(status.wifiUplinkIsPhone)
        XCTAssertEqual(status.networkName, "David's MacBook Pro")
        XCTAssertEqual(status.channel, 0)
        XCTAssertEqual(status.shareFrom, .init(name: "iPhone USB", interface: "en13", connected: false))
        XCTAssertEqual(status.uplinks, [.init(name: "iPhone USB", interface: "en13", connected: false)],
                       "always-present ports (Ethernet Adapter, Thunderbolt N) aren't offered")
    }

    func testAndroidAndHomeWiFi() {
        let wifi = InterfaceAddress(name: "en0", address: "192.168.43.20", netmask: "255.255.255.0")
        var snapshot = Self.snapshot(addresses: [wifi])
        snapshot.primaryInterface = "en0"
        snapshot.gateway = "192.168.43.1"
        XCTAssertTrue(HotspotProbe.status(.init(snapshot: snapshot, nat: nil)).wifiUplinkIsPhone)
        snapshot.gateway = "192.168.1.1"
        XCTAssertFalse(HotspotProbe.status(.init(snapshot: snapshot, nat: nil)).wifiUplinkIsPhone)
        snapshot.androidMetered = true
        XCTAssertTrue(HotspotProbe.status(.init(snapshot: snapshot, nat: nil)).wifiUplinkIsPhone)

        let home = InterfaceAddress(name: "en0", address: "10.0.4.79", netmask: "255.255.252.0")
        let status = HotspotProbe.status(.init(snapshot: Self.snapshot(addresses: [home]), nat: nil))
        XCTAssertTrue(status.wifiIsUplink)
        XCTAssertFalse(status.wifiUplinkIsPhone)
        XCTAssertNil(status.shareFrom, "never configured")
        XCTAssertEqual(status.uplinks, [])

        let linkLocal = InterfaceAddress(name: "en0", address: "169.254.3.4", netmask: "255.255.0.0")
        XCTAssertFalse(HotspotProbe.status(.init(snapshot: Self.snapshot(addresses: [linkLocal]), nat: nil)).wifiIsUplink)
    }

    func testSharingOnFromIPhoneUSB() {
        let snapshot = Self.snapshot(addresses: [Self.lo, Self.bridge, Self.iPhoneUSB], iPhonePresent: true)
        let status = HotspotProbe.status(.init(snapshot: snapshot, nat: NATPreferences.parse(Self.natOnToWiFi)))
        XCTAssertTrue(status.sharingOn)
        XCTAssertTrue(status.enabledInSettings)
        XCTAssertTrue(status.sharesToWiFi)
        XCTAssertFalse(status.wifiIsUplink)
        XCTAssertEqual(status.channel, 36)
        XCTAssertEqual(status.shareFrom, .init(name: "iPhone USB", interface: "en13", connected: true))
        XCTAssertEqual(status.uplinks, [.init(name: "iPhone USB", interface: "en13", connected: true)])
    }

    func testUplinkOrdering() {
        var snapshot = Self.snapshot(addresses: [
            Self.lo,
            InterfaceAddress(name: "en8", address: "192.168.1.50", netmask: "255.255.255.0"),   // USB LAN, cabled
            InterfaceAddress(name: "en9", address: "169.254.1.1", netmask: "255.255.0.0"),     // BT PAN, no lease
            InterfaceAddress(name: "en1", address: "10.9.9.9", netmask: "255.0.0.0"),          // Thunderbolt 1, unbridged
            InterfaceAddress(name: "utun3", address: "100.64.0.2", netmask: "255.255.255.255"),
            InterfaceAddress(name: "feth2326", address: "10.147.15.122", netmask: "255.255.255.0"),
        ], iPhonePresent: true)
        snapshot.kinds["en8"] = .ethernet; snapshot.displayNames["en8"] = "USB 10/100/1000 LAN"
        snapshot.kinds["en9"] = .ethernet; snapshot.displayNames["en9"] = "Bluetooth PAN"
        snapshot.kinds["en10"] = .ethernet; snapshot.displayNames["en10"] = "Thunderbolt Ethernet Slot 1"
        snapshot.kinds["utun3"] = .other; snapshot.kinds["feth2326"] = .other

        let status = HotspotProbe.status(.init(snapshot: snapshot, nat: NATPreferences.parse(Data(Self.natOffXML.utf8))))
        XCTAssertEqual(status.uplinks.map(\.interface), ["en1", "en8", "en13", "en10", "en9"],
                       "connected first; then the configured share-from, iPhone, Ethernet, Bluetooth")
        XCTAssertEqual(status.uplinks.filter(\.connected).map(\.interface), ["en1", "en8"])
        XCTAssertEqual(status.uplinks.first { $0.interface == "en9" }?.name, "Bluetooth PAN")
    }

    func testShareFromFollowsARenamedDevice() {
        var snapshot = Self.snapshot(addresses: [InterfaceAddress(name: "en7", address: "172.20.10.3", netmask: "255.255.255.240")])
        snapshot.kinds["en7"] = .iPhoneUSB
        snapshot.displayNames["en7"] = "iPhone USB"
        let status = HotspotProbe.status(.init(snapshot: snapshot, nat: NATPreferences.parse(Data(Self.natOffXML.utf8))))
        XCTAssertEqual(status.shareFrom, .init(name: "iPhone USB", interface: "en7", connected: true))
        XCTAssertEqual(status.uplinks, [.init(name: "iPhone USB", interface: "en7", connected: true)],
                       "no duplicate entry for the saved en13")
    }

    // MARK: Manager

    @MainActor
    func testManagerFillsHotspotAndNudges() async throws {
        let world = FakeWorld()
        world.now = Self.leaseNow
        world.snapshot = Self.snapshot(addresses: [Self.lo, Self.bridge, Self.iPhoneUSB], iPhonePresent: true)
        world.contents[HelperLayout.fake.natPreferences + ".plist"] = Self.natOnToWiFi
        world.contents["/fake/dhcpd_leases"] = Data(Self.leases.utf8)
        world.neighbours = [.init(address: "192.168.2.3", interface: "bridge100", complete: true)]
        let manager = NetworkManager(environment: makeEnvironment(world: world))

        let status = await manager.currentStatus()
        XCTAssertEqual(status.topology, .macHotspot)
        XCTAssertTrue(status.hotspot.sharingOn)
        XCTAssertEqual(status.hotspot.car, .init(name: "Tesla_Model_3", address: "192.168.2.3", isTesla: true))
        XCTAssertEqual(status.hotspot.devices.count, 1)
        XCTAssertEqual(Set(world.nudged), ["192.168.2.2", "192.168.2.9"])

        // Sharing off: no lease or ARP work at all.
        world.nudged = []
        world.snapshot = Self.snapshot(addresses: [Self.lo])
        let off = manager.hotspotStatus()
        XCTAssertFalse(off.sharingOn)
        XCTAssertEqual(off.devices, [])
        XCTAssertEqual(world.nudged, [])
    }

    @MainActor
    func testNetworkChangeObservers() {
        let manager = NetworkManager(environment: makeEnvironment(world: FakeWorld()))
        var calls = 0
        manager.addNetworkChangeObserver { calls += 1 }
        manager.addNetworkChangeObserver { calls += 10 }
        manager.networkDidChange()
        XCTAssertEqual(calls, 11)
    }

    // MARK: Watcher

    func testWatcherSeesTheNATFileReplaced() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dashcast-nat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let nat = dir.appendingPathComponent("com.apple.nat.plist")
        try Data(Self.natOffXML.utf8).write(to: nat)

        let fired = expectation(description: "change")
        fired.assertForOverFulfill = false
        let unrelated = LockedCounter()
        let watcher = SystemNetworkWatcher(natPreferencesPath: nat.path, dynamicStore: false,
                                           coalesce: .milliseconds(50)) { unrelated.increment(); fired.fulfill() }
        XCTAssertTrue(watcher.watchingNATPreferences)

        // Another file in the directory changing isn't Internet Sharing.
        try Data("x".utf8).write(to: dir.appendingPathComponent("preferences.plist"), options: .atomic)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(unrelated.value, 0)

        try Self.natOnToWiFi.write(to: nat, options: .atomic)
        wait(for: [fired], timeout: 3)
        withExtendedLifetime(watcher) {}
    }

    func testDynamicStoreWatchArms() {
        let watcher = SystemNetworkWatcher(natPreferencesPath: nil) {}
        XCTAssertTrue(watcher.watchingDynamicStore, "keys and patterns are accepted")
        XCTAssertFalse(watcher.watchingNATPreferences)
        XCTAssertTrue(SystemNetworkWatcher.patterns.contains("^State:/Network/Interface/lo0/IPv4$"),
                      "the service address appearing on lo0 is a change (listeners can bind now)")
    }

    /// The directory watch holds a descriptor: if the directory is deleted (or renamed) and comes
    /// back, the watcher must follow the new one instead of watching the dead vnode forever.
    func testWatcherFollowsAReplacedDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dashcast-natdir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let nat = dir.appendingPathComponent("com.apple.nat.plist")
        try Data(Self.natOffXML.utf8).write(to: nat)

        let changes = LockedCounter()
        let watcher = SystemNetworkWatcher(natPreferencesPath: nat.path, dynamicStore: false,
                                           coalesce: .milliseconds(50)) { changes.increment() }
        try FileManager.default.removeItem(at: dir)
        Thread.sleep(forTimeInterval: 0.3)
        let afterDelete = changes.value
        XCTAssertEqual(afterDelete, 1, "the file going away with its directory is a change")

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.natOnToWiFi.write(to: nat)
        let deadline = Date().addingTimeInterval(5)
        while changes.value == afterDelete, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertEqual(changes.value, afterDelete + 1, "seen through the re-opened directory")
        XCTAssertTrue(watcher.watchingNATPreferences)

        // And later edits in the new directory still count.
        try Data(Self.natOffXML.utf8).write(to: nat, options: .atomic)
        let edited = Date().addingTimeInterval(3)
        while changes.value == afterDelete + 1, Date() < edited { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertEqual(changes.value, afterDelete + 2)
        withExtendedLifetime(watcher) {}
    }

    /// Watchers created and dropped in quick succession (SCDynamicStore callbacks may be in flight
    /// as one goes away): the store owns its relay, so nothing dangles.
    func testWatchersComeAndGo() {
        for _ in 0..<50 {
            let watcher = SystemNetworkWatcher(natPreferencesPath: nil, coalesce: .milliseconds(1)) {}
            XCTAssertTrue(watcher.watchingDynamicStore)
        }
    }

    // MARK: Live (read-only)

    /// `DASHCAST_LIVE=1 swift test --filter HotspotProbeTests/testLiveReader` prints what this Mac
    /// reports right now; asserts only what's always true.
    @MainActor
    func testLiveReader() throws {
        guard ProcessInfo.processInfo.environment["DASHCAST_LIVE"] == "1" else {
            throw XCTSkip("set DASHCAST_LIVE=1 to read this Mac's real Internet Sharing state")
        }
        let manager = NetworkManager()
        let snapshot = InterfaceScanner.snapshot()
        let status = manager.hotspotStatus(snapshot: snapshot)
        print("LIVE hotspot: \(status)")
        print("LIVE leases: \(DHCPLeases.parse((try? String(contentsOfFile: HotspotProbe.leasesPath, encoding: .utf8)) ?? ""))")
        if !status.sharingOn { XCTAssertEqual(status.devices, []) }
        XCTAssertFalse(status.uplinks.contains { $0.interface.hasPrefix("utun") || $0.interface.hasPrefix("bridge") })
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
