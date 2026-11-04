import Foundation
import Security

/// One Mac-local key, independent of the active profile and never synced.
nonisolated struct ElevenLabsKeychain: Sendable {
    var api: KeychainAPI = .system

    /// The data-protection keychain never prompts for a rebuilt binary. A
    /// build without the keychain-access-groups entitlement (ad-hoc signed)
    /// gets errSecMissingEntitlement from it and uses the login keychain
    /// instead, as `GoogleDriveKeychain` does.
    private func query(legacy: Bool = false) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.clipbuilder.elevenlabs",
            kSecAttrAccount as String: "api-key",
        ]
        if !legacy { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    func read() throws -> String? {
        var result = copy(legacy: false)
        if result.status == errSecMissingEntitlement { result = copy(legacy: true) }
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess else { throw StoreError(status: result.status) }
        guard let data = result.data, let key = String(data: data, encoding: .utf8) else {
            throw StoreError(status: errSecDecode)
        }
        return key
    }

    func write(_ key: String?) throws {
        guard let key else {
            for legacy in [false, true] {
                let status = api.delete(query(legacy: legacy))
                guard status == errSecSuccess || status == errSecItemNotFound
                    || status == errSecMissingEntitlement else { throw StoreError(status: status) }
            }
            return
        }
        do {
            try store(Data(key.utf8), legacy: false)
        } catch let error as StoreError where error.status == errSecMissingEntitlement {
            try store(Data(key.utf8), legacy: true)
        }
    }

    private func copy(legacy: Bool) -> (status: OSStatus, data: Data?) {
        var query = query(legacy: legacy)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return api.copyMatching(query)
    }

    private func store(_ data: Data, legacy: Bool) throws {
        let query = query(legacy: legacy)
        var status = api.update(query, [kSecValueData as String: data])
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = api.add(attributes)
        }
        guard status == errSecSuccess else { throw StoreError(status: status) }
    }

    nonisolated struct StoreError: LocalizedError, Equatable {
        let status: OSStatus
        var errorDescription: String? {
            "Could not access your ElevenLabs key in the keychain (\(status)). Unlock your keychain and try again."
        }
    }
}
