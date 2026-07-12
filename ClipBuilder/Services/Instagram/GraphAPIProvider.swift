import Foundation

/// Official Instagram Graph API access for the user's own business/creator
/// account — real insights (reach, saves, shares, watch time) and stable
/// downloads. The long-lived token lives in the Keychain; account discovery
/// goes through the token's Facebook pages (graph.facebook.com).
nonisolated struct GraphAPIProvider: InstagramProvider {
    let token: String
    /// Known IG user id (cached in settings after connect) — skips discovery.
    var igUserID: String?

    var sourceName: String { "graph" }

    private static let base = "https://graph.facebook.com/v23.0"

    /// Graph timestamps look like "2026-07-11T13:00:38+0000".
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }()

    // MARK: - Requests

    private func getJSON(_ path: String, query: [String: String]) async throws -> [String: Any] {
        guard var components = URLComponents(string: "\(Self.base)/\(path)") else {
            throw InstagramError.fetchFailed("Invalid Graph API path: \(path)")
        }
        components.queryItems = query
            .merging(["access_token": token]) { current, _ in current }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else {
            throw InstagramError.fetchFailed("Invalid Graph API URL for \(path)")
        }
        let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 30))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstagramError.parseFailed("Graph API returned non-JSON for \(path)")
        }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "unknown error"
            if (error["code"] as? Int) == 190 {
                throw InstagramError.fetchFailed(
                    "Instagram access token expired or invalid — reconnect in Settings → Instagram. (\(message))")
            }
            throw InstagramError.fetchFailed("Graph API: \(message)")
        }
        return object
    }

    nonisolated struct ResolvedAccount: Sendable {
        var id: String
        var username: String
        var name: String?
        var followers: Int?
    }

    /// The IG business/creator account behind the token's pages, matched to
    /// `username` when given (else the first one found — used by Connect).
    func resolveAccount(matching username: String?) async throws -> ResolvedAccount {
        let object = try await getJSON("me/accounts", query: [
            "fields": "instagram_business_account{id,username,name,followers_count}",
        ])
        let accounts = (object["data"] as? [[String: Any]] ?? []).compactMap { page -> ResolvedAccount? in
            guard let account = page["instagram_business_account"] as? [String: Any],
                  let id = account["id"] as? String,
                  let igUsername = account["username"] as? String else { return nil }
            return ResolvedAccount(id: id, username: igUsername,
                                   name: account["name"] as? String,
                                   followers: account["followers_count"] as? Int)
        }
        guard !accounts.isEmpty else {
            throw InstagramError.fetchFailed(
                "No Instagram business/creator account is linked to this token's Facebook pages")
        }
        guard let username else { return accounts[0] }
        guard let match = accounts.first(where: {
            $0.username.caseInsensitiveCompare(username) == .orderedSame
        }) else {
            let found = accounts.map { "@\($0.username)" }.joined(separator: ", ")
            throw InstagramError.fetchFailed(
                "@\(username) is not among the token's Instagram accounts (found: \(found))")
        }
        return match
    }

    // MARK: - InstagramProvider

    func fetchProfile(username: String,
                      log: @escaping @Sendable (String) -> Void) async throws -> IGProfileInfo {
        let account = try await resolveAccount(matching: username)
        return IGProfileInfo(username: account.username, displayName: account.name,
                             igUserID: account.id, followers: account.followers)
    }

    func fetchReels(username: String, limit: Int,
                    log: @escaping @Sendable (String) -> Void) async throws -> [IGMediaItem] {
        let userID: String
        if let igUserID, !igUserID.isEmpty {
            userID = igUserID
        } else {
            userID = try await resolveAccount(matching: username).id
        }
        log("Fetching @\(username) via the Graph API...")
        let object = try await getJSON("\(userID)/media", query: [
            "fields": "id,caption,media_type,media_product_type,media_url,thumbnail_url,"
                + "permalink,timestamp,like_count,comments_count",
            "limit": String(limit),
        ])
        let entries = (object["data"] as? [[String: Any]] ?? [])
            .filter { $0["media_type"] as? String == "VIDEO" }
        guard !entries.isEmpty else {
            throw InstagramError.fetchFailed("No videos found on @\(username) via the Graph API")
        }
        log("Found \(entries.count) videos/reels — fetching insights...")
        // Insights are one extra request per media; run a few at a time and
        // tolerate per-item failures (older posts lack some metrics).
        return try await BoundedConcurrency.map(entries, limit: 4) { _, node in
            await self.mediaItem(node: node, log: log)
        }
    }

    private func mediaItem(node: [String: Any],
                           log: @Sendable (String) -> Void) async -> IGMediaItem {
        var item = IGMediaItem(mediaID: node["id"] as? String ?? "")
        item.mediaType = (node["media_product_type"] as? String) == "REELS" ? "reel" : "video"
        item.caption = node["caption"] as? String ?? ""
        item.permalink = node["permalink"] as? String
        if let timestamp = node["timestamp"] as? String {
            item.postedAt = Self.dateFormatter.date(from: timestamp)
        }
        item.thumbnailRemoteURL = node["thumbnail_url"] as? String
        item.videoRemoteURL = node["media_url"] as? String

        var stats = IGStats(likes: node["like_count"] as? Int,
                            comments: node["comments_count"] as? Int)
        if let insights = try? await getJSON("\(item.mediaID)/insights", query: [
            "metric": "views,reach,likes,comments,shares,saved,ig_reels_avg_watch_time",
        ]) {
            for metric in insights["data"] as? [[String: Any]] ?? [] {
                guard let name = metric["name"] as? String,
                      let value = (metric["values"] as? [[String: Any]])?.first?["value"] as? NSNumber
                else { continue }
                switch name {
                case "views": stats.views = value.intValue
                case "reach": stats.reach = value.intValue
                case "likes": stats.likes = value.intValue
                case "comments": stats.comments = value.intValue
                case "shares": stats.shares = value.intValue
                case "saved": stats.saves = value.intValue
                case "ig_reels_avg_watch_time": stats.avgWatchTime = value.doubleValue / 1000
                default: break
                }
            }
        } else {
            log("Insights unavailable for \(item.mediaID) — keeping public counts")
        }
        item.stats = stats
        return item
    }

    func downloadThumbnail(_ item: IGMediaItem, to destination: URL) async throws {
        guard let remote = item.thumbnailRemoteURL, let url = URL(string: remote) else {
            throw InstagramError.fetchFailed("Media \(item.mediaID) has no thumbnail URL")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              !data.isEmpty else {
            throw InstagramError.fetchFailed("Thumbnail download failed for \(item.mediaID)")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }

    func downloadVideo(_ item: IGMediaItem, to destination: URL,
                       log: @escaping @Sendable (String) -> Void) async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // media_url is a signed CDN URL that expires; re-fetch a fresh one
        // when the cached one is missing or stale.
        var downloaded = await download(item.videoRemoteURL, to: destination)
        if !downloaded {
            let object = try await getJSON(item.mediaID, query: ["fields": "media_url"])
            downloaded = await download(object["media_url"] as? String, to: destination)
        }
        guard downloaded else {
            throw InstagramError.fetchFailed("Video download failed for \(item.mediaID)")
        }
        log("Downloaded reel \(item.mediaID) via the Graph API")
    }

    /// Download by web shortcode: find the graph media whose permalink
    /// carries it and fetch that media_url. Lets rows listed via the public
    /// web API download through the official API — no cookies needed.
    func downloadVideo(shortcode: String, to destination: URL,
                       log: @escaping @Sendable (String) -> Void) async throws {
        let userID: String
        if let igUserID, !igUserID.isEmpty {
            userID = igUserID
        } else {
            userID = try await resolveAccount(matching: nil).id
        }
        let object = try await getJSON("\(userID)/media", query: [
            "fields": "permalink,media_url",
            "limit": "50",
        ])
        let match = (object["data"] as? [[String: Any]] ?? []).first {
            ($0["permalink"] as? String)?.contains("/\(shortcode)/") == true
        }
        guard let remote = match?["media_url"] as? String else {
            throw InstagramError.fetchFailed(
                "Reel \(shortcode) is not among the account's recent media on the Graph API")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard await download(remote, to: destination) else {
            throw InstagramError.fetchFailed("Video download failed for \(shortcode)")
        }
        log("Downloaded reel \(shortcode) via the Graph API")
    }

    private func download(_ remote: String?, to destination: URL) async -> Bool {
        guard let remote, let url = URL(string: remote),
              let (temporary, response) = try? await URLSession.shared.download(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
        else { return false }
        try? FileManager.default.removeItem(at: destination)
        return (try? FileManager.default.moveItem(at: temporary, to: destination)) != nil
    }
}
