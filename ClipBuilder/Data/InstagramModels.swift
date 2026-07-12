import Foundation

/// A saved Instagram account whose reels the app browses — the user's own
/// ('own') or any public account ('public').
nonisolated struct IGAccountRecord: Identifiable, Sendable, Hashable {
    var id: Int64
    var username: String
    var kind: String                 // 'own' | 'public'
    var displayName: String?
    var igUserID: String?
    var followers: Int?
    var profilePicPath: String?
    var lastFetchedAt: Date?
    var addedAt: String?

    var isOwn: Bool { kind == "own" }
}

/// Engagement metrics — all optional because the two providers return
/// different sets (yt-dlp: public counts; Graph API insights: reach, saves,
/// shares, watch time). Stored as JSON in ig_media.stats_json.
nonisolated struct IGStats: Codable, Sendable, Hashable {
    var views: Int?
    var likes: Int?
    var comments: Int?
    var shares: Int?
    var saves: Int?
    var reach: Int?
    var avgWatchTime: Double?

    enum CodingKeys: String, CodingKey {
        case views, likes, comments, shares, saves, reach
        case avgWatchTime = "avg_watch_time"
    }

    init(views: Int? = nil, likes: Int? = nil, comments: Int? = nil,
         shares: Int? = nil, saves: Int? = nil, reach: Int? = nil,
         avgWatchTime: Double? = nil) {
        self.views = views
        self.likes = likes
        self.comments = comments
        self.shares = shares
        self.saves = saves
        self.reach = reach
        self.avgWatchTime = avgWatchTime
    }
}

/// One cached reel/video row from ig_media.
nonisolated struct IGMediaRecord: Identifiable, Sendable, Hashable {
    var id: Int64
    var accountID: Int64
    var mediaID: String              // IG shortcode (yt-dlp) or Graph media id
    var mediaType: String            // reel | video
    var caption: String
    var permalink: String?
    var postedAt: Date?
    var duration: Double
    var thumbnailPath: String?
    var localVideoPath: String?
    var statsJSON: String
    var source: String               // 'ytdlp' | 'graph'
    var fetchedAt: String?

    var stats: IGStats {
        statsJSON.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode(IGStats.self, from: $0) } ?? IGStats()
    }

    var thumbnailURL: URL? {
        thumbnailPath.flatMap { FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
    }

    var localVideoURL: URL? {
        localVideoPath.flatMap { FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
    }
}

/// Upsert payload for ig_media — what a provider fetch produces.
nonisolated struct IGMediaUpsert: Sendable {
    var accountID: Int64
    var mediaID: String
    var mediaType: String = "reel"
    var caption: String = ""
    var permalink: String?
    var postedAt: Date?
    var duration: Double = 0
    var statsJSON: String = "{}"
    var source: String = "ytdlp"
}

/// A template chosen in the Instagram tab, waiting for the Wizard to consume
/// on its next run (or be dismissed).
nonisolated struct WizardTemplateHandoff: Sendable, Hashable {
    var templateJSON: String
    var label: String            // "@handle · 1.2M views"
}

nonisolated struct IGTemplateRecord: Sendable, Hashable {
    var id: Int64
    var mediaID: Int64
    var templateJSON: String
    var provider: String?
    var model: String?
    var analyzedAt: String?
}

/// Structured analysis of a reference reel — the AI's answer to "what makes
/// this reel work, structurally". Cached in ig_templates.template_json and
/// injected into the Wizard's plan prompt.
nonisolated struct ReelTemplate: Codable, Sendable {
    struct Hook: Codable, Sendable {
        var type: String
        var description: String
    }
    struct Phase: Codable, Sendable {
        var phase: String
        var start: Double
        var end: Double
        var description: String
    }

    var duration: Double
    var hook: Hook
    var cutCount: Int
    var cutsPerMinute: Double
    var cutRhythm: String
    var pacingCurve: String
    var structure: [Phase]
    var visualStyle: String
    var textOverlayUsage: String
    var musicUsage: String
    var captionStyle: String
    var whyItWorks: String

    enum CodingKeys: String, CodingKey {
        case duration, hook, structure
        case cutCount = "cut_count"
        case cutsPerMinute = "cuts_per_minute"
        case cutRhythm = "cut_rhythm"
        case pacingCurve = "pacing_curve"
        case visualStyle = "visual_style"
        case textOverlayUsage = "text_overlay_usage"
        case musicUsage = "music_usage"
        case captionStyle = "caption_style"
        case whyItWorks = "why_it_works"
    }
}

extension Int {
    /// 12345 → "12.3K", 4200000 → "4.2M" — Instagram-style compact counts.
    var compactFormatted: String {
        formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}
