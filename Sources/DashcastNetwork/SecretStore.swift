import Foundation
import Security

/// Dashcast's own secrets. Implementations must only ever touch items under their own service.
protocol SecretStore: AnyObject {
    func read(_ account: String) throws -> String?
    /// True when the item exists, without reading its data (no keychain access prompt).
    func exists(_ account: String) -> Bool
    func write(_ value: String, account: String) throws
    func delete(_ account: String) throws
}

enum SecretAccount {
    static let service = "online.davidlam.dashcast"
    static let cloudflareToken = "cloudflare-api-token"
    static let p12Passphrase = "tls-p12-passphrase"
}

/// Generic passwords in the login keychain, scoped to exactly one service + account per call.
/// Every query names both kSecAttrService and kSecAttrAccount; nothing here enumerates or reads
/// any other item.
final class KeychainSecretStore: SecretStore {
    let service: String

    init(service: String = SecretAccount.service) { self.service = service }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read(_ account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw NetworkError.keychain(status)
        }
    }

    func exists(_ account: String) -> Bool {
        var query = baseQuery(account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(baseQuery(account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        switch update {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = baseQuery(account)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Dashcast (\(account))"
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw NetworkError.keychain(status) }
        default:
            throw NetworkError.keychain(update)
        }
    }

    func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NetworkError.keychain(status) }
    }
}

enum RandomSecret {
    /// 48 hex characters (192 bits) from SecRandomCopyBytes.
    static func hex(bytes count: Int = 24) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
