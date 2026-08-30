import Foundation

/// Fetches everything the Reports tab needs beyond the reels grid, for the
/// Graph-connected account: today's account snapshot, every post of the
/// last 90 days, per-post insights, comments, daily account insights, the
/// follower series, and audience demographics. Each step commits on its
/// own and records a checkpoint, so Stop (cancellation) or a rate limit
/// leaves usable data and the next Refresh resumes where this one stopped.
nonisolated struct InstagramReportSync {
    static let mediaLookbackDays = 90
    static let insightsLookbackDays = 30
    static let commentsLookbackDays = 14
    static let accountInsightsLookbackDays = 30

    static let feedMetrics = ["reach", "views", "total_interactions", "shares", "saved", "likes", "comments",
                              "follows", "profile_activity", "profile_visits"]
    static let reelMetrics = ["reach", "views", "total_interactions", "shares", "saved", "likes", "comments",
                              "ig_reels_avg_watch_time", "ig_reels_video_view_total_time"]
    static let simpleMetrics = ["accounts_engaged", "replies", "reposts", "views", "reach", "total_interactions",
                                "likes", "comments", "shares", "saves", "profile_views", "website_clicks",
                                "profile_links_taps"]
    static let productTypeMetrics = ["total_interactions", "likes", "comments", "shares", "saves", "reach", "views"]
    static let followTypeMetrics = ["reach", "views", "follows_and_unfollows"]
    static let demographicDimensions = ["age", "city", "country", "gender"]

    let provider: GraphAPIProvider
    let username: String

    private static let calendar = ReportDates.calendar

    static func dayKey(_ date: Date) -> String { ReportDates.dayKey(date) }
    static func date(fromDayKey key: String) -> Date? { ReportDates.date(fromDayKey: key) }
    static func iso(_ date: Date) -> String { ReportDates.iso(date) }

    func run(accountID: Int64, igUserID: String, database: Database,
             log: @escaping @Sendable (String) -> Void) async throws {
        let now = Date()
        let state = try await database.igSyncState(accountID: accountID)
        if state["last_report_sync_at"] == nil {
            log("First report sync — fetching 90 days of posts and 30 days of account history")
        }

        // 1. Today's account snapshot.
        log("IGPROGRESS:0.12:Account snapshot")
        let details = try await provider.fetchAccountDetails(userID: igUserID)
        try await database.upsertIGAccountSnapshots(accountID: accountID, [
            IGAccountSnapshot(date: Self.dayKey(now), followers: details.followers, follows: details.follows,
                              mediaCount: details.mediaCount, source: "graph"),
        ])
        try Task.checkCancellation()

        // 2. Every post of the last 90 days.
        log("IGPROGRESS:0.16:Fetching 90 days of posts")
        let mediaSince = Self.calendar.date(byAdding: .day, value: -Self.mediaLookbackDays, to: now) ?? now
        let nodes = try await provider.fetchAllMedia(userID: igUserID, since: mediaSince, log: log)
        var rowsByID: [Int64: IGGraphMediaNode] = [:]
        let thumbsDirectory = SettingsStore.instagramCacheDirectory(username: username)
            .appendingPathComponent("thumbs")
        for node in nodes {
            guard let shortcode = node.shortcode else { continue }
            let rowID = try await database.upsertIGReportMedia(IGReportMediaUpsert(
                accountID: accountID, shortcode: shortcode, mediaID: node.id,
                mediaType: node.mediaType, productType: node.productType,
                caption: node.caption, captionTruncated: false, permalink: node.permalink,
                postedAt: node.timestamp, likeCount: node.likeCount, commentsCount: node.commentsCount,
                thumbnailURL: node.thumbnailURL ?? (node.mediaType == "IMAGE" ? node.mediaURL : nil),
                source: "graph"))
            rowsByID[rowID] = node
            // Reuse the grid's cached thumbnail when the reel is already there.
            let cached = thumbsDirectory.appendingPathComponent("\(node.id).jpg")
            if FileManager.default.fileExists(atPath: cached.path) {
                try await database.setIGReportMediaThumbnailPath(id: rowID, path: cached.path)
            }
        }
        try Task.checkCancellation()

        // 3. Per-post insights: recent posts every time, older ones once.
        let insightsSince = Self.calendar.date(byAdding: .day, value: -Self.insightsLookbackDays, to: now) ?? now
        let haveInsights = try await database.fetchIGReportMediaInsightDates(accountID: accountID)
        let targets = rowsByID.filter { rowID, node in
            node.productType != "STORY" && ((node.timestamp ?? now) >= insightsSince || haveInsights[rowID] == nil)
        }
        if !targets.isEmpty {
            log("IGPROGRESS:0.3:Post insights (\(targets.count) posts)")
            log("Fetching insights for \(targets.count) posts…")
            let fetchedAt = Self.iso(now)
            let results = try await BoundedConcurrency.map(Array(targets), limit: 4) { _, entry in
                try Task.checkCancellation()
                let (rowID, node) = entry
                let metrics = node.productType == "REELS" ? Self.reelMetrics : Self.feedMetrics
                do {
                    let values = try await provider.fetchMediaInsights(mediaID: node.id, metrics: metrics)
                    return values.map { IGMediaInsightSnapshot(reportMediaID: rowID, metric: $0.key, value: $0.value,
                                                               fetchedAt: fetchedAt, source: "graph") }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Older posts lack some metrics; keep the public counts.
                    return [
                        IGMediaInsightSnapshot(reportMediaID: rowID, metric: "likes",
                                               value: Double(node.likeCount ?? 0), fetchedAt: fetchedAt),
                        IGMediaInsightSnapshot(reportMediaID: rowID, metric: "comments",
                                               value: Double(node.commentsCount ?? 0), fetchedAt: fetchedAt),
                    ]
                }
            }
            try await database.insertIGMediaInsightSnapshots(results.flatMap { $0 })
        }
        try Task.checkCancellation()

        // 4. Comments (with replies) for new posts and the last two weeks.
        let commentsSyncedAt = state["comments_synced_at"].flatMap { Database.parseISODate($0) }
        let commentsSince = Self.calendar.date(byAdding: .day, value: -Self.commentsLookbackDays, to: now) ?? now
        let commentTargets = rowsByID.filter { _, node in
            guard node.productType != "STORY", let posted = node.timestamp else { return false }
            if let commentsSyncedAt { return posted >= commentsSince || posted > commentsSyncedAt }
            return true
        }
        if !commentTargets.isEmpty {
            log("IGPROGRESS:0.5:Comments (\(commentTargets.count) posts)")
            log("Fetching comments for \(commentTargets.count) posts…")
            let fetched = try await BoundedConcurrency.map(Array(commentTargets), limit: 3) { _, entry in
                try Task.checkCancellation()
                let (rowID, node) = entry
                do {
                    let comments = try await provider.fetchComments(mediaID: node.id)
                    let parents = Dictionary(comments.map { ($0.id, $0.timestamp) }, uniquingKeysWith: { a, _ in a })
                    return comments.compactMap { comment -> IGCommentRecord? in
                        guard let timestamp = comment.timestamp else { return nil }
                        let ref = comment.parentID.flatMap { parents[$0] ?? nil } ?? node.timestamp
                        return IGCommentRecord(id: comment.id, reportMediaID: rowID,
                                               parentCommentID: comment.parentID, username: comment.username,
                                               text: comment.text, likeCount: comment.likeCount,
                                               hidden: comment.hidden, timestamp: timestamp, refTimestamp: ref)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    log("Comments unavailable for \(node.shortcode ?? node.id): \(error)")
                    return []
                }
            }
            let records = fetched.flatMap { $0 }
            try await database.upsertIGComments(accountID: accountID, records)
            try await database.setIGSyncState(accountID: accountID, key: "comments_synced_at", value: Self.iso(now))
            log("Stored \(records.count) comments")
        }
        try Task.checkCancellation()

        // 5. Daily account insights, one UTC day at a time up to yesterday.
        let today = Self.date(fromDayKey: Self.dayKey(now)) ?? now
        let yesterday = Self.calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let floor = Self.calendar.date(byAdding: .day, value: -Self.accountInsightsLookbackDays, to: today) ?? today
        var day = state["account_insights_last_day"].flatMap(Self.date(fromDayKey:))
            .flatMap { Self.calendar.date(byAdding: .day, value: 1, to: $0) } ?? floor
        if day < floor { day = floor }
        let totalDays = max(1, (Self.calendar.dateComponents([.day], from: day, to: yesterday).day ?? 0) + 1)
        var days = 0
        while day <= yesterday {
            try Task.checkCancellation()
            log("IGPROGRESS:\(0.6 + 0.2 * Double(days) / Double(totalDays)):Account insights — \(Self.dayKey(day))")
            let next = Self.calendar.date(byAdding: .day, value: 1, to: day) ?? day
            let rows = try await fetchDailyInsights(userID: igUserID, since: day, until: next, log: log)
                .map { IGAccountInsightRow(metric: $0.metric, period: "day", dimension: $0.dimension,
                                           breakdown: $0.breakdown, value: $0.value,
                                           endTime: Self.iso(day), source: "graph") }
            try await database.upsertIGAccountInsights(accountID: accountID, rows)
            try await database.setIGSyncState(accountID: accountID, key: "account_insights_last_day",
                                              value: Self.dayKey(day))
            days += 1
            day = next
        }
        if days > 0 { log("Stored account insights for \(days) day\(days == 1 ? "" : "s")") }

        // 6. Follower series (the API keeps 30 days).
        log("IGPROGRESS:0.82:Follower series")
        let followerSince = Self.calendar.date(byAdding: .day, value: -30, to: now) ?? now
        do {
            let series = try await provider.fetchFollowerCountSeries(userID: igUserID, since: followerSince)
            try await database.upsertIGAccountInsights(accountID: accountID, series.map {
                IGAccountInsightRow(metric: "follower_count", period: "day", dimension: "", breakdown: "",
                                    value: $0.value, endTime: "\($0.date)T00:00:00Z", source: "graph")
            })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log("Follower series unavailable: \(error)")
        }
        try Task.checkCancellation()

        // 7. Rolling 28-day totals (Instagram de-duplicates reach across days).
        log("IGPROGRESS:0.86:Rolling 28-day totals")
        let since28 = Self.calendar.date(byAdding: .day, value: -28, to: now) ?? now
        let rolling = try await fetchDailyInsights(userID: igUserID, since: since28, until: now, log: log)
        try await database.upsertIGAccountInsights(accountID: accountID, rolling.map {
            IGAccountInsightRow(metric: $0.metric, period: "days_28", dimension: $0.dimension,
                                breakdown: $0.breakdown, value: $0.value, endTime: Self.iso(today), source: "graph")
        })
        try Task.checkCancellation()

        // 8. Demographics once per day.
        log("IGPROGRESS:0.92:Audience demographics")
        if state["demographics_date"] != Self.dayKey(now) {
            var rows: [IGDemographicRow] = []
            for (metric, timeframe) in [("follower_demographics", "last_30_days"),
                                        ("engaged_audience_demographics", "this_month")] {
                for dimension in Self.demographicDimensions {
                    try Task.checkCancellation()
                    do {
                        let values = try await provider.fetchDemographics(userID: igUserID, metric: metric,
                                                                          breakdown: dimension, timeframe: timeframe)
                        rows += values.map {
                            IGDemographicRow(metric: metric, dimension: dimension, value: $0.value, count: $0.count,
                                             timeframe: timeframe, fetchedDate: Self.dayKey(now), source: "graph")
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        log("\(metric)/\(dimension) unavailable: \(error)")
                    }
                }
            }
            if !rows.isEmpty {
                try await database.upsertIGDemographics(accountID: accountID, rows)
                try await database.setIGSyncState(accountID: accountID, key: "demographics_date",
                                                  value: Self.dayKey(now))
            }
        }

        try await database.setIGSyncState(accountID: accountID, key: "last_report_sync_at", value: Self.iso(now))
        try await database.setIGSyncState(accountID: accountID, key: "last_report_error", value: "")
        log("Report data updated")
    }

    /// The four batched account-insight calls for one window; a batch that
    /// Instagram rejects as a whole is retried metric by metric so one
    /// unsupported metric doesn't blank the day.
    private func fetchDailyInsights(userID: String, since: Date, until: Date,
                                    log: @escaping @Sendable (String) -> Void) async throws
        -> [IGGraphInsightValue] {
        var values: [IGGraphInsightValue] = []
        let batches: [(metrics: [String], breakdown: String?)] = [
            (Self.simpleMetrics, nil),
            (Self.productTypeMetrics, "media_product_type"),
            (Self.followTypeMetrics, "follow_type"),
            (["profile_links_taps"], "contact_button_type"),
        ]
        for batch in batches {
            do {
                values += try await provider.fetchAccountInsights(userID: userID, metrics: batch.metrics,
                                                                  since: since, until: until,
                                                                  breakdown: batch.breakdown)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard batch.metrics.count > 1 else {
                    log("\(batch.metrics[0]) unavailable: \(error)")
                    continue
                }
                for metric in batch.metrics {
                    do {
                        values += try await provider.fetchAccountInsights(userID: userID, metrics: [metric],
                                                                          since: since, until: until,
                                                                          breakdown: batch.breakdown)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        log("\(metric) unavailable: \(error)")
                    }
                }
            }
        }
        return values
    }
}
