import Foundation

/// Built-in rows of the Scenes screen's batch column: Recent and one row
/// per video type. Each has a negative sentinel ID so it can sit in the
/// same `Set<Int64>` selection as real analyze batches (whose IDs are > 0)
/// and the "All batches" row (-1).
nonisolated enum SceneBatchFilter: Int64, CaseIterable, Sendable {
    case recent = -2
    case interviews = -3
    case podcasts = -4
    case fights = -5
    case recaps = -6
    case training = -7
    case other = -8
    case screen = -9

    /// Recent covers batches analyzed in the last three days.
    static let recentWindow: TimeInterval = 3 * 24 * 60 * 60

    var id: Int64 { rawValue }

    var title: String {
        switch self {
        case .recent: "Recent"
        case .interviews: "Interviews"
        case .podcasts: "Podcasts"
        case .fights: "Fights"
        case .recaps: "Fight Recaps"
        case .training: "Training"
        case .other: "Other"
        case .screen: "Screen Recordings"
        }
    }

    var systemImage: String {
        switch self {
        case .recent: "clock"
        case .interviews: "bubble.left.and.bubble.right"
        case .podcasts: "mic"
        case .fights: "figure.boxing"
        case .recaps: "film.stack"
        case .training: "figure.strengthtraining.traditional"
        case .other: "questionmark.square.dashed"
        case .screen: "rectangle.on.rectangle"
        }
    }

    var help: String {
        switch self {
        case .recent: "Scenes from batches analyzed in the last 3 days"
        case .interviews: "Scenes from batches of videos typed Interview"
        case .podcasts: "Scenes from batches of videos typed Podcast"
        case .fights: "Scenes from batches of videos typed Fight"
        case .recaps: "Scenes from batches of videos typed Fight Recap"
        case .training: "Scenes from batches of videos typed Training"
        case .screen: "Scenes from batches of videos typed Screen recording"
        case .other: "Scenes from batches of videos typed Other or not typed yet"
        }
    }

    /// What a batch needs to be matched by a built-in row.
    struct Run: Sendable {
        var id: Int64
        var analyzedAt: Date?
        var videoType: VideoType?
    }

    func matches(_ run: Run, now: Date) -> Bool {
        switch self {
        case .recent:
            guard let analyzedAt = run.analyzedAt else { return false }
            return now.timeIntervalSince(analyzedAt) <= Self.recentWindow
        case .interviews: return run.videoType == .interview
        case .podcasts: return run.videoType == .podcast
        case .fights: return run.videoType == .fight
        case .recaps: return run.videoType == .recap
        case .training: return run.videoType == .training
        case .screen: return run.videoType == .screen
        // Untyped videos land here so every batch has a type row.
        case .other: return run.videoType == .other || run.videoType == nil
        }
    }

    /// The batch IDs a selection of real batches and built-in rows stands
    /// for: the selected batches plus every batch a selected row matches.
    static func runIDs(for selection: Set<Int64>, runs: [Run], now: Date) -> Set<Int64> {
        let filters = allCases.filter { selection.contains($0.id) }
        var ids = selection.filter { $0 > 0 }
        for run in runs where filters.contains(where: { $0.matches(run, now: now) }) {
            ids.insert(run.id)
        }
        return ids
    }
}
