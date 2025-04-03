
import Foundation

final class Device {
    private static let identifierKey = "IdentifierKey"
    
    class var identifier: String? {
        return loadIdentifier() ?? createIdentifier()
    }
    
    private class func createIdentifier() -> String? {
        let uuid = UUID()
        guard let data = uuid.uuidString.data(using: .utf8) else {
            return nil
        }
        
        let query: [String : Any] = [kSecClass as String: kSecClassGenericPassword as String,
                                     kSecAttrAccount as String : identifierKey,
                                     kSecValueData as String: data ]
        
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == noErr {
            return uuid.uuidString
        } else {
            return nil
        }
    }
    
    private class func loadIdentifier() -> String? {
        let query: [String : Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrAccount as String : identifierKey,
                                     kSecReturnData as String: kCFBooleanTrue!,
                                     kSecMatchLimit as String: kSecMatchLimitOne ]
        
        var dataTypeRef: AnyObject? = nil
        let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        
        if status == noErr, let data = dataTypeRef as? Data {
            return String(data: data, encoding: .utf8)
        } else {
            return nil
        }
    }
}
