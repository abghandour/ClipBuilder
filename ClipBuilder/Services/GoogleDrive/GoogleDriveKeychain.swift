import Foundation
import Security

nonisolated protocol DriveCredentialStore: Sendable {
    func read(profile: String) throws -> Data?
    func write(_ data: Data?, profile: String) throws
}

/// The four Security calls this store makes, behind a seam so the migration
/// can be tested without touching a real keychain.
nonisolated struct KeychainAPI: Sendable {
    var copyMatching: @Sendable ([String: Any]) -> (status: OSStatus, data: Data?)
    var update: @Sendable ([String: Any], [String: Any]) -> OSStatus
    var add: @Sendable ([String: Any]) -> OSStatus
    var delete: @Sendable ([String: Any]) -> OSStatus

    static let system = KeychainAPI(
        copyMatching: { query in
            var value: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &value)
            return (status, value as? Data)
        },
        update: { query, attributes in
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        },
        add: { attributes in SecItemAdd(attributes as CFDictionary, nil) },
        delete: { query in SecItemDelete(query as CFDictionary) })
}

/// Same update-or-add pattern as Instagram's KeychainStore, in a separate service.
nonisolated struct GoogleDriveKeychain: DriveCredentialStore {
    var service = "com.clipbuilder.google-drive"
    /// Injected by tests; the real Security framework otherwise.
    var api: KeychainAPI = .system

    /// The data-protection keychain has no per-signature access list, so it
    /// never asks the user to allow a rebuilt binary. The file-based login
    /// keychain (`legacy: true`) is only read to migrate an old item, and
    /// written to when this build has no entitlement for the new one.
    private func query(_ profile: String, legacy: Bool = false) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile,
        ]
        if !legacy { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    private func copy(_ profile: String, legacy: Bool) -> (status: OSStatus, data: Data?) {
        var query = query(profile, legacy: legacy)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return api.copyMatching(query)
    }

    func read(profile: String) throws -> Data? {
        let modern = copy(profile, legacy: false)
        if modern.status == errSecSuccess { return modern.data }
        if modern.status != errSecItemNotFound, modern.status != errSecMissingEntitlement {
            throw GoogleDriveError.keychain(modern.status)
        }
        // Nothing in the data-protection keychain: adopt the old item once.
        let legacy = copy(profile, legacy: true)
        if legacy.status == errSecItemNotFound { return nil }
        guard legacy.status == errSecSuccess, let data = legacy.data else {
            throw GoogleDriveError.keychain(legacy.status)
        }
        if modern.status != errSecMissingEntitlement, (try? store(data, profile: profile, legacy: false)) != nil {
            // Only drop the old copy once the new one is safely written; a
            // refused migration leaves the legacy item exactly as it was.
            _ = api.delete(query(profile, legacy: true))
        }
        return data
    }

    func write(_ data: Data?, profile: String) throws {
        guard let data else {
            for legacy in [false, true] {
                let status = api.delete(query(profile, legacy: legacy))
                guard status == errSecSuccess || status == errSecItemNotFound
                    || status == errSecMissingEntitlement else {
                    throw GoogleDriveError.keychain(status)
                }
            }
            return
        }
        do {
            try store(data, profile: profile, legacy: false)
        } catch GoogleDriveError.keychain(errSecMissingEntitlement) {
            // A build without the keychain-access-group entitlement cannot
            // use the data-protection keychain: keep working the old way.
            try store(data, profile: profile, legacy: true)
        }
    }

    private func store(_ data: Data, profile: String, legacy: Bool) throws {
        let query = query(profile, legacy: legacy)
        var status = api.update(query, [kSecValueData as String: data])
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = api.add(add)
        }
        guard status == errSecSuccess else { throw GoogleDriveError.keychain(status) }
    }
}
