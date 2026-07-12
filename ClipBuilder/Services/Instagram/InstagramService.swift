import Foundation

/// Orchestrates Instagram fetching and caching: picks a provider, refreshes
/// accounts into the per-profile DB, and manages the on-disk media cache.
/// Template analysis (Phase 2) builds on ensureDownloaded.
actor InstagramService {
    private let ai: AIService

    init(ai: AIService) {
        self.ai = ai
    }

    /// Auto-refresh throttle — the tab opens instantly from cache and only
    /// re-fetches stale accounts; manual Refresh bypasses this.
    static let autoRefreshInterval: TimeInterval = 6 * 3600

    /// Graph API once connected AND the username matches the connected
    /// account; everything else goes through the public web API.
    private func provider(for username: String, settings: InstagramSettings) -> any InstagramProvider {
        graphProvider(for: username, settings: settings) ?? InstagramWebProvider(settings: settings)
    }

    private func graphProvider(for username: String, settings: InstagramSettings) -> GraphAPIProvider? {
        guard settings.isGraphConnected,
              settings.connectedUsername.caseInsensitiveCompare(username) == .orderedSame,
              let token = KeychainStore.read(account: KeychainStore.graphTokenAccount) else {
            return nil
        }
        return GraphAPIProvider(token: token,
                                igUserID: settings.connectedIGUserID.isEmpty
                                    ? nil : settings.connectedIGUserID)
    }

    private func thumbnailDestination(username: String, mediaID: String) -> URL {
        SettingsStore.instagramCacheDirectory(username: username)
            .appendingPathComponent("thumbs/\(mediaID).jpg")
    }

    private func videoDestination(username: String, mediaID: String) -> URL {
        SettingsStore.instagramCacheDirectory(username: username)
            .appendingPathComponent("videos/\(mediaID).mp4")
    }

    /// Fetch reels + stats for an account, upsert rows, and download any
    /// missing thumbnails. Returns the refreshed account id. A failing Graph
    /// API connection (expired token, revoked permission) degrades to the
    /// public web API instead of breaking the refresh.
    @discardableResult
    func refreshAccount(username: String, kind: String, database: Database,
                        settings: InstagramSettings, limit: Int,
                        log: @escaping @Sendable (String) -> Void) async throws -> Int64 {
        let primary = provider(for: username, settings: settings)
        do {
            return try await refreshAccount(using: primary, username: username, kind: kind,
                                            database: database, limit: limit, log: log)
        } catch let error where primary is GraphAPIProvider && !(error is CancellationError) {
            log("Graph API failed (\(error)) — falling back to the public web API")
            return try await refreshAccount(using: InstagramWebProvider(settings: settings),
                                            username: username, kind: kind,
                                            database: database, limit: limit, log: log)
        }
    }

    private func refreshAccount(using provider: any InstagramProvider,
                                username: String, kind: String, database: Database,
                                limit: Int,
                                log: @escaping @Sendable (String) -> Void) async throws -> Int64 {
        let profile = try await provider.fetchProfile(username: username, log: log)
        let accountID = try await database.upsertIGAccount(username: username, kind: kind,
                                                           displayName: profile.displayName,
                                                           igUserID: profile.igUserID,
                                                           followers: profile.followers)

        let items = try await provider.fetchReels(username: username,
                                                  limit: max(1, min(limit, 24)), log: log)
        for item in items {
            var upsert = IGMediaUpsert(accountID: accountID, mediaID: item.mediaID)
            upsert.mediaType = item.mediaType
            upsert.caption = item.caption
            upsert.permalink = item.permalink
            upsert.postedAt = item.postedAt
            upsert.duration = item.duration ?? 0
            upsert.statsJSON = item.statsJSON
            upsert.source = provider.sourceName
            let rowID = try await database.upsertIGMedia(upsert)

            let thumbnail = thumbnailDestination(username: username, mediaID: item.mediaID)
            if !FileManager.default.fileExists(atPath: thumbnail.path) {
                do {
                    try await provider.downloadThumbnail(item, to: thumbnail)
                    try await database.setIGMediaLocalPaths(id: rowID, thumbnailPath: thumbnail.path,
                                                            localVideoPath: nil)
                } catch {
                    log("Thumbnail for \(item.mediaID) failed — will retry next refresh")
                }
            } else {
                try await database.setIGMediaLocalPaths(id: rowID, thumbnailPath: thumbnail.path,
                                                        localVideoPath: nil)
            }
            try Task.checkCancellation()
        }
        if provider.sourceName == "graph" {
            try await database.pruneSupersededIGMedia(accountID: accountID)
        }
        try await database.markIGAccountFetched(id: accountID)
        log("Fetched \(items.count) reels for @\(username)")
        return accountID
    }

    /// Download the reel video if missing; write-through to the
    /// imported_externals registry. Returns the local file URL.
    func ensureDownloaded(media: IGMediaRecord, account: IGAccountRecord, database: Database,
                          settings: InstagramSettings,
                          log: @escaping @Sendable (String) -> Void) async throws -> URL {
        if let existing = media.localVideoURL { return existing }
        let destination = videoDestination(username: account.username, mediaID: media.mediaID)

        if media.source == "graph" {
            // Graph rows carry graph media ids; the provider re-fetches a
            // fresh signed media_url. (Without a token, provider(for:) falls
            // back to the web path, which downloads via the permalink.)
            var item = IGMediaItem(mediaID: media.mediaID)
            item.permalink = media.permalink
            try await provider(for: account.username, settings: settings)
                .downloadVideo(item, to: destination, log: log)
        } else {
            // Web rows carry shortcodes the Graph API can't resolve directly.
            // For the connected account, match the shortcode by permalink on
            // the Graph API first (official, no cookies); otherwise — or if
            // that misses — use the web path (direct CDN, then yt-dlp).
            var downloaded = false
            if let graph = graphProvider(for: account.username, settings: settings) {
                do {
                    try await graph.downloadVideo(shortcode: media.mediaID,
                                                  to: destination, log: log)
                    downloaded = true
                } catch {
                    log("Graph API lookup failed (\(error.userMessage)) — trying the web download")
                }
            }
            if !downloaded {
                var item = IGMediaItem(mediaID: media.mediaID)
                item.permalink = media.permalink
                try await InstagramWebProvider(settings: settings)
                    .downloadVideo(item, to: destination, log: log)
            }
        }

        try await database.setIGMediaLocalPaths(id: media.id, thumbnailPath: nil,
                                                localVideoPath: destination.path)
        try await database.registerImportedExternal(platform: "instagram",
                                                    externalID: media.mediaID,
                                                    title: String(media.caption.prefix(120)),
                                                    pageURL: media.permalink,
                                                    localPath: destination.path)
        return destination
    }

    // MARK: - Template analysis (Phase 2)

    /// Analyze a reel into a ReelTemplate, cached in ig_templates: download →
    /// probe → objective cut detection → sampled frames → AI structural read.
    @discardableResult
    func analyzeTemplate(media: IGMediaRecord, account: IGAccountRecord, database: Database,
                         settings: InstagramSettings, force: Bool = false,
                         log: @escaping @Sendable (String) -> Void) async throws -> ReelTemplate {
        if !force, let cached = try await database.fetchIGTemplate(mediaID: media.id),
           let template = try? JSONDecoder().decode(ReelTemplate.self,
                                                    from: Data(cached.templateJSON.utf8)) {
            log("Using cached template analysis")
            return template
        }

        let video = try await ensureDownloaded(media: media, account: account,
                                               database: database, settings: settings, log: log)
        let info = await FFmpeg.info(of: video)
        let duration = info.duration > 0 ? info.duration : media.duration
        guard duration > 0 else {
            throw InstagramError.parseFailed("could not determine the reel's duration")
        }

        log("Detecting cuts...")
        let cuts = (try? await FFmpeg.sceneChangeTimestamps(of: video)) ?? []
        try Task.checkCancellation()

        log("Extracting frames...")
        let timestamps = Analyzer.frameTimestamps(duration: duration)
        let frames = ((try? await BoundedConcurrency.map(timestamps, limit: FFmpeg.jobLimit) { _, time in
            await ThumbnailService.jpegFrame(url: video, at: time).map {
                AIFrame(jpeg: $0, label: String(format: "%.1fs", time))
            }
        }) ?? []).compactMap { $0 }
        guard !frames.isEmpty else {
            throw InstagramError.parseFailed("no frames could be extracted from the reel")
        }
        try Task.checkCancellation()

        log("Analyzing structure (\(frames.count) frames, \(cuts.count) detected cuts)...")
        let prompt = Self.templatePrompt(media: media, duration: duration, cuts: cuts)
        let response = try await ai.call(prompt: prompt, task: "analysis", frames: frames,
                                         timeout: 300, log: log)
        guard let data = AIResponseParser.jsonData(from: response),
              var template = try? JSONDecoder().decode(ReelTemplate.self, from: data) else {
            throw InstagramError.parseFailed("the AI's template analysis was not valid JSON")
        }
        // The probe is authoritative for duration and cut count — the model
        // occasionally echoes rounded or hallucinated numbers.
        template.duration = duration.rounded(toPlaces: 1)
        if !cuts.isEmpty {
            template.cutCount = cuts.count
            template.cutsPerMinute = (Double(cuts.count) / duration * 60).rounded(toPlaces: 1)
        }

        let json = (try? JSONEncoder().encode(template))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? String(data: data, encoding: .utf8) ?? "{}"
        let attribution = await ai.resolveProviderModel(task: "analysis")
        try await database.saveIGTemplate(mediaID: media.id, templateJSON: json,
                                          provider: attribution.provider, model: attribution.model)
        log("Template analysis saved")
        return template
    }

    private static func templatePrompt(media: IGMediaRecord, duration: Double,
                                       cuts: [Double]) -> String {
        let stats = media.stats
        var statsLine = ""
        if let views = stats.views { statsLine += "\(views) views" }
        if let likes = stats.likes { statsLine += statsLine.isEmpty ? "\(likes) likes" : ", \(likes) likes" }
        if let comments = stats.comments { statsLine += statsLine.isEmpty ? "\(comments) comments" : ", \(comments) comments" }
        let cutsLine = cuts.isEmpty
            ? "No hard cuts were detected (single take, or soft transitions only)."
            : cuts.map { String(format: "%.2f", $0) }.joined(separator: ", ")
        return """
        You are a short-form video editor deconstructing a high-performing Instagram Reel so its STRUCTURE can be replicated with different footage.

        Reel facts (authoritative — do not contradict them):
        - Duration: \(String(format: "%.1f", duration))s
        - Performance: \(statsLine.isEmpty ? "unknown" : statsLine)
        - Caption: \(media.caption.isEmpty ? "(none)" : String(media.caption.prefix(400)))
        - Detected cut timestamps (ffmpeg scene detection): \(cutsLine)

        The frames above are sampled at their labeled timestamps. Combine them with the cut timestamps to reconstruct the reel's editing structure.

        Return a JSON object with EXACTLY this structure:
        {
          "duration": \(String(format: "%.1f", duration)),
          "hook": {"type": "<hook category, e.g. action-peak, question, reveal, text-promise>", "description": "<what happens in the first 1-3s and why it stops the scroll>"},
          "cut_count": \(cuts.count),
          "cuts_per_minute": <number>,
          "cut_rhythm": "<how cut lengths behave: steady / accelerating / beat-synced / long-short alternation, with rough shot lengths>",
          "pacing_curve": "<how energy evolves start to end, e.g. explosive open, breather at 40%, rising to climax>",
          "structure": [
            {"phase": "<name, e.g. hook>", "start": 0.0, "end": 2.5, "description": "<what this phase does>"}
          ],
          "visual_style": "<framing, camera movement, color/lighting, location variety>",
          "text_overlay_usage": "<how on-screen text is used, or 'none'>",
          "music_usage": "<how audio/music drives the edit, or what's audible>",
          "caption_style": "<how the written caption hooks engagement>",
          "why_it_works": "<2-3 sentences on the structural reasons this reel performs>"
        }

        RULES:
        - "structure" phases must tile 0.0 to \(String(format: "%.1f", duration)) in order without gaps
        - Align phase boundaries to detected cut timestamps where sensible
        - Describe STRUCTURE and TECHNIQUE, never the literal subject matter — the template will be applied to different footage
        - Return ONLY the JSON object, no markdown fences, no explanation
        """
    }
}
