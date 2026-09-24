import AppKit
import DashcastContracts
import XCTest
@testable import DashcastNetwork

final class LoopbackHelperTests: XCTestCase {
    private let production = HelperLayout.production

    func testPlistContents() throws {
        let data = try LoopbackHelper.plistData()
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, "online.davidlam.dashcast.alias")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/bin/sh", "/Library/PrivilegedHelperTools/online.davidlam.dashcast.netsetup"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["StartInterval"] as? Int, 60)
        XCTAssertEqual(plist["WatchPaths"] as? [String], ["/Library/Preferences/SystemConfiguration",
                                                          "/Library/Application Support/Dashcast/dns-trigger"])
        XCTAssertEqual(plist["EnvironmentVariables"] as? [String: String], ["DASHCAST_HELPER_VERSION": "2"])
        XCTAssertNil(plist["KeepAlive"])
        XCTAssertEqual(LoopbackHelper.installedVersion(plist: data), 2)
    }

    func testInstalledVersionOfOlderPlists() throws {
        let v1: [String: Any] = ["Label": LoopbackHelper.label, "RunAtLoad": true,
                                 "ProgramArguments": ["/sbin/ifconfig", "lo0", "alias", "\(svc)/32"]]
        XCTAssertEqual(LoopbackHelper.installedVersion(plist: try PropertyListSerialization.data(fromPropertyList: v1, format: .xml, options: 0)), 1)
        XCTAssertEqual(LoopbackHelper.installedVersion(plist: Data("garbage".utf8)), 1)
    }

    func testPlistPassesPlutilLint() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dashcast-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        try LoopbackHelper.plistData().write(to: url)
        let output = try sh("/usr/bin/plutil", ["-lint", url.path])
        XCTAssertTrue(output.contains("OK"), output)
    }

    func testPfRules() throws {
        XCTAssertEqual(LoopbackHelper.pfRules(),
                       "rdr pass on bridge100 inet proto { udp tcp } from any to any port 53 -> \(svc) port 53530\n")
        XCTAssertEqual(LoopbackHelper.pfAnchor, "com.apple/250.DashcastDNS")
    }

    /// `pfctl -n` parses without loading anything (and works without root on this macOS).
    func testPfRulesParseWithPfctl() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dashcast-\(UUID().uuidString).pf")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(LoopbackHelper.pfRules().utf8).write(to: url)
        let output = try sh("/sbin/pfctl", ["-a", LoopbackHelper.pfAnchor, "-nvf", url.path])
        XCTAssertTrue(output.contains("rdr pass on bridge100 inet proto udp from any to any port = 53 -> \(svc) port 53530"), output)
        XCTAssertTrue(output.contains("rdr pass on bridge100 inet proto tcp from any to any port = 53 -> \(svc) port 53530"), output)
    }

    /// The default pf.conf really has the anchor point the rules go under.
    func testSystemPfConfHasComAppleRdrAnchor() throws {
        let conf = try String(contentsOfFile: "/etc/pf.conf", encoding: .utf8)
        XCTAssertTrue(conf.contains("rdr-anchor \"com.apple/*\""), conf)
    }

    func testScriptParses() throws {
        let script = LoopbackHelper.script()
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(script.contains("# dashcast-helper-version: 2"))
        XCTAssertTrue(script.contains("PATH='/usr/bin:/bin:/usr/sbin:/sbin'"))
        XCTAssertTrue(script.contains("RULES='rdr pass on bridge100 inet proto { udp tcp } from any to any port 53 -> \(svc) port 53530'"))
        XCTAssertNil(try shellSyntaxError(script))
    }

    func testInstallCommand() throws {
        let plist = try LoopbackHelper.plistData()
        let script = Data(LoopbackHelper.script().utf8)
        let command = LoopbackHelper.installShellCommand(plist: plist, script: script, uid: 501)
        let plistPath = "'/Library/LaunchDaemons/online.davidlam.dashcast.alias.plist'"
        let scriptPath = "'/Library/PrivilegedHelperTools/online.davidlam.dashcast.netsetup'"
        let trigger = "'/Library/Application Support/Dashcast/dns-trigger'"
        XCTAssertEqual(command.components(separatedBy: " && "), [
            "/bin/mkdir -p '/Library/LaunchDaemons' '/Library/PrivilegedHelperTools' '/Library/Application Support/Dashcast'",
            "/bin/echo '\(script.base64EncodedString())' | /usr/bin/base64 -D > \(scriptPath)",
            "/usr/sbin/chown root:wheel \(scriptPath)",
            "/bin/chmod 755 \(scriptPath)",
            "/usr/bin/touch \(trigger)",
            "/usr/sbin/chown 501 \(trigger)",
            "/bin/chmod 644 \(trigger)",
            "/bin/echo '\(plist.base64EncodedString())' | /usr/bin/base64 -D > \(plistPath)",
            "/usr/sbin/chown root:wheel \(plistPath)",
            "/bin/chmod 644 \(plistPath)",
            "{ /bin/launchctl bootout system/online.davidlam.dashcast.alias >/dev/null 2>&1 || true; }",
            "{ /bin/launchctl bootstrap system \(plistPath) || { /bin/sleep 1; /bin/launchctl bootstrap system \(plistPath); }; }",
            "/bin/sh \(scriptPath)",
        ])
        XCTAssertNil(try shellSyntaxError(command))
    }

    /// Both embedded payloads decode (with macOS's own base64) back to exactly what we generated.
    func testInstallCommandPayloadsDecode() throws {
        let plist = try LoopbackHelper.plistData()
        let script = Data(LoopbackHelper.script().utf8)
        let command = LoopbackHelper.installShellCommand(plist: plist, script: script, uid: 501)
        let quoted = command.components(separatedBy: "/bin/echo '").dropFirst().map { $0.components(separatedBy: "'")[0] }
        XCTAssertEqual(quoted.count, 2)
        for (b64, expected) in zip(quoted, [script, plist]) {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("dashcast-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: out) }
            try sh("/bin/sh", ["-c", "/bin/echo '\(b64)' | /usr/bin/base64 -D > '\(out.path)'"])
            XCTAssertEqual(try Data(contentsOf: out), expected)
        }
    }

    func testUninstallCommand() throws {
        let command = LoopbackHelper.uninstallShellCommand()
        XCTAssertEqual(command, [
            "/bin/launchctl bootout system/online.davidlam.dashcast.alias >/dev/null 2>&1",
            "/bin/rm -f '/Library/LaunchDaemons/online.davidlam.dashcast.alias.plist' '/Library/PrivilegedHelperTools/online.davidlam.dashcast.netsetup' '/Library/Application Support/Dashcast/dns-trigger'",
            "/bin/rmdir '/Library/Application Support/Dashcast' >/dev/null 2>&1",
            "/sbin/pfctl -a 'com.apple/250.DashcastDNS' -F all >/dev/null 2>&1",
            "t=$(/bin/cat '/var/run/online.davidlam.dashcast.pf-token' 2>/dev/null)",
            "if [ -n \"$t\" ]; then /sbin/pfctl -X \"$t\" >/dev/null 2>&1; fi",
            "/bin/rm -f '/var/run/online.davidlam.dashcast.pf-token' '/var/run/online.davidlam.dashcast.status'",
            "/sbin/ifconfig lo0 -alias \(svc) >/dev/null 2>&1",
            "exit 0",
        ].joined(separator: "; "))
        XCTAssertNil(try shellSyntaxError(command))
    }

    func testAppleScriptSourcesCompile() throws {
        let install = LoopbackHelper.installShellCommand(plist: try LoopbackHelper.plistData(),
                                                         script: Data(LoopbackHelper.script().utf8), uid: 501)
        for command in [install, LoopbackHelper.uninstallShellCommand()] {
            let source = LoopbackHelper.appleScriptSource(shellCommand: command, prompt: "Dashcast needs \"admin\" rights")
            XCTAssertTrue(source.hasPrefix("do shell script \""))
            XCTAssertTrue(source.hasSuffix("with administrator privileges"))
            // Compiling parses the script without running it (no password prompt).
            let script = try XCTUnwrap(NSAppleScript(source: source))
            var error: NSDictionary?
            XCTAssertTrue(script.compileAndReturnError(&error), "\(String(describing: error))")
        }
    }

    func testAppleScriptEscape() {
        XCTAssertEqual(LoopbackHelper.appleScriptEscape(#"a\b"c"#), #"a\\b\"c"#)
        XCTAssertEqual(LoopbackHelper.shellQuote("it's"), #"'it'\''s'"#)
    }

    func testRuntimeStatusParse() {
        let on = LoopbackHelper.RuntimeStatus.parse("version=2\nredirect=on\nreason=\nanchor=ok\n")
        XCTAssertEqual(on, .init(version: 2, redirectActive: true, reason: nil, anchorPointPresent: true))
        let off = LoopbackHelper.RuntimeStatus.parse("version=2\nredirect=off\nreason=dns-not-listening\nanchor=missing\n")
        XCTAssertEqual(off, .init(version: 2, redirectActive: false, reason: "dns-not-listening", anchorPointPresent: false))
    }

    // MARK: Manager flows (fake privileged runner: no prompt)

    @MainActor
    func testInstallFlowUsesRunnerAndVerifies() async throws {
        let world = FakeWorld()
        world.snapshot = InterfaceSnapshot(addresses: [InterfaceAddress(name: "lo0", address: "127.0.0.1")])
        let runner = FakePrivilegedRunner()
        let manager = NetworkManager(environment: makeEnvironment(world: world, runner: runner))
        XCTAssertNil(manager.installedHelperVersion())
        runner.onRun = { _ in
            try? world.installHelper()
            world.snapshot.addresses.append(InterfaceAddress(name: "lo0", address: svc))
        }
        try await manager.installLoopbackHelper()
        XCTAssertEqual(runner.commands.count, 1)
        let layout = HelperLayout.fake
        XCTAssertEqual(runner.commands[0].command, LoopbackHelper.installShellCommand(
            plist: try LoopbackHelper.plistData(layout: layout), script: Data(LoopbackHelper.script(layout: layout).utf8),
            uid: 501, layout: layout))
        XCTAssertTrue(runner.commands[0].prompt.contains(svc))
        XCTAssertEqual(manager.installedHelperVersion(), 2)
        XCTAssertFalse(manager.helperNeedsUpdate)

        runner.onRun = { _ in
            world.removeHelper()
            world.snapshot.addresses.removeAll { $0.address == svc }
        }
        try await manager.uninstallLoopbackHelper()
        XCTAssertEqual(runner.commands.last?.command, LoopbackHelper.uninstallShellCommand(layout: layout))
        XCTAssertNil(manager.installedHelperVersion())
    }

    @MainActor
    func testOutdatedHelperIsReportedAndUpgraded() async throws {
        let world = FakeWorld()
        world.reachable = false
        world.snapshot = InterfaceSnapshot(addresses: [InterfaceAddress(name: "lo0", address: svc),
                                                       InterfaceAddress(name: "en0", address: "192.168.8.20")],
                                           primaryInterface: "en0", kinds: ["en0": .wifi])
        try world.installHelper(version: 1)
        let runner = FakePrivilegedRunner()
        let manager = NetworkManager(environment: makeEnvironment(world: world, runner: runner))
        XCTAssertEqual(manager.installedHelperVersion(), 1)
        XCTAssertTrue(manager.helperNeedsUpdate)
        var status = await manager.currentStatus()
        XCTAssertFalse(status.helperInstalled, "an outdated helper reads as not installed so the UI offers the install")
        XCTAssertTrue(status.summary.contains("update the network helper (v1 → v2)"), status.summary)

        // A v2 plist whose script went missing is treated as needing a reinstall too.
        try world.installHelper()
        world.files.remove(HelperLayout.fake.scriptPath)
        XCTAssertEqual(manager.installedHelperVersion(), 1)

        runner.onRun = { _ in try? world.installHelper() }
        try await manager.installLoopbackHelper()
        status = await manager.currentStatus()
        XCTAssertTrue(status.helperInstalled)
        XCTAssertFalse(status.summary.contains("network helper"), status.summary)
    }

    @MainActor
    func testInstallReportsAliasMissingAndCancellation() async throws {
        let world = FakeWorld()
        let runner = FakePrivilegedRunner()
        let manager = NetworkManager(environment: makeEnvironment(world: world, runner: runner))
        runner.onRun = { _ in try? world.installHelper() }
        do {
            try await manager.installLoopbackHelper()
            XCTFail("expected helperDidNotApply")
        } catch NetworkError.helperDidNotApply(let message) {
            XCTAssertTrue(message.contains("isn't on lo0"), message)
        }
        runner.error = NetworkError.userCancelled
        do {
            try await manager.installLoopbackHelper()
            XCTFail("expected userCancelled")
        } catch NetworkError.userCancelled {}
    }
}
