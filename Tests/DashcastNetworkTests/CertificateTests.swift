import DashcastContracts
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

    /// Writes `<base>/certificates/<hostname>.{crt,key}` the way lego does. `altNames` adds a
    /// subjectAltName extension (lego's certificates always have one); without it only the CN names the host.
    @discardableResult
    private func makeLegoFixture(in base: URL, ecKey: Bool = true, days: Int = 90, hostname: String = "car.example.com",
                                 altNames: [String]? = nil) throws -> (crt: URL, key: URL) {
        let work = base.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        let certs = base.appendingPathComponent("certificates", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: certs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        try sh(openssl, ["req", "-x509", "-new", "-nodes", "-newkey", "rsa:2048", "-keyout", "ca.key", "-out", "ca.pem",
                         "-days", "365", "-subj", "/CN=Dashcast Test Issuer"], cwd: work)
        if ecKey {
            // LibreSSL writes a scalar with a leading zero byte as 31 bytes (~1 key in 256), which
            // SecPKCS12Import can't pair with its certificate. lego (Go) always pads to 32; so do we.
            repeat {
                try sh(openssl, ["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "leaf.key"], cwd: work)
                try sh(openssl, ["ec", "-in", "leaf.key", "-outform", "DER", "-out", "leaf.der"], cwd: work)
            } while try Data(contentsOf: work.appendingPathComponent("leaf.der")).dropFirst(6).first != 0x20
        } else {
            try sh(openssl, ["genrsa", "-out", "leaf.key", "2048"], cwd: work)
        }
        try sh(openssl, ["req", "-new", "-key", "leaf.key", "-subj", "/CN=\(hostname)", "-out", "leaf.csr"], cwd: work)
        var extensions: [String] = []
        if let altNames {
            try "subjectAltName=\(altNames.map { "DNS:\($0)" }.joined(separator: ","))\n"
                .write(to: work.appendingPathComponent("san.ext"), atomically: true, encoding: .utf8)
            extensions = ["-extfile", "san.ext"]
        }
        try sh(openssl, ["x509", "-req", "-in", "leaf.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-set_serial", "4242",
                         "-days", String(days), "-out", "leaf.pem"] + extensions, cwd: work)

        let crt = certs.appendingPathComponent("\(hostname).crt")
        let key = certs.appendingPathComponent("\(hostname).key")
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
        let output = dir.appendingPathComponent("car.example.com.p12")
        let passphrase = RandomSecret.hex()

        let built = try await PKCS12.build(certificate: fixture.crt, key: fixture.key, output: output, passphrase: passphrase)
        print("[pkcs12] EC P-256 bundle accepted with variant: \(built.variant.isEmpty ? "default" : built.variant.joined(separator: " "))")

        // Re-import from disk, the way the TLS listener will.
        let imported = try PKCS12.importIdentity(Data(contentsOf: output), passphrase: passphrase)
        XCTAssertEqual(imported.subject, "car.example.com", "identity's certificate must be the leaf, not the issuer")
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
        XCTAssertEqual(built.imported.subject, "car.example.com")
    }

    /// Which openssl variants does SecPKCS12Import accept on this macOS? (Default must work.)
    func testEachVariantAgainstSecPKCS12Import() async throws {
        let fixture = try makeLegoFixture(in: dir)
        var accepted: [String] = []
        for variant in PKCS12.variants {
            let out = dir.appendingPathComponent("v-\(UUID().uuidString).p12")
            let args = PKCS12.exportArguments(certificate: fixture.crt, key: fixture.key, output: out,
                                              friendlyName: "car.example.com", variant: variant)
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
        try makeLegoFixture(in: appSupport.appendingPathComponent("lego"))
        let noDomain = try await manager.renewIfNeeded()
        XCTAssertFalse(noDomain, "no own domain → no certificate to look after")
        try manager.setOwnDomain(OwnDomain(hostname: "car.example.com", provider: .cloudflare))
        try FileManager.default.removeItem(at: appSupport.appendingPathComponent("lego"))

        XCTAssertNil(manager.tlsMaterial())
        XCTAssertNil(manager.certificateExpiry())
        let nothingYet = try await manager.renewIfNeeded()
        XCTAssertFalse(nothingYet, "never issues a first certificate on its own")

        try makeLegoFixture(in: appSupport.appendingPathComponent("lego"))
        let rebuilt = try await manager.renewIfNeeded()
        XCTAssertTrue(rebuilt, "fresh lego PEM without a .p12 → repackage")

        let material = try XCTUnwrap(manager.tlsMaterial())
        XCTAssertEqual(material.pkcs12URL, appSupport.appendingPathComponent("car.example.com.p12"))
        XCTAssertEqual(material.hostname, "car.example.com")
        XCTAssertEqual(material.passphrase, secrets.values["tls-p12-passphrase"])
        XCTAssertEqual(material.passphrase.count, 48)
        let imported = try PKCS12.importIdentity(Data(contentsOf: material.pkcs12URL), passphrase: material.passphrase)
        XCTAssertEqual(imported.subject, "car.example.com")
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

        // Another hostname has no certificate yet; removing the domain withholds it too.
        world.now = Date()
        try manager.setOwnDomain(OwnDomain(hostname: "tesla.example.org", provider: .cloudflare))
        XCTAssertNil(manager.tlsMaterial())
        try manager.setOwnDomain(OwnDomain(hostname: "car.example.com", provider: .cloudflare))
        XCTAssertEqual(manager.tlsMaterial()?.hostname, "car.example.com")
        try manager.setOwnDomain(nil)
        XCTAssertNil(manager.tlsMaterial())
        XCTAssertNil(manager.certificateExpiry())
    }

    // MARK: Names a certificate covers

    func testSubjectAltNamesFromDER() throws {
        let fixture = try makeLegoFixture(in: dir, hostname: "car.example.com",
                                          altNames: ["car.example.com", "*.cars.example.com", "Other.Example.Net"])
        let leaf = try XCTUnwrap(PEM.certificates(in: String(contentsOf: fixture.crt, encoding: .utf8)).first)
        XCTAssertEqual(CertificateNames.dnsNames(of: leaf), ["car.example.com", "*.cars.example.com", "other.example.net"])

        let cnOnly = try makeLegoFixture(in: dir.appendingPathComponent("cn"), hostname: "cn.example.com")
        let cnLeaf = try XCTUnwrap(PEM.certificates(in: String(contentsOf: cnOnly.crt, encoding: .utf8)).first)
        XCTAssertEqual(CertificateNames.dnsNames(of: cnLeaf), ["cn.example.com"], "no SAN → the common name")
        XCTAssertEqual(CertificateNames.subjectAltNames(inDER: [0x30, 0x03, 0x06, 0x03, 0x55]), [], "truncated DER is harmless")
    }

    func testHostnameCoverage() {
        let names = ["car.example.com", "*.cars.example.com"]
        XCTAssertTrue(CertificateNames.covers(names, hostname: "car.example.com"))
        XCTAssertTrue(CertificateNames.covers(names, hostname: "CAR.Example.com"))
        XCTAssertTrue(CertificateNames.covers(names, hostname: "blue.cars.example.com"))
        XCTAssertFalse(CertificateNames.covers(names, hostname: "cars.example.com"), "a wildcard needs a label")
        XCTAssertFalse(CertificateNames.covers(names, hostname: "a.b.cars.example.com"), "a wildcard covers one label")
        XCTAssertFalse(CertificateNames.covers(names, hostname: "example.com"))
        XCTAssertFalse(CertificateNames.covers([], hostname: "car.example.com"))
    }

    // MARK: Importing a certificate (other DNS providers)

    @MainActor
    private func manualManager(appSupport: URL, secrets: InMemorySecretStore, world: FakeWorld = FakeWorld()) throws -> NetworkManager {
        let manager = NetworkManager(environment: makeEnvironment(world: world, secrets: secrets, appSupport: appSupport))
        try manager.setOwnDomain(OwnDomain(hostname: "car.example.com", provider: .manual))
        return manager
    }

    @MainActor
    func testImportPEMCertificateAndKey() async throws {
        let secrets = InMemorySecretStore()
        let appSupport = dir.appendingPathComponent("AppSupport", isDirectory: true)
        let manager = try manualManager(appSupport: appSupport, secrets: secrets)
        let fixture = try makeLegoFixture(in: dir.appendingPathComponent("pem"), altNames: ["car.example.com"])

        try await manager.importCertificate(.pem(certificate: Data(contentsOf: fixture.crt), key: Data(contentsOf: fixture.key)))
        let material = try XCTUnwrap(manager.tlsMaterial())
        XCTAssertEqual(material.hostname, "car.example.com")
        XCTAssertEqual(material.pkcs12URL, appSupport.appendingPathComponent("car.example.com.p12"))
        XCTAssertEqual(material.passphrase.count, 48, "packaged under Dashcast's own passphrase")
        XCTAssertEqual(try XCTUnwrap(manager.certificateExpiry()).timeIntervalSinceNow, 90 * 86_400, accuracy: 3_600)
        let permissions = try FileManager.default.attributesOfItem(atPath: material.pkcs12URL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: appSupport.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [], "staging file cleaned up")

        // Renewal never touches an imported certificate, and there's nothing to provision.
        let renewed = try await manager.renewIfNeeded()
        XCTAssertFalse(renewed)
        do {
            try await manager.provisionCertificate()
            XCTFail("expected Cloudflare-only error")
        } catch NetworkError.invalidArgument(let message) {
            XCTAssertTrue(message.contains("Cloudflare only"), message)
        }
    }

    @MainActor
    func testImportPKCS12KeepsItsPassphrase() async throws {
        let secrets = InMemorySecretStore()
        let appSupport = dir.appendingPathComponent("AppSupport", isDirectory: true)
        let manager = try manualManager(appSupport: appSupport, secrets: secrets)
        let fixture = try makeLegoFixture(in: dir.appendingPathComponent("p12"), altNames: ["*.example.com"])
        let p12 = dir.appendingPathComponent("mine.p12")
        _ = try await PKCS12.build(certificate: fixture.crt, key: fixture.key, output: p12, passphrase: "user pass")

        do {
            try await manager.importCertificate(.pkcs12(Data(contentsOf: p12), passphrase: "wrong"))
            XCTFail("expected pkcs12Rejected")
        } catch NetworkError.pkcs12Rejected {}
        XCTAssertNil(manager.tlsMaterial())

        try await manager.importCertificate(.pkcs12(Data(contentsOf: p12), passphrase: "user pass"))
        let material = try XCTUnwrap(manager.tlsMaterial(), "a wildcard covers the hostname")
        XCTAssertEqual(material.passphrase, "user pass")
        XCTAssertEqual(try Data(contentsOf: material.pkcs12URL), try Data(contentsOf: p12), "stored as given")
    }

    @MainActor
    func testImportRejectsOtherHostnamesAndExpiredCertificates() async throws {
        let secrets = InMemorySecretStore()
        let appSupport = dir.appendingPathComponent("AppSupport", isDirectory: true)
        let world = FakeWorld()
        let manager = try manualManager(appSupport: appSupport, secrets: secrets, world: world)

        let other = try makeLegoFixture(in: dir.appendingPathComponent("other"), hostname: "car.example.org",
                                        altNames: ["car.example.org", "www.example.org"])
        do {
            try await manager.importCertificate(.pem(certificate: Data(contentsOf: other.crt), key: Data(contentsOf: other.key)))
            XCTFail("expected a name mismatch")
        } catch NetworkError.certificateNameMismatch(let hostname, let names) {
            XCTAssertEqual(hostname, "car.example.com")
            XCTAssertEqual(names, ["car.example.org", "www.example.org"])
        }
        XCTAssertNil(manager.tlsMaterial(), "nothing replaced")
        XCTAssertFalse(FileManager.default.fileExists(atPath: appSupport.appendingPathComponent("car.example.com.p12").path))

        let good = try makeLegoFixture(in: dir.appendingPathComponent("good"), days: 10, altNames: ["car.example.com"])
        world.now = Date().addingTimeInterval(11 * 86_400)
        do {
            try await manager.importCertificate(.pem(certificate: Data(contentsOf: good.crt), key: Data(contentsOf: good.key)))
            XCTFail("expected an expiry error")
        } catch NetworkError.invalidArgument(let message) {
            XCTAssertTrue(message.contains("expired"), message)
        }

        try manager.setOwnDomain(nil)
        do {
            try await manager.importCertificate(.pem(certificate: Data(contentsOf: good.crt), key: Data(contentsOf: good.key)))
            XCTFail("expected noOwnDomain")
        } catch NetworkError.noOwnDomain {}
    }
}
