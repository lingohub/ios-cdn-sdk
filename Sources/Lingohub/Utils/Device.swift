
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

    /// SDK 1.0.x wrote the identifier with a generic account name and no service attribute,
    /// which the keychain stores as an empty service string. Adopt that item (re-saving it
    /// under the namespaced attributes) so existing installs keep their identifier. The
    /// query pins the service to the empty string so it can only match a service-less item
    /// as written by 1.0.x, and the value must parse as a UUID - both guard against picking
    /// up a host app's own keychain item. The legacy item itself is left untouched.
    private class func migrateLegacyIdentifier() -> String? {
        guard let legacyValue = read(account: legacyAccount, service: ""),
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
