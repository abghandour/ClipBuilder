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

/// One item per profile in the shared keychain (`AppKeychain`).
nonisolated struct GoogleDriveKeychain: DriveCredentialStore {
    var service = "com.clipbuilder.google-drive"
    /// Injected by tests; the real Security framework otherwise.
    var api: KeychainAPI = .system

    private func item(_ profile: String) -> AppKeychain.Item {
        AppKeychain.Item(service: service, account: profile, api: api)
    }

    func read(profile: String) throws -> Data? {
        do { return try item(profile).read() } catch { throw GoogleDriveError.keychain(error.status) }
    }

    func write(_ data: Data?, profile: String) throws {
        do { try item(profile).write(data) } catch { throw GoogleDriveError.keychain(error.status) }
    }
}
