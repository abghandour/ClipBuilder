import Foundation
import Testing
@testable import Clip_Builder

@Suite("Instagram Graph account discovery")
struct GraphAPIProviderTests {
    private let profile = #"{"id":"ig-123","username":"peacegrappler","name":"Peace Grappler","followers_count":1234}"#

    @Test("Stored ID fetches the profile directly without listing pages")
    func storedProfile() async throws {
        let transport = InstagramTestTransport(["ig-123": .json(profile)])
        let graph = transport.provider()
        defer { transport.finish(graph) }
        let result = try await graph.fetchProfile(username: "peacegrappler", log: { _ in })
        #expect(result.igUserID == "ig-123")
        #expect(result.username == "peacegrappler")
        #expect(result.displayName == "Peace Grappler")
        #expect(result.followers == 1234)
        #expect(transport.requests.map { $0.url?.path } == ["/v23.0/ig-123"])
        #expect(fields(transport.requests.first) == "id,username,name,followers_count")
    }

    @Test("Page token resolves through me when the page list is empty", arguments: [nil, ""] as [String?])
    func pageTokenDiscovery(id: String?) async throws {
        let transport = InstagramTestTransport([
            "me/accounts": .json(#"{"data":[]}"#),
            "me": .json("{\"instagram_business_account\":\(profile)}"),
        ])
        let graph = transport.provider(id: id)
        defer { transport.finish(graph) }
        let result = try await graph.fetchProfile(username: "PeaceGrappler", log: { _ in })
        #expect(result.igUserID == "ig-123")
        #expect(result.followers == 1234)
        #expect(transport.requests.map { $0.url?.path } == ["/v23.0/me/accounts", "/v23.0/me"])
        #expect(fields(transport.requests.last) == "instagram_business_account{id,username,name,followers_count}")
    }

    @Test("Unknown object and permission codes rediscover once", arguments: [100, 10, 200])
    func rediscovery(code: Int) async throws {
        let transport = InstagramTestTransport([
            "old-id": .json("{\"error\":{\"code\":\(code),\"message\":\"Cannot access object\"}}"),
            "me/accounts": .json("{\"data\":[{\"instagram_business_account\":\(profile)}]}"),
        ])
        let graph = transport.provider(id: "old-id")
        defer { transport.finish(graph) }
        let result = try await graph.fetchProfile(username: "peacegrappler", log: { message in
            #expect(message.contains("rediscovering"))
            #expect(message.contains("Cannot access object"))
        })
        #expect(result.igUserID == "ig-123")
        #expect(transport.requests.count == 2)
    }

    @Test("Expired tokens and rate limits never trigger discovery", arguments: [190, 4, 17, 32, 613])
    func noRediscovery(code: Int) async throws {
        let transport = InstagramTestTransport([
            "ig-123": .json("{\"error\":{\"code\":\(code),\"message\":\"Graph failure\"}}"),
        ])
        let graph = transport.provider()
        defer { transport.finish(graph) }
        do {
            _ = try await graph.fetchProfile(username: "peacegrappler", log: { _ in })
            Issue.record("Expected Graph failure")
        } catch InstagramError.graphAPI(let actualCode, _) {
            #expect(actualCode == code)
        }
        #expect(transport.requests.count == 1)
    }

    @Test("Page token is reused only for the matching Instagram account", arguments: ["ig-123", "different-id"])
    func ownPageToken(id: String) async throws {
        let transport = InstagramTestTransport([
            "me/accounts": .json(#"{"data":[]}"#),
            "me": .json("{\"instagram_business_account\":\(profile)}"),
        ])
        let graph = transport.provider()
        defer { transport.finish(graph) }
        let token = try await graph.pageAccessToken(igUserID: id)
        #expect(token == (id == "ig-123" ? graph.token : nil))
        #expect(transport.requests.count == 2)
    }

    @Test("Missing accounts retain the actionable discovery error")
    func missingAccount() async throws {
        let transport = InstagramTestTransport(["me/accounts": .json(#"{"data":[]}"#), "me": .json("{}")])
        let graph = transport.provider(id: nil)
        defer { transport.finish(graph) }
        do {
            _ = try await graph.resolveAccount(matching: nil)
            Issue.record("Expected account discovery failure")
        } catch InstagramError.fetchFailed(let detail) {
            #expect(detail == "No Instagram business/creator account is linked to this token's Facebook pages")
        }
    }

    private func fields(_ request: URLRequest?) -> String? {
        guard let url = request?.url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "fields" }?.value
    }
}
