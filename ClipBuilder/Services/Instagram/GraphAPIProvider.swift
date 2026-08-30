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
        return try await getJSON(url: url, label: path)
    }

    /// Absolute-URL variant — `paging.next` links already carry the token.
    func getJSON(url: URL, label: String) async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 30))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstagramError.parseFailed("Graph API returned non-JSON for \(label)")
        }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "unknown error"
            switch error["code"] as? Int {
            case 190:
                throw InstagramError.fetchFailed(
                    "Instagram access token expired or invalid — reconnect in Settings → Instagram. (\(message))")
            case 4, 17, 32, 613:
                throw InstagramError.fetchFailed(
                    "Instagram rate limit reached (\(message)) — the next Refresh resumes where this one stopped")
            case 10, 200:
                throw InstagramError.fetchFailed(
                    "Instagram refused \(label): \(message) — the connected token may lack a permission "
                    + "(instagram_manage_insights, instagram_manage_comments, pages_read_engagement)")
            default:
                throw InstagramError.fetchFailed("Graph API: \(message)")
            }
        }
        return object
    }

    private func postJSON(_ path: String, form: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: "\(Self.base)/\(path)") else {
            throw InstagramError.fetchFailed("Invalid Graph API path: \(path)")
        }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(form.merging(["access_token": token]) { current, _ in current })
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstagramError.parseFailed("Graph API returned non-JSON for \(path)")
        }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "unknown error"
            switch error["code"] as? Int {
            case 190:
                throw InstagramError.fetchFailed(
                    "Instagram access token expired or invalid — reconnect in Settings → Instagram. (\(message))")
            case 200, 10:
                throw InstagramError.fetchFailed(
                    "Instagram refused the request: \(message) — the connected token likely lacks the "
                    + "instagram_content_publish permission; reconnect in Settings → Instagram with a token that includes it")
            default:
                throw InstagramError.fetchFailed("Graph API: \(message)")
            }
        }
        return object
    }

    /// Strict form encoding (RFC 3986 unreserved only) so captions with
    /// newlines, '+', '&', or emoji survive the round trip.
    private static func formEncode(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        .joined(separator: "&")
        .data(using: .utf8) ?? Data()
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
            throw InstagramError.fetchFailed(
                "Video download failed for \(item.mediaID) — the Graph API returned no usable media_url (common for reels with licensed audio)")
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

    // MARK: - Publishing

    nonisolated struct PublishedReel: Sendable {
        var mediaID: String
        var permalink: String?
    }

    /// Publish a local video file to the account as a Reel via the content
    /// publishing API's resumable upload — no public hosting needed:
    /// create a REELS container, POST the bytes to rupload.facebook.com,
    /// poll the container until Instagram finishes processing, then publish.
    /// Requires the token to carry instagram_content_publish.
    func publishReel(username: String?, file: URL, caption: String, shareToFeed: Bool,
                     log: @escaping @Sendable (String) -> Void) async throws -> PublishedReel {
        let userID: String
        if let igUserID, !igUserID.isEmpty {
            userID = igUserID
        } else {
            userID = try await resolveAccount(matching: username).id
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else {
            throw InstagramError.fetchFailed("\(file.lastPathComponent) is missing or empty")
        }

        log("Creating the reel container…")
        let container = try await postJSON("\(userID)/media", form: [
            "media_type": "REELS",
            "upload_type": "resumable",
            "caption": caption,
            "share_to_feed": shareToFeed ? "true" : "false",
        ])
        guard let containerID = container["id"] as? String else {
            throw InstagramError.parseFailed("The media container response had no id")
        }
        guard let uploadURL = (container["uri"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://rupload.facebook.com/ig-api-upload/v23.0/\(containerID)") else {
            throw InstagramError.fetchFailed("No usable upload URL for container \(containerID)")
        }

        log(String(format: "Uploading %@ (%.1f MB)…", file.lastPathComponent,
                   Double(fileSize) / 1_048_576))
        var request = URLRequest(url: uploadURL, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("0", forHTTPHeaderField: "offset")
        request.setValue(String(fileSize), forHTTPHeaderField: "file_size")
        let (uploadData, _) = try await URLSession.shared.upload(for: request, fromFile: file)
        let uploadObject = (try? JSONSerialization.jsonObject(with: uploadData)) as? [String: Any] ?? [:]
        guard uploadObject["success"] as? Bool == true else {
            let detail = (uploadObject["debug_info"] as? [String: Any])?["message"] as? String
                ?? String(data: uploadData, encoding: .utf8) ?? "unknown error"
            throw InstagramError.fetchFailed("Video upload failed: \(detail)")
        }

        log("Waiting for Instagram to process the video…")
        // Processing normally takes 15–90s; poll every 5s, give up after 5min.
        let deadline = Date().addingTimeInterval(300)
        poll: while true {
            try await Task.sleep(for: .seconds(5))
            let status = try await getJSON(containerID, query: ["fields": "status_code,status"])
            switch status["status_code"] as? String {
            case "FINISHED":
                break poll
            case "ERROR", "EXPIRED":
                let detail = status["status"] as? String ?? "no detail from Instagram"
                throw InstagramError.fetchFailed(
                    "Instagram rejected the video (\(detail)). Reels must be MP4, 3s–15min, ≤1GB — "
                    + "Clip Builder renders comply, so this usually means an audio/licensing issue")
            default:
                guard Date() < deadline else {
                    throw InstagramError.fetchFailed(
                        "Timed out after 5 minutes waiting for Instagram to process the video")
                }
            }
        }

        log("Publishing the reel…")
        let published = try await postJSON("\(userID)/media_publish",
                                           form: ["creation_id": containerID])
        guard let mediaID = published["id"] as? String else {
            throw InstagramError.parseFailed("The publish response had no media id")
        }
        let permalink = (try? await getJSON(mediaID, query: ["fields": "permalink"]))?["permalink"] as? String
        log("Published ✓")
        return PublishedReel(mediaID: mediaID, permalink: permalink)
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

// MARK: - Report data (account insights, all media, comments, demographics)

/// One post of any type from `/{ig-user}/media`.
nonisolated struct IGGraphMediaNode: Sendable {
    var id: String
    var caption: String = ""
    var mediaType: String?           // IMAGE | VIDEO | CAROUSEL_ALBUM
    var productType: String?         // FEED | REELS | STORY
    var mediaURL: String?
    var thumbnailURL: String?
    var permalink: String?
    var timestamp: Date?
    var likeCount: Int?
    var commentsCount: Int?

    var shortcode: String? { GraphAPIProvider.shortcode(from: permalink) }
}

nonisolated struct IGGraphComment: Sendable {
    var id: String
    var text: String
    var timestamp: Date?
    var username: String?
    var fromID: String?
    var likeCount: Int
    var hidden: Bool
    var parentID: String?
}

/// One value from `/{ig-user}/insights` (`metric_type=total_value`),
/// optionally one slice of a breakdown.
nonisolated struct IGGraphInsightValue: Sendable {
    var metric: String
    var dimension: String = ""
    var breakdown: String = ""
    var value: Double
}

extension GraphAPIProvider {
    /// The same provider with a different token (the Page token for
    /// account-level insights and comments).
    func withToken(_ token: String) -> GraphAPIProvider {
        GraphAPIProvider(token: token, igUserID: igUserID)
    }

    static func shortcode(from permalink: String?) -> String? { IGShortcode.parse(permalink) }

    private static func parseTimestamp(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return Database.parseISODate(string)
    }

    /// Page access token for the page that owns `igUserID` — peace-grappler
    /// uses it for every IG call; account insights and comments are the ones
    /// that need it. Nil when the token has no page access.
    func pageAccessToken(igUserID: String) async throws -> String? {
        let object = try await getJSON("me/accounts", query: [
            "fields": "id,access_token,instagram_business_account{id}",
        ])
        let pages = object["data"] as? [[String: Any]] ?? []
        let page = pages.first {
            (($0["instagram_business_account"] as? [String: Any])?["id"] as? String) == igUserID
        } ?? pages.first { $0["instagram_business_account"] != nil }
        return page?["access_token"] as? String
    }

    func fetchAccountDetails(userID: String) async throws
        -> (followers: Int?, follows: Int?, mediaCount: Int?) {
        let object = try await getJSON(userID, query: ["fields": "followers_count,follows_count,media_count"])
        return (object["followers_count"] as? Int, object["follows_count"] as? Int,
                object["media_count"] as? Int)
    }

    /// Every post (any type) newer than `since`, following the cursor until
    /// a page's oldest post is older than the cutoff.
    func fetchAllMedia(userID: String, since: Date,
                       log: @escaping @Sendable (String) -> Void) async throws -> [IGGraphMediaNode] {
        var nodes: [IGGraphMediaNode] = []
        var object = try await getJSON("\(userID)/media", query: [
            "fields": "id,caption,media_type,media_product_type,media_url,thumbnail_url,permalink,timestamp,"
                + "like_count,comments_count",
            "limit": "50",
        ])
        var pages = 0
        while true {
            pages += 1
            var reachedCutoff = false
            for node in object["data"] as? [[String: Any]] ?? [] {
                guard let id = node["id"] as? String else { continue }
                let timestamp = Self.parseTimestamp(node["timestamp"])
                if let timestamp, timestamp < since {
                    reachedCutoff = true
                    continue
                }
                nodes.append(IGGraphMediaNode(
                    id: id, caption: node["caption"] as? String ?? "",
                    mediaType: node["media_type"] as? String,
                    productType: node["media_product_type"] as? String,
                    mediaURL: node["media_url"] as? String,
                    thumbnailURL: node["thumbnail_url"] as? String,
                    permalink: node["permalink"] as? String,
                    timestamp: timestamp,
                    likeCount: node["like_count"] as? Int,
                    commentsCount: node["comments_count"] as? Int))
            }
            guard !reachedCutoff, pages < 20,
                  let next = (object["paging"] as? [String: Any])?["next"] as? String,
                  let url = URL(string: next) else { break }
            try Task.checkCancellation()
            object = try await getJSON(url: url, label: "\(userID)/media (page \(pages + 1))")
        }
        log("Found \(nodes.count) posts since \(since.formatted(date: .abbreviated, time: .omitted))")
        return nodes
    }

    /// Per-media insight values (current totals). Missing metrics are
    /// simply absent — older posts lack some.
    func fetchMediaInsights(mediaID: String, metrics: [String]) async throws -> [String: Double] {
        let object = try await getJSON("\(mediaID)/insights", query: ["metric": metrics.joined(separator: ",")])
        var values: [String: Double] = [:]
        for metric in object["data"] as? [[String: Any]] ?? [] {
            guard let name = metric["name"] as? String else { continue }
            if let value = (metric["values"] as? [[String: Any]])?.first?["value"] as? NSNumber {
                values[name] = value.doubleValue
            } else if let total = (metric["total_value"] as? [String: Any])?["value"] as? NSNumber {
                values[name] = total.doubleValue
            }
        }
        return values
    }

    /// Account-level totals for [since, until) — `metric_type=total_value`,
    /// with the optional breakdown expanded into one value per slice.
    func fetchAccountInsights(userID: String, metrics: [String], period: String = "day",
                              since: Date, until: Date, breakdown: String? = nil) async throws
        -> [IGGraphInsightValue] {
        var query: [String: String] = [
            "metric": metrics.joined(separator: ","),
            "period": period,
            "metric_type": "total_value",
            "since": String(Int(since.timeIntervalSince1970)),
            "until": String(Int(until.timeIntervalSince1970)),
        ]
        if let breakdown { query["breakdown"] = breakdown }
        let object = try await getJSON("\(userID)/insights", query: query)
        var values: [IGGraphInsightValue] = []
        for metric in object["data"] as? [[String: Any]] ?? [] {
            guard let name = metric["name"] as? String,
                  let total = metric["total_value"] as? [String: Any] else { continue }
            if let breakdown, let breakdowns = total["breakdowns"] as? [[String: Any]] {
                for slice in breakdowns {
                    for result in slice["results"] as? [[String: Any]] ?? [] {
                        let label = (result["dimension_values"] as? [String])?.first ?? ""
                        let value = (result["value"] as? NSNumber)?.doubleValue ?? 0
                        values.append(IGGraphInsightValue(metric: name, dimension: breakdown,
                                                          breakdown: label, value: value))
                    }
                }
            } else if let value = total["value"] as? NSNumber {
                values.append(IGGraphInsightValue(metric: name, value: value.doubleValue))
            }
        }
        return values
    }

    /// Daily `follower_count` values (date → value), up to 30 days back.
    func fetchFollowerCountSeries(userID: String, since: Date) async throws -> [(date: String, value: Double)] {
        let object = try await getJSON("\(userID)/insights", query: [
            "metric": "follower_count",
            "period": "day",
            "since": String(Int(since.timeIntervalSince1970)),
            "until": String(Int(Date().timeIntervalSince1970)),
        ])
        var series: [(date: String, value: Double)] = []
        for metric in object["data"] as? [[String: Any]] ?? [] {
            for entry in metric["values"] as? [[String: Any]] ?? [] {
                guard let end = entry["end_time"] as? String,
                      let value = entry["value"] as? NSNumber else { continue }
                series.append((String(end.prefix(10)), value.doubleValue))
            }
        }
        return series
    }

    /// `follower_demographics` / `engaged_audience_demographics` for one
    /// breakdown dimension and timeframe.
    func fetchDemographics(userID: String, metric: String, breakdown: String,
                           timeframe: String) async throws -> [(value: String, count: Int)] {
        let object = try await getJSON("\(userID)/insights", query: [
            "metric": metric,
            "period": "lifetime",
            "metric_type": "total_value",
            "breakdown": breakdown,
            "timeframe": timeframe,
        ])
        var rows: [(value: String, count: Int)] = []
        for entry in object["data"] as? [[String: Any]] ?? [] {
            guard let total = entry["total_value"] as? [String: Any] else { continue }
            for slice in total["breakdowns"] as? [[String: Any]] ?? [] {
                for result in slice["results"] as? [[String: Any]] ?? [] {
                    let label = (result["dimension_values"] as? [String])?.first ?? ""
                    rows.append((label, (result["value"] as? NSNumber)?.intValue ?? 0))
                }
            }
        }
        return rows
    }

    /// Comments and their replies for one post — replies come inline via
    /// the `replies{…}` field expansion, one request per page of comments.
    func fetchComments(mediaID: String) async throws -> [IGGraphComment] {
        let fields = "id,text,timestamp,username,from,like_count,hidden"
        var object = try await getJSON("\(mediaID)/comments", query: [
            "fields": "\(fields),replies{\(fields)}",
            "limit": "50",
        ])
        var comments: [IGGraphComment] = []
        var pages = 0
        while true {
            pages += 1
            for node in object["data"] as? [[String: Any]] ?? [] {
                guard let comment = Self.comment(from: node, parentID: nil) else { continue }
                comments.append(comment)
                for reply in ((node["replies"] as? [String: Any])?["data"] as? [[String: Any]]) ?? [] {
                    if let record = Self.comment(from: reply, parentID: comment.id) { comments.append(record) }
                }
            }
            guard pages < 10,
                  let next = (object["paging"] as? [String: Any])?["next"] as? String,
                  let url = URL(string: next) else { break }
            try Task.checkCancellation()
            object = try await getJSON(url: url, label: "\(mediaID)/comments (page \(pages + 1))")
        }
        return comments
    }

    private static func comment(from node: [String: Any], parentID: String?) -> IGGraphComment? {
        guard let id = node["id"] as? String else { return nil }
        let from = node["from"] as? [String: Any]
        return IGGraphComment(id: id, text: node["text"] as? String ?? "",
                              timestamp: parseTimestamp(node["timestamp"]),
                              username: node["username"] as? String ?? from?["username"] as? String,
                              fromID: from?["id"] as? String,
                              likeCount: node["like_count"] as? Int ?? 0,
                              hidden: node["hidden"] as? Bool ?? false,
                              parentID: parentID)
    }
}
