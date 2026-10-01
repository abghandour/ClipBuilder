import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

@Suite("Instagram refresh fallback")
struct InstagramServiceTests {
    @Test("Graph permission, expiry and discovery errors keep their message and require reconnection",
          arguments: [10, 200, 190, 100])
    func graphFailuresDoNotUseWeb(code: Int) async throws {
        let transport = InstagramTestTransport([
            "ig-123": .json("{\"error\":{\"code\":\(code),\"message\":\"Token cannot access this account\"}}"),
            "me/accounts": .json(#"{"data":[]}"#),
            "me": .json("{}"),
        ])
        let graph = transport.provider()
        defer { transport.finish(graph) }
        let web = InstagramWebSpy()
        let service = makeService(graph: graph, web: web)
        let temp = try TempDatabase()
        do {
            _ = try await service.refreshAccount(username: "peacegrappler", kind: "own", database: temp.database,
                                                 settings: connectedSettings(), limit: 4, log: { _ in })
            Issue.record("Expected Graph failure")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("Reconnect in Settings → Instagram"))
            #expect(message.contains(code == 190 ? "Token cannot access this account" : "No Instagram business/creator account"))
        }
        #expect(web.profileCalls == 0)
    }

    @Test("Permission failure during discovery retains the Graph message")
    func discoveryPermissionFailure() async throws {
        let transport = InstagramTestTransport([
            "me/accounts": .json(#"{"error":{"code":10,"message":"Missing pages permission"}}"#),
        ])
        let graph = transport.provider(id: nil)
        defer { transport.finish(graph) }
        let web = InstagramWebSpy()
        let temp = try TempDatabase()
        do {
            _ = try await makeService(graph: graph, web: web).refreshAccount(
                username: "peacegrappler", kind: "own", database: temp.database,
                settings: connectedSettings(), limit: 4, log: { _ in })
            Issue.record("Expected permission failure")
        } catch {
            #expect(String(describing: error).contains("Missing pages permission"))
            #expect(String(describing: error).contains("Reconnect in Settings → Instagram"))
        }
        #expect(web.profileCalls == 0)
    }

    @Test("Network and non-JSON failures refresh through the web provider", arguments: [true, false])
    func transportFallsBack(networkFailure: Bool) async throws {
        let reply: InstagramTestTransport.Reply = networkFailure ? .failure(.notConnectedToInternet) : .json("<html>Bad gateway</html>")
        let transport = InstagramTestTransport(["ig-123": reply])
        let graph = transport.provider()
        defer { transport.finish(graph) }
        let web = InstagramWebSpy()
        let temp = try TempDatabase()
        let id = try await makeService(graph: graph, web: web).refreshAccount(
            username: "peacegrappler", kind: "own", database: temp.database,
            settings: connectedSettings(), limit: 4, log: { _ in })
        #expect(web.profileCalls == 1)
        let accounts = try await temp.database.fetchIGAccounts()
        #expect(accounts.first?.id == id)
        #expect(accounts.first?.displayName == "Web profile")
    }

    @Test("Rediscovered ID is used for media and media permissions never fall back")
    func recoveredIDForMedia() async throws {
        let transport = InstagramTestTransport([
            "ig-123": .json(#"{"error":{"code":100,"message":"Unknown object"}}"#),
            "me/accounts": .json(#"{"data":[{"instagram_business_account":{"id":"new-id","username":"peacegrappler"}}]}"#),
            "new-id/media": .json(#"{"error":{"code":10,"message":"Media permission denied"}}"#),
        ])
        let graph = transport.provider()
        defer { transport.finish(graph) }
        let web = InstagramWebSpy()
        let temp = try TempDatabase()
        do {
            _ = try await makeService(graph: graph, web: web).refreshAccount(
                username: "peacegrappler", kind: "own", database: temp.database,
                settings: connectedSettings(), limit: 4, log: { _ in })
            Issue.record("Expected media permission failure")
        } catch {
            #expect(String(describing: error).contains("Media permission denied"))
            #expect(String(describing: error).contains("Reconnect in Settings → Instagram"))
        }
        #expect(transport.requests.map { $0.url?.path } == ["/v23.0/ig-123", "/v23.0/me/accounts", "/v23.0/new-id/media"])
        #expect(web.profileCalls == 0)
        let accounts = try await temp.database.fetchIGAccounts()
        #expect(accounts.first?.igUserID == "new-id")
    }

    @Test("URLSession cancellation never falls back")
    func cancellation() async throws {
        let transport = InstagramTestTransport(["ig-123": .failure(.cancelled)])
        let graph = transport.provider()
        defer { transport.finish(graph) }
        let web = InstagramWebSpy()
        let temp = try TempDatabase()
        do {
            _ = try await makeService(graph: graph, web: web).refreshAccount(
                username: "peacegrappler", kind: "own", database: temp.database,
                settings: connectedSettings(), limit: 4, log: { _ in })
            Issue.record("Expected cancellation")
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        }
        #expect(web.profileCalls == 0)
    }

    @Test("Malformed profiles and unexpected JSON shapes never use web", arguments: ["{}", "[]", "null"])
    func invalidJSONShape(body: String) async throws {
        let transport = InstagramTestTransport(["ig-123": .json(body)])
        let graph = transport.provider()
        defer { transport.finish(graph) }
        let web = InstagramWebSpy()
        let temp = try TempDatabase()
        do {
            _ = try await makeService(graph: graph, web: web).refreshAccount(
                username: "peacegrappler", kind: "own", database: temp.database,
                settings: connectedSettings(), limit: 4, log: { _ in })
            Issue.record("Expected invalid response failure")
        } catch {
            #expect(String(describing: error).contains("Reconnect in Settings → Instagram"))
        }
        #expect(web.profileCalls == 0)
    }

    @Test("A rate limit keeps its own message without a reconnect hint")
    func rateLimitIsNotReconnect() async throws {
        let transport = InstagramTestTransport([
            "ig-123": .json(#"{"error":{"code":4,"message":"Application request limit reached"}}"#),
        ])
        let graph = transport.provider()
        defer { transport.finish(graph) }
        let web = InstagramWebSpy()
        let service = makeService(graph: graph, web: web)
        let temp = try TempDatabase()
        do {
            _ = try await service.refreshAccount(username: "peacegrappler", kind: "own", database: temp.database,
                                                 settings: connectedSettings(), limit: 4, log: { _ in })
            Issue.record("Expected the rate-limit failure")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("rate limit"))
            #expect(!message.contains("Reconnect"))
        }
        #expect(web.profileCalls == 0)
    }

    @Test("Only transport errors are recoverable")
    func classification() {
        #expect(InstagramError.isRecoverableTransport(URLError(.timedOut)))
        #expect(InstagramError.isRecoverableTransport(InstagramError.nonJSONResponse("Bad gateway")))
        #expect(!InstagramError.isRecoverableTransport(URLError(.cancelled)))
        #expect(!InstagramError.isRecoverableTransport(CancellationError()))
        #expect(!InstagramError.isRecoverableTransport(InstagramError.graphAPI(code: 10, message: "Permission denied")))
        #expect(!InstagramError.isRecoverableTransport(InstagramError.fetchFailed("No accounts")))
        #expect(!InstagramError.isRecoverableTransport(InstagramError.parseFailed("Missing profile fields")))
    }

    @Test("Refresh requires a token older than 24 hours and expiry within 14 days or unknown",
          arguments: [23.0, 24.0, 25.0], [nil, -1.0, 0.0, 14.0, 15.0] as [Double?])
    func refreshWindow(ageHours: Double, expiryDays: Double?) async throws {
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let transport = InstagramTestTransport([
            "refresh_access_token": .json(#"{"access_token":"IGrefreshed","expires_in":5184000}"#),
        ])
        let graph = transport.provider(flavor: .instagram)
        defer { transport.finish(graph) }
        let saved = Mutex<InstagramTokenRefresh?>(nil)
        let service = InstagramService(ai: AIService(config: AIConfig()),
            makeGraphProvider: { _, _ in graph },
            persistTokenRefresh: { refresh, _, oldToken in
                #expect(oldToken == graph.token)
                saved.withLock { $0 = refresh }
                return true
            }, now: { instant })
        var settings = connectedSettings()
        settings.tokenFlavor = "instagram"
        settings.tokenRefreshedAt = instant.addingTimeInterval(-ageHours * 3600)
        settings.tokenExpiresAt = expiryDays.map { instant.addingTimeInterval($0 * 86400) }
        let provider = await service.refreshTokenIfNeeded(settings: settings, log: { _ in })
        let expected = ageHours > 24 && (expiryDays.map { $0 > 0 && $0 <= 14 } ?? true)
        #expect(transport.requests.count == (expected ? 1 : 0))
        #expect(provider?.token == (expected ? "IGrefreshed" : graph.token))
        #expect((saved.withLock { $0 } != nil) == expected)
        if expected {
            let request = try #require(transport.requests.first)
            #expect(request.url?.host == "graph.instagram.com")
            #expect(request.url?.path == "/refresh_access_token")
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(components.queryItems?.first { $0.name == "grant_type" }?.value == "ig_refresh_token")
            #expect(components.queryItems?.first { $0.name == "access_token" }?.value == graph.token)
            #expect(saved.withLock { $0?.refreshedAt } == instant)
            #expect(saved.withLock { $0?.expiresAt } == instant.addingTimeInterval(60 * 86400))
        }
    }

    @Test("Facebook tokens and tokens of unknown age never refresh", arguments: [InstagramTokenFlavor.facebook, .instagram])
    func doesNotRefresh(flavor: InstagramTokenFlavor) async throws {
        let transport = InstagramTestTransport([:])
        let graph = transport.provider(flavor: flavor)
        defer { transport.finish(graph) }
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let service = InstagramService(ai: AIService(config: AIConfig()), makeGraphProvider: { _, _ in graph },
            persistTokenRefresh: { _, _, _ in Issue.record("Unexpected token write"); return true }, now: { instant })
        var settings = connectedSettings()
        settings.tokenFlavor = flavor.rawValue
        settings.tokenRefreshedAt = flavor == .facebook ? instant.addingTimeInterval(-48 * 3600) : nil
        settings.tokenExpiresAt = instant.addingTimeInterval(86400)
        _ = await service.refreshTokenIfNeeded(settings: settings, log: { _ in })
        #expect(transport.requests.isEmpty)
    }

    @Test("Successful refresh persists the replacement and dates once for concurrent and stale snapshots")
    @MainActor
    func refreshPersists() async throws {
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let transport = InstagramTestTransport([
            "refresh_access_token": .json(#"{"access_token":"IGnew-token","expires_in":123456}"#),
            "ig-123": .json(#"{"id":"ig-123","username":"peacegrappler"}"#),
        ])
        let graph = transport.provider(flavor: .instagram)
        defer { transport.finish(graph) }
        let writes = Mutex<[(String, InstagramTokenRefresh)]>([])
        let keychain = Mutex(graph.token)
        var settings = connectedSettings()
        settings.tokenFlavor = "instagram"
        settings.tokenRefreshedAt = instant.addingTimeInterval(-48 * 3600)
        settings.tokenExpiresAt = instant.addingTimeInterval(86400)
        var appSettings = AppSettings()
        appSettings.instagram = settings
        let profile = Fixtures.brand(name: "Instagram refresh test")
        let store = AppStore(settings: appSettings, profiles: [profile], active: profile,
                             ai: AIService(config: appSettings.ai))
        let service = InstagramService(ai: AIService(config: AIConfig()), makeGraphProvider: { _, _ in graph.withToken(keychain.withLock { $0 }) },
            persistTokenRefresh: { refresh, original, token in
                try await store.applyInstagramTokenRefresh(refresh, settings: original, replacing: token,
                    readToken: { account in
                        #expect(account == "instagram_graph_token")
                        return keychain.withLock { $0 }
                    }, saveToken: { value, account in
                        keychain.withLock { $0 = value }
                        writes.withLock { $0.append((account, refresh)) }
                    })
            }, now: { instant })
        let snapshot = settings
        async let first = service.refreshTokenIfNeeded(settings: snapshot, log: { _ in })
        async let second = service.refreshTokenIfNeeded(settings: snapshot, log: { _ in })
        let (a, b) = await (first, second)
        let third = await service.refreshTokenIfNeeded(settings: snapshot, log: { _ in })
        #expect(a?.token == "IGnew-token" && b?.token == "IGnew-token" && third?.token == "IGnew-token")
        _ = try await a?.fetchProfile(username: "peacegrappler", log: { _ in })
        #expect(transport.requests.filter { $0.url?.path == "/refresh_access_token" }.count == 1)
        #expect(transport.requests.allSatisfy { $0.url?.host == "graph.instagram.com" })
        let values = writes.withLock { $0 }
        #expect(values.count == 1)
        #expect(values.first?.0 == "instagram_graph_token")
        #expect(values.first?.1.token == "IGnew-token")
        #expect(values.first?.1.refreshedAt == instant)
        #expect(values.first?.1.expiresAt == instant.addingTimeInterval(123456))
        #expect(keychain.withLock { $0 } == "IGnew-token")
        #expect(store.settings.instagram.tokenRefreshedAt == instant)
        #expect(store.settings.instagram.tokenExpiresAt == instant.addingTimeInterval(123456))
        let profileURL = try #require(transport.requests.last?.url)
        #expect(URLComponents(url: profileURL, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "access_token" }?.value == "IGnew-token")
    }

    @Test("Failed refresh preserves the old token and still fetches, logging once")
    func refreshFailureContinuesFetch() async throws {
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let transport = InstagramTestTransport([
            "refresh_access_token": .json(#"{"error":{"code":190,"message":"Refresh rejected"}}"#),
            "ig-123": .json(#"{"id":"ig-123","username":"peacegrappler"}"#),
            "ig-123/media": .json(#"{"data":[{"id":"reel-1","media_type":"VIDEO"}]}"#),
            "reel-1/insights": .json(#"{"data":[]}"#),
            // Reports are separate from fetching reels and may lack extra permissions.
            "ig-123/insights": .json(#"{"error":{"code":10,"message":"No report permission"}}"#),
            "reel-1/comments": .json(#"{"data":[]}"#),
        ])
        let graph = transport.provider(flavor: .instagram)
        defer { transport.finish(graph) }
        let logs = Mutex<[String]>([])
        let service = InstagramService(ai: AIService(config: AIConfig()), makeGraphProvider: { _, _ in graph },
            persistTokenRefresh: { _, _, _ in Issue.record("Failed refresh must not write the Keychain"); return true },
            now: { instant })
        var settings = connectedSettings()
        settings.tokenFlavor = "instagram"
        settings.tokenRefreshedAt = instant.addingTimeInterval(-48 * 3600)
        settings.tokenExpiresAt = instant.addingTimeInterval(86400)
        let temp = try TempDatabase()
        let existingID = try await temp.database.upsertIGAccount(username: "peacegrappler", kind: "own",
                                                              displayName: nil, igUserID: "ig-123", followers: nil)
        try await temp.database.setIGSyncState(accountID: existingID, key: "account_insights_last_day",
                                               value: InstagramReportSync.dayKey(Date()))
        let accountID = try await service.refreshAccount(username: "peacegrappler", kind: "own",
            database: temp.database, settings: settings, limit: 4, log: { message in logs.withLock { $0.append(message) } })
        #expect(accountID > 0)
        _ = await service.refreshTokenIfNeeded(settings: settings, log: { message in logs.withLock { $0.append(message) } })
        #expect(logs.withLock { $0.filter { $0.contains("token refresh failed") }.count } == 1)
        #expect(transport.requests.contains { $0.url?.path == "/v23.0/ig-123/media" })
        #expect(transport.requests.allSatisfy { request in
            guard let url = request.url else { return false }
            return url.host == "graph.instagram.com"
                && URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first { $0.name == "access_token" }?.value == graph.token
        })
    }

    @Test("A Keychain write failure leaves the current provider in use")
    func refreshPersistenceFailure() async throws {
        let transport = InstagramTestTransport([
            "refresh_access_token": .json(#"{"access_token":"IGreplacement","expires_in":5184000}"#),
        ])
        let graph = transport.provider(flavor: .instagram)
        defer { transport.finish(graph) }
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let service = InstagramService(ai: AIService(config: AIConfig()), makeGraphProvider: { _, _ in graph },
            persistTokenRefresh: { _, _, _ in throw InstagramError.fetchFailed("Keychain write failed") },
            now: { instant })
        var settings = connectedSettings()
        settings.tokenFlavor = "instagram"
        settings.tokenRefreshedAt = instant.addingTimeInterval(-48 * 3600)
        let provider = await service.refreshTokenIfNeeded(settings: settings, log: { _ in })
        #expect(provider?.token == graph.token)
    }

    @Test("Publishing refreshes before creating the container")
    func publishRefreshesFirst() async throws {
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let transport = InstagramTestTransport([
            "refresh_access_token": .json(#"{"access_token":"IGpublish-token","expires_in":5184000}"#),
            "POST ig-123/media": .json(#"{"error":{"code":10,"message":"Publishing not granted"}}"#),
        ])
        let graph = transport.provider(flavor: .instagram)
        defer { transport.finish(graph) }
        let writes = Mutex(0)
        let service = InstagramService(ai: AIService(config: AIConfig()), makeGraphProvider: { _, _ in graph },
            persistTokenRefresh: { _, _, _ in writes.withLock { $0 += 1 }; return true }, now: { instant })
        var settings = connectedSettings()
        settings.tokenFlavor = "instagram"
        settings.tokenRefreshedAt = instant.addingTimeInterval(-48 * 3600)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("instagram-service-publish-\(UUID().uuidString).mp4")
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            _ = try await service.publishReel(file: file, caption: "", shareToFeed: true, settings: settings, log: { _ in })
            Issue.record("Expected the publish permission error")
        } catch {
            #expect(String(describing: error).contains("instagram_business_content_publish"))
        }
        #expect(writes.withLock { $0 } == 1)
        #expect(transport.requests.map { $0.url?.path } == ["/refresh_access_token", "/v23.0/ig-123/media"])
        #expect(transport.requests.allSatisfy { $0.url?.host == "graph.instagram.com" })
    }

    private func makeService(graph: GraphAPIProvider, web: InstagramWebSpy) -> InstagramService {
        InstagramService(ai: AIService(config: AIConfig()), makeGraphProvider: { _, _ in graph },
                         makeWebProvider: { _ in web })
    }

    private func connectedSettings() -> InstagramSettings {
        var settings = InstagramSettings()
        settings.connectedUsername = "peacegrappler"
        settings.connectedIGUserID = "ig-123"
        return settings
    }
}

nonisolated private final class InstagramWebSpy: InstagramProvider, Sendable {
    let sourceName = "web-test"
    private let calls = Mutex(0)
    var profileCalls: Int { calls.withLock { $0 } }

    func fetchProfile(username: String, log: @escaping @Sendable (String) -> Void) async throws -> IGProfileInfo {
        calls.withLock { $0 += 1 }
        return IGProfileInfo(username: username, displayName: "Web profile")
    }

    func fetchReels(username: String, limit: Int, log: @escaping @Sendable (String) -> Void) async throws -> [IGMediaItem] { [] }
    func downloadThumbnail(_ item: IGMediaItem, to destination: URL) async throws { Issue.record("Unexpected thumbnail") }
    func downloadVideo(_ item: IGMediaItem, to destination: URL, log: @escaping @Sendable (String) -> Void) async throws {
        Issue.record("Unexpected video download")
    }
}
