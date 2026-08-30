import Foundation

// MARK: - Stored rows (Instagram report tables)

/// One day's account counters — the follower time series behind every
/// growth number. `source` is 'graph' (live refresh) or 'import' (backfilled
/// from the peace-grappler report artifacts).
nonisolated struct IGAccountSnapshot: Sendable, Hashable {
    var date: String                 // YYYY-MM-DD (UTC)
    var followers: Int?
    var follows: Int?
    var mediaCount: Int?
    var source: String = "graph"
}

/// One post of any type (reel, feed image/video, carousel) for the reports.
/// Separate from `ig_media`, which stays reels-only for the Posts grid.
nonisolated struct IGReportMediaRow: Identifiable, Sendable, Hashable {
    var id: Int64
    var accountID: Int64
    var mediaID: String?             // Graph media id (nil for import rows until linked)
    var shortcode: String            // from the permalink — the join key with imports
    var mediaType: String?           // IMAGE | VIDEO | CAROUSEL_ALBUM
    var productType: String?         // FEED | REELS | STORY
    var caption: String
    var captionTruncated: Bool
    var permalink: String?
    var postedAt: Date?
    var likeCount: Int?
    var commentsCount: Int?
    var thumbnailURL: String?
    var thumbnailPath: String?
    var source: String
    /// Latest value per insight metric (reach, views, likes, comments,
    /// shares, saved, total_interactions, ig_reels_avg_watch_time, …).
    var metrics: [String: Double] = [:]

    var isReel: Bool { productType == "REELS" }
    var isStory: Bool { productType == "STORY" }
    var isCarousel: Bool { mediaType == "CAROUSEL_ALBUM" }
    /// Badge text mirroring the web reports (REELS / FEED / CAROUSEL).
    var typeLabel: String {
        if isReel { return "REELS" }
        if isCarousel { return "CAROUSEL" }
        return productType ?? "FEED"
    }

    func metric(_ name: String) -> Int? { metrics[name].map { Int($0.rounded()) } }
    var reach: Int? { metric("reach") }
    var views: Int? { metric("views") }
    var likes: Int? { metric("likes") ?? likeCount }
    var comments: Int? { metric("comments") ?? commentsCount }
    var shares: Int? { metric("shares") }
    var saves: Int? { metric("saved") }
    var totalInteractions: Int? {
        metric("total_interactions")
            ?? [likes, comments, shares, saves].compactMap { $0 }.reduce(0, +)
    }
    /// likes + comments — the web reports' "engagement".
    var engagement: Int { (likes ?? 0) + (comments ?? 0) }

    var localThumbnailURL: URL? {
        thumbnailPath.flatMap { FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
    }
    var permalinkURL: URL? { permalink.flatMap(URL.init(string:)) }
}

/// Upsert payload for ig_report_media.
nonisolated struct IGReportMediaUpsert: Sendable {
    var accountID: Int64
    var shortcode: String
    var mediaID: String?
    var mediaType: String?
    var productType: String?
    var caption: String = ""
    var captionTruncated = false
    var permalink: String?
    var postedAt: Date?
    var likeCount: Int?
    var commentsCount: Int?
    var thumbnailURL: String?
    var source: String = "graph"
}

nonisolated struct IGMediaInsightSnapshot: Sendable, Hashable {
    var reportMediaID: Int64
    var metric: String
    var value: Double
    var fetchedAt: String            // ISO-8601 UTC
    var source: String = "graph"
}

/// One account-level insight value — a plain daily total, a rolling 28-day
/// total, a calendar-month total, or a 30-day window sum imported from a
/// report — optionally broken down (media_product_type, follow_type,
/// contact_button_type).
nonisolated struct IGAccountInsightRow: Sendable, Hashable {
    var metric: String
    var period: String               // day | days_28 | month | window_30d
    var dimension: String            // '' when not broken down
    var breakdown: String            // '' when not broken down
    var value: Double
    var endTime: String              // ISO-8601 UTC
    var source: String = "graph"

    var endDate: String { String(endTime.prefix(10)) }
}

nonisolated struct IGDemographicRow: Sendable, Hashable {
    var metric: String               // follower_demographics | engaged_audience_demographics
    var dimension: String            // age | city | country | gender
    var value: String                // bucket label
    var count: Int
    var timeframe: String            // last_30_days | this_month | this_week
    var fetchedDate: String          // YYYY-MM-DD
    var source: String = "graph"
}

nonisolated struct IGCommentRecord: Sendable, Hashable {
    var id: String
    var reportMediaID: Int64
    var parentCommentID: String?
    var username: String?
    var text: String
    var likeCount: Int
    var hidden: Bool
    var timestamp: Date
    /// Parent comment time for replies, else the post time — the "early"
    /// bonus is measured against it.
    var refTimestamp: Date?

    var isReply: Bool { parentCommentID != nil }
}

/// One row of a community ranking — computed live from comments, or
/// imported from a report's rankings table.
nonisolated struct IGCommenterRankingRow: Identifiable, Sendable, Hashable {
    var username: String
    var score: Int
    var early: Int
    var textComments: Int
    var emojiComments: Int
    var textReplies: Int
    var emojiReplies: Int
    var id: String { username.lowercased() }
    var total: Int { textComments + emojiComments + textReplies + emojiReplies }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(username: lhs.username, score: lhs.score + rhs.score, early: lhs.early + rhs.early,
             textComments: lhs.textComments + rhs.textComments,
             emojiComments: lhs.emojiComments + rhs.emojiComments,
             textReplies: lhs.textReplies + rhs.textReplies,
             emojiReplies: lhs.emojiReplies + rhs.emojiReplies)
    }
}

nonisolated struct IGImportedRanking: Sendable, Hashable {
    var periodKey: String            // all_time | last30 | YYYY-MM
    var asOf: String                 // YYYY-MM-DD the numbers are current to
    var rows: [IGCommenterRankingRow]
}

/// "Top Active Commenters" — comments / replies / total plus the posts they
/// commented on most.
nonisolated struct IGCommenterActivityRow: Identifiable, Sendable, Hashable {
    var username: String
    var comments: Int
    var replies: Int
    var topPosts: [String]           // "12x on \"caption…\""
    var id: String { username.lowercased() }
    var total: Int { comments + replies }
}

nonisolated struct IGImportedActivity: Sendable, Hashable {
    var periodKey: String
    var asOf: String
    var rows: [IGCommenterActivityRow]
}

/// One day's AI review of a reel, imported from the peace-grappler
/// video-analysis sidecars (score vs 90-day benchmarks, tier, what worked,
/// what to fix, top tip).
nonisolated struct IGReelAnalysisRow: Sendable, Hashable {
    var reportMediaID: Int64
    var date: String                 // YYYY-MM-DD of the analysis
    var score: Int
    var tier: String                 // Top Performer | Average | Needs Work
    var good: [String]
    var bad: [String]
    var topTip: String?
}

/// Everything the report builder reads for one account, fetched in one go
/// from the Database actor.
nonisolated struct IGReportInputs: Sendable {
    var account: IGAccountRecord
    var snapshots: [IGAccountSnapshot] = []
    var media: [IGReportMediaRow] = []
    var accountInsights: [IGAccountInsightRow] = []
    var demographics: [IGDemographicRow] = []
    var comments: [IGCommentRecord] = []
    var importedRankings: [IGImportedRanking] = []
    var importedActivity: [IGImportedActivity] = []
    /// Sorted by analysis date ascending — the last row per reel is current.
    var reelAnalyses: [IGReelAnalysisRow] = []
    /// window_end (YYYY-MM-DD) → 168 counts, Monday-first, 24 per day.
    var importedHeatmaps: [String: [Int]] = [:]
    var ignoredUsernames: Set<String> = []
    var syncState: [String: String] = [:]
}

// MARK: - Shortcodes

nonisolated enum IGShortcode {
    /// `/(p|reel)/<shortcode>/` from a permalink — the key the report
    /// artifacts and the Graph API share.
    static func parse(_ permalink: String?) -> String? {
        guard let permalink else { return nil }
        let pattern = #"instagram\.com/(?:p|reel|reels|tv)/([A-Za-z0-9_-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: permalink, range: NSRange(permalink.startIndex..., in: permalink)),
              let range = Range(match.range(at: 1), in: permalink) else { return nil }
        return String(permalink[range])
    }
}

// MARK: - Dates

/// UTC day keys shared by the sync, the importer, and the builder.
nonisolated enum ReportDates {
    static let calendar = ReportPeriod.utcCalendar

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// "YYYY-MM-DD" in UTC.
    static func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(fromDayKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }
}

// MARK: - Report period

/// The window a report is built for. Rolling windows end now; months are
/// calendar months (UTC), as in the peace-grappler monthly reports.
nonisolated enum ReportPeriod: Hashable, Sendable, Identifiable {
    case last7
    case last30
    case monthToDate
    case month(year: Int, month: Int)
    case allTime

    var id: String {
        switch self {
        case .last7: return "last7"
        case .last30: return "last30"
        case .monthToDate: return "mtd"
        case .month(let y, let m): return String(format: "%04d-%02d", y, m)
        case .allTime: return "all"
        }
    }

    static func from(id: String) -> ReportPeriod {
        switch id {
        case "last7": return .last7
        case "mtd": return .monthToDate
        case "all": return .allTime
        default:
            let parts = id.split(separator: "-")
            if parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]) {
                return .month(year: y, month: m)
            }
            return .last30
        }
    }

    var label: String {
        switch self {
        case .last7: return "Last 7 Days"
        case .last30: return "Last 30 Days"
        case .monthToDate: return "This Month"
        case .month(let y, let m): return Self.monthLabel(year: y, month: m)
        case .allTime: return "All Time"
        }
    }

    /// `YYYY-MM` for calendar months (this month included), nil for rolling windows.
    func monthKey(now: Date) -> String? {
        switch self {
        case .month(let y, let m): return String(format: "%04d-%02d", y, m)
        case .monthToDate:
            let c = Self.utcCalendar.dateComponents([.year, .month], from: now)
            return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
        default: return nil
        }
    }

    var isRolling: Bool {
        switch self {
        case .last7, .last30: return true
        default: return false
        }
    }

    /// Half-open [since, until) in UTC; nil = unbounded.
    func range(now: Date) -> (since: Date?, until: Date?) {
        let cal = Self.utcCalendar
        switch self {
        case .last7: return (cal.date(byAdding: .day, value: -7, to: now), nil)
        case .last30: return (cal.date(byAdding: .day, value: -30, to: now), nil)
        case .monthToDate:
            let start = cal.date(from: cal.dateComponents([.year, .month], from: now))
            return (start, nil)
        case .month(let y, let m):
            let start = cal.date(from: DateComponents(year: y, month: m, day: 1))
            let end = start.flatMap { cal.date(byAdding: .month, value: 1, to: $0) }
            return (start, end)
        case .allTime: return (nil, nil)
        }
    }

    func contains(_ date: Date?, now: Date) -> Bool {
        guard let date else { return false }
        let (since, until) = range(now: now)
        if let since, date < since { return false }
        if let until, date >= until { return false }
        return true
    }

    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func monthLabel(year: Int, month: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMMM yyyy"
        let date = utcCalendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
        return formatter.string(from: date)
    }
}

// MARK: - Assembled report

/// A finished report for one account and period — the view renders this
/// without touching the database.
nonisolated struct InstagramReport: Sendable {
    /// A headline number with an optional delta and breakdown chips.
    struct Stat: Identifiable, Sendable, Hashable {
        var label: String
        var value: String
        var delta: Delta?
        var note: String?
        var breakdown: [LabeledValue] = []
        var id: String { label }
    }

    struct Delta: Sendable, Hashable {
        var amount: Double
        var percent: Double?
        var suffix: String = ""
        var isPositive: Bool { amount > 0 }
        var isNegative: Bool { amount < 0 }
    }

    struct LabeledValue: Identifiable, Sendable, Hashable {
        var label: String
        var value: Double
        var id: String { label }
        var intValue: Int { Int(value.rounded()) }
    }

    struct DatedValue: Identifiable, Sendable, Hashable {
        var date: Date
        var value: Double
        var id: Date { date }
    }

    struct GrowthCard: Identifiable, Sendable, Hashable {
        var label: String
        var delta: Int?
        var id: String { label }
    }

    struct PublishedRow: Identifiable, Sendable, Hashable {
        var label: String
        var total: Int
        var reels: Int
        var feed: Int
        var carousels: Int
        var id: String { label }
    }

    struct EngagementWindow: Identifiable, Sendable, Hashable {
        var label: String
        var posts: Int
        var likes: Int
        var comments: Int
        var shares: Int
        var saves: Int
        var reach: Int
        var views: Int
        var id: String { label }
        var totalEngagement: Int { likes + comments }
        var avgPerPost: Int { posts > 0 ? Int((Double(totalEngagement) / Double(posts)).rounded()) : 0 }
    }

    struct ReachBar: Identifiable, Sendable, Hashable {
        var id: Int64
        var date: Date
        var reach: Int
        var type: String
    }

    struct Overview: Sendable {
        var kpis: [Stat] = []
        var followerGrowth: [GrowthCard] = []
        var followerSeries: [DatedValue] = []
        var newFollowersSeries: [DatedValue] = []
        var newFollowersTotal = 0
        var contentPublished: [PublishedRow] = []
        var engagement: [EngagementWindow] = []
        var accountInsights: [Stat] = []
        var accountInsightsNote: String?
        var interactionRate: Double?
        var contentMix: [LabeledValue] = []
        var reachPerPost: [ReachBar] = []
        var reachByType: [LabeledValue] = []
        var viewsByType: [LabeledValue] = []
        var interactionsByType: [LabeledValue] = []
        var reachByFollow: [LabeledValue] = []
        var viewsByFollow: [LabeledValue] = []
        var linkTaps: [LabeledValue] = []
    }

    struct PostRow: Identifiable, Sendable, Hashable {
        var media: IGReportMediaRow
        var rank: Int = 0
        var id: Int64 { media.id }
        var date: Date { media.postedAt ?? .distantPast }
        var type: String { media.typeLabel }
        var caption: String { media.caption }
        var reach: Int { media.reach ?? 0 }
        var views: Int { media.views ?? 0 }
        var likes: Int { media.likes ?? 0 }
        var comments: Int { media.comments ?? 0 }
        var shares: Int { media.shares ?? 0 }
        var saves: Int { media.saves ?? 0 }
        var engagement: Int { media.engagement }
        var quality: Double {
            ReelPerformance.score(IGStats(views: media.views, likes: media.likes, comments: media.comments,
                                          shares: media.shares, saves: media.saves, reach: media.reach))
        }
    }

    struct HashtagStat: Identifiable, Sendable, Hashable {
        var tag: String
        var count: Int
        var avgReach: Int
        var avgInteractions: Int
        var id: String { tag }
    }

    struct DailyPoint: Identifiable, Sendable, Hashable {
        var date: Date
        var reach: Int = 0
        var views: Int = 0
        var likes: Int = 0
        var comments: Int = 0
        var saves: Int = 0
        var shares: Int = 0
        var id: Date { date }
    }

    struct ReelAnalysis: Identifiable, Sendable, Hashable {
        var media: IGReportMediaRow
        var date: String
        var score: Int
        var tier: String
        var good: [String]
        var bad: [String]
        var topTip: String?
        var id: Int64 { media.id }
    }

    struct PostPerformance: Sendable {
        var rows: [PostRow] = []
        var topByEngagement: [PostRow] = []
        var topLiked: [PostRow] = []
        var topDiscussed: [PostRow] = []
        var topShared: [PostRow] = []
        var hashtags: [HashtagStat] = []
        var postsSummary: [Stat] = []
        var reelsSummary: [Stat] = []
        var postsDaily: [DailyPoint] = []
        var reelsDaily: [DailyPoint] = []
        var algorithmStatus: AlgorithmStatus?
        /// Latest imported AI review per reel in the period, newest first.
        var reelAnalyses: [ReelAnalysis] = []
    }

    struct AlgorithmStatus: Sendable, Hashable {
        var verdict: String            // HIGH | STABLE | LOW
        var detail: String
        var recentViews: Int
        var previousViews: Int
    }

    struct PostCommenters: Identifiable, Sendable, Hashable {
        var media: IGReportMediaRow
        var uniqueCount: Int
        var entries: [LabeledValue]
        var id: Int64 { media.id }
    }

    struct Community: Sendable {
        var topCommenters: [IGCommenterActivityRow] = []
        var topCommentersNote: String?
        var perPost: [PostCommenters] = []
        var rankingsAllTime: [IGCommenterRankingRow] = []
        var rankingsPeriod: [IGCommenterRankingRow] = []
        var rankingsNote: String?
        var heatmap: [Int] = Array(repeating: 0, count: 168)
        var heatmapNote: String?
        var liveCommentCount = 0
    }

    struct Audience: Sendable {
        var age: [LabeledValue] = []
        var gender: [LabeledValue] = []
        var countries: [LabeledValue] = []
        var cities: [LabeledValue] = []
        var engagedAge: [LabeledValue] = []
        var engagedGender: [LabeledValue] = []
        var engagedCountries: [LabeledValue] = []
        var engagedCities: [LabeledValue] = []
        var asOf: String?
        var engagedAsOf: String?
    }

    var period: ReportPeriod
    var periodLabel: String
    var generatedAt: Date
    var lastRefreshed: Date?
    var importedThrough: String?
    var availableMonths: [ReportPeriod] = []
    var overview = Overview()
    var posts = PostPerformance()
    var community = Community()
    var audience = Audience()

    /// False when nothing has been synced or imported yet.
    var hasData: Bool {
        !overview.followerSeries.isEmpty || !posts.rows.isEmpty || !overview.accountInsights.isEmpty
    }
}
