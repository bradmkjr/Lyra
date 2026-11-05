import Foundation
import Security

/// Service for storing and retrieving credentials using the Keychain.
public enum KeychainService {
    /// The service name used to store Pandora credentials.
    private static let serviceName = "com.velpeo.Lyra"
    
    /// Saves user credentials to the keychain.
    public static func saveCredentials(_ username: String, password: String) throws {
        // First, delete any existing credential
        try deleteCredentials()
        
        // Create a dictionary for the password item
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: username,
            kSecValueData as String: password.data(using: .utf8)!,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        
        // Add the item to the keychain
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }
    
    /// Retrieves user credentials from the keychain.
    public static func getCredentials() throws -> (username: String, password: String)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: "",
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecReturnRef as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess {
            guard let dict = result as? [String: Any],
                  let username = dict[kSecAttrAccount as String] as? String,
                  let passwordData = dict[kSecValueData as String] as? Data else {
                return nil
            }
            
            return (username, String(data: passwordData, encoding: .utf8) ?? "")
        } else if status == errSecItemNotFound {
            return nil
        } else {
            throw KeychainError(status: status)
        }
    }
    
    /// Deletes user credentials from the keychain.
    public static func deleteCredentials() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError(status: status)
        }
    }
}

/// Errors that can occur when working with the keychain.
public enum KeychainError: Error, Equatable {
    case invalidStatus(CInt)
    
    init(status: CInt) {
        self = .invalidStatus(status)
    }
    
    public var errorDescription: String? {
        switch self {
        case .invalidStatus(let status):
            return "Keychain error: \(status)"
        }
    }
}