import Foundation
import Security

/// Own service/account namespace. Never reads or changes Instagram/Drive items.
actor TeamSyncSession {
    private let base: SupabaseClient
    private var session: SupabaseClient.Session?
    private var loaded = false
    private var generation = 0
    private var refresh: Task<SupabaseClient.Session, Error>?
    private let service = "com.mokotti-solutions.clipbuilder.team-sync"

    init(url: URL, publishableKey: String) {
        base = SupabaseClient(baseURL: url, apiKey: publishableKey)
    }

    private func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: base.baseURL.absoluteString]
    }

    func restore() throws -> SupabaseClient.Session? {
        if loaded { return session }
        var query = query()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
        if let data = result as? Data { session = try JSONDecoder().decode(SupabaseClient.Session.self, from: data) }
        loaded = true
        return session
    }

    private func save(_ value: SupabaseClient.Session) throws {
        let data = try JSONEncoder().encode(value)
        let attributes = [kSecValueData as String: data]
        var status = SecItemUpdate(query() as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query()
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw keychainError(status) }
        session = value
        loaded = true
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey:
            "Could not access the Team session in Keychain (\(status))."])
    }

    func sendCode(email: String) async throws { try await base.sendEmailCode(to: email) }

    func verify(email: String, code: String) async throws {
        var value = try await base.verifyEmailCode(email: email, code: code)
        value.email = email
        value.expires_at = Date().timeIntervalSince1970 + Double(value.expires_in ?? 3600)
        generation += 1
        try save(value)
    }

    func client() async throws -> SupabaseClient {
        guard var value = try restore() else { throw SyncError.invalidRow("Sign in to Team sync") }
        if (value.expires_at ?? 0) < Date().timeIntervalSince1970 + 60 {
            guard let token = value.refresh_token else { throw SyncError.invalidRow("Sign in again") }
            let capturedGeneration = generation
            let task: Task<SupabaseClient.Session, Error>
            if let refresh { task = refresh }
            else {
                task = Task { try await base.refreshSession(refreshToken: token) }
                refresh = task
            }
            do {
                var renewed = try await task.value
                guard capturedGeneration == generation else { throw CancellationError() }
                renewed.email = value.email
                renewed.expires_at = Date().timeIntervalSince1970 + Double(renewed.expires_in ?? 3600)
                try save(renewed)
                value = renewed
                refresh = nil
            } catch {
                refresh = nil
                throw error
            }
        }
        var client = base
        client.accessToken = value.access_token
        return client
    }

    func signOut() throws {
        generation += 1
        refresh?.cancel()
        refresh = nil
        let status = SecItemDelete(query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
        session = nil
        loaded = true
    }
}
