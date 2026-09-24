import DashcastContracts
import Foundation
import Network
import XCTest
@testable import DashcastNetwork

/// The contract's service address (the DNS record, the lo0 alias and the router route all follow it).
let svc = DashcastDefaults.serviceAddress

/// Intercepts every request made through a session built with `StubURLProtocol.session()`.
final class StubURLProtocol: URLProtocol {
    struct Recorded { var request: URLRequest; var body: Data? }
    typealias Handler = (URLRequest, Data?) throws -> (Int, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: Handler?
    nonisolated(unsafe) private static var _recorded: [Recorded] = []

    static func reset(_ handler: @escaping Handler) {
        lock.lock(); _handler = handler; _recorded = []; lock.unlock()
    }
    static var recorded: [Recorded] { lock.lock(); defer { lock.unlock() }; return _recorded }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        Self.lock.lock()
        Self._recorded.append(Recorded(request: request, body: body))
        let handler = Self._handler
        Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.unsupportedURL) }
            let (status, data) = try handler(request, body)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

final class InMemorySecretStore: SecretStore {
    var values: [String: String] = [:]
    func read(_ account: String) throws -> String? { values[account] }
    func exists(_ account: String) -> Bool { values[account] != nil }
    func write(_ value: String, account: String) throws { values[account] = value }
    func delete(_ account: String) throws { values[account] = nil }
}

@MainActor
final class FakePrivilegedRunner: PrivilegedRunner {
    var commands: [(command: String, prompt: String)] = []
    var error: Error?
    var onRun: ((String) -> Void)?
    func run(shellCommand: String, prompt: String) async throws -> String {
        commands.append((shellCommand, prompt))
        if let error { throw error }
        onRun?(shellCommand)
        return ""
    }
}

/// Mutable fake world the test environment reads from.
final class FakeWorld: @unchecked Sendable {
    var snapshot = InterfaceSnapshot(addresses: [])
    var files: Set<String> = []
    var contents: [String: Data] = [:]
    var touched: [String] = []
    var executables: Set<String> = []
    var reachable = true
    var now = Date()
    var runningApps: [String] = []
    var upstreams: [NWEndpoint] = []

    /// Pretend the current helper (plist + script) is installed.
    func installHelper(version: Int = LoopbackHelper.version, layout: HelperLayout = .fake) throws {
        files.insert(layout.plistPath)
        files.insert(layout.scriptPath)
        if version >= 2 {
            contents[layout.plistPath] = try LoopbackHelper.plistData(layout: layout)
        } else {
            let v1: [String: Any] = ["Label": LoopbackHelper.label, "RunAtLoad": true,
                                     "ProgramArguments": ["/sbin/ifconfig", "lo0", "alias", "\(svc)/32"]]
            contents[layout.plistPath] = try PropertyListSerialization.data(fromPropertyList: v1, format: .xml, options: 0)
            files.remove(layout.scriptPath)
        }
    }

    func removeHelper(layout: HelperLayout = .fake) {
        files.remove(layout.plistPath)
        files.remove(layout.scriptPath)
        contents[layout.plistPath] = nil
    }
}

extension HelperLayout {
    static let fake = HelperLayout(
        plistPath: "/fake/online.davidlam.dashcast.alias.plist",
        scriptPath: "/fake/online.davidlam.dashcast.netsetup",
        triggerDirectory: "/fake/support",
        triggerPath: "/fake/support/dns-trigger",
        tokenPath: "/fake/run/pf-token",
        statusPath: "/fake/run/status",
        natPreferences: "/fake/com.apple.nat",
        searchPath: "/usr/bin:/bin")
}

@MainActor
func makeEnvironment(world: FakeWorld, secrets: SecretStore = InMemorySecretStore(),
                     runner: PrivilegedRunner? = nil,
                     appSupport: URL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("dashcast-tests-\(UUID().uuidString)"),
                     session: URLSession = StubURLProtocol.session()) -> NetworkEnvironment {
    NetworkEnvironment(
        appSupportDir: appSupport,
        helperLayout: .fake,
        secrets: secrets,
        session: session,
        privilegedRunner: runner ?? FakePrivilegedRunner(),
        snapshot: { world.snapshot },
        fileExists: { world.files.contains($0) || FileManager.default.fileExists(atPath: $0) },
        isExecutable: { world.executables.contains($0) },
        bundleResourceURL: nil,
        defaults: UserDefaults(suiteName: "dashcast-tests-\(UUID().uuidString)")!,
        now: { world.now },
        internetReachable: { world.reachable },
        runningApplicationNames: { world.runningApps },
        openssl: PKCS12.opensslPath,
        readFile: { world.contents[$0] ?? FileManager.default.contents(atPath: $0) },
        touchFile: { world.touched.append($0) },
        uid: 501,
        localDNSHost: "127.0.0.1",
        localDNSPort: 0,
        dnsUpstreams: { world.upstreams })
}

/// Runs /bin/sh -n (parse only, executes nothing) over a script and returns stderr on failure.
func shellSyntaxError(_ script: String) throws -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-n", "-c", script]
    let err = Pipe()
    process.standardError = err
    try process.run()
    process.waitUntilExit()
    let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return process.terminationStatus == 0 ? nil : text
}

/// Runs a command synchronously for test fixtures; fails the test on a non-zero exit.
@discardableResult
func sh(_ executable: String, _ arguments: [String], cwd: URL? = nil,
        file: StaticString = #filePath, line: UInt = #line) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let cwd { process.currentDirectoryURL = cwd }
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: outData, as: UTF8.self) + String(decoding: errData, as: UTF8.self)
    XCTAssertEqual(process.terminationStatus, 0, "\(executable) \(arguments.joined(separator: " ")): \(text)", file: file, line: line)
    return text
}
