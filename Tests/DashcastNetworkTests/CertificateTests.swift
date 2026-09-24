import Network
import Security
import XCTest
@testable import DashcastNetwork

/// Real openssl → PKCS#12 → SecPKCS12Import(kSecImportToMemoryOnly) → SecIdentity, with fixtures
/// shaped like lego's output (EC P-256 key in SEC1 PEM, leaf + issuer bundle in the .crt).
final class CertificateTests: XCTestCase {
    private var dir: URL!
    private let openssl = "/usr/bin/openssl"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dashcast-cert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Writes `<base>/certificates/car.davidlam.online.{crt,key}` the way lego does.
    @discardableResult
    private func makeLegoFixture(in base: URL, ecKey: Bool = true, days: Int = 90) throws -> (crt: URL, key: URL) {
        let work = base.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        let certs = base.appendingPathComponent("certificates", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: certs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        try sh(openssl, ["req", "-x509", "-new", "-nodes", "-newkey", "rsa:2048", "-keyout", "ca.key", "-out", "ca.pem",
                         "-days", "365", "-subj", "/CN=Dashcast Test Issuer"], cwd: work)
        if ecKey {
            try sh(openssl, ["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "leaf.key"], cwd: work)
        } else {
            try sh(openssl, ["genrsa", "-out", "leaf.key", "2048"], cwd: work)
        }
        try sh(openssl, ["req", "-new", "-key", "leaf.key", "-subj", "/CN=car.davidlam.online", "-out", "leaf.csr"], cwd: work)
        try sh(openssl, ["x509", "-req", "-in", "leaf.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-set_serial", "4242",
                         "-days", String(days), "-out", "leaf.pem"], cwd: work)

        let crt = certs.appendingPathComponent("car.davidlam.online.crt")
        let key = certs.appendingPathComponent("car.davidlam.online.key")
        let bundle = try Data(contentsOf: work.appendingPathComponent("leaf.pem")) + Data(contentsOf: work.appendingPathComponent("ca.pem"))
        try bundle.write(to: crt)
        try FileManager.default.copyItem(at: work.appendingPathComponent("leaf.key"), to: key)
        return (crt, key)
    }

    func testOpenSSLIsLibreSSL() throws {
        let version = try sh(openssl, ["version"])
        print("[pkcs12] \(openssl) = \(version.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    func testPKCS12RoundTripECBundleLikeLego() async throws {
        let fixture = try makeLegoFixture(in: dir, ecKey: true)
        let output = dir.appendingPathComponent("car.davidlam.online.p12")
        let passphrase = RandomSecret.hex()

        let built = try await PKCS12.build(certificate: fixture.crt, key: fixture.key, output: output, passphrase: passphrase)
        print("[pkcs12] EC P-256 bundle accepted with variant: \(built.variant.isEmpty ? "default" : built.variant.joined(separator: " "))")

        // Re-import from disk, the way the TLS listener will.
        let imported = try PKCS12.importIdentity(Data(contentsOf: output), passphrase: passphrase)
        XCTAssertEqual(imported.subject, "car.davidlam.online", "identity's certificate must be the leaf, not the issuer")
        let notAfter = try XCTUnwrap(imported.notAfter)
        XCTAssertEqual(notAfter.timeIntervalSinceNow, 90 * 86_400, accuracy: 3_600)

        var key: SecKey?
        XCTAssertEqual(SecIdentityCopyPrivateKey(imported.identity, &key), errSecSuccess)
        let attributes = try XCTUnwrap(SecKeyCopyAttributes(XCTUnwrap(key)) as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrKeyType as String] as? String, kSecAttrKeyTypeECSECPrimeRandom as String)

        // Private key and certificate really pair: sign with the key, verify with the cert's public key.
        let message = Data("dashcast".utf8)
        var error: Unmanaged<CFError>?
        let signature = try XCTUnwrap(SecKeyCreateSignature(key!, .ecdsaSignatureMessageX962SHA256, message as CFData, &error) as Data?)
        let publicKey = try XCTUnwrap(SecCertificateCopyKey(imported.certificate))
        XCTAssertTrue(SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256, message as CFData, signature as CFData, &error))

        // Network.framework accepts it as a TLS identity.
        XCTAssertNotNil(sec_identity_create(imported.identity))

        // Stored 0600, and no temp files left behind.
        let permissions = try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    func testPKCS12RoundTripRSA() async throws {
        let fixture = try makeLegoFixture(in: dir, ecKey: false)
        let output = dir.appendingPathComponent("rsa.p12")
        let built = try await PKCS12.build(certificate: fixture.crt, key: fixture.key, output: output, passphrase: "pw")
        XCTAssertEqual(built.imported.subject, "car.davidlam.online")
    }

    /// Which openssl variants does SecPKCS12Import accept on this macOS? (Default must work.)
    func testEachVariantAgainstSecPKCS12Import() async throws {
        let fixture = try makeLegoFixture(in: dir)
        var accepted: [String] = []
        for variant in PKCS12.variants {
            let out = dir.appendingPathComponent("v-\(UUID().uuidString).p12")
            let args = PKCS12.exportArguments(certificate: fixture.crt, key: fixture.key, output: out,
                                              friendlyName: "car.davidlam.online", variant: variant)
            var env = ProcessInfo.processInfo.environment
            env[PKCS12.passphraseEnvironmentKey] = "pw"
            let result = try await ProcessRunner.run(openssl, args, environment: env, timeout: 30)
            let label = variant.isEmpty ? "default" : variant.joined(separator: " ")
            guard result.status == 0, let data = try? Data(contentsOf: out) else {
                print("[pkcs12] variant \(label): openssl refused (\(result.tail(1)))")
                continue
            }
            do {
                _ = try PKCS12.importIdentity(data, passphrase: "pw")
                accepted.append(label)
                print("[pkcs12] variant \(label): SecPKCS12Import OK")
            } catch {
                print("[pkcs12] variant \(label): SecPKCS12Import rejected: \(error.localizedDescription)")
            }
        }
        XCTAssertTrue(accepted.contains("default"), "LibreSSL default output should import; accepted: \(accepted)")
    }

    func testWrongPassphraseIsRejected() async throws {
        let fixture = try makeLegoFixture(in: dir)
        let output = dir.appendingPathComponent("x.p12")
        _ = try await PKCS12.build(certificate: fixture.crt, key: fixture.key, output: output, passphrase: "right")
        XCTAssertThrowsError(try PKCS12.importIdentity(Data(contentsOf: output), passphrase: "wrong")) { error in
            guard case NetworkError.pkcs12Rejected = error else { return XCTFail("\(error)") }
        }
    }

    func testBuildFailsCleanlyOnMismatchedKey() async throws {
        let a = try makeLegoFixture(in: dir.appendingPathComponent("a"))
        let b = try makeLegoFixture(in: dir.appendingPathComponent("b"))
        let output = dir.appendingPathComponent("bad.p12")
        do {
            _ = try await PKCS12.build(certificate: a.crt, key: b.key, output: output, passphrase: "pw")
            XCTFail("expected failure")
        } catch NetworkError.opensslFailed(let message) {
            XCTAssertFalse(message.isEmpty)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testPEMLeafExpiry() throws {
        let fixture = try makeLegoFixture(in: dir, days: 45)
        let expiry = try XCTUnwrap(PEM.leafExpiry(at: fixture.crt))
        XCTAssertEqual(expiry.timeIntervalSinceNow, 45 * 86_400, accuracy: 3_600)
        XCTAssertEqual(PEM.certificates(in: try String(contentsOf: fixture.crt, encoding: .utf8)).count, 2)
    }

    func testRenewalWindow() {
        let now = Date()
        XCTAssertTrue(PKCS12.needsRenewal(expiry: nil, now: now))
        XCTAssertTrue(PKCS12.needsRenewal(expiry: now.addingTimeInterval(29 * 86_400), now: now))
        XCTAssertTrue(PKCS12.needsRenewal(expiry: now.addingTimeInterval(-1), now: now))
        XCTAssertFalse(PKCS12.needsRenewal(expiry: now.addingTimeInterval(31 * 86_400), now: now))
    }

    // MARK: NetworkManager end to end (no network: lego output already on disk)

    @MainActor
    func testManagerPackagesLegoOutputAndServesTLSMaterial() async throws {
        let world = FakeWorld()
        let secrets = InMemorySecretStore()
        let appSupport = dir.appendingPathComponent("AppSupport/Dashcast", isDirectory: true)
        let manager = NetworkManager(environment: makeEnvironment(world: world, secrets: secrets, appSupport: appSupport))

        XCTAssertNil(manager.tlsMaterial())
        XCTAssertNil(manager.certificateExpiry())
        let nothingYet = try await manager.renewIfNeeded()
        XCTAssertFalse(nothingYet, "never issues a first certificate on its own")

        try makeLegoFixture(in: appSupport.appendingPathComponent("lego"))
        let rebuilt = try await manager.renewIfNeeded()
        XCTAssertTrue(rebuilt, "fresh lego PEM without a .p12 → repackage")

        let material = try XCTUnwrap(manager.tlsMaterial())
        XCTAssertEqual(material.pkcs12URL, appSupport.appendingPathComponent("car.davidlam.online.p12"))
        XCTAssertEqual(material.passphrase, secrets.values["tls-p12-passphrase"])
        XCTAssertEqual(material.passphrase.count, 48)
        let imported = try PKCS12.importIdentity(Data(contentsOf: material.pkcs12URL), passphrase: material.passphrase)
        XCTAssertEqual(imported.subject, "car.davidlam.online")
        XCTAssertEqual(try XCTUnwrap(manager.certificateExpiry()).timeIntervalSinceNow, 90 * 86_400, accuracy: 3_600)

        let notDue = try await manager.renewIfNeeded()
        XCTAssertFalse(notDue)

        // 70 days later: inside the 30-day window. No token → the renewal attempt says so.
        world.now = Date().addingTimeInterval(70 * 86_400)
        XCTAssertNotNil(manager.tlsMaterial(), "still valid, just due")
        do {
            _ = try await manager.renewIfNeeded()
            XCTFail("expected missingCloudflareToken")
        } catch NetworkError.missingCloudflareToken {}

        // After expiry, the material is withheld.
        world.now = Date().addingTimeInterval(91 * 86_400)
        XCTAssertNil(manager.tlsMaterial())
    }
}
