import Foundation

nonisolated enum ReportCSVExporter {
    static func export(
        directory: URL, videos: [GeneratedVideoRecord],
        traits: [Int64: PublishedEditTraits], report: InstagramReport?,
        insights: EditingPerformanceInsights
    ) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var files: [URL] = []

        var reelRows = [
            [
                "file", "generated_at", "width", "height", "cadence", "pace_curve",
                "hook_type", "hook_length", "people", "screen_types", "cut_targets",
                "views", "reach", "watch_time", "shares", "saves", "comments",
            ]
        ]
        for video in videos {
            let trait = traits[video.id]
            let stats = video.instagramStats
            reelRows.append([
                video.filename, video.generatedAt ?? "", value(trait?.outputWidth),
                value(trait?.outputHeight), value(trait?.cutCadence), trait?.paceCurve ?? "",
                trait?.hookType ?? "", value(trait?.hookLength),
                trait?.peopleKeys.joined(separator: "|") ?? "",
                trait?.screenSeconds.keys.sorted().joined(separator: "|") ?? "",
                trait?.cutTargets.map { "\($0.key):\($0.value)" }.sorted().joined(separator: "|") ?? "",
                value(stats?.views), value(stats?.reach), value(stats?.avgWatchTime),
                value(stats?.shares), value(stats?.saves), value(stats?.comments),
            ])
        }
        files.append(try write(reelRows, named: "reels.csv", to: directory))

        let athleteRows =
            [
                [
                    "athlete", "appearances", "followers_per_appearance", "views_per_appearance",
                    "reach_per_appearance", "watch_time_per_appearance", "shares_per_appearance",
                    "saves_per_appearance", "comments_per_appearance",
                ]
            ]
            + insights.athletes.map {
                [
                    $0.name, value($0.appearances), value($0.followersGained),
                    value($0.views), value($0.reach), value($0.watchTime),
                    value($0.shares), value($0.saves), value($0.comments),
                ]
            }
        files.append(try write(athleteRows, named: "athlete-rankings.csv", to: directory))

        let patternRows =
            [["dimension", "variant", "reels", "average_watch_time", "average_reach"]]
            + insights.patterns.map {
                [
                    $0.dimension, $0.value, value($0.reels),
                    value($0.averageWatchTime), value($0.averageReach),
                ]
            }
        files.append(try write(patternRows, named: "editing-rankings.csv", to: directory))

        var weekly: [String: (posts: Int, reach: Int, views: Int, likes: Int, comments: Int, saves: Int, shares: Int)] =
            [:]
        for point in report?.posts.postsDaily ?? [] {
            let components = Calendar(identifier: .iso8601).dateComponents(
                [.yearForWeekOfYear, .weekOfYear], from: point.date)
            let key = String(
                format: "%04d-W%02d", components.yearForWeekOfYear ?? 0,
                components.weekOfYear ?? 0)
            var row = weekly[key] ?? (0, 0, 0, 0, 0, 0, 0)
            row.posts += 1
            row.reach += point.reach
            row.views += point.views
            row.likes += point.likes
            row.comments += point.comments
            row.saves += point.saves
            row.shares += point.shares
            weekly[key] = row
        }
        let weeklyRows =
            [["week", "posts", "reach", "views", "likes", "comments", "saves", "shares"]]
            + weekly.sorted { $0.key < $1.key }.map { key, row in
                [
                    key, value(row.posts), value(row.reach), value(row.views), value(row.likes),
                    value(row.comments), value(row.saves), value(row.shares),
                ]
            }
        files.append(try write(weeklyRows, named: "account-weekly.csv", to: directory))
        return files
    }

    private static func value<T>(_ value: T?) -> String { value.map(String.init(describing:)) ?? "" }

    private static func write(_ rows: [[String]], named name: String, to directory: URL) throws -> URL {
        let output = directory.appending(path: name)
        let csv = rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
        try csv.write(to: output, atomically: true, encoding: .utf8)
        return output
    }

    private static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacing("\"", with: "\"\""))\""
    }
}
