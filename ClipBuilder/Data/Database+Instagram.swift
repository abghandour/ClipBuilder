import Foundation

extension Database {
    // MARK: - Instagram

    @discardableResult
    func upsertIGAccount(username: String, kind: String, displayName: String?,
                         igUserID: String?, followers: Int?) throws -> Int64 {
        let rows = try connection.query("""
            INSERT INTO ig_accounts (username, kind, display_name, ig_user_id, followers)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(username) DO UPDATE SET
                kind=excluded.kind,
                display_name=COALESCE(excluded.display_name, ig_accounts.display_name),
                ig_user_id=COALESCE(excluded.ig_user_id, ig_accounts.ig_user_id),
                followers=COALESCE(excluded.followers, ig_accounts.followers)
            RETURNING id
            """, [.text(username), .text(kind),
                  displayName.map(SQLValue.text) ?? .null,
                  igUserID.map(SQLValue.text) ?? .null,
                  followers.map { SQLValue.integer(Int64($0)) } ?? .null])
        return rows.first?["id"]?.intValue ?? connection.lastInsertRowID
    }

    func fetchIGAccounts() throws -> [IGAccountRecord] {
        try connection.query("SELECT * FROM ig_accounts ORDER BY kind DESC, username COLLATE NOCASE").map {
            IGAccountRecord(id: $0["id"]?.intValue ?? 0,
                            username: $0["username"]?.stringValue ?? "",
                            kind: $0["kind"]?.stringValue ?? "public",
                            displayName: $0["display_name"]?.stringValue,
                            igUserID: $0["ig_user_id"]?.stringValue,
                            followers: $0["followers"]?.intValue.map(Int.init),
                            profilePicPath: $0["profile_pic_path"]?.stringValue,
                            lastFetchedAt: Self.parseSQLiteDate($0["last_fetched_at"]?.stringValue),
                            addedAt: $0["added_at"]?.stringValue)
        }
    }

    func deleteIGAccount(id: Int64) throws {
        try connection.execute("DELETE FROM ig_accounts WHERE id = ?", [.integer(id)])
    }

    func markIGAccountFetched(id: Int64) throws {
        try connection.execute("UPDATE ig_accounts SET last_fetched_at = datetime('now') WHERE id = ?",
                               [.integer(id)])
    }

    /// Upsert one fetched media item. Never clears cached local paths —
    /// refreshes update stats/caption, downloads happen separately.
    @discardableResult
    func upsertIGMedia(_ item: IGMediaUpsert) throws -> Int64 {
        let rows = try connection.query("""
            INSERT INTO ig_media (account_id, media_id, media_type, caption, permalink,
                                  posted_at, duration, stats_json, source, fetched_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
            ON CONFLICT(account_id, media_id) DO UPDATE SET
                media_type=excluded.media_type,
                caption=excluded.caption,
                permalink=COALESCE(excluded.permalink, ig_media.permalink),
                posted_at=COALESCE(excluded.posted_at, ig_media.posted_at),
                duration=CASE WHEN excluded.duration > 0 THEN excluded.duration ELSE ig_media.duration END,
                stats_json=excluded.stats_json,
                source=excluded.source,
                fetched_at=datetime('now')
            RETURNING id
            """, [.integer(item.accountID), .text(item.mediaID), .text(item.mediaType),
                  .text(item.caption),
                  item.permalink.map(SQLValue.text) ?? .null,
                  item.postedAt.map { .text(Self.sqliteDateString($0)) } ?? .null,
                  .real(item.duration), .text(item.statsJSON), .text(item.source)])
        return rows.first?["id"]?.intValue ?? connection.lastInsertRowID
    }

    func fetchIGMedia(accountID: Int64) throws -> [IGMediaRecord] {
        try connection.query("""
            SELECT * FROM ig_media WHERE account_id = ? ORDER BY posted_at DESC, id DESC
            """, [.integer(accountID)]).map {
            IGMediaRecord(id: $0["id"]?.intValue ?? 0,
                          accountID: $0["account_id"]?.intValue ?? 0,
                          mediaID: $0["media_id"]?.stringValue ?? "",
                          mediaType: $0["media_type"]?.stringValue ?? "reel",
                          caption: $0["caption"]?.stringValue ?? "",
                          permalink: $0["permalink"]?.stringValue,
                          postedAt: Self.parseSQLiteDate($0["posted_at"]?.stringValue),
                          duration: $0["duration"]?.doubleValue ?? 0,
                          thumbnailPath: $0["thumbnail_path"]?.stringValue,
                          localVideoPath: $0["local_video_path"]?.stringValue,
                          statsJSON: $0["stats_json"]?.stringValue ?? "{}",
                          source: $0["source"]?.stringValue ?? "ytdlp",
                          fetchedAt: $0["fetched_at"]?.stringValue)
        }
    }

    /// After a Graph refresh, drop rows for the same reels previously fetched
    /// via the web (same permalink, different media id) — except ones that
    /// already carry a template analysis.
    func pruneSupersededIGMedia(accountID: Int64) throws {
        try connection.execute("""
            DELETE FROM ig_media WHERE account_id = ?1 AND source != 'graph'
                AND id NOT IN (SELECT media_id FROM ig_templates)
                AND permalink IN (SELECT permalink FROM ig_media
                                  WHERE account_id = ?1 AND source = 'graph'
                                    AND permalink IS NOT NULL)
            """, [.integer(accountID)])
    }

    func setIGMediaLocalPaths(id: Int64, thumbnailPath: String?, localVideoPath: String?) throws {
        if let thumbnailPath {
            try connection.execute("UPDATE ig_media SET thumbnail_path = ? WHERE id = ?",
                                   [.text(thumbnailPath), .integer(id)])
        }
        if let localVideoPath {
            try connection.execute("UPDATE ig_media SET local_video_path = ? WHERE id = ?",
                                   [.text(localVideoPath), .integer(id)])
        }
    }

    func saveIGTemplate(mediaID: Int64, templateJSON: String, provider: String?, model: String?) throws {
        try connection.execute("""
            INSERT INTO ig_templates (media_id, template_json, provider, model, analyzed_at)
            VALUES (?, ?, ?, ?, datetime('now'))
            ON CONFLICT(media_id) DO UPDATE SET
                template_json=excluded.template_json,
                provider=excluded.provider,
                model=excluded.model,
                analyzed_at=datetime('now')
            """, [.integer(mediaID), .text(templateJSON),
                  provider.map(SQLValue.text) ?? .null,
                  model.map(SQLValue.text) ?? .null])
    }

    func fetchIGTemplate(mediaID: Int64) throws -> IGTemplateRecord? {
        try connection.query("SELECT * FROM ig_templates WHERE media_id = ?", [.integer(mediaID)]).first.map {
            IGTemplateRecord(id: $0["id"]?.intValue ?? 0,
                             mediaID: $0["media_id"]?.intValue ?? 0,
                             templateJSON: $0["template_json"]?.stringValue ?? "",
                             provider: $0["provider"]?.stringValue,
                             model: $0["model"]?.stringValue,
                             analyzedAt: $0["analyzed_at"]?.stringValue)
        }
    }

    /// IDs of media that already have a cached template analysis.
    func fetchIGTemplateMediaIDs(accountID: Int64) throws -> Set<Int64> {
        let rows = try connection.query("""
            SELECT t.media_id FROM ig_templates t
            JOIN ig_media m ON m.id = t.media_id WHERE m.account_id = ?
            """, [.integer(accountID)])
        return Set(rows.compactMap { $0["media_id"]?.intValue })
    }

    /// Write-through registry entry for a downloaded external video —
    /// honors imported_externals' contract shared with the Python app.
    func registerImportedExternal(platform: String, externalID: String, title: String?,
                                  pageURL: String?, localPath: String?) throws {
        try connection.execute("""
            INSERT OR REPLACE INTO imported_externals (platform, external_id, title, page_url, local_path)
            VALUES (?, ?, ?, ?, ?)
            """, [.text(platform), .text(externalID),
                  title.map(SQLValue.text) ?? .null,
                  pageURL.map(SQLValue.text) ?? .null,
                  localPath.map(SQLValue.text) ?? .null])
    }

    // MARK: - Instagram reports

    /// Live rows replace imported ones; imports never overwrite live data.
    private static func sourceWins(_ table: String) -> String {
        "(excluded.source = 'graph' OR \(table).source = 'import')"
    }

    static func iso(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    nonisolated static func parseISODate(_ string: String?) -> Date? {
        guard let string else { return nil }
        if let date = isoFormatter.date(from: string) { return date }
        if let date = graphDateFormatter.date(from: string) { return date }
        return parseSQLiteDate(string)
    }

    /// Graph timestamps use "+0000" without a colon.
    private nonisolated static let graphDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }()

    func upsertIGAccountSnapshots(accountID: Int64, _ snapshots: [IGAccountSnapshot]) throws {
        try connection.transaction {
            for snapshot in snapshots {
                try connection.execute("""
                    INSERT INTO ig_account_snapshots
                        (account_id, snapshot_date, followers_count, follows_count, media_count, source)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_id, snapshot_date) DO UPDATE SET
                        followers_count=COALESCE(excluded.followers_count, ig_account_snapshots.followers_count),
                        follows_count=COALESCE(excluded.follows_count, ig_account_snapshots.follows_count),
                        media_count=COALESCE(excluded.media_count, ig_account_snapshots.media_count),
                        source=excluded.source
                    WHERE \(Self.sourceWins("ig_account_snapshots"))
                    """, [.integer(accountID), .text(snapshot.date),
                          snapshot.followers.map { .integer(Int64($0)) } ?? .null,
                          snapshot.follows.map { .integer(Int64($0)) } ?? .null,
                          snapshot.mediaCount.map { .integer(Int64($0)) } ?? .null,
                          .text(snapshot.source)])
            }
        }
    }

    @discardableResult
    func upsertIGReportMedia(_ item: IGReportMediaUpsert) throws -> Int64 {
        let rows = try connection.query("""
            INSERT INTO ig_report_media
                (account_id, shortcode, media_id, media_type, media_product_type, caption, caption_truncated,
                 permalink, posted_at, like_count, comments_count, thumbnail_url, source, fetched_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
            ON CONFLICT(account_id, shortcode) DO UPDATE SET
                media_id=COALESCE(excluded.media_id, ig_report_media.media_id),
                media_type=COALESCE(excluded.media_type, ig_report_media.media_type),
                media_product_type=COALESCE(excluded.media_product_type, ig_report_media.media_product_type),
                caption=CASE WHEN excluded.caption_truncated = 0 OR ig_report_media.caption = ''
                             THEN excluded.caption ELSE ig_report_media.caption END,
                caption_truncated=CASE WHEN excluded.caption_truncated = 0 THEN 0
                                       ELSE ig_report_media.caption_truncated END,
                permalink=COALESCE(excluded.permalink, ig_report_media.permalink),
                posted_at=COALESCE(excluded.posted_at, ig_report_media.posted_at),
                like_count=COALESCE(excluded.like_count, ig_report_media.like_count),
                comments_count=COALESCE(excluded.comments_count, ig_report_media.comments_count),
                thumbnail_url=COALESCE(excluded.thumbnail_url, ig_report_media.thumbnail_url),
                source=CASE WHEN excluded.source = 'graph' THEN 'graph' ELSE ig_report_media.source END,
                fetched_at=datetime('now')
            RETURNING id
            """, [.integer(item.accountID), .text(item.shortcode),
                  item.mediaID.map(SQLValue.text) ?? .null,
                  item.mediaType.map(SQLValue.text) ?? .null,
                  item.productType.map(SQLValue.text) ?? .null,
                  .text(item.caption), .integer(item.captionTruncated ? 1 : 0),
                  item.permalink.map(SQLValue.text) ?? .null,
                  item.postedAt.map { .text(Self.sqliteDateString($0)) } ?? .null,
                  item.likeCount.map { .integer(Int64($0)) } ?? .null,
                  item.commentsCount.map { .integer(Int64($0)) } ?? .null,
                  item.thumbnailURL.map(SQLValue.text) ?? .null,
                  .text(item.source)])
        return rows.first?["id"]?.intValue ?? connection.lastInsertRowID
    }

    /// Upsert many post rows in one transaction, returning their ids in
    /// order — the sync's first pass writes 90 days of posts, and one
    /// commit per row meant one fsync per row.
    func upsertIGReportMediaBatch(_ items: [IGReportMediaUpsert]) throws -> [Int64] {
        try connection.transaction {
            try items.map { try upsertIGReportMedia($0) }
        }
    }

    func setIGReportMediaThumbnailPaths(_ paths: [(id: Int64, path: String)]) throws {
        try connection.transaction {
            for entry in paths {
                try connection.execute("UPDATE ig_report_media SET thumbnail_path = ? WHERE id = ?",
                                       [.text(entry.path), .integer(entry.id)])
            }
        }
    }

    func setIGReportMediaThumbnailPath(id: Int64, path: String) throws {
        try connection.execute("UPDATE ig_report_media SET thumbnail_path = ? WHERE id = ?",
                               [.text(path), .integer(id)])
    }

    /// shortcode → row id for the account (imports link by shortcode).
    func fetchIGReportMediaIDs(accountID: Int64) throws -> [String: Int64] {
        var map: [String: Int64] = [:]
        for row in try connection.query("SELECT id, shortcode FROM ig_report_media WHERE account_id = ?",
                                        [.integer(accountID)]) {
            if let shortcode = row["shortcode"]?.stringValue, let id = row["id"]?.intValue {
                map[shortcode] = id
            }
        }
        return map
    }

    /// Graph media id → row id (for the video-analysis sidecars).
    func fetchIGReportMediaGraphIDs(accountID: Int64) throws -> [String: Int64] {
        var map: [String: Int64] = [:]
        for row in try connection.query(
            "SELECT id, media_id FROM ig_report_media WHERE account_id = ? AND media_id IS NOT NULL",
            [.integer(accountID)]) {
            if let mediaID = row["media_id"]?.stringValue, let id = row["id"]?.intValue {
                map[mediaID] = id
            }
        }
        return map
    }

    /// Append insight snapshots. A value identical to the newest stored one
    /// for the same metric is skipped, so history stays compact.
    func insertIGMediaInsightSnapshots(_ snapshots: [IGMediaInsightSnapshot]) throws {
        guard !snapshots.isEmpty else { return }
        try connection.transaction {
            typealias SnapshotKey = String
            func key(reportMediaID: Int64, metric: String) -> SnapshotKey {
                "\(reportMediaID)\u{1F}\(metric)"
            }

            // Prefetch the latest values for the affected media in chunks so
            // a refresh does not issue one SELECT per metric snapshot.
            let reportMediaIDs = Array(Set(snapshots.map(\.reportMediaID)))
            var latestByKey: [SnapshotKey: (value: Double, fetchedAt: String)] = [:]
            for start in stride(from: 0, to: reportMediaIDs.count, by: 900) {
                let end = min(start + 900, reportMediaIDs.count)
                let ids = Array(reportMediaIDs[start..<end])
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
                let rows = try connection.query("""
                    SELECT s.report_media_id, s.metric, s.value, s.fetched_at
                    FROM ig_media_insight_snapshots s
                    JOIN (
                        SELECT report_media_id, metric, MAX(fetched_at) AS latest
                        FROM ig_media_insight_snapshots
                        WHERE report_media_id IN (\(placeholders))
                        GROUP BY report_media_id, metric
                    ) latest ON latest.report_media_id = s.report_media_id
                        AND latest.metric = s.metric AND latest.latest = s.fetched_at
                    """, ids.map(SQLValue.integer))
                for row in rows {
                    guard let reportMediaID = row["report_media_id"]?.intValue,
                          let metric = row["metric"]?.stringValue,
                          let value = row["value"]?.doubleValue,
                          let fetchedAt = row["fetched_at"]?.stringValue else { continue }
                    latestByKey[key(reportMediaID: reportMediaID, metric: metric)] = (value, fetchedAt)
                }
            }

            for snapshot in snapshots {
                let snapshotKey = key(reportMediaID: snapshot.reportMediaID, metric: snapshot.metric)
                if let latest = latestByKey[snapshotKey], latest.value == snapshot.value,
                   latest.fetchedAt <= snapshot.fetchedAt {
                    continue
                }
                try connection.execute("""
                    INSERT INTO ig_media_insight_snapshots (report_media_id, metric, value, fetched_at, source)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(report_media_id, metric, fetched_at) DO UPDATE SET
                        value=excluded.value, source=excluded.source
                    WHERE \(Self.sourceWins("ig_media_insight_snapshots"))
                    """, [.integer(snapshot.reportMediaID), .text(snapshot.metric), .real(snapshot.value),
                          .text(snapshot.fetchedAt), .text(snapshot.source)])
                if latestByKey[snapshotKey].map({ snapshot.fetchedAt > $0.fetchedAt }) ?? true {
                    latestByKey[snapshotKey] = (snapshot.value, snapshot.fetchedAt)
                }
            }
        }
    }

    func upsertIGAccountInsights(accountID: Int64, _ rows: [IGAccountInsightRow]) throws {
        try connection.transaction {
            for row in rows {
                try connection.execute("""
                    INSERT INTO ig_account_insights
                        (account_id, metric, period, breakdown_dimension, breakdown_value, value, end_time, source)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_id, metric, period, breakdown_dimension, breakdown_value, end_time)
                    DO UPDATE SET value=excluded.value, source=excluded.source
                    WHERE \(Self.sourceWins("ig_account_insights"))
                    """, [.integer(accountID), .text(row.metric), .text(row.period), .text(row.dimension),
                          .text(row.breakdown), .real(row.value), .text(row.endTime), .text(row.source)])
            }
        }
    }

    func upsertIGDemographics(accountID: Int64, _ rows: [IGDemographicRow]) throws {
        try connection.transaction {
            for row in rows {
                try connection.execute("""
                    INSERT INTO ig_audience_demographics
                        (account_id, metric, dimension, dimension_value, timeframe, value, fetched_date, source)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_id, metric, dimension, dimension_value, timeframe, fetched_date)
                    DO UPDATE SET value=excluded.value, source=excluded.source
                    WHERE \(Self.sourceWins("ig_audience_demographics"))
                    """, [.integer(accountID), .text(row.metric), .text(row.dimension), .text(row.value),
                          .text(row.timeframe), .integer(Int64(row.count)), .text(row.fetchedDate),
                          .text(row.source)])
            }
        }
    }

    func upsertIGComments(accountID: Int64, _ comments: [IGCommentRecord]) throws {
        try connection.transaction {
            for comment in comments {
                try connection.execute("""
                    INSERT INTO ig_comments
                        (id, account_id, report_media_id, parent_comment_id, username, text, like_count, hidden,
                         timestamp, ref_timestamp, fetched_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
                    ON CONFLICT(id) DO UPDATE SET
                        username=COALESCE(excluded.username, ig_comments.username),
                        text=excluded.text, like_count=excluded.like_count, hidden=excluded.hidden,
                        ref_timestamp=COALESCE(excluded.ref_timestamp, ig_comments.ref_timestamp),
                        fetched_at=datetime('now')
                    """, [.text(comment.id), .integer(accountID), .integer(comment.reportMediaID),
                          comment.parentCommentID.map(SQLValue.text) ?? .null,
                          comment.username.map(SQLValue.text) ?? .null,
                          .text(comment.text), .integer(Int64(comment.likeCount)),
                          .integer(comment.hidden ? 1 : 0), .text(Self.iso(comment.timestamp)),
                          comment.refTimestamp.map { .text(Self.iso($0)) } ?? .null])
            }
        }
    }

    func upsertIGCommenterRankingsImport(accountID: Int64, _ ranking: IGImportedRanking) throws {
        try connection.transaction {
            try connection.execute(
                "DELETE FROM ig_commenter_rankings_import WHERE account_id = ? AND period_key = ? AND as_of < ?",
                [.integer(accountID), .text(ranking.periodKey), .text(ranking.asOf)])
            for (index, row) in ranking.rows.enumerated() {
                try connection.execute("""
                    INSERT INTO ig_commenter_rankings_import
                        (account_id, period_key, as_of, username, rank, score, early, text_comments, emoji_comments,
                         text_replies, emoji_replies, total)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_id, period_key, username) DO UPDATE SET
                        as_of=excluded.as_of, rank=excluded.rank, score=excluded.score, early=excluded.early,
                        text_comments=excluded.text_comments, emoji_comments=excluded.emoji_comments,
                        text_replies=excluded.text_replies, emoji_replies=excluded.emoji_replies,
                        total=excluded.total
                    WHERE excluded.as_of >= ig_commenter_rankings_import.as_of
                    """, [.integer(accountID), .text(ranking.periodKey), .text(ranking.asOf),
                          .text(row.username), .integer(Int64(index + 1)), .integer(Int64(row.score)),
                          .integer(Int64(row.early)), .integer(Int64(row.textComments)),
                          .integer(Int64(row.emojiComments)), .integer(Int64(row.textReplies)),
                          .integer(Int64(row.emojiReplies)), .integer(Int64(row.total))])
            }
        }
    }

    func upsertIGCommenterActivityImport(accountID: Int64, _ activity: IGImportedActivity) throws {
        try connection.transaction {
            try connection.execute(
                "DELETE FROM ig_commenter_activity_import WHERE account_id = ? AND period_key = ? AND as_of < ?",
                [.integer(accountID), .text(activity.periodKey), .text(activity.asOf)])
            for row in activity.rows {
                let posts = (try? JSONSerialization.data(withJSONObject: row.topPosts))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                try connection.execute("""
                    INSERT INTO ig_commenter_activity_import
                        (account_id, period_key, as_of, username, comments, replies, total, top_posts_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_id, period_key, username) DO UPDATE SET
                        as_of=excluded.as_of, comments=excluded.comments, replies=excluded.replies,
                        total=excluded.total, top_posts_json=excluded.top_posts_json
                    WHERE excluded.as_of >= ig_commenter_activity_import.as_of
                    """, [.integer(accountID), .text(activity.periodKey), .text(activity.asOf),
                          .text(row.username), .integer(Int64(row.comments)), .integer(Int64(row.replies)),
                          .integer(Int64(row.total)), .text(posts)])
            }
        }
    }

    func upsertIGHeatmapImport(accountID: Int64, windowEnd: String, counts: [Int]) throws {
        guard counts.count == 168 else { return }
        try connection.transaction {
            for (index, count) in counts.enumerated() {
                try connection.execute("""
                    INSERT OR REPLACE INTO ig_comment_heatmap_import (account_id, window_end, dow, hour, count)
                    VALUES (?, ?, ?, ?, ?)
                    """, [.integer(accountID), .text(windowEnd), .integer(Int64(index / 24)),
                          .integer(Int64(index % 24)), .integer(Int64(count))])
            }
        }
    }

    func upsertIGReelAnalyses(accountID: Int64, _ rows: [IGReelAnalysisRow]) throws {
        func json(_ strings: [String]) -> String {
            (try? JSONSerialization.data(withJSONObject: strings))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        try connection.transaction {
            for row in rows {
                try connection.execute("""
                    INSERT OR REPLACE INTO ig_reel_analysis_import
                        (account_id, report_media_id, analysis_date, score, tier, good_json, bad_json, top_tip)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.integer(accountID), .integer(row.reportMediaID), .text(row.date),
                          .integer(Int64(row.score)), .text(row.tier), .text(json(row.good)),
                          .text(json(row.bad)), row.topTip.map(SQLValue.text) ?? .null])
            }
        }
    }

    func fetchIGIgnoredAccounts(accountID: Int64) throws -> [String] {
        try connection.query(
            "SELECT username FROM ig_ignored_accounts WHERE account_id = ? ORDER BY username COLLATE NOCASE",
            [.integer(accountID)]).compactMap { $0["username"]?.stringValue }
    }

    func addIGIgnoredAccount(accountID: Int64, username: String, reason: String?) throws {
        try connection.execute("""
            INSERT OR IGNORE INTO ig_ignored_accounts (account_id, username, reason) VALUES (?, ?, ?)
            """, [.integer(accountID), .text(username), reason.map(SQLValue.text) ?? .null])
    }

    func removeIGIgnoredAccount(accountID: Int64, username: String) throws {
        try connection.execute("DELETE FROM ig_ignored_accounts WHERE account_id = ? AND username = ?",
                               [.integer(accountID), .text(username)])
    }

    func igSyncState(accountID: Int64) throws -> [String: String] {
        var state: [String: String] = [:]
        for row in try connection.query("SELECT key, value FROM ig_report_sync_state WHERE account_id = ?",
                                        [.integer(accountID)]) {
            if let key = row["key"]?.stringValue, let value = row["value"]?.stringValue { state[key] = value }
        }
        return state
    }

    func setIGSyncState(accountID: Int64, key: String, value: String) throws {
        try connection.execute("""
            INSERT OR REPLACE INTO ig_report_sync_state (account_id, key, value) VALUES (?, ?, ?)
            """, [.integer(accountID), .text(key), .text(value)])
    }

    /// Media rows with insight snapshots, for the sync's "which posts still
    /// need insights" decision: id → newest fetched_at.
    func fetchIGReportMediaInsightDates(accountID: Int64) throws -> [Int64: String] {
        var map: [Int64: String] = [:]
        for row in try connection.query("""
            SELECT s.report_media_id AS id, MAX(s.fetched_at) AS latest
            FROM ig_media_insight_snapshots s JOIN ig_report_media m ON m.id = s.report_media_id
            WHERE m.account_id = ? AND s.source = 'graph' GROUP BY s.report_media_id
            """, [.integer(accountID)]) {
            if let id = row["id"]?.intValue, let latest = row["latest"]?.stringValue { map[id] = latest }
        }
        return map
    }

    /// Everything the report builder needs, in one round trip to the actor.
    func fetchIGReportInputs(account: IGAccountRecord) throws -> IGReportInputs {
        let accountID = account.id
        var inputs = IGReportInputs(account: account)

        inputs.snapshots = try connection.query(
            "SELECT * FROM ig_account_snapshots WHERE account_id = ? ORDER BY snapshot_date",
            [.integer(accountID)]).map {
            IGAccountSnapshot(date: $0["snapshot_date"]?.stringValue ?? "",
                              followers: $0["followers_count"]?.intValue.map(Int.init),
                              follows: $0["follows_count"]?.intValue.map(Int.init),
                              mediaCount: $0["media_count"]?.intValue.map(Int.init),
                              source: $0["source"]?.stringValue ?? "graph")
        }

        var metrics: [Int64: [String: Double]] = [:]
        for row in try connection.query("""
            SELECT s.report_media_id AS id, s.metric, s.value
            FROM ig_media_insight_snapshots s
            JOIN (SELECT snapshots.report_media_id AS report_media_id,
                         snapshots.metric AS metric,
                         MAX(snapshots.fetched_at) AS latest
                  FROM ig_media_insight_snapshots snapshots
                  JOIN ig_report_media report_media ON report_media.id = snapshots.report_media_id
                  WHERE report_media.account_id = ?1
                  GROUP BY snapshots.report_media_id, snapshots.metric) l
              ON l.report_media_id = s.report_media_id AND l.metric = s.metric AND l.latest = s.fetched_at
            JOIN ig_report_media m ON m.id = s.report_media_id
            WHERE m.account_id = ?1
            """, [.integer(accountID)]) {
            guard let id = row["id"]?.intValue, let metric = row["metric"]?.stringValue,
                  let value = row["value"]?.doubleValue else { continue }
            metrics[id, default: [:]][metric] = value
        }
        inputs.media = try connection.query(
            "SELECT * FROM ig_report_media WHERE account_id = ? ORDER BY posted_at DESC, id DESC",
            [.integer(accountID)]).map {
            let id = $0["id"]?.intValue ?? 0
            return IGReportMediaRow(id: id, accountID: accountID,
                                    mediaID: $0["media_id"]?.stringValue,
                                    shortcode: $0["shortcode"]?.stringValue ?? "",
                                    mediaType: $0["media_type"]?.stringValue,
                                    productType: $0["media_product_type"]?.stringValue,
                                    caption: $0["caption"]?.stringValue ?? "",
                                    captionTruncated: $0["caption_truncated"]?.boolValue ?? false,
                                    permalink: $0["permalink"]?.stringValue,
                                    postedAt: Self.parseSQLiteDate($0["posted_at"]?.stringValue),
                                    likeCount: $0["like_count"]?.intValue.map(Int.init),
                                    commentsCount: $0["comments_count"]?.intValue.map(Int.init),
                                    thumbnailURL: $0["thumbnail_url"]?.stringValue,
                                    thumbnailPath: $0["thumbnail_path"]?.stringValue,
                                    source: $0["source"]?.stringValue ?? "graph",
                                    metrics: metrics[id] ?? [:])
        }

        inputs.accountInsights = try connection.query(
            "SELECT * FROM ig_account_insights WHERE account_id = ? ORDER BY end_time",
            [.integer(accountID)]).map {
            IGAccountInsightRow(metric: $0["metric"]?.stringValue ?? "",
                                period: $0["period"]?.stringValue ?? "day",
                                dimension: $0["breakdown_dimension"]?.stringValue ?? "",
                                breakdown: $0["breakdown_value"]?.stringValue ?? "",
                                value: $0["value"]?.doubleValue ?? 0,
                                endTime: $0["end_time"]?.stringValue ?? "",
                                source: $0["source"]?.stringValue ?? "graph")
        }

        inputs.demographics = try connection.query("""
            SELECT d.* FROM ig_audience_demographics d
            JOIN (SELECT metric, dimension, timeframe, MAX(fetched_date) AS latest
                  FROM ig_audience_demographics WHERE account_id = ?1 GROUP BY metric, dimension, timeframe) l
              ON l.metric = d.metric AND l.dimension = d.dimension AND l.timeframe = d.timeframe
                 AND l.latest = d.fetched_date
            WHERE d.account_id = ?1 ORDER BY d.value DESC
            """, [.integer(accountID)]).map {
            IGDemographicRow(metric: $0["metric"]?.stringValue ?? "",
                             dimension: $0["dimension"]?.stringValue ?? "",
                             value: $0["dimension_value"]?.stringValue ?? "",
                             count: Int($0["value"]?.intValue ?? 0),
                             timeframe: $0["timeframe"]?.stringValue ?? "",
                             fetchedDate: $0["fetched_date"]?.stringValue ?? "",
                             source: $0["source"]?.stringValue ?? "graph")
        }

        inputs.comments = try connection.query(
            "SELECT * FROM ig_comments WHERE account_id = ? AND hidden = 0 ORDER BY timestamp",
            [.integer(accountID)]).compactMap {
            guard let timestamp = Self.parseISODate($0["timestamp"]?.stringValue) else { return nil }
            return IGCommentRecord(id: $0["id"]?.stringValue ?? "",
                                   reportMediaID: $0["report_media_id"]?.intValue ?? 0,
                                   parentCommentID: $0["parent_comment_id"]?.stringValue,
                                   username: $0["username"]?.stringValue,
                                   text: $0["text"]?.stringValue ?? "",
                                   likeCount: Int($0["like_count"]?.intValue ?? 0),
                                   hidden: $0["hidden"]?.boolValue ?? false,
                                   timestamp: timestamp,
                                   refTimestamp: Self.parseISODate($0["ref_timestamp"]?.stringValue))
        }

        var rankings: [String: IGImportedRanking] = [:]
        for row in try connection.query(
            "SELECT * FROM ig_commenter_rankings_import WHERE account_id = ? ORDER BY period_key, rank",
            [.integer(accountID)]) {
            let key = row["period_key"]?.stringValue ?? ""
            let entry = IGCommenterRankingRow(username: row["username"]?.stringValue ?? "",
                                              score: Int(row["score"]?.intValue ?? 0),
                                              early: Int(row["early"]?.intValue ?? 0),
                                              textComments: Int(row["text_comments"]?.intValue ?? 0),
                                              emojiComments: Int(row["emoji_comments"]?.intValue ?? 0),
                                              textReplies: Int(row["text_replies"]?.intValue ?? 0),
                                              emojiReplies: Int(row["emoji_replies"]?.intValue ?? 0))
            rankings[key, default: IGImportedRanking(periodKey: key, asOf: row["as_of"]?.stringValue ?? "",
                                                     rows: [])].rows.append(entry)
        }
        inputs.importedRankings = Array(rankings.values)

        var activity: [String: IGImportedActivity] = [:]
        for row in try connection.query(
            "SELECT * FROM ig_commenter_activity_import WHERE account_id = ? ORDER BY period_key, total DESC",
            [.integer(accountID)]) {
            let key = row["period_key"]?.stringValue ?? ""
            let posts = row["top_posts_json"]?.stringValue.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
            let entry = IGCommenterActivityRow(username: row["username"]?.stringValue ?? "",
                                               comments: Int(row["comments"]?.intValue ?? 0),
                                               replies: Int(row["replies"]?.intValue ?? 0),
                                               topPosts: posts)
            activity[key, default: IGImportedActivity(periodKey: key, asOf: row["as_of"]?.stringValue ?? "",
                                                      rows: [])].rows.append(entry)
        }
        inputs.importedActivity = Array(activity.values)

        for row in try connection.query(
            "SELECT window_end, dow, hour, count FROM ig_comment_heatmap_import WHERE account_id = ?",
            [.integer(accountID)]) {
            guard let end = row["window_end"]?.stringValue, let dow = row["dow"]?.intValue,
                  let hour = row["hour"]?.intValue, let count = row["count"]?.intValue else { continue }
            var grid = inputs.importedHeatmaps[end] ?? Array(repeating: 0, count: 168)
            let index = Int(dow) * 24 + Int(hour)
            if grid.indices.contains(index) { grid[index] = Int(count) }
            inputs.importedHeatmaps[end] = grid
        }

        inputs.reelAnalyses = try connection.query(
            "SELECT * FROM ig_reel_analysis_import WHERE account_id = ? ORDER BY analysis_date",
            [.integer(accountID)]).map {
            func strings(_ column: String) -> [String] {
                $0[column]?.stringValue.flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
            }
            return IGReelAnalysisRow(reportMediaID: $0["report_media_id"]?.intValue ?? 0,
                                     date: $0["analysis_date"]?.stringValue ?? "",
                                     score: Int($0["score"]?.intValue ?? 0),
                                     tier: $0["tier"]?.stringValue ?? "",
                                     good: strings("good_json"), bad: strings("bad_json"),
                                     topTip: $0["top_tip"]?.stringValue)
        }

        inputs.ignoredUsernames = Set(try fetchIGIgnoredAccounts(accountID: accountID).map { $0.lowercased() })
        inputs.syncState = try igSyncState(accountID: accountID)
        return inputs
    }
}
