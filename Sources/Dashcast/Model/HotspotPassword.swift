import Foundation
import Security

/// The hotspot's Wi‑Fi password, made by Dashcast so it's easy to type on the Tesla's touchscreen:
/// two short everyday words and two digits, lowercase letters and digits only ("maplesky47").
enum HotspotPassword {
    /// Short, unambiguous, easy to spell.
    static let words = [
        "maple", "sky", "river", "cloud", "stone", "pine", "lake", "sun", "moon", "star", "leaf", "bird",
        "wave", "sand", "hill", "rain", "snow", "wind", "fern", "oak", "bear", "fox", "owl", "deer",
        "sea", "bay", "dune", "glow", "mint", "plum", "pear", "lime", "rose", "sage", "cedar", "coral",
        "amber", "olive", "ruby", "jade", "frost", "storm", "tide", "reef", "peak", "cove", "brook", "field",
        "honey", "berry", "lemon", "mango", "otter", "robin", "tiger", "panda", "comet", "orbit", "pixel", "zebra",
    ]
    static let lengths = 10...12

    static func generate<R: RandomNumberGenerator>(using generator: inout R) -> String {
        while true {
            let first = words.randomElement(using: &generator)!
            let second = words.randomElement(using: &generator)!
            let digits = String(format: "%02d", Int.random(in: 10...99, using: &generator))
            let password = first + second + digits
            if first != second, lengths.contains(password.count) { return password }
        }
    }

    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return generate(using: &generator)
    }

    /// Lowercase ASCII letters and digits, the right length (what `generate` makes).
    static func isEasyToType(_ password: String) -> Bool {
        lengths.contains(password.count) && password.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }
}

/// Where the hotspot password lives.
protocol HotspotPasswordStoring: AnyObject {
    func load() -> String?
    func save(_ password: String)
}

/// The login Keychain (a generic password; the hotspot's own copy is in the System keychain, which
/// Dashcast can't read).
final class KeychainHotspotPasswordStore: HotspotPasswordStoring {
    static let service = "online.davidlam.dashcast.hotspot"
    static let account = "hotspot"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    func load() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ password: String) {
        let data = Data(password.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Dashcast hotspot"
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

/// Snapshots and tests: never touches the Keychain.
final class MemoryHotspotPasswordStore: HotspotPasswordStoring {
    private var password: String?
    init(_ password: String? = nil) { self.password = password }
    func load() -> String? { password }
    func save(_ password: String) { self.password = password }
}
