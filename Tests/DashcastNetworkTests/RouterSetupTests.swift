import XCTest
@testable import DashcastNetwork

final class RouterSetupTests: XCTestCase {
    func testScriptContents() throws {
        let script = RouterSetup.script(macLANAddress: "192.168.8.123")
        let lines = script.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "#!/bin/sh")
        for expected in [
            "MAC_IP='192.168.8.123'",
            "uci add network route >/dev/null",
            "uci rename network.@route[-1]='dashcast_car'",
            "uci set network.dashcast_car.interface='lan'",
            "uci set network.dashcast_car.target='\(svc)'",
            "uci set network.dashcast_car.netmask='255.255.255.255'",
            "uci set network.dashcast_car.gateway=\"$MAC_IP\"",
            "uci commit network",
            "/etc/init.d/network reload",
            "uci add_list dhcp.@dnsmasq[0].rebind_domain='davidlam.online'",
            "uci add_list dhcp.@dnsmasq[0].address='/car.davidlam.online/\(svc)'",
            "uci commit dhcp",
            "/etc/init.d/dnsmasq restart",
        ] {
            XCTAssertTrue(lines.contains(expected), "missing line: \(expected)")
        }
        // The route is replaced, not stacked, when the script is re-run.
        let delete = try XCTUnwrap(lines.firstIndex(of: "uci -q delete network.dashcast_car || true"))
        let add = try XCTUnwrap(lines.firstIndex(of: "uci add network route >/dev/null"))
        XCTAssertLessThan(delete, add)
        // Commit + reload happen after the settings.
        XCTAssertLessThan(try XCTUnwrap(lines.firstIndex(of: "uci set network.dashcast_car.gateway=\"$MAC_IP\"")),
                          try XCTUnwrap(lines.firstIndex(of: "uci commit network")))
        XCTAssertTrue(script.contains("reserve the Mac's DHCP lease"), "lease reminder")
        XCTAssertTrue(script.contains("Reserve IP"))
        XCTAssertTrue(script.contains("rebind_protection='0'"), "documents the disable-it-entirely alternative")
        // Old Dashcast address entries are removed before the current one is added.
        let cleanup = try XCTUnwrap(lines.firstIndex(of: "for entry in $(uci -q get dhcp.@dnsmasq[0].address); do"))
        let addAddress = try XCTUnwrap(lines.firstIndex(of: "uci add_list dhcp.@dnsmasq[0].address='/car.davidlam.online/\(svc)'"))
        XCTAssertLessThan(cleanup, addAddress)
        XCTAssertLessThan(addAddress, try XCTUnwrap(lines.firstIndex(of: "uci commit dhcp")))
        XCTAssertNil(try shellSyntaxError(script))
    }

    func testInvalidAddressProducesFailingScript() throws {
        for bad in ["", "192.168.8", "1.2.3.4; reboot", "$(reboot)"] {
            let script = RouterSetup.script(macLANAddress: bad)
            XCTAssertTrue(script.contains("exit 1"), bad)
            XCTAssertFalse(script.contains("uci "), bad)
            XCTAssertFalse(script.contains("$("), bad)
            XCTAssertFalse(script.contains(";" + " reboot"), bad)
            XCTAssertNil(try shellSyntaxError(script), bad)
        }
    }

    func testSSHInvocation() throws {
        let invocation = try RouterSetup.sshInvocation(
            host: "192.168.8.1", user: "root", password: "s3cret pass'word",
            askpassPath: "/tmp/x/askpass.sh",
            baseEnvironment: ["PATH": "/usr/bin:/bin", "SSH_AUTH_SOCK": "/tmp/agent", "HOME": "/Users/test"])
        XCTAssertEqual(invocation.executable, "/usr/bin/ssh")
        XCTAssertEqual(invocation.arguments, [
            "-T",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-o", "PubkeyAuthentication=no",
            "-o", "PreferredAuthentications=keyboard-interactive,password",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "-l", "root",
            "192.168.8.1",
            "sh -s",
        ])
        XCTAssertFalse(invocation.arguments.joined(separator: " ").contains("s3cret"), "password never on the command line")
        XCTAssertEqual(invocation.environment["SSH_ASKPASS"], "/tmp/x/askpass.sh")
        XCTAssertEqual(invocation.environment["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertEqual(invocation.environment["DASHCAST_SSH_PASSWORD"], "s3cret pass'word")
        XCTAssertNotNil(invocation.environment["DISPLAY"])
        XCTAssertNil(invocation.environment["SSH_AUTH_SOCK"])
        XCTAssertEqual(invocation.environment["PATH"], "/usr/bin:/bin")
    }

    func testSSHRejectsOptionInjection() {
        XCTAssertThrowsError(try RouterSetup.sshInvocation(host: "-oProxyCommand=evil", user: "root", password: "x",
                                                           askpassPath: "/a", baseEnvironment: [:]))
        XCTAssertThrowsError(try RouterSetup.sshInvocation(host: "router lan", user: "root", password: "x",
                                                           askpassPath: "/a", baseEnvironment: [:]))
        XCTAssertThrowsError(try RouterSetup.sshInvocation(host: "192.168.8.1", user: "-l", password: "x",
                                                           askpassPath: "/a", baseEnvironment: [:]))
        XCTAssertThrowsError(try RouterSetup.sshInvocation(host: "192.168.8.1", user: "root@x", password: "x",
                                                           askpassPath: "/a", baseEnvironment: [:]))
        XCTAssertNoThrow(try RouterSetup.sshInvocation(host: "console.gl-inet.com", user: "root", password: "x",
                                                       askpassPath: "/a", baseEnvironment: [:]))
    }

    /// The askpass helper prints exactly the password from the environment and holds no secret itself.
    func testAskpassScriptEchoesPasswordFromEnvironment() throws {
        let askpass = try RouterSetup.writeAskpass()
        defer { try? FileManager.default.removeItem(at: askpass.directory) }
        let attributes = try FileManager.default.attributesOfItem(atPath: askpass.script.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let dirAttributes = try FileManager.default.attributesOfItem(atPath: askpass.directory.path)
        XCTAssertEqual((dirAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        let process = Process()
        process.executableURL = askpass.script
        process.environment = ["DASHCAST_SSH_PASSWORD": "p@ss word 'quoted' $HOME"]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                       "p@ss word 'quoted' $HOME\n")
        XCTAssertFalse(RouterSetup.askpassScript.contains("p@ss"))
    }

    @MainActor
    func testApplyRouterSetupRequiresRouterTopology() async {
        let world = FakeWorld()
        world.snapshot = InterfaceSnapshot(addresses: [InterfaceAddress(name: "en0", address: "172.20.10.3")],
                                           primaryInterface: "en0", kinds: ["en0": .wifi])
        let manager = NetworkManager(environment: makeEnvironment(world: world))
        do {
            try await manager.applyRouterSetup(host: "192.168.8.1", password: "x")
            XCTFail("expected invalidArgument")
        } catch NetworkError.invalidArgument(let message) {
            XCTAssertTrue(message.contains("travel router"), message)
        } catch {
            XCTFail("\(error)")
        }
    }
}
