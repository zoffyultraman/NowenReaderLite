import Foundation
import Security

/// Keychain 工具 - 存取账号密码与服务器 API Key。
enum KeychainHelper {
    private static let accountService = "com.nowen.readerlite.accounts"
    private static let apiKeyService = "com.nowen.readerlite.api-keys"

    /// 保存密码
    @discardableResult
    static func savePassword(_ password: String, for accountID: String) -> Bool {
        saveSecret(password, account: accountID, service: accountService)
    }

    /// 读取密码
    static func readPassword(for accountID: String) -> String? {
        readSecret(account: accountID, service: accountService)
    }

    /// 删除密码
    @discardableResult
    static func deletePassword(for accountID: String) -> Bool {
        deleteSecret(account: accountID, service: accountService)
    }

    @discardableResult
    static func saveAPIKey(_ apiKey: String, for serverURL: String) -> Bool {
        saveSecret(apiKey, account: serverURL, service: apiKeyService)
    }

    static func readAPIKey(for serverURL: String) -> String? {
        readSecret(account: serverURL, service: apiKeyService)
    }

    static func hasAPIKey(for serverURL: String) -> Bool {
        readAPIKey(for: serverURL) != nil
    }

    @discardableResult
    static func deleteAPIKey(for serverURL: String) -> Bool {
        deleteSecret(account: serverURL, service: apiKeyService)
    }

    private static func saveSecret(
        _ secret: String,
        account: String,
        service: String
    ) -> Bool {
        guard let data = secret.data(using: .utf8) else { return false }
        let lookupQuery: NSDictionary = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let updateStatus = SecItemUpdate(
            lookupQuery,
            [kSecValueData: data] as NSDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        let insertQuery: NSDictionary = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        return SecItemAdd(insertQuery, nil) == errSecSuccess
    }

    private static func readSecret(account: String, service: String) -> String? {
        let query: NSDictionary = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteSecret(account: String, service: String) -> Bool {
        let query: NSDictionary = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
