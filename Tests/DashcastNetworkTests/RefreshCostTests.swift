import DashcastContracts
import Foundation
import XCTest
@testable import DashcastNetwork

/// `currentStatus()` runs on every network change and every 2 s while the Car Hotspot window is
/// open, for as long as the hotspot is up: what it can reuse, it must.
@MainActor
final class RefreshCostTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dashcast-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    final class CountingSecretStore: SecretStore {
        var values: [String: String] = [:]
        var reads = 0
        var existsChecks = 0
        func read(_ account: String) throws -> String? { reads += 1; return values[account] }
        func exists(_ account: String) -> Bool { existsChecks += 1; return values[account] != nil }
        func write(_ value: String, account: String) throws { values[account] = value }
        func delete(_ account: String) throws { values[account] = nil }
    }

    /// The hardware scan (SCNetworkInterfaceCopyAll, most of a refresh) reruns only when the set of
    /// interfaces changes; addresses and the primary service are read fresh every time.
    func testScannerRescansHardwareOnlyWhenInterfacesChange() {
        var names: Set<String> = ["lo0", "en0"]
        var address = "192.168.1.20"
        var hardwareCalls = 0
        let scanner = CachingInterfaceScanner(
            scan: { ([InterfaceAddress(name: "en0", address: address)], names) },
            primary: { ("en0", "192.168.1.1", false) },
            hardware: {
                hardwareCalls += 1
                return (["en0": .wifi], ["en0": "Wi-Fi"])
            })
        XCTAssertEqual(scanner.snapshot().kinds, ["en0": .wifi])
        address = "192.168.1.21"
        let again = scanner.snapshot()
        XCTAssertEqual(again.addresses.first?.address, "192.168.1.21", "addresses are always fresh")
        XCTAssertEqual(again.gateway, "192.168.1.1")
        XCTAssertEqual(hardwareCalls, 1)

        names.insert("en7")   // a USB adapter appears (no address yet)
        _ = scanner.snapshot()
        XCTAssertEqual(hardwareCalls, 2)
        XCTAssertEqual(scanner.hardwareScans, 2)
    }

    /// The kernel lists a new adapter a moment before SystemConfiguration knows it: that gap isn't
    /// cached, or the adapter would stay unknown until the next interface change.
    func testScannerAsksAgainUntilANewPortIsKnown() {
        var known = false
        var hardwareCalls = 0
        let scanner = CachingInterfaceScanner(
            scan: { ([], ["lo0", "en0", "en7", "utun3"]) },
            primary: { (nil, nil, false) },
            hardware: {
                hardwareCalls += 1
                var kinds: [String: InterfaceKind] = ["en0": .wifi]
                if known { kinds["en7"] = .ethernet }
                return (kinds, [:])
            })
        XCTAssertNil(scanner.snapshot().kinds["en7"])
        known = true
        XCTAssertEqual(scanner.snapshot().kinds["en7"], .ethernet)
        _ = scanner.snapshot()
        XCTAssertEqual(hardwareCalls, 2, "complete now (utun3 never has a kind, and needn't)")
    }

    /// The real scanner agrees with the one-shot scan (read-only, this Mac).
    func testCachingScannerMatchesALiveScan() {
        let cached = CachingInterfaceScanner()
        let first = cached.snapshot()
        let second = cached.snapshot()
        let live = InterfaceScanner.snapshot()
        XCTAssertEqual(second.kinds, live.kinds)
        XCTAssertEqual(second.displayNames, live.displayNames)
        XCTAssertEqual(second.primaryInterface, live.primaryInterface)
        XCTAssertEqual(Set(first.addresses.map(\.name)), Set(live.addresses.map(\.name)))
        XCTAssertEqual(cached.hardwareScans, 1)
    }

    /// bootpd's leases and the NAT settings are parsed once per file version, not per refresh.
    func testLeasesAndNATSettingsAreReadOncePerFileVersion() throws {
        let world = FakeWorld()
        world.now = HotspotProbeTests.leaseNow
        world.snapshot = HotspotProbeTests.snapshot(addresses: [HotspotProbeTests.lo, HotspotProbeTests.bridge])
        world.neighbours = [.init(address: "192.168.2.3", interface: "bridge100", complete: true),
                            .init(address: "192.168.2.4", interface: "bridge100", complete: true)]
        let leases = dir.appendingPathComponent("dhcpd_leases")
        let nat = dir.appendingPathComponent("com.apple.nat")
        try Data(HotspotProbeTests.leases.utf8).write(to: leases)
        try HotspotProbeTests.natOnToWiFi.write(to: nat.appendingPathExtension("plist"))

        var reads: [String: Int] = [:]
        var environment = makeEnvironment(world: world)
        environment.helperLayout.natPreferences = nat.path
        environment.dhcpLeasesPath = leases.path
        environment.readFile = { path in
            reads[path, default: 0] += 1
            return FileManager.default.contents(atPath: path)
        }
        let manager = NetworkManager(environment: environment)

        for _ in 0..<5 { _ = manager.hotspotStatus() }
        XCTAssertEqual(reads[leases.path], 1)
        XCTAssertEqual(reads[nat.path + ".plist"], 1)
        XCTAssertEqual(manager.hotspotStatus().devices.map(\.address), ["192.168.2.3"])

        // A new device joins: bootpd rewrites the file and the next refresh sees it.
        let joined = HotspotProbeTests.leases + "\n{\n\tname=Tesla_Model_Y\n\tip_address=192.168.2.4\n\tlease=0x6ac1f16a\n}\n"
        try Data(joined.utf8).write(to: leases, options: .atomic)
        XCTAssertEqual(manager.hotspotStatus().devices.map(\.address), ["192.168.2.3", "192.168.2.4"])
        XCTAssertEqual(reads[leases.path], 2)

        // A file that goes away is read (and found missing) every time, never served stale.
        try FileManager.default.removeItem(at: leases)
        XCTAssertEqual(manager.hotspotStatus().devices, [])
    }

    /// A leased address that doesn't answer ARP is nudged once per `nudgeInterval`, however often
    /// the status refreshes (the hotspot window polls every 2 s).
    func testNudgesAreRateLimited() async {
        let world = FakeWorld()
        world.now = HotspotProbeTests.leaseNow
        world.snapshot = HotspotProbeTests.snapshot(addresses: [HotspotProbeTests.lo, HotspotProbeTests.bridge])
        world.contents["/fake/dhcpd_leases"] = Data(HotspotProbeTests.leases.utf8)
        world.neighbours = [.init(address: "192.168.2.3", interface: "bridge100", complete: true)]
        let manager = NetworkManager(environment: makeEnvironment(world: world))

        _ = await manager.currentStatus()
        XCTAssertEqual(Set(world.nudged), ["192.168.2.2", "192.168.2.9"])
        for _ in 0..<4 {   // the hotspot window's 2 s poll, for 8 s
            world.now = world.now.addingTimeInterval(2)
            _ = manager.hotspotStatus()
        }
        XCTAssertEqual(world.nudged.count, 2, "no repeat inside the interval")
        world.now = world.now.addingTimeInterval(NetworkManager.nudgeInterval)
        _ = manager.hotspotStatus()
        XCTAssertEqual(world.nudged.count, 4)

        // isStillOnNetwork asks on purpose, so it isn't rate limited.
        var environment = makeEnvironment(world: world)
        environment.neighbourSettle = .milliseconds(10)
        world.snapshot.addresses.append(InterfaceAddress(name: "en0", address: "192.168.2.50", netmask: "255.255.255.0"))
        let presence = NetworkManager(environment: environment)
        _ = presence.hotspotStatus()
        let before = world.nudged.count
        _ = await presence.isStillOnNetwork("192.168.2.9")
        XCTAssertEqual(world.nudged.count, before + 2)
    }

    /// "Has a Cloudflare token" is a keychain round trip: once per `tokenCacheLifetime`, and at once
    /// after the token is changed here.
    func testTokenCheckIsCachedAndInvalidatedOnChange() async throws {
        let world = FakeWorld()
        let secrets = CountingSecretStore()
        let manager = NetworkManager(environment: makeEnvironment(world: world, secrets: secrets))
        for _ in 0..<5 { _ = await manager.currentStatus() }
        XCTAssertEqual(secrets.existsChecks, 1)
        try manager.setCloudflareToken("tok")
        let status = await manager.currentStatus()
        XCTAssertTrue(status.hasCloudflareToken)
        XCTAssertEqual(secrets.existsChecks, 2)
        world.now = world.now.addingTimeInterval(NetworkManager.tokenCacheLifetime + 1)
        _ = manager.hasCloudflareToken()
        XCTAssertEqual(secrets.existsChecks, 3)
    }

    /// A .p12 the stored passphrase can't open used to be re-read, re-imported and its passphrase
    /// fetched from the keychain on every refresh (twice: status and the TLS listener check).
    func testUnreadableCertificateIsNotRetriedUntilItChanges() throws {
        let secrets = CountingSecretStore()
        secrets.values[SecretAccount.p12Passphrase] = "wrong"
        let manager = NetworkManager(environment: makeEnvironment(world: FakeWorld(), secrets: secrets, appSupport: dir))
        try manager.setOwnDomain(OwnDomain(hostname: "car.example.com", provider: .manual))
        let p12 = dir.appendingPathComponent("car.example.com.p12")
        try Data("not a pkcs12".utf8).write(to: p12)

        for _ in 0..<5 {
            XCTAssertNil(manager.certificateExpiry())
            XCTAssertNil(manager.tlsMaterial())
        }
        XCTAssertEqual(secrets.reads, 1)

        try Data("still not a pkcs12".utf8).write(to: p12)
        XCTAssertNil(manager.certificateExpiry())
        XCTAssertEqual(secrets.reads, 2, "a new file is looked at again")
    }

    /// No passphrase (keychain locked at login, say) isn't remembered: the next refresh tries again.
    func testMissingPassphraseIsRetried() throws {
        let secrets = CountingSecretStore()
        let manager = NetworkManager(environment: makeEnvironment(world: FakeWorld(), secrets: secrets, appSupport: dir))
        try manager.setOwnDomain(OwnDomain(hostname: "car.example.com", provider: .manual))
        try Data("x".utf8).write(to: dir.appendingPathComponent("car.example.com.p12"))
        XCTAssertNil(manager.certificateExpiry())
        XCTAssertNil(manager.certificateExpiry())
        XCTAssertEqual(secrets.reads, 2)
    }
}
