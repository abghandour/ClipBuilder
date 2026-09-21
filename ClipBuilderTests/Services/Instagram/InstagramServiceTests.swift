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
