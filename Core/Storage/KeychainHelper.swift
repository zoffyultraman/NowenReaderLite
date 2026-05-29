import Foundation
import Security

/// Keychain 工具 — 存取账号密码
enum KeychainHelper {
    private static let service = "com.nowen.readerlite.accounts"

    /// 保存密码
    @discardableResult
    static func savePassword(_ password: String, for accountID: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }

        // 先删除旧条目
        deletePassword(for: accountID)

        let query: NSDictionary = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: accountID,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        return SecItemAdd(query, nil) == errSecSuccess
    }

    /// 读取密码
    static func readPassword(for accountID: String) -> String? {
        let query: NSDictionary = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: accountID,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 删除密码
    @discardableResult
    static func deletePassword(for accountID: String) -> Bool {
        let query: NSDictionary = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: accountID,
        ]

        return SecItemDelete(query) == errSecSuccess
    }
}
