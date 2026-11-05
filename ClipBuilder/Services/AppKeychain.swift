import Foundation
import Security

/// The keychain the stable and beta apps share. Items live in the
/// data-protection keychain under one access group that both bundle ids are
/// entitled to (`Clip Builder.entitlements`), so a key entered in one app is
/// the other's too, and no app ever prompts for a rebuilt binary. A build
/// without the entitlement (ad-hoc signed) gets errSecMissingEntitlement from
/// that keychain and works in the login keychain instead; an item found only
/// there is adopted by the shared keychain on first read.
nonisolated enum AppKeychain {
    /// `<team id>.com.mokotti-solutions.clipbuilder.shared`, the only entry
    /// in `keychain-access-groups`. Both channels sign with the same team.
    static let accessGroup = "D7JTNCH58D.com.mokotti-solutions.clipbuilder.shared"

    nonisolated struct Failure: Error, Equatable {
        let status: OSStatus
    }

    /// One generic-password item: `service` and `account` name it in either
    /// keychain. Reads prefer the shared keychain and migrate from the login
    /// keychain; writes go to the shared keychain unless this build cannot.
    nonisolated struct Item: Sendable {
        let service: String
        let account: String
        /// Injected by tests; the real Security framework otherwise.
        var api: KeychainAPI = .system

        func query(legacy: Bool) -> [String: Any] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            if !legacy {
                query[kSecUseDataProtectionKeychain as String] = true
                query[kSecAttrAccessGroup as String] = AppKeychain.accessGroup
            }
            return query
        }

        func read() throws(Failure) -> Data? {
            let shared = copy(legacy: false)
            if shared.status == errSecSuccess { return shared.data }
            guard shared.status == errSecItemNotFound || shared.status == errSecMissingEntitlement else {
                throw Failure(status: shared.status)
            }
            // Nothing in the shared keychain: adopt the login-keychain item once.
            let legacy = copy(legacy: true)
            if legacy.status == errSecItemNotFound { return nil }
            guard legacy.status == errSecSuccess, let data = legacy.data else {
                throw Failure(status: legacy.status)
            }
            if shared.status != errSecMissingEntitlement, (try? store(data, legacy: false)) != nil {
                // Only drop the old copy once the new one is safely written; a
                // refused migration leaves the login item exactly as it was.
                _ = api.delete(query(legacy: true))
            }
            return data
        }

        /// `nil` removes the item from both keychains.
        func write(_ data: Data?) throws(Failure) {
            guard let data else {
                for legacy in [false, true] {
                    let status = api.delete(query(legacy: legacy))
                    guard status == errSecSuccess || status == errSecItemNotFound
                        || status == errSecMissingEntitlement else { throw Failure(status: status) }
                }
                return
            }
            do {
                try store(data, legacy: false)
            } catch let failure where failure.status == errSecMissingEntitlement {
                try store(data, legacy: true)
            }
        }

        private func copy(legacy: Bool) -> (status: OSStatus, data: Data?) {
            var query = query(legacy: legacy)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            return api.copyMatching(query)
        }

        private func store(_ data: Data, legacy: Bool) throws(Failure) {
            let query = query(legacy: legacy)
            var status = api.update(query, [kSecValueData as String: data])
            if status == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = api.add(add)
            }
            guard status == errSecSuccess else { throw Failure(status: status) }
        }
    }
}
