import Foundation

/// Public-web Instagram access: one request to the web profile API returns
/// the account info plus its recent media with stats, thumbnails, captions,
/// and direct CDN video URLs — no subprocess, works anonymously for public
/// accounts. (yt-dlp's profile extractor is currently broken upstream, so
/// it serves only as the video-download fallback here, where its
/// --cookies-from-browser support shines.)
nonisolated struct InstagramWebProvider: InstagramProvider {
    let settings: InstagramSettings

    var sourceName: String { "web" }

    /// Instagram's public web-app id — required header for the JSON API.
    private static let appID = "936619743392459"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

    // MARK: - Requests

    /// Cookie header parsed from a Netscape cookies.txt when configured.
    /// Browser-keychain cookie sources only apply to the yt-dlp fallback —
    /// Safari/Chrome stores can't be read directly from here.
    private var cookieHeader: String? {
        guard settings.cookieSource == "file", !settings.cookieFilePath.isEmpty else { return nil }
        let path = (settings.cookieFilePath as NSString).expandingTildeInPath
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let pairs = content.split(separator: "\n").compactMap { line -> String? in
            guard !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 7, parts[0].hasSuffix("instagram.com") else { return nil }
            return "\(parts[5])=\(parts[6])"
        }
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(Self.appID, forHTTPHeaderField: "x-ig-app-id")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let cookieHeader {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        return request
    }

    private func profileJSON(username: String) async throws -> [String: Any] {
        guard let url = URL(string: "https://www.instagram.com/api/v1/users/web_profile_info/?username=\(username)") else {
            throw InstagramError.fetchFailed("Invalid username: \(username)")
        }
        let (data, response) = try await URLSession.shared.data(for: request(url))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status != 404 else {
            throw InstagramError.fetchFailed("@\(username) doesn't exist")
        }
        guard (200..<300).contains(status),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObject = root["data"] as? [String: Any],
              let user = dataObject["user"] as? [String: Any] else {
            throw InstagramError.fetchFailed(
                "Instagram blocked the request for @\(username) (HTTP \(status)). It may be a private account, or add a cookies.txt in Settings → Instagram and retry.")
        }
        return user
    }

    // MARK: - InstagramProvider

    func fetchProfile(username: String,
                      log: @escaping @Sendable (String) -> Void) async throws -> IGProfileInfo {
        let user = try await profileJSON(username: username)
        let followers = (user["edge_followed_by"] as? [String: Any])?["count"] as? Int
        return IGProfileInfo(username: username,
                             displayName: user["full_name"] as? String,
                             igUserID: user["id"] as? String,
                             followers: followers)
    }

    func fetchReels(username: String, limit: Int,
                    log: @escaping @Sendable (String) -> Void) async throws -> [IGMediaItem] {
        log("Fetching @\(username)...")
        let user = try await profileJSON(username: username)
        let timeline = user["edge_owner_to_timeline_media"] as? [String: Any]
        let edges = (timeline?["edges"] as? [[String: Any]]) ?? []
        let items = edges.compactMap { edge -> IGMediaItem? in
            guard let node = edge["node"] as? [String: Any],
                  node["is_video"] as? Bool == true,
                  let shortcode = node["shortcode"] as? String else { return nil }
            return Self.mediaItem(shortcode: shortcode, node: node)
        }
        guard !items.isEmpty else {
            throw InstagramError.fetchFailed(
                "No videos found for @\(username) — private account, no video posts, or Instagram limited the anonymous request (a cookies.txt in Settings → Instagram makes this reliable).")
        }
        log("Found \(items.count) videos/reels")
        return Array(items.prefix(limit))
    }

    private static func mediaItem(shortcode: String, node: [String: Any]) -> IGMediaItem {
        var item = IGMediaItem(mediaID: shortcode)
        item.mediaType = (node["product_type"] as? String) == "clips" ? "reel" : "video"
        if let captionEdges = (node["edge_media_to_caption"] as? [String: Any])?["edges"] as? [[String: Any]],
           let first = captionEdges.first?["node"] as? [String: Any] {
            item.caption = first["text"] as? String ?? ""
        }
        item.permalink = "https://www.instagram.com/reel/\(shortcode)/"
        if let timestamp = node["taken_at_timestamp"] as? Double {
            item.postedAt = Date(timeIntervalSince1970: timestamp)
        }
        item.duration = node["video_duration"] as? Double ?? 0
        item.stats = IGStats(views: node["video_view_count"] as? Int,
                             likes: ((node["edge_liked_by"] as? [String: Any])?["count"] as? Int)
                                 ?? ((node["edge_media_preview_like"] as? [String: Any])?["count"] as? Int),
                             comments: (node["edge_media_to_comment"] as? [String: Any])?["count"] as? Int)
        item.thumbnailRemoteURL = node["thumbnail_src"] as? String
        item.videoRemoteURL = node["video_url"] as? String
        return item
    }

    func downloadThumbnail(_ item: IGMediaItem, to destination: URL) async throws {
        guard let remote = item.thumbnailRemoteURL, let url = URL(string: remote) else {
            throw InstagramError.fetchFailed("Reel \(item.mediaID) has no thumbnail URL")
        }
        let (data, response) = try await URLSession.shared.data(for: request(url))
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

        // Direct CDN URL from the listing first — signed and short-lived,
        // but free when it works.
        if let remote = item.videoRemoteURL, let url = URL(string: remote) {
            log("Downloading reel \(item.mediaID)...")
            if let (temporary, response) = try? await URLSession.shared.download(for: request(url)),
               (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                log("Downloaded reel \(item.mediaID)")
                return
            }
            log("Direct download expired — falling back to yt-dlp")
        }

        try await downloadViaYtDlp(item, to: destination, log: log)
    }

    /// yt-dlp fallback: handles expired CDN URLs and login-walled posts, and
    /// is the only path that can use browser-keychain cookies.
    private func downloadViaYtDlp(_ item: IGMediaItem, to destination: URL,
                                  log: @escaping @Sendable (String) -> Void) async throws {
        guard let permalink = item.permalink else {
            throw InstagramError.fetchFailed("Reel \(item.mediaID) has no permalink")
        }
        guard let binary = ProcessRunner.locate("yt-dlp") else {
            throw InstagramError.toolMissing("yt-dlp")
        }
        var arguments = ["-f", "mp4/best", "--no-warnings", "-o", destination.path]
        switch settings.cookieSource {
        case "safari", "chrome", "firefox":
            arguments += ["--cookies-from-browser", settings.cookieSource]
        case "file" where !settings.cookieFilePath.isEmpty:
            arguments += ["--cookies", (settings.cookieFilePath as NSString).expandingTildeInPath]
        default:
            break
        }
        let result = try await ProcessRunner.run(executable: binary,
                                                 arguments: arguments + [permalink],
                                                 timeout: 300)
        guard result.exitCode == 0, FileManager.default.fileExists(atPath: destination.path) else {
            let tail = result.stderrText.split(separator: "\n").suffix(3).joined(separator: "\n")
            throw InstagramError.fetchFailed(
                "Video download failed: \(tail)\nTry setting browser cookies in Settings → Instagram.")
        }
        log("Downloaded reel \(item.mediaID) via yt-dlp")
    }
}
