import CryptoKit
import Foundation

nonisolated struct GoogleOAuthConfiguration: Codable, Equatable, Sendable {
    var clientID: String
    var clientSecret: String
    var isConfigured: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    static var bundled: Self {
        Self(
            clientID: Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientID") as? String ?? "",
            clientSecret: Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientSecret") as? String ?? "")
    }
}

nonisolated struct DriveCredential: Codable, Sendable {
    var refreshToken: String
    var issuedAt: Date
    var email: String
    var applicationID: String? = nil
    var expiresAt: Date { issuedAt.addingTimeInterval(7 * 24 * 3600) }
}

nonisolated enum DriveConnectionState: Equatable, Sendable {
    case notConfigured, disconnected
    case reconnect(email: String, expires: Date?)
    case connected(email: String, expires: Date)
}

actor GoogleDriveAuth {
    static let scopes = [
        "https://www.googleapis.com/auth/drive.readonly",
        "https://www.googleapis.com/auth/drive.file", "openid", "email",
    ]
    private(set) var configuration: GoogleOAuthConfiguration
    private let configurationStore: GoogleDriveConfigurationStore?
    private let transport: any DriveTransport
    private let credentials: any DriveCredentialStore
    private var access: [String: (token: String, expiry: Date)] = [:]
    private var invalidProfiles: Set<String> = []
    private var refreshTasks: [String: Task<String, Error>] = [:]
    private var generations: [String: Int] = [:]

    init(
        configuration: GoogleOAuthConfiguration? = nil,
        configurationStore: GoogleDriveConfigurationStore = GoogleDriveConfigurationStore(),
        transport: any DriveTransport = URLSessionDriveTransport(),
        credentials: any DriveCredentialStore = GoogleDriveKeychain()
    ) {
        self.configurationStore = configuration == nil ? configurationStore : nil
        self.configuration = configuration ?? ((try? configurationStore.resolved()) ?? .bundled)
        self.transport = transport
        self.credentials = credentials
    }

    func applicationOverride() throws -> GoogleOAuthConfiguration? { try configurationStore?.override() }

    func saveApplicationOverride(_ value: GoogleOAuthConfiguration?) throws {
        guard let configurationStore else { throw GoogleDriveError.notConfigured }
        try configurationStore.save(value)
        configuration = try configurationStore.resolved()
        // Tokens belong to the previous application. Preserve account identity
        // but require a fresh sign-in, including for profiles attached later.
        for profile in Set(generations.keys).union(access.keys).union(refreshTasks.keys) {
            generations[profile, default: 0] += 1
        }
        for task in refreshTasks.values { task.cancel() }
        refreshTasks.removeAll()
        invalidProfiles.formUnion(generations.keys)
        access.removeAll()
    }

    func credential(profile: String) throws -> DriveCredential? {
        try credentials.read(profile: profile).map { try JSONDecoder().decode(DriveCredential.self, from: $0) }
    }

    func state(profile: String, now: Date = Date()) -> DriveConnectionState {
        guard configuration.isConfigured else { return .notConfigured }
        guard let saved = try? credential(profile: profile) else { return .disconnected }
        if invalidProfiles.contains(profile) || saved.expiresAt <= now || !matchesApplication(saved) {
            return .reconnect(email: saved.email, expires: saved.expiresAt)
        }
        return .connected(email: saved.email, expires: saved.expiresAt)
    }

    private func matchesApplication(_ saved: DriveCredential) -> Bool {
        if let applicationID = saved.applicationID { return applicationID == configuration.clientID }
        // Legacy connections predate overrides and belong to the bundled app.
        return (try? configurationStore?.override()) == nil
    }

    func invalidate(profile: String) {
        access[profile] = nil
        invalidProfiles.insert(profile)
    }

    func disconnect(profile: String) throws {
        generations[profile, default: 0] += 1
        refreshTasks.removeValue(forKey: profile)?.cancel()
        access[profile] = nil
        invalidProfiles.remove(profile)
        try credentials.write(nil, profile: profile)
    }

    func accessToken(profile: String, now: Date = Date()) async throws -> String {
        guard configuration.isConfigured else { throw GoogleDriveError.notConfigured }
        guard let saved = try credential(profile: profile), saved.expiresAt > now,
            !invalidProfiles.contains(profile),
            matchesApplication(saved)
        else {
            invalidate(profile: profile)
            throw GoogleDriveError.reconnect
        }
        if let cached = access[profile], cached.expiry > now.addingTimeInterval(60) { return cached.token }
        if let running = refreshTasks[profile] { return try await running.value }
        let generation = generations[profile, default: 0]
        generations[profile] = generation
        let task = Task { try await self.refresh(saved, profile: profile, generation: generation, now: now) }
        refreshTasks[profile] = task
        defer { refreshTasks[profile] = nil }
        return try await task.value
    }

    private func refresh(_ saved: DriveCredential, profile: String, generation: Int, now: Date) async throws -> String {
        do {
            let token = try await tokenRequest(["grant_type": "refresh_token", "refresh_token": saved.refreshToken])
            try Task.checkCancellation()
            guard generations[profile, default: 0] == generation else { throw CancellationError() }
            if let scopes = token.scope, !Self.hasDriveScopes(scopes) { throw GoogleDriveError.reconnect }
            access[profile] = (token.accessToken, now.addingTimeInterval(token.expiresIn))
            // Refresh does not extend Google's seven-day testing lifetime.
            return token.accessToken
        } catch GoogleDriveError.reconnect {
            invalidate(profile: profile)
            throw GoogleDriveError.reconnect
        }
    }

    func completeSignIn(code: String, verifier: String, redirectURI: String, profile: String) async throws {
        guard configuration.isConfigured else { throw GoogleDriveError.notConfigured }
        let generation = generations[profile, default: 0]
        generations[profile] = generation
        let token = try await tokenRequest([
            "grant_type": "authorization_code", "code": code,
            "code_verifier": verifier, "redirect_uri": redirectURI,
        ])
        guard let refresh = token.refreshToken, !refresh.isEmpty,
            let scope = token.scope, Self.hasDriveScopes(scope)
        else { throw GoogleDriveError.reconnect }
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else { throw GoogleDriveError.reconnect }
        struct User: Decodable { var email: String }
        let user = try JSONDecoder().decode(User.self, from: data)
        guard generations[profile, default: 0] == generation else { throw CancellationError() }
        // Reconnect must keep the same account: existing Drive ids belong to it.
        if let previous = try credential(profile: profile), previous.email != user.email {
            throw GoogleDriveError.accountMismatch(expected: previous.email)
        }
        let saved = DriveCredential(
            refreshToken: refresh, issuedAt: Date(), email: user.email, applicationID: configuration.clientID)
        try credentials.write(JSONEncoder().encode(saved), profile: profile)
        invalidProfiles.remove(profile)
        access[profile] = (token.accessToken, Date().addingTimeInterval(token.expiresIn))
    }

    nonisolated static func hasDriveScopes(_ scope: String) -> Bool {
        let granted = Set(scope.split(separator: " ").map(String.init))
        return Set(scopes.prefix(2)).isSubset(of: granted)
    }
    nonisolated static func challenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    nonisolated static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(
            values.sorted { $0.key < $1.key }.map {
                "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
            }.joined(separator: "&").utf8)
    }
    private struct Token: Decodable {
        var accessToken: String
        var expiresIn: Double
        var refreshToken: String?
        var scope: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case scope
        }
    }
    private func tokenRequest(_ values: [String: String]) async throws -> Token {
        var fields = values
        fields["client_id"] = configuration.clientID
        fields["client_secret"] = configuration.clientSecret
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(fields)
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            if response.statusCode == 400 || response.statusCode == 401 { throw GoogleDriveError.reconnect }
            throw GoogleDriveError.server(response.statusCode)
        }
        return try JSONDecoder().decode(Token.self, from: data)
    }
}
