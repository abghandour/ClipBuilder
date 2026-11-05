import Foundation
import Security

/// Minimal Keychain wrapper for the Instagram Graph API token — secrets never
/// go in app_settings.json (plaintext, shared with the Python app). Items live
/// in the shared keychain (`AppKeychain`).
nonisolated enum KeychainStore {
    private static let service = "com.clipbuilder.instagram"

    /// Account name for the long-lived Meta Graph API access token.
    static let graphTokenAccount = "instagram_graph_token"

    static func graphTokenAccount(igUserID: String) -> String {
        "instagram_graph_token:\(igUserID)"
    }

    private static func item(_ account: String, api: KeychainAPI) -> AppKeychain.Item {
        AppKeychain.Item(service: service, account: account, api: api)
    }

    static func save(_ value: String, account: String, api: KeychainAPI = .system) throws {
        do {
            try item(account, api: api).write(Data(value.utf8))
        } catch {
            throw InstagramError.fetchFailed("Keychain write failed (OSStatus \(error.status))")
        }
    }

    static func read(account: String, api: KeychainAPI = .system) -> String? {
        guard let data = try? item(account, api: api).read() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String, api: KeychainAPI = .system) {
        try? item(account, api: api).write(nil)
    }
}
