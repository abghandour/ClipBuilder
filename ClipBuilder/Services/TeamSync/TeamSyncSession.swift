import Foundation
import Security

/// Own service/account namespace in the shared keychain (`AppKeychain`), so
/// the stable and beta apps share one sign-in. Never reads or changes
/// Instagram/Drive items.
actor TeamSyncSession {
    private let base: SupabaseClient
    private var session: SupabaseClient.Session?
    private var loaded = false
    private var generation = 0
    private var refresh: Task<SupabaseClient.Session, Error>?
    private let item: AppKeychain.Item

    init(url: URL, publishableKey: String, keychain: KeychainAPI = .system) {
        base = SupabaseClient(baseURL: url, apiKey: publishableKey)
        item = AppKeychain.Item(service: "com.mokotti-solutions.clipbuilder.team-sync",
                                account: url.absoluteString, api: keychain)
    }

    /// Whether a session is stored for this server, without touching the
    /// keychain: a keychain read at launch can block on an access prompt.
    /// The marker follows every save and sign-out; a session stored before
    /// the marker existed is recognised on its next restore.
    nonisolated static func hasStoredSession(url: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: markerKey(url: url))
    }

    nonisolated static func markerKey(url: String) -> String { "teamSync.hasSession.\(url)" }

    private func markStored(_ stored: Bool) {
        UserDefaults.standard.set(stored, forKey: Self.markerKey(url: base.baseURL.absoluteString))
    }

    func restore() throws -> SupabaseClient.Session? {
        if loaded { return session }
        let data: Data?
        do { data = try item.read() } catch { throw keychainError(error.status) }
        if let data { session = try JSONDecoder().decode(SupabaseClient.Session.self, from: data) }
        loaded = true
        markStored(session != nil)
        return session
    }

    private func save(_ value: SupabaseClient.Session) throws {
        let data = try JSONEncoder().encode(value)
        do { try item.write(data) } catch { throw keychainError(error.status) }
        session = value
        loaded = true
        markStored(true)
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
        guard var value = try restore() else { throw SyncError.signedOut }
        if (value.expires_at ?? 0) < Date().timeIntervalSince1970 + 60 {
            guard let token = value.refresh_token else { throw SyncError.signedOut }
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
        do { try item.write(nil) } catch { throw keychainError(error.status) }
        session = nil
        loaded = true
        markStored(false)
    }
}
