
import Foundation

/// Provides a stable, anonymous installation identifier, stored in the keychain.
/// It is sent to the CDN as `clientUser` for usage metering only.
final class Device {
    private static let service = "com.lingohub.sdk"
    private static let account = "device-identifier"
    /// SDK 1.0.x stored the identifier without a service attribute under this account name.
    private static let legacyAccount = "IdentifierKey"

    class var identifier: String? {
        return loadIdentifier() ?? migrateLegacyIdentifier() ?? createIdentifier()
    }

    private class func createIdentifier() -> String? {
        let uuid = UUID().uuidString
        return store(uuid) ? uuid : nil
    }

    private class func store(_ identifier: String) -> Bool {
        guard let data = identifier.data(using: .utf8) else {
            return false
        }

        let deleteQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                          kSecAttrService as String: service,
                                          kSecAttrAccount as String: account]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: service,
                                       kSecAttrAccount as String: account,
                                       // Allow reads during background update checks after the first unlock
                                       kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                                       kSecValueData as String: data]
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    private class func loadIdentifier() -> String? {
        return read(account: account, service: service)
    }

    /// SDK 1.0.x wrote the identifier with a generic account name and no service attribute.
    /// Adopt it (re-saving under the namespaced attributes) so existing installs keep their
    /// identifier. The legacy item is only adopted if it holds a UUID, so a host app's own
    /// keychain item with the same account name is never picked up. The legacy item itself
    /// is left untouched.
    private class func migrateLegacyIdentifier() -> String? {
        guard let legacyValue = read(account: legacyAccount, service: nil),
              UUID(uuidString: legacyValue) != nil else {
            return nil
        }
        _ = store(legacyValue)
        return legacyValue
    }

    private class func read(account: String, service: String?) -> String? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: kCFBooleanTrue!,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        if let service = service {
            query[kSecAttrService as String] = service
        }

        var dataTypeRef: AnyObject? = nil
        let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        if status == errSecSuccess, let data = dataTypeRef as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
}
