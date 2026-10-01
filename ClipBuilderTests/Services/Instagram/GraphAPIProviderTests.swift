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

    @Test("User token without visible pages names the missing permissions")
    func userTokenWithoutPages() async throws {
        let transport = InstagramTestTransport([
            "me/accounts": .json(#"{"data":[]}"#),
            "me": .json(#"{"error":{"code":100,"message":"(#100) Tried accessing nonexisting field (instagram_business_account)"}}"#),
            "me/permissions": .json(#"{"data":[{"permission":"instagram_basic","status":"granted"},{"permission":"pages_show_list","status":"declined"},{"permission":"instagram_manage_insights","status":"granted"}]}"#),
        ])
        let graph = transport.provider(id: nil)
        defer { transport.finish(graph) }
        do {
            _ = try await graph.resolveAccount(matching: nil)
            Issue.record("Expected account discovery failure")
        } catch InstagramError.fetchFailed(let detail) {
            #expect(detail.contains("can't see any Facebook Page"))
            #expect(detail.contains("lacks pages_show_list, pages_read_engagement"))
            #expect(!detail.contains("instagram_basic"))
            #expect(!detail.contains("nonexisting field"))
        }
        #expect(transport.requests.map { $0.url?.path } == ["/v23.0/me/accounts", "/v23.0/me", "/v23.0/me/permissions"])
    }

    @Test("User token with every permission points at the Page role")
    func userTokenWithoutPageRole() async throws {
        let transport = InstagramTestTransport([
            "me/accounts": .json(#"{"data":[]}"#),
            "me": .json(#"{"error":{"code":100,"message":"nonexisting field"}}"#),
            "me/permissions": .json(#"{"data":[{"permission":"instagram_basic","status":"granted"},{"permission":"pages_show_list","status":"granted"},{"permission":"pages_read_engagement","status":"granted"},{"permission":"instagram_manage_insights","status":"granted"}]}"#),
        ])
        let graph = transport.provider(id: nil)
        defer { transport.finish(graph) }
        do {
            _ = try await graph.resolveAccount(matching: nil)
            Issue.record("Expected account discovery failure")
        } catch InstagramError.fetchFailed(let detail) {
            #expect(detail.contains("still has a role on the Page"))
            #expect(!detail.contains("lacks"))
        }
    }

    @Test("Page token lookup yields nil for a User token without pages")
    func noPageTokenForUserToken() async throws {
        let transport = InstagramTestTransport([
            "me/accounts": .json(#"{"data":[]}"#),
            "me": .json(#"{"error":{"code":100,"message":"nonexisting field"}}"#),
        ])
        let graph = transport.provider()
        defer { transport.finish(graph) }
        let token = try await graph.pageAccessToken(igUserID: "ig-123")
        #expect(token == nil)
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

    @Test("Instagram Login discovers user_id rather than app-scoped id", arguments: ["BUSINESS", "MEDIA_CREATOR"])
    func instagramDiscovery(type: String) async throws {
        let transport = InstagramTestTransport([
            "me": .json("{\"id\":\"app-scoped\",\"user_id\":\"ig-123\",\"username\":\"peacegrappler\",\"name\":\"Peace Grappler\",\"followers_count\":1234,\"account_type\":\"\(type)\"}"),
        ])
        let graph = transport.provider(id: nil, flavor: .instagram)
        defer { transport.finish(graph) }
        let result = try await graph.resolveAccount(matching: "PeaceGrappler")
        #expect(result.id == "ig-123")
        #expect(result.username == "peacegrappler")
        #expect(result.name == "Peace Grappler")
        #expect(result.followers == 1234)
        #expect(transport.requests.map { $0.url?.host } == ["graph.instagram.com"])
        #expect(transport.requests.map { $0.url?.path } == ["/v23.0/me"])
        #expect(fields(transport.requests.first) == "user_id,username,name,account_type,followers_count")
    }

    @Test("Instagram Login rejects personal accounts with a Professional account hint")
    func instagramPersonalAccount() async throws {
        let transport = InstagramTestTransport([
            "me": .json(#"{"user_id":"ig-123","username":"personal","account_type":"PERSONAL"}"#),
        ])
        let graph = transport.provider(id: nil, flavor: .instagram)
        defer { transport.finish(graph) }
        do {
            _ = try await graph.resolveAccount(matching: nil)
            Issue.record("Expected a personal-account error")
        } catch InstagramError.fetchFailed(let detail) {
            #expect(detail == "@personal is a personal account; switch it to Business or Creator in the Instagram app")
        }
        #expect(transport.requests.allSatisfy { $0.url?.host == "graph.instagram.com" })
    }

    @Test("Instagram Login username mismatch lists the found account")
    func instagramMismatch() async throws {
        let transport = InstagramTestTransport([
            "me": .json(#"{"user_id":"ig-123","username":"found","account_type":"BUSINESS"}"#),
        ])
        let graph = transport.provider(id: nil, flavor: .instagram)
        defer { transport.finish(graph) }
        do {
            _ = try await graph.resolveAccount(matching: "wanted")
            Issue.record("Expected a username mismatch")
        } catch InstagramError.fetchFailed(let detail) {
            #expect(detail == "@wanted is not among the token's Instagram accounts (found: @found)")
        }
    }

    @Test("Instagram Login never requests Facebook permissions or Page tokens")
    func instagramHasNoPageRequests() async throws {
        let transport = InstagramTestTransport([:])
        let graph = transport.provider(flavor: .instagram)
        defer { transport.finish(graph) }
        #expect(await graph.missingPermissions().isEmpty)
        #expect(try await graph.pageAccessToken(igUserID: "ig-123") == nil)
        #expect(transport.requests.isEmpty)
        #expect(graph.withToken("replacement").flavor == .instagram)
    }

    @Test("Instagram Login cached profile retains the canonical user_id")
    func instagramCachedID() async throws {
        let transport = InstagramTestTransport([
            "ig-123": .json(#"{"id":"app-scoped","username":"peacegrappler"}"#),
        ])
        let graph = transport.provider(flavor: .instagram)
        defer { transport.finish(graph) }
        let profile = try await graph.fetchProfile(username: "peacegrappler", log: { _ in })
        #expect(profile.igUserID == "ig-123")
        #expect(transport.requests.first?.url?.host == "graph.instagram.com")
    }

    @Test("All Graph read requests use the confirmed flavor", arguments: [InstagramTokenFlavor.facebook, .instagram])
    func readHosts(flavor: InstagramTokenFlavor) async throws {
        let host = flavor == .instagram ? "graph.instagram.com" : "graph.facebook.com"
        let transport = InstagramTestTransport([
            "ig-123": .json(profile),
            "ig-123/media": .json("{\"data\":[{\"id\":\"media-1\",\"media_type\":\"VIDEO\"}],\"paging\":{\"next\":\"https://\(host)/v23.0/next-media\"}}"),
            "next-media": .json(#"{"data":[]}"#),
            "media-1/insights": .json(#"{"data":[{"name":"views","values":[{"value":42}]}]}"#),
            "ig-123/insights": .json(#"{"data":[]}"#),
            "media-1/comments": .json("{\"data\":[{\"id\":\"comment-1\",\"text\":\"Hello\"}],\"paging\":{\"next\":\"https://\(host)/v23.0/next-comments\"}}"),
            "next-comments": .json(#"{"data":[]}"#),
        ])
        let graph = transport.provider(flavor: flavor)
        defer { transport.finish(graph) }
        _ = try await graph.fetchProfile(username: "peacegrappler", log: { _ in })
        let reels = try await graph.fetchReels(username: "peacegrappler", limit: 4, log: { _ in })
        #expect(reels.first?.stats.views == 42)
        _ = try await graph.fetchAccountDetails(userID: "ig-123")
        _ = try await graph.fetchAllMedia(userID: "ig-123", since: .distantPast, log: { _ in })
        _ = try await graph.fetchMediaInsights(mediaID: "media-1", metrics: ["views", "reach"])
        _ = try await graph.fetchAccountInsights(userID: "ig-123", metrics: ["reach"], since: .distantPast, until: Date())
        _ = try await graph.fetchFollowerCountSeries(userID: "ig-123", since: .distantPast)
        _ = try await graph.fetchDemographics(userID: "ig-123", metric: "follower_demographics",
                                               breakdown: "age", timeframe: "last_30_days")
        let comments = try await graph.fetchComments(mediaID: "media-1")
        #expect(comments.first?.text == "Hello")
        #expect(transport.requests.count == 12)
        #expect(transport.requests.allSatisfy { $0.url?.host == host })
    }

    @Test("Container, processing and publishing use the confirmed flavor", arguments: [InstagramTokenFlavor.facebook, .instagram])
    func publishHosts(flavor: InstagramTokenFlavor) async throws {
        let host = flavor == .instagram ? "graph.instagram.com" : "graph.facebook.com"
        let transport = InstagramTestTransport([
            "POST ig-123/media": .json(#"{"id":"container-1","uri":"https://rupload.facebook.com/ig-api-upload/v23.0/container-1"}"#),
            "ig-api-upload/v23.0/container-1": .json(#"{"success":true}"#),
            "container-1": .json(#"{"status_code":"FINISHED"}"#),
            "POST ig-123/media_publish": .json(#"{"id":"published-1"}"#),
            "published-1": .json(#"{"permalink":"https://www.instagram.com/reel/published/"}"#),
        ])
        let graph = transport.provider(flavor: flavor)
        defer { transport.finish(graph) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("instagram-publish-\(UUID().uuidString).mp4")
        try Data([0, 1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await graph.publishReel(username: "peacegrappler", file: file, caption: "Test + & caption",
                                                  shareToFeed: true, log: { _ in })
        #expect(result.mediaID == "published-1")
        #expect(result.permalink == "https://www.instagram.com/reel/published/")
        let graphRequests = transport.requests.filter { $0.url?.host != "rupload.facebook.com" }
        #expect(graphRequests.map { $0.url?.path } == ["/v23.0/ig-123/media", "/v23.0/container-1", "/v23.0/ig-123/media_publish", "/v23.0/published-1"])
        #expect(graphRequests.map { $0.httpMethod } == ["POST", "GET", "POST", "GET"])
        #expect(graphRequests.allSatisfy { $0.url?.host == host })
        // The upload URI is returned by Meta and is independent of the Graph host.
        #expect(transport.requests.filter { $0.url?.host == "rupload.facebook.com" }.count == 1)
    }

    @Test("Instagram errors name Instagram Login and its scopes", arguments: [190, 10, 200])
    func instagramErrors(code: Int) async throws {
        let transport = InstagramTestTransport([
            "media-1/insights": .json("{\"error\":{\"code\":\(code),\"message\":\"Denied\"}}"),
            "POST ig-123/media": .json("{\"error\":{\"code\":\(code),\"message\":\"Denied\"}}"),
        ])
        let graph = transport.provider(flavor: .instagram)
        defer { transport.finish(graph) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("instagram-error-\(UUID().uuidString).mp4")
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        for publishing in [false, true] {
            do {
                if publishing {
                    _ = try await graph.publishReel(username: nil, file: file, caption: "", shareToFeed: true, log: { _ in })
                } else {
                    _ = try await graph.fetchMediaInsights(mediaID: "media-1", metrics: ["views"])
                }
                Issue.record("Expected Graph rejection")
            } catch {
                let message = String(describing: error)
                if code == 190 {
                    #expect(message.contains("Instagram Login token expired or was revoked; generate a new one in the Meta app dashboard"))
                } else {
                    #expect(message.contains(publishing ? "instagram_business_content_publish" : "instagram_business_manage_insights"))
                    #expect(!message.contains("pages_read_engagement"))
                }
            }
        }
        #expect(transport.requests.allSatisfy { $0.url?.host == "graph.instagram.com" })
    }

    @Test("Download URL lookups use the confirmed flavor", arguments: [InstagramTokenFlavor.facebook, .instagram])
    func downloadLookupHosts(flavor: InstagramTokenFlavor) async throws {
        let transport = InstagramTestTransport([
            "media-1": .json("{}"),
            "ig-123/media": .json(#"{"data":[]}"#),
        ])
        let graph = transport.provider(flavor: flavor)
        defer { transport.finish(graph) }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("instagram-download-\(UUID().uuidString)/video.mp4")
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        do {
            try await graph.downloadVideo(IGMediaItem(mediaID: "media-1"), to: destination, log: { _ in })
            Issue.record("Expected missing media URL")
        } catch InstagramError.fetchFailed(let detail) {
            #expect(detail.contains("no usable media_url"))
        }
        do {
            try await graph.downloadVideo(shortcode: "missing", to: destination, log: { _ in })
            Issue.record("Expected missing shortcode")
        } catch InstagramError.fetchFailed(let detail) {
            #expect(detail.contains("not among the account's recent media"))
        }
        let host = flavor == .instagram ? "graph.instagram.com" : "graph.facebook.com"
        #expect(transport.requests.map { $0.url?.host } == [host, host])
        #expect(transport.requests.map { $0.url?.path } == ["/v23.0/media-1", "/v23.0/ig-123/media"])
    }

    @Test("No-visible-Pages guidance offers Instagram Login", arguments: [[], ["pages_show_list"]])
    func noPagesAlternative(missing: [String]) {
        #expect(GraphAPIProvider.noVisiblePagesMessage(missing: missing)
            .contains("Or generate an Instagram Login token for the account instead (no Facebook Page needed)"))
    }

    private func fields(_ request: URLRequest?) -> String? {
        guard let url = request?.url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "fields" }?.value
    }
}
