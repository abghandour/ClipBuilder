import Foundation
import Security

/// The Sync Labs API key: one per Mac, independent of the active profile and
/// never synced. In the shared keychain, so the stable and beta apps use it.
nonisolated struct SyncLabsKeychain: Sendable {
    var api: KeychainAPI = .system

    private var item: AppKeychain.Item {
        AppKeychain.Item(service: "com.clipbuilder.synclabs", account: "api-key", api: api)
    }

    func read() throws -> String? {
        let data: Data?
        do { data = try item.read() } catch { throw StoreError(status: error.status) }
        guard let data else { return nil }
        guard let key = String(data: data, encoding: .utf8) else { throw StoreError(status: errSecDecode) }
        return key
    }

    func write(_ key: String?) throws {
        do { try item.write(key.map { Data($0.utf8) }) } catch { throw StoreError(status: error.status) }
    }

    nonisolated struct StoreError: LocalizedError, Equatable {
        let status: OSStatus
        var errorDescription: String? {
            "Could not access your Sync Labs key in the keychain (\(status)). Unlock your keychain and try again."
        }
    }
}
