import XCTest
@testable import DashcastNetwork

/// Runs the real helper script (as the current user) against stub `ifconfig`/`pfctl`/`netstat`/
/// `defaults`/`sleep` that record what they're asked to do. Nothing touches the real network or pf.
final class HelperScriptTests: XCTestCase {
    private var root: URL!
    private var state: URL!
    private var layout: HelperLayout!
    private var scriptURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dashcast-helper-\(UUID().uuidString)", isDirectory: true)
        state = root.appendingPathComponent("state", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let run = root.appendingPathComponent("run", isDirectory: true)
        for dir in [state!, bin, run] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

        let stubs: [String: String] = [
            "ifconfig": """
            #!/bin/sh
            echo "ifconfig $*" >> "$STATE/log"
            if [ "$1" = lo0 ]; then
              if [ "$2" = alias ]; then printf '\\tinet %s netmask 0xffffffff\\n' "${3%/32}" >> "$STATE/lo0"; exit 0; fi
              cat "$STATE/lo0" 2>/dev/null; exit 0
            fi
            [ -f "$STATE/iface-$1" ]
            """,
            "netstat": "#!/bin/sh\ncat \"$STATE/netstat\" 2>/dev/null\nexit 0\n",
            "defaults": "#!/bin/sh\ncat \"$STATE/nat\" 2>/dev/null\nexit 0\n",
            "sleep": """
            #!/bin/sh
            echo "sleep $*" >> "$STATE/log"
            if [ -f "$STATE/bridge-after-sleep" ]; then touch "$STATE/iface-bridge100"; fi
            exit 0
            """,
            "pfctl": """
            #!/bin/sh
            echo "pfctl $*" >> "$STATE/log"
            case "$*" in
              "-s nat") cat "$STATE/main-nat" 2>/dev/null ;;
              "-a com.apple/250.DashcastDNS -s nat") cat "$STATE/anchor" 2>/dev/null ;;
              "-a com.apple/250.DashcastDNS -f -") cat > "$STATE/anchor" ;;
              "-a com.apple/250.DashcastDNS -F all") rm -f "$STATE/anchor" ;;
              "-s References") cat "$STATE/refs" 2>/dev/null ;;
              "-E") echo "No ALTQ support in kernel" >&2; echo "pf enabled" >&2; echo "Token : 424242" >&2; echo 424242 >> "$STATE/refs" ;;
              "-X "*) grep -v "^$2\\$" "$STATE/refs" > "$STATE/refs.new"; mv "$STATE/refs.new" "$STATE/refs" ;;
            esac
            exit 0
            """,
        ]
        for (name, body) in stubs {
            let url = bin.appendingPathComponent(name)
            try Data((body + "\n").utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        layout = HelperLayout(plistPath: root.appendingPathComponent("helper.plist").path,
                              scriptPath: root.appendingPathComponent("netsetup").path,
                              triggerDirectory: root.path,
                              triggerPath: root.appendingPathComponent("dns-trigger").path,
                              tokenPath: run.appendingPathComponent("pf-token").path,
                              statusPath: run.appendingPathComponent("status").path,
                              natPreferences: root.appendingPathComponent("com.apple.nat").path,
                              searchPath: "\(bin.path):/usr/bin:/bin")
        scriptURL = URL(fileURLWithPath: layout.scriptPath)
        try Data(LoopbackHelper.script(layout: layout).utf8).write(to: scriptURL)
        // The main ruleset has Apple's anchor point, as on a stock Mac.
        try write("main-nat", "nat-anchor \"com.apple/*\" all\nrdr-anchor \"com.apple/*\" all\n")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: state.appendingPathComponent(name))
    }

    private func read(_ name: String) -> String? {
        try? String(contentsOf: state.appendingPathComponent(name), encoding: .utf8)
    }

    private func remove(_ name: String) { try? FileManager.default.removeItem(at: state.appendingPathComponent(name)) }

    private var status: LoopbackHelper.RuntimeStatus? {
        (try? String(contentsOfFile: layout.statusPath, encoding: .utf8)).map(LoopbackHelper.RuntimeStatus.parse)
    }

    /// Runs the script once and returns the commands it issued.
    @discardableResult
    private func runScript() throws -> [String] {
        remove("log")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        process.environment = ["STATE": state.path]
        let err = Pipe()
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        return (read("log") ?? "").split(separator: "\n").map(String.init)
    }

    private var listeningLine: String { "udp4       0      0  \(svc).53530         *.*\n" }

    func testNoHotspotAddsAliasAndNoRedirect() throws {
        let log = try runScript()
        XCTAssertTrue(log.contains("ifconfig lo0 alias \(svc)/32"), "\(log)")
        XCTAssertFalse(log.contains("pfctl -E"))
        XCTAssertEqual(status, .init(version: 2, redirectActive: false, reason: "no-hotspot", anchorPointPresent: true))

        // Alias already present → not re-added.
        let again = try runScript()
        XCTAssertFalse(again.contains("ifconfig lo0 alias \(svc)/32"), "\(again)")
    }

    func testHotspotWithResponderLoadsAnchorAndEnablesPfOnce() throws {
        try write("iface-bridge100", "")
        try write("netstat", "udp4       0      0  *.5353                 *.*\n" + listeningLine)
        let log = try runScript()
        XCTAssertTrue(log.contains("pfctl -a com.apple/250.DashcastDNS -f -"), "\(log)")
        XCTAssertEqual(read("anchor"), LoopbackHelper.pfRules())
        XCTAssertTrue(log.contains("pfctl -E"))
        XCTAssertEqual(try String(contentsOfFile: layout.tokenPath, encoding: .utf8), "424242\n")
        XCTAssertEqual(status, .init(version: 2, redirectActive: true, reason: nil, anchorPointPresent: true))

        // Idempotent: the rules are there and the token is still referenced → nothing to do.
        let again = try runScript()
        XCTAssertFalse(again.contains("pfctl -E"), "\(again)")
        XCTAssertFalse(again.contains("pfctl -a com.apple/250.DashcastDNS -f -"), "\(again)")
        XCTAssertEqual(read("refs"), "424242\n", "exactly one enable reference")

        // Dashcast quits: the responder is gone → redirect removed, reference released.
        try write("netstat", "udp4       0      0  *.5353                 *.*\n")
        let off = try runScript()
        XCTAssertTrue(off.contains("pfctl -a com.apple/250.DashcastDNS -F all"), "\(off)")
        XCTAssertTrue(off.contains("pfctl -X 424242"), "\(off)")
        XCTAssertNil(read("anchor"))
        XCTAssertEqual(read("refs"), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.tokenPath))
        XCTAssertEqual(status, .init(version: 2, redirectActive: false, reason: "dns-not-listening", anchorPointPresent: true))
    }

    func testResponderOnOtherPortOrAddressDoesNotCount() throws {
        try write("iface-bridge100", "")
        try write("netstat", "udp4  0  0  \(svc).535300   *.*\nudp4  0  0  127.0.0.1.53530   *.*\n")
        let log = try runScript()
        XCTAssertFalse(log.contains("pfctl -E"), "\(log)")
        XCTAssertEqual(status?.reason, "dns-not-listening")
    }

    func testStaleTokenIsReplaced() throws {
        try write("iface-bridge100", "")
        try write("netstat", listeningLine)
        try Data("999\n".utf8).write(to: URL(fileURLWithPath: layout.tokenPath)) // e.g. from before a reboot
        let log = try runScript()
        XCTAssertTrue(log.contains("pfctl -E"), "\(log)")
        XCTAssertEqual(try String(contentsOfFile: layout.tokenPath, encoding: .utf8), "424242\n")
    }

    func testWaitsForBridgeWhenSharingJustTurnedOn() throws {
        try write("nat", "{\n    NAT = {\n        Enabled = 1;\n    };\n}\n")
        try write("bridge-after-sleep", "")
        try write("netstat", listeningLine)
        let log = try runScript()
        XCTAssertEqual(log.filter { $0 == "sleep 1" }.count, 1, "\(log)")
        XCTAssertEqual(status?.redirectActive, true)
    }

    func testGivesUpWaitingAfterTwentySeconds() throws {
        try write("nat", "{ NAT = { Enabled = 1; }; }\n")
        let log = try runScript()
        XCTAssertEqual(log.filter { $0 == "sleep 1" }.count, 20)
        XCTAssertEqual(status?.reason, "no-hotspot")
    }

    func testReportsMissingAnchorPoint() throws {
        try write("main-nat", "")
        try runScript()
        XCTAssertEqual(status?.anchorPointPresent, false)
    }
}
