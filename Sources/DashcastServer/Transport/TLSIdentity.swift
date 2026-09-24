import DashcastContracts
import Foundation
import Network
import Security

/// Loads a PKCS#12 into memory (never the keychain) and builds Network.framework TLS options.
struct TLSIdentity: @unchecked Sendable {   // immutable
    let identity: sec_identity_t
    let commonName: String?
    let expiry: Date?
    /// File size + modification date; a change means the certificate was renewed.
    let fileStamp: String

    enum LoadError: Error, CustomStringConvertible {
        case unreadable(String)
        case importFailed(OSStatus)
        case noIdentity

        var description: String {
            switch self {
            case .unreadable(let s): return "can't read PKCS#12: \(s)"
            case .importFailed(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "PKCS#12 import failed: \(message)"
            case .noIdentity: return "PKCS#12 has no identity"
            }
        }
    }

    static func fileStamp(for url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let date = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)-\(date)"
    }

    static func load(_ material: TLSMaterial) throws -> TLSIdentity {
        let data: Data
        do { data = try Data(contentsOf: material.pkcs12URL) } catch { throw LoadError.unreadable(error.localizedDescription) }
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: material.passphrase,
            kSecImportToMemoryOnly as String: true,
        ]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else { throw LoadError.importFailed(status) }
        guard let entries = items as? [[String: Any]],
              let entry = entries.first(where: { $0[kSecImportItemIdentity as String] != nil }),
              let identityRef = entry[kSecImportItemIdentity as String] else { throw LoadError.noIdentity }
        let secIdentity = identityRef as! SecIdentity   // CF type; the cast can't fail

        var leaf: SecCertificate?
        SecIdentityCopyCertificate(secIdentity, &leaf)
        // Send the intermediates too (the car won't fetch them). The chain array excludes the leaf,
        // which `sec_identity_create_with_certificates` takes from the identity.
        let chain = (entry[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
        let intermediates = chain.filter { cert in
            guard let leaf else { return true }
            return !CFEqual(cert, leaf) && !Self.isSelfSigned(cert)
        }
        let identity: sec_identity_t?
        if intermediates.isEmpty {
            identity = sec_identity_create(secIdentity)
        } else {
            identity = sec_identity_create_with_certificates(secIdentity, ([leaf].compactMap { $0 } + intermediates) as CFArray)
        }
        guard let identity else { throw LoadError.noIdentity }

        var commonName: CFString?
        if let leaf { SecCertificateCopyCommonName(leaf, &commonName) }
        let expiry = leaf.flatMap(Self.notAfter)
        return TLSIdentity(identity: identity, commonName: commonName as String?, expiry: expiry,
                           fileStamp: fileStamp(for: material.pkcs12URL) ?? "")
    }

    private static func isSelfSigned(_ cert: SecCertificate) -> Bool {
        guard let subject = SecCertificateCopyNormalizedSubjectSequence(cert),
              let issuer = SecCertificateCopyNormalizedIssuerSequence(cert) else { return false }
        return CFEqual(subject, issuer)
    }

    private static func notAfter(_ cert: SecCertificate) -> Date? {
        let keys = [kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(cert, keys, nil) as? [String: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
              let number = entry[kSecPropertyKeyValue as String] as? NSNumber else { return nil }
        return Date(timeIntervalSinceReferenceDate: number.doubleValue)
    }

    func tlsOptions() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let sec = options.securityProtocolOptions
        sec_protocol_options_set_local_identity(sec, identity)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_add_tls_application_protocol(sec, "http/1.1")
        return options
    }
}
