import Foundation

/// Backfills report history from a checkout of the peace-grappler repo —
/// the generated HTML/JSON report artifacts committed there daily (its
/// SQLite database is not in the repo). Walks the git history of the two
/// data-bearing pages so day-by-day series are reconstructed, and reads
/// the monthly reports and video-analysis sidecars from the working tree.
/// Every write is an upsert keyed on natural keys, so re-running is safe.
///
/// The engagement report's "Account Insights" cards are deliberately not
/// imported: that generator sums daily and rolling-28-day rows together,
/// so its totals are inflated. The insights page's 30-day breakdowns are
/// used instead, and live refreshes supply correct daily rows from then on.
nonisolated enum PeaceGrapplerImporter {
    struct Summary: Sendable {
        var snapshots = 0
        var posts = 0
        var insightRows = 0
        var rankings = 0
        var reelAnalyses = 0
        var commitsRead = 0
        var asOf: String?

        var description: String {
            "Imported \(snapshots) follower snapshots, \(posts) posts, \(insightRows) insight rows, "
                + "\(rankings) ranking rows, \(reelAnalyses) reel analyses from \(commitsRead) report versions"
                + (asOf.map { " (through \($0))" } ?? "")
        }
    }

    enum ImportError: Error, CustomStringConvertible {
        case notARepo(String)
        case gitMissing

        var description: String {
            switch self {
            case .notARepo(let path):
                return "\(path) is not a peace-grappler checkout (no .git or engagement-report.html)"
            case .gitMissing: return "git is not installed"
            }
        }
    }

    /// Default checkout location, used when the setting is empty.
    static func defaultRepoPath() -> String? {
        let path = NSHomeDirectory() + "/repos/peace-grappler"
        return FileManager.default.fileExists(atPath: path + "/engagement-report.html") ? path : nil
    }

    static func run(repoPath: String, accountID: Int64, username: String, database: Database,
                    log: @escaping @Sendable (String) -> Void) async throws -> Summary {
        let repo = URL(fileURLWithPath: (repoPath as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git").path),
              FileManager.default.fileExists(atPath: repo.appendingPathComponent("engagement-report.html").path)
        else { throw ImportError.notARepo(repo.path) }
        guard let git = ProcessRunner.locate("git")
            ?? (FileManager.default.fileExists(atPath: "/usr/bin/git") ? URL(fileURLWithPath: "/usr/bin/git") : nil)
        else { throw ImportError.gitMissing }

        var summary = Summary()
        let state = try await database.igSyncState(accountID: accountID)
        let previousAsOf = state["import_as_of"] ?? ""

        // Each page: one version per day (the last commit of the day).
        let engagementCommits = try await commits(git: git, repo: repo, file: "engagement-report.html")
        let insightsCommits = try await commits(git: git, repo: repo, file: "peacegrappler-insights.html")
        log("Reading \(engagementCommits.count) engagement report versions and "
            + "\(insightsCommits.count) insights versions from git…")
        log("IGPROGRESS:0.03:Listing report versions")

        // 1. The rolling engagement report, oldest → newest, so every day's
        //    post metrics land as dated snapshots and the newest version
        //    settles the current numbers.
        var shortcodeIDs = try await database.fetchIGReportMediaIDs(accountID: accountID)
        for (index, commit) in engagementCommits.enumerated() {
            try Task.checkCancellation()
            let isHead = index == engagementCommits.count - 1
            if !isHead && commit.date <= previousAsOf { continue }
            guard let html = try await show(git: git, repo: repo, sha: commit.sha, file: "engagement-report.html")
            else { continue }
            summary.commitsRead += 1
            log("IGPROGRESS:\(0.05 + 0.55 * Double(index + 1) / Double(max(1, engagementCommits.count))):"
                + "Engagement report \(commit.date)")
            let report = EngagementReportParser.parse(html)
            let asOf = report.generatedDate ?? commit.date

            if isHead {
                // The chart carries the full follower series since day one.
                var snapshots = report.followerSeries.map {
                    IGAccountSnapshot(date: $0.date, followers: $0.value, source: "import")
                }
                if let last = snapshots.indices.last {
                    snapshots[last].follows = report.kpis["Following"]
                    snapshots[last].mediaCount = report.kpis["Posts"]
                }
                try await database.upsertIGAccountSnapshots(accountID: accountID, snapshots)
                summary.snapshots += snapshots.count
            } else {
                try await database.upsertIGAccountSnapshots(accountID: accountID, [
                    IGAccountSnapshot(date: asOf, followers: report.kpis["Followers"],
                                      follows: report.kpis["Following"], mediaCount: report.kpis["Posts"],
                                      source: "import"),
                ])
            }

            // Post rows + that day's metric values. New posts are inserted
            // in one transaction (one commit per report version, not per
            // post); the head version also refreshes known rows in one go.
            var snapshots: [IGMediaInsightSnapshot] = []
            var newPosts: [EngagementReportParser.Post] = []
            var headRefresh: [IGReportMediaUpsert] = []
            func recordMetrics(_ post: EngagementReportParser.Post, rowID: Int64) {
                for (metric, value) in post.metrics {
                    snapshots.append(IGMediaInsightSnapshot(reportMediaID: rowID, metric: metric, value: Double(value),
                                                            fetchedAt: "\(asOf)T00:00:00Z", source: "import"))
                }
            }
            var queuedShortcodes = Set<String>()
            for post in report.posts {
                if let existing = shortcodeIDs[post.shortcode] {
                    if isHead { headRefresh.append(post.upsert(accountID: accountID)) }
                    recordMetrics(post, rowID: existing)
                } else if queuedShortcodes.insert(post.shortcode).inserted {
                    newPosts.append(post)
                }
            }
            if !newPosts.isEmpty {
                let ids = try await database.upsertIGReportMediaBatch(newPosts.map { $0.upsert(accountID: accountID) })
                for (post, rowID) in zip(newPosts, ids) {
                    shortcodeIDs[post.shortcode] = rowID
                    summary.posts += 1
                    recordMetrics(post, rowID: rowID)
                }
            }
            if !headRefresh.isEmpty {
                _ = try await database.upsertIGReportMediaBatch(headRefresh)
            }
            try await database.insertIGMediaInsightSnapshots(snapshots)
            summary.insightRows += snapshots.count

            if isHead {
                try await database.upsertIGDemographics(accountID: accountID,
                                                        report.demographicRows(fetchedDate: asOf))
                if !report.rankingAllTime.isEmpty {
                    try await database.upsertIGCommenterRankingsImport(accountID: accountID,
                        IGImportedRanking(periodKey: "all_time", asOf: asOf, rows: report.rankingAllTime))
                    summary.rankings += report.rankingAllTime.count
                }
                if !report.rankingPeriod.isEmpty {
                    try await database.upsertIGCommenterRankingsImport(accountID: accountID,
                        IGImportedRanking(periodKey: "last30", asOf: asOf, rows: report.rankingPeriod))
                    summary.rankings += report.rankingPeriod.count
                }
                if !report.commenters.isEmpty {
                    try await database.upsertIGCommenterActivityImport(accountID: accountID,
                        IGImportedActivity(periodKey: "last30", asOf: asOf, rows: report.commenters))
                }
                summary.asOf = asOf
            }
            if summary.commitsRead % 20 == 0 { log("…\(summary.commitsRead) report versions read") }
        }

        // 2. Monthly engagement reports (working tree): month totals + rankings.
        log("IGPROGRESS:0.62:Monthly reports")
        let monthlyFiles = (try? FileManager.default.contentsOfDirectory(atPath: repo.path))?
            .filter { $0.range(of: #"^engagement-report-\d{4}-\d{2}\.html$"#, options: .regularExpression) != nil }
            .sorted() ?? []
        for file in monthlyFiles {
            try Task.checkCancellation()
            guard let html = try? String(contentsOf: repo.appendingPathComponent(file), encoding: .utf8) else { continue }
            let monthKey = String(file.dropFirst("engagement-report-".count).prefix(7))
            let report = EngagementReportParser.parse(html)
            let asOf = report.generatedDate ?? monthKey + "-01"
            if !report.rankingPeriod.isEmpty {
                try await database.upsertIGCommenterRankingsImport(accountID: accountID,
                    IGImportedRanking(periodKey: monthKey, asOf: asOf, rows: report.rankingPeriod))
                summary.rankings += report.rankingPeriod.count
            }
            if !report.commenters.isEmpty {
                try await database.upsertIGCommenterActivityImport(accountID: accountID,
                    IGImportedActivity(periodKey: monthKey, asOf: asOf, rows: report.commenters))
            }
        }
        log("Read \(monthlyFiles.count) monthly reports")

        // 3. Insights page history: daily new followers, 30-day breakdowns,
        //    age/gender history, comment heatmaps.
        for (index, commit) in insightsCommits.enumerated() {
            try Task.checkCancellation()
            let isHead = index == insightsCommits.count - 1
            if !isHead && commit.date <= previousAsOf { continue }
            guard let html = try await show(git: git, repo: repo, sha: commit.sha, file: "peacegrappler-insights.html")
            else { continue }
            summary.commitsRead += 1
            log("IGPROGRESS:\(0.65 + 0.25 * Double(index + 1) / Double(max(1, insightsCommits.count))):"
                + "Insights page \(commit.date)")
            let page = InsightsPageParser.parse(html)
            let endDate = page.endDate ?? commit.date
            var rows: [IGAccountInsightRow] = page.followerTrend.map {
                IGAccountInsightRow(metric: "follower_count", period: "day", dimension: "", breakdown: "",
                                    value: Double($0.value), endTime: "\($0.date)T00:00:00Z", source: "import")
            }
            for (metric, breakdown) in [("reach", page.reachBreakdown), ("views", page.viewsBreakdown),
                                        ("total_interactions", page.interactionsBreakdown)] {
                for (label, value) in breakdown {
                    rows.append(IGAccountInsightRow(metric: metric, period: "window_30d",
                                                    dimension: "media_product_type", breakdown: label,
                                                    value: Double(value), endTime: "\(endDate)T00:00:00Z",
                                                    source: "import"))
                }
            }
            try await database.upsertIGAccountInsights(accountID: accountID, rows)
            summary.insightRows += rows.count
            try await database.upsertIGDemographics(accountID: accountID, page.demographicRows(fetchedDate: endDate))
            if page.heatmap.count == 168 {
                try await database.upsertIGHeatmapImport(accountID: accountID, windowEnd: endDate, counts: page.heatmap)
            }
            if summary.commitsRead % 20 == 0 { log("…\(summary.commitsRead) report versions read") }
        }

        // 4. Video-analysis sidecars: per-reel views/reach by day, keyed by
        //    the real Graph media id.
        log("IGPROGRESS:0.92:Video-analysis sidecars")
        let sidecars = (try? FileManager.default.contentsOfDirectory(atPath: repo.path))?
            .filter { $0.range(of: #"^video-analysis-\d{4}-\d{2}-\d{2}\.json$"#, options: .regularExpression) != nil }
            .sorted() ?? []
        var graphIDs = try await database.fetchIGReportMediaGraphIDs(accountID: accountID)
        var sidecarRows = 0
        for file in sidecars {
            try Task.checkCancellation()
            guard let data = FileManager.default.contents(atPath: repo.appendingPathComponent(file).path),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let reels = object["reels"] as? [[String: Any]], !reels.isEmpty else { continue }
            let date = object["date"] as? String ?? String(file.dropFirst("video-analysis-".count).prefix(10))
            var snapshots: [IGMediaInsightSnapshot] = []
            var analyses: [IGReelAnalysisRow] = []
            for reel in reels {
                guard let mediaID = reel["id"] as? String else { continue }
                let permalink = reel["permalink"] as? String
                let shortcode = IGShortcode.parse( permalink)
                var rowID = graphIDs[mediaID] ?? shortcode.flatMap { shortcodeIDs[$0] }
                if rowID == nil, let shortcode {
                    rowID = try await database.upsertIGReportMedia(IGReportMediaUpsert(
                        accountID: accountID, shortcode: shortcode, mediaID: mediaID, mediaType: "VIDEO",
                        productType: "REELS", caption: reel["caption"] as? String ?? "", captionTruncated: true,
                        permalink: permalink,
                        postedAt: (reel["timestamp"] as? String).flatMap {
                            Database.parseISODate($0) ?? ReportDates.date(fromDayKey: String($0.prefix(10)))
                        },
                        source: "import"))
                    shortcodeIDs[shortcode] = rowID
                    summary.posts += 1
                } else if graphIDs[mediaID] == nil, let shortcode, let rowID {
                    // Link the Graph id onto a row that came from the HTML.
                    _ = try await database.upsertIGReportMedia(IGReportMediaUpsert(
                        accountID: accountID, shortcode: shortcode, mediaID: mediaID, productType: "REELS",
                        captionTruncated: true, source: "import"))
                    graphIDs[mediaID] = rowID
                }
                guard let rowID else { continue }
                graphIDs[mediaID] = rowID
                // The day's AI review of the reel (score vs benchmarks, tier,
                // what worked / what to fix, top tip).
                if let score = (reel["score"] as? NSNumber)?.intValue {
                    analyses.append(IGReelAnalysisRow(
                        reportMediaID: rowID, date: date, score: score,
                        tier: reel["tier"] as? String ?? "",
                        good: (reel["good"] as? [Any])?.compactMap { $0 as? String } ?? [],
                        bad: (reel["bad"] as? [Any])?.compactMap { $0 as? String } ?? [],
                        topTip: (reel["top_tip"] as? String).flatMap { $0.isEmpty ? nil : $0 }))
                }
                for metric in ["views", "reach"] {
                    if let value = reel[metric] as? NSNumber {
                        snapshots.append(IGMediaInsightSnapshot(reportMediaID: rowID, metric: metric,
                                                                value: value.doubleValue,
                                                                fetchedAt: "\(date)T00:00:00Z", source: "import"))
                    }
                }
            }
            try await database.insertIGMediaInsightSnapshots(snapshots)
            try await database.upsertIGReelAnalyses(accountID: accountID, analyses)
            summary.reelAnalyses += analyses.count
            sidecarRows += snapshots.count
        }
        summary.insightRows += sidecarRows
        log("Read \(sidecars.count) video-analysis sidecars")

        // 5. Bookkeeping: the account's own handle tops the all-time ranking,
        //    so it starts on the ignore list.
        if try await database.fetchIGIgnoredAccounts(accountID: accountID).isEmpty {
            try await database.addIGIgnoredAccount(accountID: accountID, username: username, reason: "own account")
        }
        if let asOf = summary.asOf {
            try await database.setIGSyncState(accountID: accountID, key: "import_as_of", value: asOf)
        }
        if let head = engagementCommits.last?.sha {
            try await database.setIGSyncState(accountID: accountID, key: "import_repo_head", value: head)
        }
        log(summary.description)
        return summary
    }

    // MARK: - Git

    struct Commit: Sendable {
        var sha: String
        var date: String
    }

    /// One commit per day (the newest that day), oldest first.
    private static func commits(git: URL, repo: URL, file: String) async throws -> [Commit] {
        let result = try await ProcessRunner.run(
            executable: git,
            arguments: ["-C", repo.path, "log", "--format=%H%x09%ad", "--date=short", "--", file],
            timeout: 60)
        guard result.exitCode == 0 else {
            throw ImportError.notARepo(result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var seen: Set<String> = []
        var commits: [Commit] = []
        for line in result.stdoutText.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count == 2 else { continue }
            let date = String(parts[1])
            guard !seen.contains(date) else { continue }   // newest first → keep the day's last commit
            seen.insert(date)
            commits.append(Commit(sha: String(parts[0]), date: date))
        }
        return commits.reversed()
    }

    private static func show(git: URL, repo: URL, sha: String, file: String) async throws -> String? {
        let result = try await ProcessRunner.run(executable: git,
                                                 arguments: ["-C", repo.path, "show", "\(sha):\(file)"],
                                                 timeout: 60)
        guard result.exitCode == 0 else { return nil }
        return String(data: result.stdout, encoding: .utf8)
    }
}

// MARK: - HTML helpers

nonisolated enum ReportHTML {
    private static let cache = RegexCache()

    private final class RegexCache: @unchecked Sendable {
        private var regexes: [String: NSRegularExpression] = [:]
        private let lock = NSLock()
        func regex(_ pattern: String) -> NSRegularExpression? {
            lock.lock(); defer { lock.unlock() }
            if let cached = regexes[pattern] { return cached }
            let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
            regexes[pattern] = regex
            return regex
        }
    }

    static func capture(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let regex = cache.regex(pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > group,
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    /// All matches, each as its capture groups (index 0 = group 1).
    static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = cache.regex(pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    /// The HTML between a heading and the next `<h2>`.
    static func section(_ heading: String, in html: String) -> String? {
        guard let start = html.range(of: heading) else { return nil }
        let rest = html[start.upperBound...]
        let end = rest.range(of: "<h2")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    static func table(id: String, in html: String) -> String? {
        guard let start = html.range(of: "id=\"\(id)\"") else { return nil }
        let rest = html[start.upperBound...]
        let end = rest.range(of: "</table>")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    static func decode(_ text: String) -> String {
        var result = text
        for (entity, replacement) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                                      ("&#39;", "'"), ("&#x27;", "'"), ("&mdash;", "—"), ("&bull;", "•"),
                                      ("&nbsp;", " "), ("&#9650;", "▲")] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func int(_ text: String?) -> Int? {
        guard let text else { return nil }
        let cleaned = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "+", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(cleaned) ?? Double(cleaned).map { Int($0) }
    }

    static func json(_ literal: String?) -> Any? {
        guard let literal, let data = literal.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// "Aug 21, 2026" → "2026-08-21".
    static func isoDate(fromReportDate text: String?) -> String? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM d, yyyy"
        guard let date = formatter.date(from: text.trimmingCharacters(in: .whitespaces)) else { return nil }
        return ReportDates.dayKey(date)
    }
}

// MARK: - engagement-report.html

nonisolated struct EngagementReportParser {
    struct Post: Sendable {
        var shortcode: String
        var permalink: String
        var postedAt: Date?
        var productType: String
        var caption: String
        var metrics: [String: Int]

        func upsert(accountID: Int64) -> IGReportMediaUpsert {
            IGReportMediaUpsert(accountID: accountID, shortcode: shortcode, mediaID: nil,
                                mediaType: productType == "REELS" ? "VIDEO" : nil,
                                productType: productType, caption: caption, captionTruncated: true,
                                permalink: permalink, postedAt: postedAt,
                                likeCount: metrics["likes"], commentsCount: metrics["comments"],
                                source: "import")
        }
    }

    struct Result: Sendable {
        var generatedDate: String?
        var followerSeries: [(date: String, value: Int)] = []
        var kpis: [String: Int] = [:]
        var age: [(String, Int)] = []
        var gender: [(String, Int)] = []
        var countries: [(String, Int)] = []
        var cities: [(String, Int)] = []
        var posts: [Post] = []
        var commenters: [IGCommenterActivityRow] = []
        var rankingAllTime: [IGCommenterRankingRow] = []
        var rankingPeriod: [IGCommenterRankingRow] = []

        func demographicRows(fetchedDate: String) -> [IGDemographicRow] {
            var rows: [IGDemographicRow] = []
            func add(_ dimension: String, _ values: [(String, Int)]) {
                for (label, count) in values {
                    let value: String
                    switch (dimension, label) {
                    case ("gender", "Male"): value = "M"
                    case ("gender", "Female"): value = "F"
                    default: value = label
                    }
                    rows.append(IGDemographicRow(metric: "follower_demographics", dimension: dimension, value: value,
                                                 count: count, timeframe: "this_month", fetchedDate: fetchedDate,
                                                 source: "import"))
                }
            }
            add("age", age); add("gender", gender); add("country", countries); add("city", cities)
            return rows
        }
    }

    static func parse(_ html: String) -> Result {
        var result = Result()
        result.generatedDate = ReportHTML.isoDate(fromReportDate:
            ReportHTML.capture(#"Report generated ([A-Z][a-z]{2} \d{1,2}, \d{4})"#, in: html))

        // Follower series from the growth chart.
        if let block = ReportHTML.capture(#"getElementById\('growthChart'\)(.*?)options:"#, in: html),
           let labels = ReportHTML.json(ReportHTML.capture(#"labels:\s*(\[[^\]]*\])"#, in: block)) as? [String],
           let data = ReportHTML.json(ReportHTML.capture(#"data:\s*(\[[^\]]*\])"#, in: block)) as? [NSNumber],
           labels.count == data.count {
            result.followerSeries = zip(labels, data).map { ($0, $1.intValue) }
        }

        // KPI cards: the first stats grid.
        if let grid = ReportHTML.capture(#"<div class="stats-grid">(.*?)<h2>"#, in: html) {
            for card in ReportHTML.matches(#"<div class="value"[^>]*>([^<]*)</div>\s*<div class="label">([^<]*)</div>"#,
                                           in: grid) {
                if let value = ReportHTML.int(card[0]) { result.kpis[ReportHTML.decode(card[1])] = value }
            }
        }

        // Demographics charts.
        func chart(_ id: String) -> [(String, Int)] {
            guard let block = ReportHTML.capture("getElementById\\('\(id)'\\)(.*?)options:", in: html),
                  let labels = ReportHTML.json(ReportHTML.capture(#"labels:\s*(\[[^\]]*\])"#, in: block)) as? [String],
                  let data = ReportHTML.json(ReportHTML.capture(#"data:\s*(\[[^\]]*\])"#, in: block)) as? [NSNumber],
                  labels.count == data.count else { return [] }
            return zip(labels, data).map { ($0, $1.intValue) }
        }
        result.age = chart("ageChart")
        result.gender = chart("genderChart")
        result.countries = chart("countryChart")
        result.cities = chart("cityChart")

        // Post performance table.
        if let table = ReportHTML.table(id: "posts-table", in: html) {
            for row in ReportHTML.matches(#"<tr>(.*?)</tr>"#, in: table) {
                let cells = ReportHTML.matches(#"data-sort="([^"]*)""#, in: row[0]).map { $0[0] }
                guard cells.count >= 9,
                      let permalink = ReportHTML.capture(#"href="([^"]+)""#, in: row[0]),
                      let shortcode = IGShortcode.parse( permalink) else { continue }
                var metrics: [String: Int] = [:]
                for (index, metric) in ["reach", "views", "likes", "comments", "shares", "saved"].enumerated() {
                    if let value = ReportHTML.int(cells[3 + index]) { metrics[metric] = value }
                }
                result.posts.append(Post(shortcode: shortcode, permalink: ReportHTML.decode(permalink),
                                         postedAt: Database.parseISODate(cells[0]),
                                         productType: cells[1], caption: ReportHTML.decode(cells[2]),
                                         metrics: metrics))
            }
        }

        // Top active commenters.
        if let table = ReportHTML.table(id: "commenters-table", in: html) {
            for row in ReportHTML.matches(#"<tr>(.*?)</tr>"#, in: table) {
                let cells = ReportHTML.matches(#"data-sort="([^"]*)""#, in: row[0]).map { $0[0] }
                guard cells.count >= 5, !cells[1].isEmpty else { continue }
                let postsCell = ReportHTML.capture(#"max-width:250px;">(.*?)</td>"#, in: row[0]) ?? ""
                let posts = postsCell.components(separatedBy: "<br>").map(ReportHTML.decode).filter { !$0.isEmpty }
                result.commenters.append(IGCommenterActivityRow(username: ReportHTML.decode(cells[1]),
                                                                comments: ReportHTML.int(cells[2]) ?? 0,
                                                                replies: ReportHTML.int(cells[3]) ?? 0,
                                                                topPosts: posts))
            }
        }

        result.rankingAllTime = ranking(tableID: "ranking-alltime-table", in: html)
        result.rankingPeriod = ranking(tableID: "ranking-last30-table", in: html)
        return result
    }

    private static func ranking(tableID: String, in html: String) -> [IGCommenterRankingRow] {
        guard let table = ReportHTML.table(id: tableID, in: html) else { return [] }
        return ReportHTML.matches(#"<tr>(.*?)</tr>"#, in: table).compactMap { row in
            let cells = ReportHTML.matches(#"data-sort="([^"]*)""#, in: row[0]).map { $0[0] }
            guard cells.count >= 9, !cells[1].isEmpty else { return nil }
            return IGCommenterRankingRow(username: ReportHTML.decode(cells[1]),
                                         score: ReportHTML.int(cells[2]) ?? 0,
                                         early: ReportHTML.int(cells[3]) ?? 0,
                                         textComments: ReportHTML.int(cells[4]) ?? 0,
                                         emojiComments: ReportHTML.int(cells[5]) ?? 0,
                                         textReplies: ReportHTML.int(cells[6]) ?? 0,
                                         emojiReplies: ReportHTML.int(cells[7]) ?? 0)
        }
    }
}

// MARK: - peacegrappler-insights.html

nonisolated struct InsightsPageParser {
    struct Result: Sendable {
        var endDate: String?
        var followerTrend: [(date: String, value: Int)] = []
        var reachBreakdown: [(String, Int)] = []
        var viewsBreakdown: [(String, Int)] = []
        var interactionsBreakdown: [(String, Int)] = []
        var age: [(bucket: String, male: Int, female: Int, unknown: Int)] = []
        var gender: [(String, Int)] = []
        var heatmap: [Int] = []

        func demographicRows(fetchedDate: String) -> [IGDemographicRow] {
            var rows = age.map {
                IGDemographicRow(metric: "follower_demographics", dimension: "age", value: $0.bucket,
                                 count: $0.male + $0.female + $0.unknown, timeframe: "last_30_days",
                                 fetchedDate: fetchedDate, source: "import")
            }
            for (label, count) in gender {
                let value = label == "Male" ? "M" : label == "Female" ? "F" : "U"
                rows.append(IGDemographicRow(metric: "follower_demographics", dimension: "gender", value: value,
                                             count: count, timeframe: "last_30_days", fetchedDate: fetchedDate,
                                             source: "import"))
            }
            return rows
        }
    }

    static func parse(_ html: String) -> Result {
        var result = Result()
        if let range = ReportHTML.capture(#"class="date-range">([^<]*)<"#, in: html) {
            let parts = range.components(separatedBy: " to ")
            result.endDate = ReportHTML.isoDate(fromReportDate: parts.last)
        }
        func constant(_ name: String) -> Any? {
            ReportHTML.json(ReportHTML.capture("const \(name) = (\\[.*?\\]|\\{.*?\\});", in: html))
        }
        if let trend = constant("FOLLOWER_TREND") as? [[String: Any]] {
            result.followerTrend = trend.compactMap {
                guard let date = $0["date"] as? String, let value = $0["value"] as? NSNumber else { return nil }
                return (date, value.intValue)
            }
        }
        func breakdown(_ name: String) -> [(String, Int)] {
            ((constant(name) as? [String: Any]) ?? [:]).compactMap { key, value in
                (value as? NSNumber).map { (key, $0.intValue) }
            }.sorted { $0.0 < $1.0 }
        }
        result.reachBreakdown = breakdown("REACH_BREAKDOWN")
        result.viewsBreakdown = breakdown("VIEWS_BREAKDOWN")
        result.interactionsBreakdown = breakdown("INT_BREAKDOWN")
        if let age = constant("AGE_DIST") as? [[String: Any]] {
            result.age = age.compactMap {
                guard let bucket = $0["bucket"] as? String else { return nil }
                return (bucket, ($0["male"] as? NSNumber)?.intValue ?? 0, ($0["female"] as? NSNumber)?.intValue ?? 0,
                        ($0["unknown"] as? NSNumber)?.intValue ?? 0)
            }
        }
        result.gender = breakdown("GENDER_TOTALS")
        result.heatmap = ReportHTML.matches(#"class="heat-cell"[^>]*title="(\d+) comments""#, in: html)
            .compactMap { Int($0[0]) }
        return result
    }
}
