import DashcastContracts
import Foundation
import Security
import XCTest
@testable import DashcastServer

/// Builds a throwaway root → intermediate → leaf chain with the system LibreSSL (the same tool the
/// network layer packages its PKCS#12 with) and exports leaf + intermediate as a .p12.
struct TestPKI {
    let dir: URL
    let p12: URL
    let rootDER: Data
    let passphrase = "dashcast-test"

    static func make() throws -> TestPKI {
        let openssl = "/usr/bin/openssl"
        guard FileManager.default.isExecutableFile(atPath: openssl) else { throw XCTSkip("no \(openssl)") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dashcast-pki-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func path(_ name: String) -> String { dir.appendingPathComponent(name).path }
        try "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n".write(toFile: path("ca.ext"), atomically: true, encoding: .utf8)
        try """
        basicConstraints=CA:FALSE
        keyUsage=critical,digitalSignature,keyEncipherment
        extendedKeyUsage=serverAuth
        subjectAltName=DNS:localhost,IP:127.0.0.1,DNS:\(DashcastDefaults.hostname)
        """.write(toFile: path("leaf.ext"), atomically: true, encoding: .utf8)

        func run(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: openssl)
            p.arguments = args
            p.currentDirectoryURL = dir
            p.standardOutput = FileHandle.nullDevice
            let err = Pipe()
            p.standardError = err
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw NSError(domain: "openssl", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(args.first ?? "") failed: \(text)"])
            }
        }
        for name in ["root", "int", "leaf"] { try run(["genrsa", "-out", "\(name).key", "2048"]) }
        try run(["req", "-new", "-key", "root.key", "-subj", "/CN=Dashcast Test Root", "-out", "root.csr"])
        try run(["x509", "-req", "-sha256", "-in", "root.csr", "-signkey", "root.key", "-days", "3", "-extfile", "ca.ext", "-out", "root.pem"])
        try run(["req", "-new", "-key", "int.key", "-subj", "/CN=Dashcast Test Intermediate", "-out", "int.csr"])
        try run(["x509", "-req", "-sha256", "-in", "int.csr", "-CA", "root.pem", "-CAkey", "root.key", "-CAcreateserial",
                 "-days", "3", "-extfile", "ca.ext", "-out", "int.pem"])
        try run(["req", "-new", "-key", "leaf.key", "-subj", "/CN=localhost", "-out", "leaf.csr"])
        try run(["x509", "-req", "-sha256", "-in", "leaf.csr", "-CA", "int.pem", "-CAkey", "int.key", "-CAcreateserial",
                 "-days", "3", "-extfile", "leaf.ext", "-out", "leaf.pem"])
        let chain = try String(contentsOfFile: path("leaf.pem"), encoding: .utf8) + String(contentsOfFile: path("int.pem"), encoding: .utf8)
        try chain.write(toFile: path("fullchain.pem"), atomically: true, encoding: .utf8)
        try run(["pkcs12", "-export", "-in", "fullchain.pem", "-inkey", "leaf.key", "-name", "dashcast",
                 "-out", "leaf.p12", "-passout", "pass:dashcast-test"])
        try run(["x509", "-in", "root.pem", "-outform", "DER", "-out", "root.der"])
        return TestPKI(dir: dir, p12: dir.appendingPathComponent("leaf.p12"),
                       rootDER: try Data(contentsOf: dir.appendingPathComponent("root.der")))
    }

    var material: TLSMaterial { TLSMaterial(pkcs12URL: p12, passphrase: passphrase) }
}

/// Trusts only the test root, so verification succeeds only if the server sends the intermediate.
final class PinnedRootDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let root: SecCertificate
    private let lock = NSLock()
    private var _presentedChainLength = 0
    var presentedChainLength: Int { lock.lock(); defer { lock.unlock() }; return _presentedChainLength }

    init(rootDER: Data) { root = SecCertificateCreateWithData(nil, rootDER as CFData)! }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    private func handle(_ challenge: URLAuthenticationChallenge,
                        _ completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return completion(.performDefaultHandling, nil) }
        lock.lock()
        _presentedChainLength = SecTrustGetCertificateCount(trust)
        lock.unlock()
        SecTrustSetAnchorCertificates(trust, [root] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        SecTrustSetNetworkFetchAllowed(trust, false)   // no AIA fetching: the intermediate must come from the server
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            completion(.useCredential, URLCredential(trust: trust))
        } else {
            completion(.cancelAuthenticationChallenge, nil)
        }
    }
}

@MainActor
final class TLSIntegrationTests: XCTestCase {
    var service: DashcastService?

    override func tearDown() async throws {
        await service?.stop()
        service = nil
    }

    func testIdentityLoadsInMemoryWithChain() throws {
        let pki = try TestPKI.make()
        defer { try? FileManager.default.removeItem(at: pki.dir) }
        let identity = try TLSIdentity.load(pki.material)
        XCTAssertEqual(identity.commonName, "localhost")
        let expiry = try XCTUnwrap(identity.expiry)
        XCTAssertGreaterThan(expiry, Date().addingTimeInterval(2 * 86_400))
        XCTAssertThrowsError(try TLSIdentity.load(TLSMaterial(pkcs12URL: pki.p12, passphrase: "wrong")))
    }

    func testHTTPSAndWSSWithFullChain() async throws {
        let pki = try TestPKI.make()
        defer { try? FileManager.default.removeItem(at: pki.dir) }
        let engine = MockEngine()
        let network = MockNetwork()
        network.material = pki.material
        var options = ServerOptions()
        options.devPort = 0
        options.tlsHost = "127.0.0.1"
        options.tlsPort = 0
        options.plainHTTPPort = nil
        let service = DashcastService(engine: engine, network: network, options: options)
        self.service = service
        await service.start()
        let port = try XCTUnwrap(service.tlsPort, service.state.log.map(\.message).joined(separator: "\n"))
        XCTAssertTrue(service.state.log.contains { $0.message.contains("Listening on https://\(DashcastDefaults.hostname) (127.0.0.1:\(port))") })

        let delegate = PinnedRootDelegate(rootDER: pki.rootDER)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (body, response) = try await session.data(from: URL(string: "https://localhost:\(port)/healthz")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "ok")
        XCTAssertEqual(delegate.presentedChainLength, 2, "server should send leaf + intermediate")

        // Connectivity probes are plain-HTTP only; over TLS the host allowlist applies.
        let (page, pageResponse) = try await session.data(from: URL(string: "https://localhost:\(port)/")!)
        XCTAssertEqual((pageResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertFalse(page.isEmpty)

        // wss:// end to end.
        let client = WSClient(url: URL(string: "wss://localhost:\(port)/ws")!, delegate: delegate)
        defer { client.close() }
        try await client.send(Fixtures.mcu3Hello)
        let streaming = await waitUntil(timeout: 5) { !client.texts("config").isEmpty && client.headers(.videoHEVC).count > 3 }
        XCTAssertTrue(streaming, "error: \(String(describing: client.error))")
        XCTAssertEqual(client.texts("config").first?["tier"] as? String, "mcu3-hevc")

        // Renewed certificate on disk → refreshNetwork reloads the listener.
        let renewed = try TestPKI.make()
        defer { try? FileManager.default.removeItem(at: renewed.dir) }
        try FileManager.default.removeItem(at: pki.p12)
        try FileManager.default.copyItem(at: renewed.p12, to: pki.p12)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: pki.p12.path)
        await service.refreshNetwork()
        XCTAssertTrue(service.state.log.contains { $0.message.contains("reloaded certificate") },
                      service.state.log.map(\.message).joined(separator: "\n"))
        let reloadedPort = try XCTUnwrap(service.tlsPort)
        let renewedDelegate = PinnedRootDelegate(rootDER: renewed.rootDER)
        let renewedSession = URLSession(configuration: .ephemeral, delegate: renewedDelegate, delegateQueue: nil)
        defer { renewedSession.invalidateAndCancel() }
        let (again, _) = try await renewedSession.data(from: URL(string: "https://localhost:\(reloadedPort)/healthz")!)
        XCTAssertEqual(String(decoding: again, as: UTF8.self), "ok")
    }
}
