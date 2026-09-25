import DashcastContracts
import XCTest
@testable import DashcastNetwork

final class LegoTests: XCTestCase {
    func testLocateOrder() {
        let bundle = URL(fileURLWithPath: "/Applications/Dashcast.app/Contents/Resources")
        XCTAssertEqual(Lego.locate(bundleResourceURL: bundle, isExecutable: { _ in true })?.path,
                       "/Applications/Dashcast.app/Contents/Resources/bin/lego")
        XCTAssertEqual(Lego.locate(bundleResourceURL: bundle, isExecutable: { $0.hasPrefix("/opt/homebrew") || $0.hasPrefix("/usr/local") })?.path,
                       "/opt/homebrew/bin/lego")
        XCTAssertEqual(Lego.locate(bundleResourceURL: nil, isExecutable: { $0 == "/usr/local/bin/lego" })?.path,
                       "/usr/local/bin/lego")
        XCTAssertNil(Lego.locate(bundleResourceURL: bundle, isExecutable: { _ in false }))
    }

    func testVersionParsing() {
        XCTAssertEqual(Lego.majorVersion(from: "lego version 5.5.2 darwin/arm64\n"), 5)
        XCTAssertEqual(Lego.majorVersion(from: "lego version 4.21.0 darwin/arm64"), 4)
        XCTAssertEqual(Lego.majorVersion(from: "lego version v4.9.1"), 4)
        XCTAssertNil(Lego.majorVersion(from: "garbage"))
    }

    func testArgumentsV5() {
        let path = "/Users/x/Library/Application Support/Dashcast/lego"
        let expected = ["run", "--accept-tos", "--email", "you@example.com", "--dns", "cloudflare",
                        "--domains", "car.example.com", "--path", path, "--renew-days", "30", "--no-random-sleep"]
        XCTAssertEqual(Lego.arguments(major: 5, email: "you@example.com", domain: "car.example.com", path: path, renew: false), expected)
        XCTAssertEqual(Lego.arguments(major: 5, email: "you@example.com", domain: "car.example.com", path: path, renew: true), expected)
    }

    /// No contact email by default: the flag is left out entirely.
    func testArgumentsWithoutEmail() {
        XCTAssertEqual(Lego.arguments(major: 5, email: nil, domain: "car.example.com", path: "/p", renew: false),
                       ["run", "--accept-tos", "--dns", "cloudflare", "--domains", "car.example.com", "--path", "/p",
                        "--renew-days", "30", "--no-random-sleep"])
    }

    func testArgumentsV4() {
        let common = ["--accept-tos", "--email", "you@example.com", "--dns", "cloudflare",
                      "--domains", "car.example.com", "--path", "/p"]
        XCTAssertEqual(Lego.arguments(major: 4, email: "you@example.com", domain: "car.example.com", path: "/p", renew: false),
                       common + ["run"])
        XCTAssertEqual(Lego.arguments(major: 4, email: "you@example.com", domain: "car.example.com", path: "/p", renew: true),
                       common + ["renew", "--days", "30", "--no-random-sleep"])
    }

    func testEnvironment() {
        let env = Lego.environment(token: "tok", base: ["PATH": "/usr/bin", "HOME": "/Users/x", "CF_API_KEY": "old",
                                                        "CLOUDFLARE_EMAIL": "e", "LEGO_SERVER": "s"])
        XCTAssertEqual(env["CF_DNS_API_TOKEN"], "tok")
        XCTAssertEqual(env["PATH"], "/usr/bin")
        XCTAssertNil(env["CF_API_KEY"])
        XCTAssertNil(env["CLOUDFLARE_EMAIL"])
        XCTAssertNil(env["LEGO_SERVER"])
    }

    /// The installed lego accepts exactly the v5 argument list (pointed at a dead local ACME URL,
    /// so nothing leaves the machine and no certificate is requested).
    func testInstalledLegoAcceptsArguments() async throws {
        guard let lego = Lego.locate(bundleResourceURL: nil, isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("lego not installed")
        }
        let version = try await ProcessRunner.run(lego.path, ["--version"])
        let major = try XCTUnwrap(Lego.majorVersion(from: version.stdout + version.stderr))
        print("[lego] \(lego.path): \(version.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dashcast-lego-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let args = Lego.arguments(major: major, email: nil, domain: "car.example.com",
                                  path: dir.path, renew: false) + ["--server", "http://127.0.0.1:9/directory"] // plain http: refused before any connection
        let result = try await ProcessRunner.run(lego.path, args,
                                                 environment: Lego.environment(token: "dummy", base: ProcessInfo.processInfo.environment),
                                                 timeout: 60)
        let output = result.stdout + result.stderr
        XCTAssertNotEqual(result.status, 0)
        XCTAssertFalse(output.contains("flag provided but not defined"), output)
        XCTAssertFalse(output.contains("Incorrect Usage"), output)
        XCTAssertTrue(output.contains("127.0.0.1:9"), "got as far as contacting the (dead) ACME server: \(output)")
    }
}

final class ManagerTests: XCTestCase {
    @MainActor
    func testStatusFromInjectedWorld() async throws {
        let world = FakeWorld()
        world.snapshot = InterfaceSnapshot(
            addresses: [InterfaceAddress(name: "lo0", address: "127.0.0.1"),
                        InterfaceAddress(name: "lo0", address: svc),
                        InterfaceAddress(name: "en0", address: "192.168.8.123")],
            primaryInterface: "en0", gateway: "192.168.8.1", kinds: ["en0": .wifi])
        try world.installHelper()
        let secrets = InMemorySecretStore()
        let manager = NetworkManager(environment: makeEnvironment(world: world, secrets: secrets))
        try manager.setOwnDomain(OwnDomain(hostname: "car.example.com", provider: .cloudflare))
        StubURLProtocol.reset { request, _ in
            XCTAssertEqual(request.url?.host, "cloudflare-dns.com")
            XCTAssertEqual(request.url?.query, "name=car.example.com&type=A")
            return (200, Data(#"{"Status":0,"Answer":[{"name":"car.example.com","type":1,"TTL":300,"data":"\#(svc)"}]}"#.utf8))
        }

        var status = await manager.currentStatus()
        XCTAssertEqual(status.topology, .router)
        XCTAssertEqual(status.interfaceName, "en0")
        XCTAssertEqual(status.macLANAddress, "192.168.8.123")
        XCTAssertTrue(status.aliasActive)
        XCTAssertTrue(status.helperInstalled)
        XCTAssertEqual(status.domain, OwnDomain(hostname: "car.example.com", provider: .cloudflare))
        XCTAssertFalse(status.hasCloudflareToken)
        XCTAssertTrue(status.dnsRecordOK)
        XCTAssertTrue(status.internetReachable)
        XCTAssertNil(status.certificateExpiry)
        XCTAssertEqual(manager.lastDNSLookup, svc)
        XCTAssertTrue(status.summary.contains("gateway 192.168.8.1"), status.summary)
        XCTAssertTrue(status.summary.contains("add a Cloudflare API token"), status.summary)
        XCTAssertTrue(status.summary.contains("get a certificate"), status.summary)
        XCTAssertFalse(status.summary.contains("network helper"), status.summary)
        XCTAssertTrue(status.summary.contains("Ready (HTTP mode): open http://\(svc) in the car."), status.summary)
        XCTAssertTrue(status.summary.contains("For HTTPS (optional; until then the car uses HTTP + WebRTC): add a Cloudflare API token; get a certificate."), status.summary)
        XCTAssertTrue(status.summary.contains("Local DNS off."), status.summary)

        // DoH answer is cached for 5 minutes.
        try manager.setCloudflareToken("  tok  \n")
        XCTAssertEqual(secrets.values["cloudflare-api-token"], "tok")
        status = await manager.currentStatus()
        XCTAssertTrue(status.hasCloudflareToken)
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
        world.now = world.now.addingTimeInterval(301)
        StubURLProtocol.reset { _, _ in (200, Data(#"{"Status":3}"#.utf8)) }
        status = await manager.currentStatus()
        XCTAssertFalse(status.dnsRecordOK)
        XCTAssertEqual(manager.lastDNSLookup, "NXDOMAIN")
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)

        // Clearing the token deletes it.
        try manager.setCloudflareToken("")
        XCTAssertFalse(manager.hasCloudflareToken())
    }

    @MainActor
    func testOfflineStatusSkipsDoH() async {
        let world = FakeWorld()
        world.reachable = false
        let manager = NetworkManager(environment: makeEnvironment(world: world))
        StubURLProtocol.reset { _, _ in XCTFail("no DoH while offline"); return (500, Data()) }
        let status = await manager.currentStatus()
        XCTAssertEqual(status.topology, .offline)
        XCTAssertFalse(status.internetReachable)
        XCTAssertFalse(status.dnsRecordOK)
        XCTAssertTrue(status.summary.hasPrefix("Offline"), status.summary)
        XCTAssertTrue(status.summary.contains("To do: install the network helper."), status.summary)
        XCTAssertTrue(status.summary.contains("No internet right now (the car link works without it)."), status.summary)
    }

    @MainActor
    func testReadySummary() {
        var status = NetworkStatus()
        status.topology = .macHotspot
        status.aliasActive = true
        status.helperInstalled = true
        status.hasCloudflareToken = true
        status.dnsRecordOK = true
        status.internetReachable = true
        let now = Date()
        status.certificateExpiry = now.addingTimeInterval(80 * 86_400)
        status.domain = OwnDomain(hostname: "car.example.com", provider: .cloudflare)
        let topology = TopologyResult(topology: .macHotspot, interfaceName: "bridge100", macLANAddress: "192.168.2.1",
                                      uplinkInterface: "en7", uplinkDescription: nil, gateway: nil, aliasActive: true,
                                      detail: "Mac hotspot.")
        XCTAssertEqual(NetworkManager.summary(status, topology: topology, now: now),
                       "Mac hotspot. Quit SideDisplay before using Dashcast; both reconfigure Internet Sharing. "
                       + "Local DNS off. Ready: open https://car.example.com in the car.")
        let redirected = NetworkManager.SummaryContext(
            localDNS: "\(svc):53530", helperVersion: 2,
            redirect: .init(version: 2, redirectActive: true, reason: nil, anchorPointPresent: true))
        XCTAssertTrue(NetworkManager.summary(status, topology: topology, now: now, context: redirected)
            .contains("Local DNS running on \(svc):53530; the car's DNS is redirected to it."))
        var notYet = redirected
        notYet.redirect = .init(version: 2, redirectActive: false, reason: "dns-not-listening", anchorPointPresent: true)
        XCTAssertTrue(NetworkManager.summary(status, topology: topology, now: now, context: notYet)
            .contains("the car's DNS isn't redirected yet"))
        status.certificateExpiry = now.addingTimeInterval(10 * 86_400 + 60)
        XCTAssertTrue(NetworkManager.summary(status, topology: topology, now: now)
            .contains("HTTPS: renew the certificate (expires in 10 days)."))
        status.certificateExpiry = nil
        XCTAssertTrue(NetworkManager.summary(status, topology: topology, now: now)
            .contains("Ready (HTTP mode): open http://\(svc) in the car."))

        // An imported certificate is replaced, not renewed.
        status.domain?.provider = .manual
        status.certificateExpiry = now.addingTimeInterval(5 * 86_400)
        XCTAssertTrue(NetworkManager.summary(status, topology: topology, now: now)
            .contains("HTTPS: replace the certificate (expires in 5 days)."))
        status.certificateExpiry = nil
        XCTAssertTrue(NetworkManager.summary(status, topology: topology, now: now)
            .contains("For HTTPS (optional; until then the car uses HTTP + WebRTC): import a certificate for car.example.com."))
    }

    @MainActor
    func testSideDisplayWarning() async {
        XCTAssertEqual(NetworkManager.sideDisplayNote, "Quit SideDisplay before using Dashcast; both reconfigure Internet Sharing.")
        for topology in [Topology.macHotspot, .phoneHotspot, .offline] {
            XCTAssertTrue(NetworkManager.explain(topology).contains(NetworkManager.sideDisplayNote), topology.rawValue)
        }
        let world = FakeWorld()
        world.reachable = false
        world.snapshot = InterfaceSnapshot(addresses: [InterfaceAddress(name: "en0", address: "192.168.8.20")],
                                           primaryInterface: "en0", kinds: ["en0": .wifi])
        let manager = NetworkManager(environment: makeEnvironment(world: world))
        var status = await manager.currentStatus()
        XCTAssertFalse(manager.isSideDisplayRunning())
        XCTAssertFalse(status.summary.contains("SideDisplay"), "router + not running → no noise")
        world.runningApps = ["Finder", "com.example.SideDisplay", "SideDisplay"]
        status = await manager.currentStatus()
        XCTAssertTrue(manager.isSideDisplayRunning())
        XCTAssertTrue(status.summary.contains("SideDisplay is running. Quit SideDisplay before using Dashcast"), status.summary)
    }

    @MainActor
    func testProvisionWithoutTokenFailsFast() async throws {
        let manager = NetworkManager(environment: makeEnvironment(world: FakeWorld()))
        try manager.setOwnDomain(OwnDomain(hostname: "car.example.com", provider: .cloudflare))
        do {
            try await manager.provisionCertificate()
            XCTFail("expected missingCloudflareToken")
        } catch NetworkError.missingCloudflareToken {
        } catch {
            XCTFail("\(error)")
        }
    }

    @MainActor
    func testProvisionEnsuresDNSThenNeedsLego() async throws {
        let secrets = InMemorySecretStore()
        secrets.values["cloudflare-api-token"] = "tok"
        let manager = NetworkManager(environment: makeEnvironment(world: FakeWorld(), secrets: secrets))
        try manager.setOwnDomain(OwnDomain(hostname: "car.example.com", provider: .cloudflare))
        StubURLProtocol.reset { request, _ in
            let ok: (Any) -> (Int, Data) = { (200, try! JSONSerialization.data(withJSONObject: ["success": true, "errors": [], "result": $0])) }
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/client/v4/zones"):
                return ok(request.url?.query == "name=example.com" ? [["id": "z", "name": "example.com"]] : [])
            case ("GET", "/client/v4/zones/z/dns_records"): return ok([])
            case ("POST", "/client/v4/zones/z/dns_records"):
                return ok(["id": "r", "type": "A", "name": "car.example.com", "content": svc, "proxied": false, "ttl": 300])
            default: return (404, Data())
            }
        }
        do {
            try await manager.provisionCertificate()
            XCTFail("expected legoNotFound (no executables in the fake world)")
        } catch NetworkError.legoNotFound {
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(StubURLProtocol.recorded.last?.request.httpMethod, "POST", "DNS record ensured before lego")
    }

    @MainActor
    func testContactEmailSetting() {
        let manager = NetworkManager(environment: makeEnvironment(world: FakeWorld()))
        XCTAssertNil(manager.acmeContactEmail, "no contact unless the user gives one")
        manager.acmeContactEmail = " you@example.com "
        XCTAssertEqual(manager.acmeContactEmail, "you@example.com")
        manager.acmeContactEmail = "  "
        XCTAssertNil(manager.acmeContactEmail)
    }

    func testInternetSharingURL() {
        XCTAssertEqual(NetworkManager.internetSharingSettingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.Sharing-Settings.extension")
    }
}

/// Real login-keychain round trip, confined to Dashcast's own service and a throwaway account.
final class KeychainTests: XCTestCase {
    func testRoundTripOwnServiceOnly() throws {
        let store = KeychainSecretStore()
        XCTAssertEqual(store.service, "online.davidlam.dashcast")
        let account = "selftest-\(UUID().uuidString)"
        defer { try? store.delete(account) }
        XCTAssertFalse(store.exists(account))
        XCTAssertNil(try store.read(account))
        try store.write("first", account: account)
        XCTAssertTrue(store.exists(account))
        XCTAssertEqual(try store.read(account), "first")
        try store.write("second", account: account)
        XCTAssertEqual(try store.read(account), "second")
        try store.delete(account)
        XCTAssertFalse(store.exists(account))
        XCTAssertNoThrow(try store.delete(account))
    }
}

/// `DASHCAST_LIVE=1 swift test --filter LiveStatusTests` prints the real status of this Mac.
final class LiveStatusTests: XCTestCase {
    @MainActor
    func testPrintLiveStatus() async throws {
        guard ProcessInfo.processInfo.environment["DASHCAST_LIVE"] == "1" else {
            throw XCTSkip("set DASHCAST_LIVE=1 to query this Mac's real network status")
        }
        let manager = NetworkManager()
        let status = await manager.currentStatus()
        let snapshot = InterfaceScanner.snapshot()
        print("""
        [live] snapshot primary=\(snapshot.primaryInterface ?? "nil") gateway=\(snapshot.gateway ?? "nil")
        [live] addresses=\(snapshot.addresses.map { "\($0.name)=\($0.address)\($0.isUp ? "" : "(down)")" }.joined(separator: " "))
        [live] kinds=\(snapshot.kinds.filter { $0.value != .other }.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value.rawValue)" }.joined(separator: " "))
        [live] topology=\(status.topology.rawValue)
        [live] interfaceName=\(status.interfaceName ?? "nil")
        [live] macLANAddress=\(status.macLANAddress ?? "nil")
        [live] aliasActive=\(status.aliasActive)
        [live] helperInstalled=\(status.helperInstalled)
        [live] hasCloudflareToken=\(status.hasCloudflareToken)
        [live] dnsRecordOK=\(status.dnsRecordOK) (DoH: \(manager.lastDNSLookup ?? "nil"))
        [live] certificateExpiry=\(status.certificateExpiry.map { "\($0)" } ?? "nil")
        [live] internetReachable=\(status.internetReachable)
        [live] summary=\(status.summary)
        [live] explain=\(NetworkManager.explain(status.topology))
        """)
    }
}
