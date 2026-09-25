import DashcastContracts
import XCTest
@testable import Dashcast

/// With no domain the app shows the service address and never a hostname.
final class ConnectionModeTests: XCTestCase {
    private let address = DashcastDefaults.serviceAddress

    @MainActor
    func testNoDomainIsCompatibilityAtTheServiceAddress() {
        var network = NetworkStatus()
        network.certificateExpiry = Date().addingTimeInterval(80 * 86_400)   // a stray certificate without a domain
        let mode = ConnectionMode(network: network)
        XCTAssertEqual(mode, .compatibility)
        XCTAssertEqual(mode.url, "http://\(address)")
        XCTAssertEqual(mode.addressToType, "http://\(address)")
        XCTAssertEqual(ConnectionMode.secureAddress(nil), "Your own domain")
        for text in [mode.url, mode.addressToType, mode.caption, ConnectionMode.secureAddress(nil)] {
            XCTAssertFalse(text.contains("davidlam"), text)
            XCTAssertFalse(text.contains(".com"), text)
        }

        let state = ServiceState()
        state.network = network
        XCTAssertEqual(state.carURL, "http://\(address)")
    }

    func testDomainWithoutCertificateStaysCompatibility() {
        var network = NetworkStatus()
        network.domain = OwnDomain(hostname: "car.example.com", provider: .cloudflare)
        XCTAssertEqual(ConnectionMode(network: network), .compatibility)
        network.certificateExpiry = Date().addingTimeInterval(-60)
        XCTAssertEqual(ConnectionMode(network: network), .compatibility, "expired")
        XCTAssertEqual(ConnectionMode.secureAddress(network.domain), "car.example.com")
    }

    @MainActor
    func testSecureUsesTheConfiguredHostname() {
        var network = NetworkStatus()
        network.domain = OwnDomain(hostname: "tesla.example.org", provider: .manual)
        network.certificateExpiry = Date().addingTimeInterval(30 * 86_400)
        let mode = ConnectionMode(network: network)
        XCTAssertEqual(mode, .secure(hostname: "tesla.example.org"))
        XCTAssertTrue(mode.isSecure)
        XCTAssertEqual(mode.url, "https://tesla.example.org")
        XCTAssertEqual(mode.addressToType, "tesla.example.org")
        let state = ServiceState()
        state.network = network
        XCTAssertEqual(state.carURL, "https://tesla.example.org")
    }

    /// The mock's first-run and compatibility scenarios carry no hostname; its secure one uses example.com.
    @MainActor
    func testMockScenariosCarryNoRealHostname() async {
        let fresh = MockNetworkManager(topology: .macHotspot, provisioned: false, domain: nil, token: false, certificate: false)
        let status = await fresh.currentStatus()
        XCTAssertNil(status.domain)
        XCTAssertFalse(fresh.routerSetupScript(macLANAddress: "192.168.8.20").contains("dnsmasq[0].address"))

        let secure = PreviewService(settings: ServiceSettings(), scenario: .init())
        XCTAssertEqual(secure.state.network.domain?.hostname, PreviewService.Scenario.exampleHostname)
        XCTAssertTrue(PreviewService.Scenario.exampleHostname.hasSuffix(".example.com"))
        let compat = PreviewService(settings: ServiceSettings(), scenario: .init(certificate: false))
        XCTAssertNil(compat.state.network.domain)
        XCTAssertEqual(ConnectionMode(network: compat.state.network).addressToType, "http://\(DashcastDefaults.serviceAddress)")
    }
}

final class CertificateFilesTests: XCTestCase {
    private let leaf = "-----BEGIN CERTIFICATE-----\nMIIBleaf\n-----END CERTIFICATE-----"
    private let issuer = "-----BEGIN CERTIFICATE-----\nMIIBissuer\n-----END CERTIFICATE-----"
    private let key = "-----BEGIN EC PRIVATE KEY-----\nMHcCAQEE\n-----END EC PRIVATE KEY-----"

    func testSeparateFilesAndCombinedFile() {
        let expected = CertificateFiles.Loaded.pem(certificate: Data("\(leaf)\n\(issuer)\n".utf8), key: Data("\(key)\n".utf8))
        XCTAssertEqual(try CertificateFiles.parse(["\(leaf)\n\(issuer)\n", key]).get(), expected)
        XCTAssertEqual(try CertificateFiles.parse([key, "junk\n\(leaf)\nmore\n\(issuer)"]).get(), expected, "file order doesn't matter")
        XCTAssertEqual(try CertificateFiles.parse(["\(key)\n\(leaf)\n\(issuer)"]).get(), expected, "one combined PEM")
    }

    func testMissingOrEncryptedKey() {
        guard case .failure(let missing) = CertificateFiles.parse([leaf]) else { return XCTFail("needs a key") }
        XCTAssertTrue(missing.message.contains("private key"))
        guard case .failure = CertificateFiles.parse([key]) else { return XCTFail("needs a certificate") }
        let encrypted = "-----BEGIN ENCRYPTED PRIVATE KEY-----\nMIIF\n-----END ENCRYPTED PRIVATE KEY-----"
        guard case .failure(let problem) = CertificateFiles.parse([leaf, encrypted]) else { return XCTFail("encrypted") }
        XCTAssertTrue(problem.message.contains("password-protected"))
        let legacy = "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES\n\nabc\n-----END RSA PRIVATE KEY-----"
        guard case .failure = CertificateFiles.parse([leaf, legacy]) else { return XCTFail("legacy encrypted") }
    }

    func testPKCS12FileWins() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dashcast-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p12 = dir.appendingPathComponent("car.pfx")
        let pem = dir.appendingPathComponent("car.pem")
        try Data([0x30, 0x82, 0x01]).write(to: p12)
        try Data(leaf.utf8).write(to: pem)
        XCTAssertEqual(try CertificateFiles.load([pem, p12]).get(), .pkcs12(Data([0x30, 0x82, 0x01]), name: "car.pfx"))
    }
}
