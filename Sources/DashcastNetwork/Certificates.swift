import DashcastContracts
import Foundation
import Security

/// Where certificate material lives under the app-support directory.
struct CertificatePaths {
    var appSupport: URL
    var domain: String = DashcastDefaults.hostname

    /// `lego --path` (accounts/ and certificates/ live under it).
    var legoDir: URL { appSupport.appendingPathComponent("lego", isDirectory: true) }
    /// Leaf + issuer bundle, as lego writes it.
    var legoCertificate: URL { legoDir.appendingPathComponent("certificates/\(domain).crt") }
    var legoKey: URL { legoDir.appendingPathComponent("certificates/\(domain).key") }
    /// What the TLS listener loads.
    var pkcs12: URL { appSupport.appendingPathComponent("\(domain).p12") }
}

// MARK: - lego

enum Lego {
    static let fallbackPaths = ["/opt/homebrew/bin/lego", "/usr/local/bin/lego"]

    /// App bundle `Resources/bin/lego`, then Homebrew (Apple silicon), then Homebrew (Intel).
    static func locate(bundleResourceURL: URL?, isExecutable: (String) -> Bool) -> URL? {
        var candidates: [String] = []
        if let bundleResourceURL { candidates.append(bundleResourceURL.appendingPathComponent("bin/lego").path) }
        candidates += fallbackPaths
        return candidates.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    /// "lego version 5.5.2 darwin/arm64" → 5. lego v5 folded run/renew into one `run` command.
    static func majorVersion(from output: String) -> Int? {
        guard let range = output.range(of: #"version v?(\d+)\."#, options: .regularExpression) else { return nil }
        let digits = output[range].drop(while: { !$0.isNumber }).prefix(while: \.isNumber)
        return Int(digits)
    }

    /// Arguments to obtain (no certificate yet) or renew (within `renewDays` of expiry).
    static func arguments(major: Int, email: String, domain: String, path: String,
                          renew: Bool, renewDays: Int = 30) -> [String] {
        let common = ["--accept-tos", "--email", email, "--dns", "cloudflare", "--domains", domain, "--path", path]
        if major >= 5 {
            // v5: `run` obtains or renews; flags belong to the command.
            return ["run"] + common + ["--renew-days", String(renewDays), "--no-random-sleep"]
        }
        // v4: global flags, then `run` or `renew --days N`.
        return renew
            ? common + ["renew", "--days", String(renewDays), "--no-random-sleep"]
            : common + ["run"]
    }

    /// Inherited environment minus any stray Cloudflare/lego settings, plus the DNS token.
    static func environment(token: String, base: [String: String]) -> [String: String] {
        var env = base.filter { key, _ in
            !(key.hasPrefix("CF_") || key.hasPrefix("CLOUDFLARE_") || key.hasPrefix("LEGO_"))
        }
        env["CF_DNS_API_TOKEN"] = token
        env["LEGO_LOG_FORMAT"] = "text" // no ANSI colour codes in captured output
        return env
    }
}

// MARK: - PKCS#12 packaging

enum PKCS12 {
    static let opensslPath = "/usr/bin/openssl"
    static let passphraseEnvironmentKey = "DASHCAST_P12_PASS"

    /// Tried in order until `SecPKCS12Import` accepts the result. macOS's LibreSSL defaults
    /// (RC2-40 certs / 3DES key / SHA-1 MAC) import fine today; the explicit 3DES form and
    /// OpenSSL 3's `-legacy` are fallbacks.
    static let variants: [[String]] = [
        [],
        ["-certpbe", "PBE-SHA1-3DES", "-keypbe", "PBE-SHA1-3DES", "-macalg", "sha1"],
        ["-legacy"],
    ]

    /// Passphrase is read from the environment so it never appears in `ps`.
    static func exportArguments(certificate: URL, key: URL, output: URL, friendlyName: String,
                                variant: [String]) -> [String] {
        ["pkcs12", "-export",
         "-in", certificate.path,
         "-inkey", key.path,
         "-out", output.path,
         "-name", friendlyName,
         "-passout", "env:\(passphraseEnvironmentKey)"] + variant
    }

    struct Imported {
        var identity: SecIdentity
        var certificate: SecCertificate
        var notAfter: Date?
        var subject: String?
    }

    /// In-memory import (kSecImportToMemoryOnly): nothing is written to the keychain.
    static func importIdentity(_ data: Data, passphrase: String) throws -> Imported {
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: passphrase,
            kSecImportToMemoryOnly as String: true,
        ]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else {
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw NetworkError.pkcs12Rejected("\(text) (\(status))")
        }
        guard let first = (items as? [[String: Any]])?.first,
              let raw = first[kSecImportItemIdentity as String],
              CFGetTypeID(raw as CFTypeRef) == SecIdentityGetTypeID() else {
            throw NetworkError.pkcs12Rejected("no identity (certificate + private key) inside")
        }
        let identity = raw as! SecIdentity
        var certificate: SecCertificate?
        let copyStatus = SecIdentityCopyCertificate(identity, &certificate)
        guard copyStatus == errSecSuccess, let certificate else {
            throw NetworkError.pkcs12Rejected("identity has no certificate (\(copyStatus))")
        }
        return Imported(identity: identity,
                        certificate: certificate,
                        notAfter: SecCertificateCopyNotValidAfterDate(certificate) as Date?,
                        subject: SecCertificateCopySubjectSummary(certificate) as String?)
    }

    struct BuildResult {
        var imported: Imported
        var variant: [String]
    }

    /// PEM cert + key → PKCS#12 at `output` (0600), verified with SecPKCS12Import before it
    /// replaces anything already there.
    static func build(certificate: URL, key: URL, output: URL, passphrase: String,
                      friendlyName: String = DashcastDefaults.hostname,
                      openssl: String = opensslPath) async throws -> BuildResult {
        let fm = FileManager.default
        let directory = output.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment[passphraseEnvironmentKey] = passphrase

        var failures: [String] = []
        for variant in variants {
            let temp = directory.appendingPathComponent(".\(output.lastPathComponent).\(UUID().uuidString).tmp")
            defer { try? fm.removeItem(at: temp) }
            let args = exportArguments(certificate: certificate, key: key, output: temp,
                                       friendlyName: friendlyName, variant: variant)
            let result = try await ProcessRunner.run(openssl, args, environment: environment, timeout: 30)
            let label = variant.isEmpty ? "default" : variant.joined(separator: " ")
            guard result.status == 0, let data = try? Data(contentsOf: temp) else {
                failures.append("[\(label)] openssl exit \(result.status): \(result.tail(4))")
                continue
            }
            do {
                let imported = try importIdentity(data, passphrase: passphrase)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
                if rename(temp.path, output.path) != 0 {
                    throw NetworkError.opensslFailed("couldn't move the .p12 into place: \(String(cString: strerror(errno)))")
                }
                return BuildResult(imported: imported, variant: variant)
            } catch let error as NetworkError {
                if case .opensslFailed = error { throw error }
                failures.append("[\(label)] \(error.localizedDescription)")
            }
        }
        throw NetworkError.opensslFailed(failures.joined(separator: "\n"))
    }

    /// Renew when fewer than `window` seconds remain (default 30 days), or already expired.
    static func needsRenewal(expiry: Date?, now: Date, window: TimeInterval = 30 * 86_400) -> Bool {
        guard let expiry else { return true }
        return expiry.timeIntervalSince(now) < window
    }
}
