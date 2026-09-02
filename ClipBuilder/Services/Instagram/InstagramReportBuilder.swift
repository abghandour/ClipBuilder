import Foundation

/// Turns the stored report rows into an `InstagramReport` for one period —
/// the same numbers the peace-grappler HTML reports compute (follower
/// deltas, likes+comments engagement, interaction rate, comment scoring,
/// hashtag stats, the weekly activity heatmap), with live and imported
/// data merged without double counting.
nonisolated enum InstagramReportBuilder {
    private static let calendar = ReportPeriod.utcCalendar
    private static let dayKey = ReportDates.dayKey
    private static let dayDate = ReportDates.date(fromDayKey:)

    static func build(_ inputs: IGReportInputs, period: ReportPeriod, now: Date = Date()) -> InstagramReport {
        var report = InstagramReport(period: period, periodLabel: period.label, generatedAt: now,
                                     lastRefreshed: inputs.syncState["last_report_sync_at"]
                                        .flatMap { Database.parseISODate($0) },
                                     importedThrough: inputs.syncState["import_as_of"])
        report.availableMonths = availableMonths(inputs, now: now)
        let media = inputs.media.filter { !$0.isStory }
        let inPeriod = media.filter { period.contains($0.postedAt, now: now) }

        report.overview = overview(inputs, media: media, inPeriod: inPeriod, period: period, now: now)
        report.posts = posts(inputs, media: media, inPeriod: inPeriod, period: period, now: now)
        report.community = community(inputs, media: media, period: period, now: now)
        report.audience = audience(inputs)
        return report
    }

    private static func availableMonths(_ inputs: IGReportInputs, now: Date) -> [ReportPeriod] {
        var keys = Set(inputs.snapshots.map { String($0.date.prefix(7)) })
        keys.formUnion(inputs.media.compactMap { $0.postedAt.map { String(dayKey($0).prefix(7)) } })
        keys.formUnion(inputs.importedRankings.map(\.periodKey).filter { $0.count == 7 })
        keys.formUnion(inputs.accountInsights.filter { $0.period == "month" }.map { String($0.endTime.prefix(7)) })
        keys.remove(String(dayKey(now).prefix(7)))   // "This Month" covers the current one
        return keys.sorted(by: >).compactMap { key in
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2 else { return nil }
            return .month(year: parts[0], month: parts[1])
        }
    }

    // MARK: - Overview

    private static func overview(_ inputs: IGReportInputs, media: [IGReportMediaRow], inPeriod: [IGReportMediaRow],
                                 period: ReportPeriod, now: Date) -> InstagramReport.Overview {
        var overview = InstagramReport.Overview()
        let snapshots = inputs.snapshots.filter { $0.followers != nil }
        let latest = snapshots.last
        let (since, until) = period.range(now: now)

        // Follower series and day-over-day gains (floored at 0, like the web).
        let chartSince = since.map { s in period == .last7 ? calendar.date(byAdding: .day, value: -30, to: now) ?? s : s }
        let windowed = snapshots.filter { snapshot in
            guard let date = dayDate(snapshot.date) else { return false }
            if let chartSince, date < calendar.date(byAdding: .day, value: -1, to: chartSince)! { return false }
            if let until, date >= until { return false }
            return true
        }
        overview.followerSeries = windowed.compactMap { snapshot in
            dayDate(snapshot.date).map { InstagramReport.DatedValue(date: $0, value: Double(snapshot.followers ?? 0)) }
        }
        let liveGains: [String: Double] = Dictionary(
            inputs.accountInsights.filter { $0.metric == "follower_count" && $0.period == "day" && $0.dimension.isEmpty }
                .map { ($0.endDate, $0.value) }, uniquingKeysWith: { _, b in b })
        var gains: [InstagramReport.DatedValue] = []
        for (index, snapshot) in windowed.enumerated() where index > 0 {
            guard let date = dayDate(snapshot.date) else { continue }
            if let chartSince, date < chartSince { continue }
            let diff = liveGains[snapshot.date]
                ?? Double(max(0, (snapshot.followers ?? 0) - (windowed[index - 1].followers ?? 0)))
            gains.append(InstagramReport.DatedValue(date: date, value: diff))
        }
        overview.newFollowersSeries = gains
        overview.newFollowersTotal = Int(gains.reduce(0) { $0 + $1.value })

        // Growth cards.
        func followers(onOrBefore date: Date) -> Int? {
            snapshots.last { dayDate($0.date).map { $0 <= date } ?? false }?.followers
        }
        let anchor: IGAccountSnapshot? = until.flatMap { end in
            snapshots.last { dayDate($0.date).map { $0 < end } ?? false }
        } ?? latest
        if let anchor, let anchorDate = dayDate(anchor.date), let current = anchor.followers {
            func delta(days: Int) -> Int? {
                calendar.date(byAdding: .day, value: -days, to: anchorDate).flatMap(followers(onOrBefore:))
                    .map { current - $0 }
            }
            var cards = [InstagramReport.GrowthCard(label: "Yesterday", delta: delta(days: 1)),
                         InstagramReport.GrowthCard(label: "Last 7 Days", delta: delta(days: 7))]
            if let monthKey = period.monthKey(now: now), let monthStart = dayDate(monthKey + "-01") {
                let before = calendar.date(byAdding: .day, value: -1, to: monthStart).flatMap(followers(onOrBefore:))
                    ?? snapshots.first { dayDate($0.date).map { $0 >= monthStart } ?? false }?.followers
                cards.append(InstagramReport.GrowthCard(label: "Month Total", delta: before.map { current - $0 }))
            } else {
                cards.append(InstagramReport.GrowthCard(label: "Last 30 Days", delta: delta(days: 30)))
            }
            overview.followerGrowth = cards
        }

        // Content published.
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let week = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        func published(_ label: String, _ rows: [IGReportMediaRow]) -> InstagramReport.PublishedRow {
            InstagramReport.PublishedRow(label: label, total: rows.count, reels: rows.filter(\.isReel).count,
                                         feed: rows.filter { !$0.isReel && !$0.isCarousel }.count,
                                         carousels: rows.filter(\.isCarousel).count)
        }
        if period.isRolling || period == .allTime || period == .monthToDate {
            overview.contentPublished = [
                published("Yesterday", media.filter { ($0.postedAt ?? .distantPast) >= yesterday }),
                published("Last 7 Days", media.filter { ($0.postedAt ?? .distantPast) >= week }),
                published(period == .last7 ? "Last 30 Days" : period.label,
                          period == .last7 ? media.filter { ReportPeriod.last30.contains($0.postedAt, now: now) } : inPeriod),
            ]
        } else {
            overview.contentPublished = [published(period.label, inPeriod)]
        }

        // Engagement analytics windows.
        func engagement(_ label: String, _ rows: [IGReportMediaRow]) -> InstagramReport.EngagementWindow {
            InstagramReport.EngagementWindow(label: label, posts: rows.count,
                                             likes: rows.reduce(0) { $0 + ($1.likes ?? 0) },
                                             comments: rows.reduce(0) { $0 + ($1.comments ?? 0) },
                                             shares: rows.reduce(0) { $0 + ($1.shares ?? 0) },
                                             saves: rows.reduce(0) { $0 + ($1.saves ?? 0) },
                                             reach: rows.reduce(0) { $0 + ($1.reach ?? 0) },
                                             views: rows.reduce(0) { $0 + ($1.views ?? 0) })
        }
        switch period {
        case .last7, .last30:
            overview.engagement = [engagement("Last 7 Days", media.filter { ReportPeriod.last7.contains($0.postedAt, now: now) }),
                                   engagement("Last 30 Days", media.filter { ReportPeriod.last30.contains($0.postedAt, now: now) })]
        case .allTime:
            overview.engagement = [engagement("Last 30 Days", media.filter { ReportPeriod.last30.contains($0.postedAt, now: now) }),
                                   engagement("All Time", media)]
        default:
            overview.engagement = [engagement(period.label, inPeriod)]
        }

        // Account-level insights.
        let insights = accountInsights(inputs.accountInsights, period: period, now: now)
        overview.accountInsightsNote = insights.note
        let order = ["accounts_engaged", "reach", "views", "total_interactions", "likes", "comments", "shares",
                     "saves", "replies", "reposts", "profile_views", "profile_links_taps", "website_clicks",
                     "follows_and_unfollows"]
        for metric in order {
            guard let total = insights.total(metric) else { continue }
            let chips = insights.breakdown(metric).map {
                InstagramReport.LabeledValue(label: $0.label.replacingOccurrences(of: "_", with: " ").capitalized,
                                             value: $0.value)
            }
            overview.accountInsights.append(InstagramReport.Stat(
                label: metric.replacingOccurrences(of: "_", with: " ").capitalized,
                value: Int(total.rounded()).formatted(), breakdown: chips))
        }
        if let reach = insights.total("reach"), reach > 0, let interactions = insights.total("total_interactions") {
            overview.interactionRate = interactions / reach * 100
        }
        func byType(_ metric: String) -> [InstagramReport.LabeledValue] {
            var map: [String: Double] = [:]
            for slice in insights.breakdown(metric, dimension: "media_product_type") {
                let label: String
                switch slice.label {
                case "AD": label = "Ad"
                case "REEL": label = "Reel"
                case "STORY": label = "Story"
                case "POST", "CAROUSEL_CONTAINER": label = "Feed"
                default: continue
                }
                map[label, default: 0] += slice.value
            }
            return ["Ad", "Feed", "Reel", "Story"].compactMap { key in
                map[key].map { InstagramReport.LabeledValue(label: key, value: $0) }
            }
        }
        func byFollow(_ metric: String) -> [InstagramReport.LabeledValue] {
            insights.breakdown(metric, dimension: "follow_type").map {
                InstagramReport.LabeledValue(label: $0.label == "FOLLOWER" ? "Follower" : "Non-follower", value: $0.value)
            }
        }
        overview.reachByType = byType("reach")
        overview.viewsByType = byType("views")
        overview.interactionsByType = byType("total_interactions")
        overview.reachByFollow = byFollow("reach")
        overview.viewsByFollow = byFollow("views")
        overview.linkTaps = insights.breakdown("profile_links_taps", dimension: "contact_button_type").map {
            InstagramReport.LabeledValue(label: $0.label.replacingOccurrences(of: "_", with: " ").capitalized,
                                         value: $0.value)
        }

        // KPI header.
        let followersNow = latest?.followers ?? inputs.account.followers
        let totalReach = inPeriod.reduce(0) { $0 + ($1.reach ?? 0) }
        let totalViews = inPeriod.reduce(0) { $0 + ($1.views ?? 0) }
        let totalInteractions = inPeriod.reduce(0) { $0 + ($1.totalInteractions ?? 0) }
        var kpis: [InstagramReport.Stat] = []
        if let followersNow {
            let growth = overview.followerGrowth.first { $0.label == "Yesterday" }?.delta
            kpis.append(InstagramReport.Stat(label: "Followers", value: followersNow.formatted(),
                                             delta: growth.map { InstagramReport.Delta(amount: Double($0), suffix: " today") }))
        }
        if let follows = latest?.follows { kpis.append(.init(label: "Following", value: follows.formatted())) }
        if let count = latest?.mediaCount { kpis.append(.init(label: "Posts", value: count.formatted())) }
        kpis.append(.init(label: "Total Reach", value: totalReach.formatted(), note: period.label))
        kpis.append(.init(label: "Total Views", value: totalViews.formatted(), note: period.label))
        kpis.append(.init(label: "Total Interactions", value: totalInteractions.formatted(), note: period.label))
        kpis.append(.init(label: "Avg Reach / Post",
                          value: inPeriod.isEmpty ? "–" : (totalReach / inPeriod.count).formatted(), note: period.label))
        kpis.append(.init(label: "Total Comments",
                          value: inPeriod.reduce(0) { $0 + ($1.comments ?? 0) }.formatted(), note: period.label))
        overview.kpis = kpis

        // Content overview.
        var mix: [String: Double] = [:]
        for row in inPeriod { mix[row.typeLabel, default: 0] += 1 }
        overview.contentMix = mix.sorted { $0.value > $1.value }.map { InstagramReport.LabeledValue(label: $0.key, value: $0.value) }
        overview.reachPerPost = inPeriod.compactMap { row in
            guard let reach = row.reach, let date = row.postedAt else { return nil }
            return InstagramReport.ReachBar(id: row.id, date: date, reach: reach, type: row.typeLabel)
        }.sorted { $0.date < $1.date }
        return overview
    }

    /// Account insight totals for a period, preferring daily rows and
    /// falling back to Instagram's own window totals (rolling 28-day,
    /// calendar month, or the imported 30-day window) when the daily
    /// history doesn't cover it.
    struct ResolvedInsights {
        var totals: [String: Double] = [:]                              // metric → total
        var slices: [String: [String: [String: Double]]] = [:]          // metric → dimension → label → value
        var note: String?

        func total(_ metric: String) -> Double? {
            if let total = totals[metric] { return total }
            // Imported window rows carry breakdowns only.
            if let byType = slices[metric]?["media_product_type"], !byType.isEmpty {
                return byType.values.reduce(0, +)
            }
            if let byFollow = slices[metric]?["follow_type"], !byFollow.isEmpty {
                return byFollow.values.reduce(0, +)
            }
            return nil
        }

        func breakdown(_ metric: String, dimension: String? = nil) -> [(label: String, value: Double)] {
            let dimensions = slices[metric] ?? [:]
            let keys = dimension.map { [$0] } ?? dimensions.keys.sorted()
            return keys.flatMap { key in
                (dimensions[key] ?? [:]).sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
            }
        }
    }

    static func accountInsights(_ rows: [IGAccountInsightRow], period: ReportPeriod, now: Date) -> ResolvedInsights {
        var resolved = ResolvedInsights()
        let (since, until) = period.range(now: now)
        func add(_ row: IGAccountInsightRow) {
            if row.dimension.isEmpty {
                resolved.totals[row.metric, default: 0] += row.value
            } else {
                resolved.slices[row.metric, default: [:]][row.dimension, default: [:]][row.breakdown, default: 0] += row.value
            }
        }
        func set(_ rows: [IGAccountInsightRow]) {
            resolved.totals = [:]; resolved.slices = [:]
            rows.forEach(add)
        }

        let daily = rows.filter { row in
            guard row.period == "day", row.metric != "follower_count", let date = dayDate(row.endDate) else { return false }
            if let since, date < since { return false }
            if let until, date >= until { return false }
            return true
        }
        let coveredDays = Set(daily.map(\.endDate)).count
        let periodDays: Int = {
            let start = since ?? dayDate(rows.map(\.endDate).min() ?? dayKey(now)) ?? now
            let end = min(until ?? now, now)
            return max(1, calendar.dateComponents([.day], from: start, to: end).day ?? 1)
        }()

        if coveredDays >= min(periodDays, 14) || (period == .last7 && coveredDays >= 5) {
            set(daily)
            resolved.note = "Daily totals for \(coveredDays) day\(coveredDays == 1 ? "" : "s")"
            return resolved
        }
        if let monthKey = period.monthKey(now: now) {
            let month = rows.filter { $0.period == "month" && $0.endTime.hasPrefix(monthKey) }
            if !month.isEmpty {
                set(month)
                resolved.note = "Month totals imported from the \(period.label) report"
                return resolved
            }
        }
        if period.isRolling || period == .allTime || period == .monthToDate {
            let rolling = rows.filter { $0.period == "days_28" }
            if let newest = rolling.map(\.endDate).max() {
                set(rolling.filter { $0.endDate == newest })
                resolved.note = "Rolling 28-day totals as of \(newest)"
                return resolved
            }
            let window = rows.filter { $0.period == "window_30d" }
            if let newest = window.map(\.endDate).max() {
                set(window.filter { $0.endDate == newest })
                resolved.note = "30-day window ending \(newest) (imported)"
                return resolved
            }
        } else if let until {
            // A past month without a monthly report: the imported window
            // that ended closest after the month.
            let window = rows.filter { $0.period == "window_30d" }
            let candidates = window.compactMap { row in dayDate(row.endDate).map { ($0, row.endDate) } }
                .filter { $0.0 < calendar.date(byAdding: .day, value: 3, to: until)! }
            if let newest = candidates.map(\.1).max() {
                set(window.filter { $0.endDate == newest })
                resolved.note = "30-day window ending \(newest) (imported)"
                return resolved
            }
        }
        if !daily.isEmpty {
            set(daily)
            resolved.note = "Daily totals for \(coveredDays) of \(periodDays) days"
        }
        return resolved
    }

    // MARK: - Posts

    private static func posts(_ inputs: IGReportInputs, media: [IGReportMediaRow], inPeriod: [IGReportMediaRow],
                              period: ReportPeriod, now: Date) -> InstagramReport.PostPerformance {
        var posts = InstagramReport.PostPerformance()
        let sorted = inPeriod.sorted { ($0.postedAt ?? .distantPast) > ($1.postedAt ?? .distantPast) }
        posts.rows = sorted.enumerated().map { InstagramReport.PostRow(media: $1, rank: $0 + 1) }
        func ranked(_ rows: [IGReportMediaRow]) -> [InstagramReport.PostRow] {
            rows.prefix(10).enumerated().map { InstagramReport.PostRow(media: $1, rank: $0 + 1) }
        }
        posts.topByEngagement = ranked(inPeriod.sorted { $0.engagement > $1.engagement })
        posts.topLiked = ranked(inPeriod.sorted { ($0.likes ?? 0) > ($1.likes ?? 0) })
        posts.topDiscussed = ranked(inPeriod.sorted { ($0.comments ?? 0) > ($1.comments ?? 0) })
        posts.topShared = ranked(inPeriod.filter { ($0.shares ?? 0) > 0 }.sorted { ($0.shares ?? 0) > ($1.shares ?? 0) })

        // Hashtags: counted once per post.
        var tags: [String: (display: String, count: Int, reach: Int, interactions: Int)] = [:]
        for row in inPeriod {
            var seen: Set<String> = []
            for match in ReportHTML.matches(#"(#[A-Za-z0-9_]+)"#, in: row.caption) {
                let key = match[0].lowercased()
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                var entry = tags[key] ?? (match[0], 0, 0, 0)
                entry.count += 1
                entry.reach += row.reach ?? 0
                entry.interactions += row.totalInteractions ?? 0
                tags[key] = entry
            }
        }
        posts.hashtags = tags.values
            .map { InstagramReport.HashtagStat(tag: $0.display, count: $0.count,
                                               avgReach: $0.reach / max(1, $0.count),
                                               avgInteractions: $0.interactions / max(1, $0.count)) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.avgReach > $1.avgReach }
            .prefix(15).map { $0 }

        // Posts vs reels summaries with deltas against the preceding window.
        let (since, until) = period.range(now: now)
        var previous: [IGReportMediaRow] = []
        if let since {
            let end = until ?? now
            let length = end.timeIntervalSince(since)
            let previousStart = since.addingTimeInterval(-length)
            previous = media.filter { row in
                guard let date = row.postedAt else { return false }
                return date >= previousStart && date < since
            }
        }
        func summary(_ name: String, _ rows: [IGReportMediaRow], _ prior: [IGReportMediaRow]) -> [InstagramReport.Stat] {
            func sum(_ rows: [IGReportMediaRow], _ key: (IGReportMediaRow) -> Int?) -> Int {
                rows.reduce(0) { $0 + (key($1) ?? 0) }
            }
            func stat(_ label: String, _ current: Int, _ before: Int?) -> InstagramReport.Stat {
                var delta: InstagramReport.Delta?
                if let before, since != nil {
                    let percent: Double? = before > 0 ? Double(current - before) / Double(before) * 100 : nil
                    delta = InstagramReport.Delta(amount: Double(current - before), percent: percent,
                                                  suffix: " vs previous period")
                }
                return InstagramReport.Stat(label: label, value: current.formatted(), delta: delta)
            }
            let reach = sum(rows, \.reach), interactions = sum(rows, \.totalInteractions)
            var stats = [
                stat("\(name) Published", rows.count, prior.count),
                stat("\(name) Reach", reach, sum(prior, \.reach)),
                stat("\(name) Views", sum(rows, \.views), sum(prior, \.views)),
                stat("\(name) Interactions", interactions, sum(prior, \.totalInteractions)),
                stat("\(name) Likes", sum(rows, \.likes), sum(prior, \.likes)),
                stat("\(name) Comments", sum(rows, \.comments), sum(prior, \.comments)),
                stat("\(name) Saves", sum(rows, \.saves), sum(prior, \.saves)),
                stat("\(name) Shares", sum(rows, \.shares), sum(prior, \.shares)),
            ]
            let rate = reach > 0 ? Double(interactions) / Double(reach) * 100 : 0
            stats.append(InstagramReport.Stat(label: "\(name) Interaction Rate", value: String(format: "%.2f%%", rate)))
            return stats
        }
        posts.postsSummary = summary("Post", inPeriod.filter { !$0.isReel }, previous.filter { !$0.isReel })
        posts.reelsSummary = summary("Reels", inPeriod.filter(\.isReel), previous.filter(\.isReel))

        func daily(_ rows: [IGReportMediaRow]) -> [InstagramReport.DailyPoint] {
            var points: [String: InstagramReport.DailyPoint] = [:]
            for row in rows {
                guard let date = row.postedAt, let day = dayDate(dayKey(date)) else { continue }
                var point = points[dayKey(date)] ?? InstagramReport.DailyPoint(date: day)
                point.reach += row.reach ?? 0; point.views += row.views ?? 0
                point.likes += row.likes ?? 0; point.comments += row.comments ?? 0
                point.saves += row.saves ?? 0; point.shares += row.shares ?? 0
                points[dayKey(date)] = point
            }
            return points.values.sorted { $0.date < $1.date }
        }
        posts.postsDaily = daily(inPeriod.filter { !$0.isReel })
        posts.reelsDaily = daily(inPeriod.filter(\.isReel))

        // Imported daily reel analyses: the latest review per reel.
        var latestAnalysis: [Int64: IGReelAnalysisRow] = [:]
        for row in inputs.reelAnalyses { latestAnalysis[row.reportMediaID] = row }   // date-ascending input
        let inPeriodByID = Dictionary(inPeriod.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        posts.reelAnalyses = latestAnalysis.values
            .compactMap { row -> InstagramReport.ReelAnalysis? in
                guard let media = inPeriodByID[row.reportMediaID] else { return nil }
                return InstagramReport.ReelAnalysis(media: media, date: row.date, score: row.score,
                                                    tier: row.tier, good: row.good, bad: row.bad,
                                                    topTip: row.topTip)
            }
            .sorted { ($0.media.postedAt ?? .distantPast) > ($1.media.postedAt ?? .distantPast) }
            .prefix(12).map { $0 }

        // Algorithm status: the 5 newest posts against the 5 before them.
        let newest = media.sorted { ($0.postedAt ?? .distantPast) > ($1.postedAt ?? .distantPast) }
        if newest.count >= 10 {
            let recent = newest.prefix(5).reduce(0) { $0 + ($1.views ?? 0) }
            let older = newest.dropFirst(5).prefix(5).reduce(0) { $0 + ($1.views ?? 0) }
            let verdict = Double(recent) > Double(older) * 1.3 ? "HIGH"
                : Double(recent) < Double(older) * 0.7 ? "LOW" : "STABLE"
            let detail = verdict == "HIGH" ? "Recent posts trending up"
                : verdict == "LOW" ? "Recent posts underperforming" : "Recent posts holding steady"
            posts.algorithmStatus = InstagramReport.AlgorithmStatus(verdict: verdict, detail: detail,
                                                                    recentViews: recent, previousViews: older)
        }
        return posts
    }

    // MARK: - Community

    /// Text comment 5 · text reply 7 · emoji-only comment 1 · emoji-only
    /// reply 2 · ×2 within 30 minutes of the post (or parent comment).
    static func score(_ comment: IGCommentRecord) -> Int {
        let emoji = isEmojiOnly(comment.text)
        let base = comment.isReply ? (emoji ? 2 : 7) : (emoji ? 1 : 5)
        return isEarly(comment) ? base * 2 : base
    }

    static func isEarly(_ comment: IGCommentRecord) -> Bool {
        guard let ref = comment.refTimestamp else { return false }
        let delta = comment.timestamp.timeIntervalSince(ref)
        return delta >= 0 && delta <= 30 * 60
    }

    /// Mirrors the report's `\p{Emoji}`-based test — empty text counts as
    /// emoji-only, and (like the Unicode property) digits, # and * do too.
    static func isEmojiOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            let properties = scalar.properties
            return properties.isEmoji || properties.isEmojiPresentation || properties.isEmojiModifier
                || properties.isEmojiModifierBase || scalar == "\u{200D}" || scalar == "\u{FE0F}"
                || (0x1F3FB...0x1F3FF).contains(scalar.value) || properties.isWhitespace
        }
    }

    static func rankings(_ comments: [IGCommentRecord]) -> [IGCommenterRankingRow] {
        var rows: [String: IGCommenterRankingRow] = [:]
        for comment in comments {
            guard let username = comment.username, !username.isEmpty else { continue }
            let key = username.lowercased()
            var row = rows[key] ?? IGCommenterRankingRow(username: username, score: 0, early: 0, textComments: 0,
                                                         emojiComments: 0, textReplies: 0, emojiReplies: 0)
            row.score += score(comment)
            if isEarly(comment) { row.early += 1 }
            switch (comment.isReply, isEmojiOnly(comment.text)) {
            case (false, false): row.textComments += 1
            case (false, true): row.emojiComments += 1
            case (true, false): row.textReplies += 1
            case (true, true): row.emojiReplies += 1
            }
            rows[key] = row
        }
        return rows.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.username < $1.username }
    }

    static func activity(_ comments: [IGCommentRecord], captions: [Int64: String]) -> [IGCommenterActivityRow] {
        var rows: [String: (row: IGCommenterActivityRow, posts: [Int64: Int])] = [:]
        for comment in comments {
            guard let username = comment.username, !username.isEmpty else { continue }
            let key = username.lowercased()
            var entry = rows[key] ?? (IGCommenterActivityRow(username: username, comments: 0, replies: 0, topPosts: []), [:])
            if comment.isReply { entry.row.replies += 1 } else { entry.row.comments += 1 }
            entry.posts[comment.reportMediaID, default: 0] += 1
            rows[key] = entry
        }
        return rows.values.map { entry in
            var row = entry.row
            row.topPosts = entry.posts.sorted { $0.value > $1.value }.prefix(3).map { mediaID, count in
                let caption = captions[mediaID] ?? "post"
                return "\(count)x on \"\(caption.prefix(28))\(caption.count > 28 ? "…" : "")\""
            }
            return row
        }.sorted { $0.total != $1.total ? $0.total > $1.total : $0.username < $1.username }
    }

    private static func community(_ inputs: IGReportInputs, media: [IGReportMediaRow], period: ReportPeriod,
                                  now: Date) -> InstagramReport.Community {
        var community = InstagramReport.Community()
        let ignored = inputs.ignoredUsernames
        let captions = Dictionary(media.map { ($0.id, $0.caption) }, uniquingKeysWith: { a, _ in a })
        let live = inputs.comments
        let livePeriod = live.filter { period.contains($0.timestamp, now: now) }
        community.liveCommentCount = livePeriod.count

        // Imported aggregates for this period, merged with live comments
        // newer than the import.
        let periodKey: String? = {
            switch period {
            case .allTime: return "all_time"
            case .last30: return "last30"
            case .last7: return nil
            default: return period.monthKey(now: now)
            }
        }()
        func endOfDay(_ key: String) -> Date? {
            dayDate(key).flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
        }
        func merge(_ imported: [IGCommenterRankingRow], liveRows: [IGCommenterRankingRow]) -> [IGCommenterRankingRow] {
            var merged: [String: IGCommenterRankingRow] = [:]
            for row in imported { merged[row.username.lowercased()] = row }
            for row in liveRows {
                let key = row.username.lowercased()
                merged[key] = merged[key].map { $0 + row } ?? row
            }
            return merged.values.filter { !ignored.contains($0.username.lowercased()) }
                .sorted { $0.score != $1.score ? $0.score > $1.score : $0.username < $1.username }
        }

        let importedAll = inputs.importedRankings.first { $0.periodKey == "all_time" }
        let allLive = importedAll.flatMap { endOfDay($0.asOf) }.map { cutoff in live.filter { $0.timestamp >= cutoff } } ?? live
        community.rankingsAllTime = merge(importedAll?.rows ?? [], liveRows: rankings(allLive))

        let importedPeriod = periodKey.flatMap { key in inputs.importedRankings.first { $0.periodKey == key } }
        let periodLive = importedPeriod.flatMap { endOfDay($0.asOf) }
            .map { cutoff in livePeriod.filter { $0.timestamp >= cutoff } } ?? livePeriod
        community.rankingsPeriod = merge(importedPeriod?.rows ?? [], liveRows: rankings(periodLive))
        if let importedPeriod {
            community.rankingsNote = "Imported rankings through \(importedPeriod.asOf)"
                + (periodLive.isEmpty ? "" : " plus \(periodLive.count) newer comments")
        } else if livePeriod.isEmpty {
            community.rankingsNote = "No comments for this period yet — Refresh fetches them for the connected account"
        }

        // Top active commenters.
        // Periods with rankings but no activity table (all time): derive
        // comments/replies from the ranking columns.
        let importedActivity = periodKey.flatMap { key in inputs.importedActivity.first { $0.periodKey == key } }
            ?? importedPeriod.map { ranking in
                IGImportedActivity(periodKey: ranking.periodKey, asOf: ranking.asOf, rows: ranking.rows.map {
                    IGCommenterActivityRow(username: $0.username, comments: $0.textComments + $0.emojiComments,
                                           replies: $0.textReplies + $0.emojiReplies, topPosts: [])
                })
            }
        let activityLive = importedActivity.flatMap { endOfDay($0.asOf) }
            .map { cutoff in livePeriod.filter { $0.timestamp >= cutoff } } ?? livePeriod
        var merged: [String: IGCommenterActivityRow] = [:]
        for row in importedActivity?.rows ?? [] { merged[row.username.lowercased()] = row }
        for row in activity(activityLive, captions: captions) {
            let key = row.username.lowercased()
            if var existing = merged[key] {
                existing.comments += row.comments
                existing.replies += row.replies
                existing.topPosts = Array((row.topPosts + existing.topPosts).prefix(3))
                merged[key] = existing
            } else {
                merged[key] = row
            }
        }
        community.topCommenters = merged.values.filter { !ignored.contains($0.username.lowercased()) }
            .sorted { $0.total != $1.total ? $0.total > $1.total : $0.username < $1.username }
            .prefix(20).map { $0 }
        if let importedActivity {
            community.topCommentersNote = "Imported through \(importedActivity.asOf)"
                + (activityLive.isEmpty ? "" : " plus \(activityLive.count) newer comments")
        }

        // Commenter breakdown: the 5 most recent posts.
        let recent = media.sorted { ($0.postedAt ?? .distantPast) > ($1.postedAt ?? .distantPast) }.prefix(5)
        community.perPost = recent.map { row in
            var counts: [String: (String, Int)] = [:]
            for comment in live where comment.reportMediaID == row.id {
                guard let username = comment.username, !ignored.contains(username.lowercased()) else { continue }
                counts[username.lowercased(), default: (username, 0)].1 += 1
            }
            let entries = counts.values.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(10)
                .map { InstagramReport.LabeledValue(label: $0.0, value: Double($0.1)) }
            return InstagramReport.PostCommenters(media: row, uniqueCount: counts.count, entries: entries)
        }

        // Weekly activity heatmap (UTC, Monday first).
        if !livePeriod.isEmpty {
            var grid = Array(repeating: 0, count: 168)
            for comment in livePeriod {
                let weekday = calendar.component(.weekday, from: comment.timestamp)   // 1 = Sunday
                let hour = calendar.component(.hour, from: comment.timestamp)
                grid[((weekday + 5) % 7) * 24 + hour] += 1
            }
            community.heatmap = grid
            community.heatmapNote = "\(livePeriod.count) comments in \(period.label)"
        } else {
            let (_, until) = period.range(now: now)
            let candidates = inputs.importedHeatmaps.keys.filter { key in
                guard let until, let end = dayDate(key) else { return true }
                return end < calendar.date(byAdding: .day, value: 3, to: until)!
            }
            if let newest = candidates.max(), let grid = inputs.importedHeatmaps[newest] {
                community.heatmap = grid
                community.heatmapNote = "Imported activity for the 30 days ending \(newest)"
            }
        }
        return community
    }

    // MARK: - Audience

    private static func audience(_ inputs: IGReportInputs) -> InstagramReport.Audience {
        var audience = InstagramReport.Audience()
        let ageOrder = ["13-17", "18-24", "25-34", "35-44", "45-54", "55-64", "65+"]
        func values(_ metric: String, _ dimension: String) -> (rows: [InstagramReport.LabeledValue], asOf: String?) {
            let rows = inputs.demographics.filter { $0.metric == metric && $0.dimension == dimension }
            guard let newest = rows.map(\.fetchedDate).max() else { return ([], nil) }
            let latest = rows.filter { $0.fetchedDate == newest }
            let timeframe = latest.first { $0.timeframe == "last_30_days" }?.timeframe ?? latest.first?.timeframe ?? ""
            var labeled = latest.filter { $0.timeframe == timeframe }.map { row -> InstagramReport.LabeledValue in
                var label = row.value
                if dimension == "gender" {
                    label = row.value == "M" ? "Male" : row.value == "F" ? "Female" : "Unspecified"
                }
                return InstagramReport.LabeledValue(label: label, value: Double(row.count))
            }
            if dimension == "age" {
                labeled.sort { (ageOrder.firstIndex(of: $0.label) ?? 99) < (ageOrder.firstIndex(of: $1.label) ?? 99) }
            } else {
                labeled.sort { $0.value > $1.value }
                if dimension != "gender" { labeled = Array(labeled.prefix(10)) }
            }
            return (labeled, newest)
        }
        let followers = "follower_demographics", engaged = "engaged_audience_demographics"
        (audience.age, audience.asOf) = values(followers, "age")
        audience.gender = values(followers, "gender").rows
        audience.countries = values(followers, "country").rows
        audience.cities = values(followers, "city").rows
        (audience.engagedAge, audience.engagedAsOf) = values(engaged, "age")
        audience.engagedGender = values(engaged, "gender").rows
        audience.engagedCountries = values(engaged, "country").rows
        audience.engagedCities = values(engaged, "city").rows
        return audience
    }
}
