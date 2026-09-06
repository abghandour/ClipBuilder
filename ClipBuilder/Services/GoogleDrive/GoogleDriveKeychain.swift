import Foundation
import Security

nonisolated protocol DriveCredentialStore: Sendable {
    func read(profile: String) throws -> Data?
    func write(_ data: Data?, profile: String) throws
}

/// Same update-or-add pattern as Instagram's KeychainStore, in a separate service.
nonisolated struct GoogleDriveKeychain: DriveCredentialStore {
    var service = "com.clipbuilder.google-drive"

    private func query(_ profile: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile,
        ]
    }
    func read(profile: String) throws -> Data? {
        var query = query(profile)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw GoogleDriveError.keychain(status) }
        return value as? Data
    }
    func write(_ data: Data?, profile: String) throws {
        let query = query(profile)
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw GoogleDriveError.keychain(status)
            }
            return
        }
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw GoogleDriveError.keychain(status) }
    }
}
