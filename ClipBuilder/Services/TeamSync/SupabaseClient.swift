import Foundation

/// Small REST/Auth adapter; no SDK or global session state. The caller owns
/// credentials (eventually Keychain) and can replace transport in every test.
nonisolated struct SupabaseClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    let baseURL: URL
    let apiKey: String
    var accessToken: String?
    private let transport: Transport

    init(baseURL: URL, apiKey: String, accessToken: String? = nil,
         transport: @escaping Transport = { try await SupabaseClient.urlSessionTransport($0) }) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.accessToken = accessToken
        self.transport = transport
    }

    static func urlSessionTransport(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SyncError.invalidRow("HTTP response") }
        return (data, response)
    }

    // Optional stored properties keep saved auth JSON forward/backward compatible.
    struct Session: Codable, Sendable {
        var access_token: String?
        var refresh_token: String?
        var expires_in: Int?
        var expires_at: Double?
        var email: String?
    }

    /// Configure the Supabase email template with {{ .Token }} for a typed code.
    /// https://supabase.com/docs/guides/auth/auth-email-passwordless
    func sendEmailCode(to email: String) async throws {
        _ = try await request(path: "auth/v1/otp", method: "POST", body: [
            "email": .string(email), "create_user": .bool(true)
        ])
    }

    func verifyEmailCode(email: String, code: String) async throws -> Session {
        let data = try await request(path: "auth/v1/verify", method: "POST", body: [
            "email": .string(email), "token": .string(code), "type": .string("email")
        ])
        let session = try JSONDecoder().decode(Session.self, from: data)
        guard let token = session.access_token, !token.isEmpty else { throw SyncError.invalidRow("access_token") }
        return session
    }

    func refreshSession(refreshToken: String) async throws -> Session {
        let data = try await request(path: "auth/v1/token", method: "POST",
                                     query: [.init(name: "grant_type", value: "refresh_token")],
                                     body: ["refresh_token": .string(refreshToken)])
        let session = try JSONDecoder().decode(Session.self, from: data)
        guard let token = session.access_token, !token.isEmpty else { throw SyncError.invalidRow("access_token") }
        return session
    }

    func schemaVersion() async throws -> Int {
        let data = try await request(path: "rest/v1/schema_version", query: [
            .init(name: "select", value: "version"), .init(name: "id", value: "eq.1")
        ])
        let rows = try JSONDecoder().decode([[String: Int]].self, from: data)
        guard rows.count == 1, let version = rows.first?["version"], version > 0 else {
            throw SyncError.invalidRow("schema_version")
        }
        return version
    }

    func push(_ wire: SyncMapping.WireRow, table: SyncTable = .lessons) async throws {
        try await push([wire], table: table)
    }

    func push(_ rows: [SyncMapping.WireRow], table: SyncTable = .lessons) async throws {
        guard !rows.isEmpty else { return }
        // PostgREST array inserts require the same keys on every object.
        let keys = Set(rows.flatMap { $0.keys })
        let batch = rows.map { row in
            Dictionary(uniqueKeysWithValues: keys.map { ($0, row[$0] ?? .null) })
        }
        _ = try await request(path: "rest/v1/\(table.name)", method: "POST",
                              query: [.init(name: "on_conflict", value: "sync_id")], encodedBody: try JSONEncoder().encode(batch),
                              prefer: "resolution=merge-duplicates,return=minimal")
    }

    /// Keyset pagination includes sync_id so equal server stamps never skip rows.
    func pull(scope: SyncScope, after cursor: SyncCursor?, limit: Int, table: SyncTable = .lessons) async throws -> [SyncMapping.WireRow] {
        var query: [URLQueryItem] = [
            .init(name: "select", value: "*"),
            .init(name: "team_id", value: "eq.\(scope.teamID.uuidString.lowercased())"),
            .init(name: "profile_id", value: "eq.\(scope.profileID.uuidString.lowercased())"),
            .init(name: "order", value: "server_updated_at.asc,sync_id.asc"),
            .init(name: "limit", value: String(limit))
        ]
        if let cursor {
            query.append(.init(name: "or", value:
                "(server_updated_at.gt.\(cursor.timestamp),and(server_updated_at.eq.\(cursor.timestamp),sync_id.gt.\(cursor.syncID)))"))
        }
        let data = try await request(path: "rest/v1/\(table.name)", query: query)
        let rows = try JSONDecoder().decode([SyncMapping.WireRow].self, from: data)
        // Reject malformed or mis-scoped pages before the database sees them.
        var previous = cursor
        for row in rows {
            let next = try SyncMapping.cursor(row, scope: scope)
            if let previous {
                guard try next.isAfter(previous) else {
                    throw SyncError.invalidRow("cursor order")
                }
            }
            previous = next
        }
        return rows
    }

    func request(path: String, method: String = "GET", query: [URLQueryItem] = [],
                         body: SyncMapping.WireRow? = nil, encodedBody: Data? = nil, prefer: String? = nil) async throws -> Data {
        try Task.checkCancellation()
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query.isEmpty ? nil : query
        // URLComponents leaves '+' literal, but PostgREST decodes query strings
        // as form data. Preserve timestamp timezone offsets as %2B, not spaces.
        if let encoded = components?.percentEncodedQuery {
            components?.percentEncodedQuery = encoded.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components?.url else { throw SyncError.invalidRow("URL") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        if let encodedBody { request.httpBody = encodedBody }
        else if let body { request.httpBody = try JSONEncoder().encode(body) }
        if request.httpBody != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else { throw SyncError.http(response.statusCode) }
        return data
    }
}
