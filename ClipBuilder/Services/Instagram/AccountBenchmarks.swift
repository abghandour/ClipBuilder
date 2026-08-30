import Foundation

/// A reel template joined to the Instagram media it analyzed — how the
/// structural traits (hook type, cut cadence, overlays) meet the numbers.
nonisolated struct IGTemplateLink: Sendable {
    var mediaID: String
    var templateJSON: String
    var statsJSON: String?
    var duration: Double
}

/// What actually performs on THIS account, computed deterministically from
/// the Reports data (90 days of posts with insights, comments, reel
/// templates). Feeds the planner (numbers instead of the generic playbook),
/// the critic (an outcome rubric), the lesson distiller, captions (hashtags
/// and hot topics), and the publish sheet (posting times). Codable so it can
/// ride inside WizardOptions and be cached.
nonisolated struct AccountBenchmarks: Codable, Sendable, Hashable {
    struct PostingSlot: Codable, Sendable, Hashable, Identifiable {
        var weekday: Int          // 1 = Monday … 7 = Sunday (local time)
        var hour: Int             // 0–23 local
        var avgReach: Int
        var posts: Int
        var id: String { "\(weekday)-\(hour)" }

        var label: String {
            let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            return "\(days[max(0, min(6, weekday - 1))]) \(String(format: "%02d:00", hour))"
        }
    }

    struct HashtagBenchmark: Codable, Sendable, Hashable, Identifiable {
        var tag: String
        var posts: Int
        var avgReach: Int
        /// avgReach ÷ the account's median reach — >1 means the tag rides
        /// above-average posts.
        var lift: Double
        var id: String { tag.lowercased() }
    }

    struct Topic: Codable, Sendable, Hashable, Identifiable {
        var name: String
        var posts: Int
        var comments: Int
        var reach: Int
        /// Comments landing within the first hour across its posts.
        var earlyComments: Int
        var id: String { name.lowercased() }
    }

    struct ReelSummary: Codable, Sendable, Hashable, Identifiable {
        var mediaID: String?
        var shortcode: String
        var caption: String
        var reach: Int
        var views: Int
        var saves: Int
        var shares: Int
        var comments: Int
        var quality: Double
        var watchSeconds: Double?
        var duration: Double?
        var hook: String?
        var cutsPerMinute: Double?
        var id: String { shortcode }

        var line: String {
            var parts = [String(format: "quality %.1f", quality), "\(reach.formatted()) reach",
                         "\(views.formatted()) views", "\(saves) saves", "\(shares) shares", "\(comments) comments"]
            if let watchSeconds { parts.append(String(format: "%.0fs avg watch", watchSeconds)) }
            if let duration, duration > 0 { parts.append("\(Int(duration.rounded()))s long") }
            if let hook { parts.append("hook: \(hook)") }
            if let cutsPerMinute { parts.append("\(Int(cutsPerMinute.rounded())) cuts/min") }
            let text = caption.replacingOccurrences(of: "\n", with: " ")
            return "- " + parts.joined(separator: " · ") + " — \"\(String(text.prefix(90)))\""
        }
    }

    /// Where one of the account's reels sits among its peers — the ground
    /// truth the critic's forecast is calibrated against.
    struct ReelScore: Codable, Sendable, Hashable {
        var quality: Double
        /// 0–100: the share of the account's reels this one beat.
        var percentile: Int
        var stats: IGStats
    }

    var username: String
    var computedAt: Date
    var windowDays: Int
    var reelCount: Int
    var postCount: Int

    var reachMedian: Int
    var reachP75: Int
    var viewsMedian: Int
    var viewsP75: Int
    /// Per 1,000 reach, medians across reels.
    var savesPer1k: Double
    var sharesPer1k: Double
    var commentsPer1k: Double
    var qualityMedian: Double
    var qualityP75: Double
    var watchSecondsMedian: Double?
    var watchSecondsTop: Double?

    /// p25…p75 of the top-quartile reels' durations, when known.
    var durationSweetSpotMin: Int?
    var durationSweetSpotMax: Int?
    var durationTopMedian: Int?
    var cutsPerMinuteTop: Int?
    var topTraits: [String] = []
    var bottomTraits: [String] = []

    var bestPostingSlots: [PostingSlot] = []
    var bestWeekdays: [String] = []
    var topHashtags: [HashtagBenchmark] = []
    var captionLengthNote: String?
    var hotTopics: [Topic] = []
    var topReels: [ReelSummary] = []
    var bottomReels: [ReelSummary] = []
    /// Graph media id → score, for every reel in the window.
    var reelScores: [String: ReelScore] = [:]

    var hasDurationSweetSpot: Bool { durationSweetSpotMin != nil && durationSweetSpotMax != nil }

    // MARK: - Build

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }()

    static func build(inputs: IGReportInputs, gridMedia: [IGMediaRecord], templates: [IGTemplateLink],
                      now: Date = Date()) -> AccountBenchmarks? {
        var windowDays = 90
        var since = ReportDates.calendar.date(byAdding: .day, value: -windowDays, to: now) ?? now
        var posts = inputs.media.filter { !$0.isStory && ($0.postedAt ?? .distantPast) >= since }
        if posts.filter(\.isReel).count < 5 {
            windowDays = 0
            since = .distantPast
            posts = inputs.media.filter { !$0.isStory }
        }
        let reels = posts.filter { $0.isReel && ($0.reach ?? 0) > 0 }
        guard reels.count >= 5 else { return nil }

        let durations = Dictionary(gridMedia.filter { $0.duration > 0 }.map { ($0.mediaID, $0.duration) },
                                   uniquingKeysWith: { a, _ in a })
        var templateByMedia: [String: [String: Any]] = [:]
        var templateDurations: [String: Double] = [:]
        for link in templates {
            if let object = link.templateJSON.data(using: .utf8)
                .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) {
                templateByMedia[link.mediaID] = object
                if link.duration > 0 { templateDurations[link.mediaID] = link.duration }
                else if let duration = (object["duration"] as? NSNumber)?.doubleValue { templateDurations[link.mediaID] = duration }
            }
        }

        func stats(_ row: IGReportMediaRow) -> IGStats {
            var watch = row.metrics["ig_reels_avg_watch_time"]
            if let value = watch, value > 300 { watch = value / 1000 }   // Graph reports milliseconds
            return IGStats(views: row.views, likes: row.likes, comments: row.comments, shares: row.shares,
                           saves: row.saves, reach: row.reach, avgWatchTime: watch)
        }
        func quality(_ row: IGReportMediaRow) -> Double { ReelPerformance.score(stats(row)) }
        func duration(_ row: IGReportMediaRow) -> Double? {
            guard let id = row.mediaID else { return nil }
            return durations[id] ?? templateDurations[id]
        }
        func hook(_ row: IGReportMediaRow) -> String? {
            guard let id = row.mediaID, let template = templateByMedia[id],
                  let hook = template["hook"] as? [String: Any] else { return nil }
            return hook["type"] as? String
        }
        func cadence(_ row: IGReportMediaRow) -> Double? {
            guard let id = row.mediaID, let template = templateByMedia[id] else { return nil }
            return (template["cuts_per_minute"] as? NSNumber)?.doubleValue
        }
        func summary(_ row: IGReportMediaRow) -> ReelSummary {
            ReelSummary(mediaID: row.mediaID, shortcode: row.shortcode, caption: row.caption,
                        reach: row.reach ?? 0, views: row.views ?? 0, saves: row.saves ?? 0,
                        shares: row.shares ?? 0, comments: row.comments ?? 0, quality: quality(row),
                        watchSeconds: stats(row).avgWatchTime, duration: duration(row),
                        hook: hook(row), cutsPerMinute: cadence(row))
        }

        let ranked = reels.sorted { quality($0) > quality($1) }
        let qualities = ranked.map(quality)
        let reaches = reels.map { Double($0.reach ?? 0) }
        let views = reels.map { Double($0.views ?? 0) }
        func rate(_ key: (IGReportMediaRow) -> Int?) -> Double {
            median(reels.map { Double(key($0) ?? 0) / Double(max(1, $0.reach ?? 1)) * 1000 })
        }
        let watches = reels.compactMap { stats($0).avgWatchTime }

        let topCount = max(3, reels.count / 4)
        let top = Array(ranked.prefix(topCount))
        let bottom = Array(ranked.suffix(max(3, reels.count / 4)))
        var topDurations = top.compactMap(duration)
        if topDurations.count < 3 {
            // Durations are only known for probed/templated reels: fall back
            // to the better half of the reels that have one.
            let known = ranked.filter { duration($0) != nil }
            if known.count >= 4 { topDurations = known.prefix(max(3, known.count / 2)).compactMap(duration) }
        }
        let topCadences = top.compactMap(cadence)

        var benchmarks = AccountBenchmarks(
            username: inputs.account.username, computedAt: now, windowDays: windowDays,
            reelCount: reels.count, postCount: posts.count,
            reachMedian: Int(median(reaches)), reachP75: Int(percentile(reaches, 0.75)),
            viewsMedian: Int(median(views)), viewsP75: Int(percentile(views, 0.75)),
            savesPer1k: rate(\.saves), sharesPer1k: rate(\.shares), commentsPer1k: rate(\.comments),
            qualityMedian: median(qualities), qualityP75: percentile(qualities, 0.75),
            watchSecondsMedian: watches.isEmpty ? nil : median(watches),
            watchSecondsTop: top.compactMap { stats($0).avgWatchTime }.isEmpty ? nil
                : median(top.compactMap { stats($0).avgWatchTime }))

        if topDurations.count >= 3 {
            benchmarks.durationSweetSpotMin = Int(percentile(topDurations, 0.25).rounded())
            benchmarks.durationSweetSpotMax = Int(percentile(topDurations, 0.75).rounded())
            benchmarks.durationTopMedian = Int(median(topDurations).rounded())
        }
        if topCadences.count >= 3 { benchmarks.cutsPerMinuteTop = Int(median(topCadences).rounded()) }
        benchmarks.topTraits = traits(of: top, hook: hook, cadence: cadence, duration: duration, stats: stats)
        benchmarks.bottomTraits = traits(of: bottom, hook: hook, cadence: cadence, duration: duration, stats: stats)
        benchmarks.topReels = top.prefix(10).map(summary)
        benchmarks.bottomReels = bottom.suffix(5).map(summary)

        // Percentiles for calibration.
        for (index, row) in ranked.enumerated() {
            guard let id = row.mediaID else { continue }
            let beaten = ranked.count - 1 - index
            benchmarks.reelScores[id] = ReelScore(quality: quality(row),
                                                  percentile: Int((Double(beaten) / Double(max(1, ranked.count - 1)) * 100).rounded()),
                                                  stats: stats(row))
        }

        // Posting slots (local time), by weekday+hour and by weekday.
        var slots: [String: (weekday: Int, hour: Int, reach: Int, posts: Int)] = [:]
        var weekdays: [Int: (reach: Int, posts: Int)] = [:]
        for row in reels {
            guard let date = row.postedAt, let reach = row.reach else { continue }
            let weekday = (calendar.component(.weekday, from: date) + 5) % 7 + 1
            let hour = calendar.component(.hour, from: date)
            let key = "\(weekday)-\(hour)"
            var slot = slots[key] ?? (weekday, hour, 0, 0)
            slot.reach += reach; slot.posts += 1
            slots[key] = slot
            weekdays[weekday, default: (0, 0)].reach += reach
            weekdays[weekday, default: (0, 0)].posts += 1
        }
        let minimumPosts = reels.count >= 30 ? 2 : 1
        benchmarks.bestPostingSlots = slots.values.filter { $0.posts >= minimumPosts }
            .map { PostingSlot(weekday: $0.weekday, hour: $0.hour, avgReach: $0.reach / $0.posts, posts: $0.posts) }
            .sorted { $0.avgReach > $1.avgReach }.prefix(3).map { $0 }
        let dayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        benchmarks.bestWeekdays = weekdays.filter { $0.value.posts >= 2 }
            .sorted { $0.value.reach / $0.value.posts > $1.value.reach / $1.value.posts }
            .prefix(2).map { "\(dayNames[$0.key - 1]) (avg \((($0.value.reach / $0.value.posts)).formatted()) reach over \($0.value.posts) reels)" }

        // Hashtags with lift over the account's median reach.
        var tags: [String: (display: String, posts: Int, reach: Int)] = [:]
        for row in posts {
            guard let reach = row.reach else { continue }
            var seen: Set<String> = []
            for match in ReportHTML.matches(#"(#[\p{L}0-9_]+)"#, in: row.caption) {
                let key = match[0].lowercased()
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                var entry = tags[key] ?? (match[0], 0, 0)
                entry.posts += 1; entry.reach += reach
                tags[key] = entry
            }
        }
        let medianReach = max(1, benchmarks.reachMedian)
        let candidates = tags.values.filter { $0.posts >= 2 }
        benchmarks.topHashtags = (candidates.isEmpty ? Array(tags.values) : candidates)
            .map { HashtagBenchmark(tag: $0.display, posts: $0.posts, avgReach: $0.reach / $0.posts,
                                    lift: Double($0.reach / $0.posts) / Double(medianReach)) }
            .sorted { $0.lift != $1.lift ? $0.lift > $1.lift : $0.posts > $1.posts }
            .prefix(10).map { $0 }

        // Caption length.
        let short = reels.filter { $0.caption.count < 100 }.map { Double($0.reach ?? 0) }
        let long = reels.filter { $0.caption.count >= 100 }.map { Double($0.reach ?? 0) }
        if short.count >= 3, long.count >= 3 {
            let shortMedian = Int(median(short)), longMedian = Int(median(long))
            benchmarks.captionLengthNote = shortMedian > longMedian
                ? "Short captions (<100 chars) reach more here: median \(shortMedian.formatted()) vs \(longMedian.formatted()) for long ones"
                : "Longer captions (≥100 chars) reach more here: median \(longMedian.formatted()) vs \(shortMedian.formatted()) for short ones"
        }

        // Hot topics: capitalized names in captions, weighted by comments and
        // first-hour comment velocity.
        var earlyByMedia: [Int64: Int] = [:]
        for comment in inputs.comments where !comment.isReply {
            if let ref = comment.refTimestamp, comment.timestamp.timeIntervalSince(ref) <= 3600 {
                earlyByMedia[comment.reportMediaID, default: 0] += 1
            }
        }
        var topics: [String: Topic] = [:]
        let stopStarts: Set<String> = ["Para", "Que", "The", "This", "That", "With", "From", "When", "What", "Who",
                                       "How", "Follow", "Watch", "Full", "New", "Best", "Top", "Fight", "Round"]
        for row in posts {
            var seen: Set<String> = []
            for match in ReportHTML.matches(#"([A-Z][\p{L}'’-]*\p{Ll}[\p{L}'’-]*(?:\s+(?:de|da|do|dos|das|von|van|del)?\s*[A-Z][\p{L}'’-]*\p{Ll}[\p{L}'’-]*)+)"#,
                                            in: row.caption) {
                let name = match[0].trimmingCharacters(in: .whitespaces)
                let first = name.split(separator: " ").first.map(String.init) ?? ""
                guard name.count >= 5, name.count <= 40, !stopStarts.contains(first),
                      !name.uppercased().hasPrefix("UFC ") else { continue }
                let key = name.lowercased()
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                var topic = topics[key] ?? Topic(name: name, posts: 0, comments: 0, reach: 0, earlyComments: 0)
                topic.posts += 1
                topic.comments += row.comments ?? 0
                topic.reach += row.reach ?? 0
                topic.earlyComments += earlyByMedia[row.id] ?? 0
                topics[key] = topic
            }
        }
        benchmarks.hotTopics = topics.values
            .sorted { ($0.comments + $0.earlyComments * 3) > ($1.comments + $1.earlyComments * 3) }
            .prefix(8).map { $0 }
        return benchmarks
    }

    private static func traits(of reels: [IGReportMediaRow],
                               hook: (IGReportMediaRow) -> String?, cadence: (IGReportMediaRow) -> Double?,
                               duration: (IGReportMediaRow) -> Double?,
                               stats: (IGReportMediaRow) -> IGStats) -> [String] {
        guard !reels.isEmpty else { return [] }
        var lines: [String] = []
        let hooks = reels.compactMap(hook)
        if hooks.count >= 3 {
            let counts = Dictionary(grouping: hooks, by: { $0 }).mapValues(\.count)
                .sorted { $0.value > $1.value }.prefix(3)
            lines.append("hooks: " + counts.map { "\($0.key) (\($0.value) of \(hooks.count))" }.joined(separator: ", "))
        }
        let cadences = reels.compactMap(cadence)
        if cadences.count >= 2 { lines.append("cut cadence: median \(Int(median(cadences).rounded())) cuts/min") }
        let durations = reels.compactMap(duration)
        if durations.count >= 2 {
            lines.append("length: median \(Int(median(durations).rounded()))s (\(Int(durations.min()!.rounded()))–\(Int(durations.max()!.rounded()))s)")
        }
        let watches = reels.compactMap { stats($0).avgWatchTime }
        if watches.count >= 2 { lines.append(String(format: "avg watch: median %.0fs", median(watches))) }
        let saves = reels.map { Double($0.saves ?? 0) / Double(max(1, $0.reach ?? 1)) * 1000 }
        let shares = reels.map { Double($0.shares ?? 0) / Double(max(1, $0.reach ?? 1)) * 1000 }
        lines.append(String(format: "per 1k reach: %.1f saves, %.1f shares", median(saves), median(shares)))
        let captionLength = reels.map { Double($0.caption.count) }
        lines.append("caption length: median \(Int(median(captionLength))) chars")
        return lines
    }

    private static func median(_ values: [Double]) -> Double { percentile(values, 0.5) }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = p * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down)), upper = Int(position.rounded(.up))
        if lower == upper { return sorted[lower] }
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    // MARK: - Prompt blocks

    private var windowLabel: String { windowDays > 0 ? "last \(windowDays) days" : "all time" }

    /// For the planner: the account's own numbers, outranking the generic
    /// playbook wherever they disagree.
    func plannerBlock() -> String {
        var lines: [String] = []
        lines.append("Measured from @\(username)'s \(reelCount) reels (\(windowLabel)), normalized by reach. These numbers outrank the generic playbook below; a reference template or explicit user instructions still outrank them.")
        lines.append("- Typical reel: \(reachMedian.formatted()) reach / \(viewsMedian.formatted()) views (top quartile \(reachP75.formatted()) / \(viewsP75.formatted())); "
            + String(format: "%.1f saves and %.1f shares per 1k reach", savesPer1k, sharesPer1k)
            + (watchSecondsMedian.map { String(format: "; %.0fs avg watch (top reels %.0fs)", $0, watchSecondsTop ?? $0) } ?? ""))
        if let min = durationSweetSpotMin, let max = durationSweetSpotMax, let target = durationTopMedian {
            lines.append("- Length sweet spot: the top reels run \(min)–\(max)s (median \(target)s) — plan inside that unless told otherwise")
        }
        if let cuts = cutsPerMinuteTop { lines.append("- Top reels cut at ~\(cuts) cuts/min") }
        if !topTraits.isEmpty { lines.append("- TOP-QUARTILE traits: " + topTraits.joined(separator: "; ")) }
        if !bottomTraits.isEmpty { lines.append("- BOTTOM-QUARTILE traits (avoid): " + bottomTraits.joined(separator: "; ")) }
        if !topReels.isEmpty {
            lines.append("- Strongest reels:")
            lines.append(contentsOf: topReels.prefix(6).map { "  \($0.line)" })
        }
        if !bottomReels.isEmpty {
            lines.append("- Weakest reels:")
            lines.append(contentsOf: bottomReels.prefix(3).map { "  \($0.line)" })
        }
        if !hotTopics.isEmpty {
            lines.append("- Subjects drawing the most comments: "
                + hotTopics.prefix(5).map { "\($0.name) (\($0.comments) comments over \($0.posts) posts)" }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    /// For the critic: the outcome rubric to forecast against.
    func criticBlock() -> String {
        var lines: [String] = []
        lines.append("@\(username)'s audience, measured over \(reelCount) reels (\(windowLabel)): median \(reachMedian.formatted()) reach, "
            + String(format: "%.1f saves and %.1f shares per 1k reach", savesPer1k, sharesPer1k)
            + (watchSecondsMedian.map { String(format: ", %.0fs avg watch", $0) } ?? "")
            + ". Quality score = (saves×45 + shares×35 + comments×12 + likes×8) ÷ reach; median "
            + String(format: "%.1f, top quartile %.1f.", qualityMedian, qualityP75))
        if !topTraits.isEmpty { lines.append("What the top-quartile reels share: " + topTraits.joined(separator: "; ")) }
        if !bottomTraits.isEmpty { lines.append("What the bottom-quartile reels share: " + bottomTraits.joined(separator: "; ")) }
        if let min = durationSweetSpotMin, let max = durationSweetSpotMax {
            lines.append("Top reels run \(min)–\(max)s; reels well outside that band underperform here.")
        }
        if !topReels.isEmpty {
            lines.append("Reference — the account's best recent reels:")
            lines.append(contentsOf: topReels.prefix(4).map { "  \($0.line)" })
        }
        return lines.joined(separator: "\n")
    }

    /// For the lesson distiller: the evidence base, with traits attached.
    func lessonsBlock() -> String {
        var lines: [String] = ["## ACCOUNT BENCHMARKS (@\(username), \(windowLabel), \(reelCount) reels)"]
        lines.append(plannerBlock())
        let lifting = topHashtags.filter { $0.lift >= 1 }
        if !lifting.isEmpty {
            lines.append("- Hashtags with the best reach lift: "
                + lifting.prefix(6).map { String(format: "%@ (%.1f× median reach, %d posts)", $0.tag, $0.lift, $0.posts) }
                    .joined(separator: ", "))
        }
        if !bestPostingSlots.isEmpty {
            lines.append("- Best posting slots (local time): "
                + bestPostingSlots.map { "\($0.label) (avg \($0.avgReach.formatted()) reach, \($0.posts) reels)" }.joined(separator: ", "))
        }
        if let captionLengthNote { lines.append("- \(captionLengthNote)") }
        return lines.joined(separator: "\n")
    }

    /// For captions: what the audience responds to.
    func captionBlock() -> String {
        var lines: [String] = []
        let lifting = topHashtags.filter { $0.lift >= 1 }
        if !lifting.isEmpty {
            lines.append("- Hashtags that ride this account's best-reaching posts (prefer these over generic ones): "
                + lifting.prefix(8).map { String(format: "%@ (%.1f× median reach)", $0.tag, $0.lift) }.joined(separator: ", "))
        }
        if !hotTopics.isEmpty {
            lines.append("- Names/subjects that draw the most comments here: "
                + hotTopics.prefix(5).map { "\($0.name) (\($0.comments) comments)" }.joined(separator: ", ")
                + " — name them when the reel is about them")
        }
        if let captionLengthNote { lines.append("- \(captionLengthNote)") }
        if lines.isEmpty { return "" }
        return "\nWhat performs on this account (measured, \(windowLabel)):\n" + lines.joined(separator: "\n") + "\n"
    }

    /// Short lines for the Reports UI and the gap report.
    var summaryLines: [String] {
        var lines: [String] = []
        lines.append("\(reelCount) reels analyzed (\(windowLabel)) · median \(reachMedian.formatted()) reach · "
            + String(format: "%.1f saves & %.1f shares per 1k reach", savesPer1k, sharesPer1k))
        if let min = durationSweetSpotMin, let max = durationSweetSpotMax, let target = durationTopMedian {
            lines.append("Length sweet spot \(min)–\(max)s (top reels median \(target)s)")
        }
        if let cuts = cutsPerMinuteTop { lines.append("Top reels cut at ~\(cuts) cuts/min") }
        if !bestPostingSlots.isEmpty {
            lines.append("Best posting slots: " + bestPostingSlots.map(\.label).joined(separator: ", ") + " (local)")
        }
        if !bestWeekdays.isEmpty { lines.append("Best days: " + bestWeekdays.joined(separator: "; ")) }
        if !topHashtags.isEmpty {
            lines.append("Hashtags with lift: " + topHashtags.prefix(5).map { String(format: "%@ %.1f×", $0.tag, $0.lift) }.joined(separator: ", "))
        }
        if !hotTopics.isEmpty {
            lines.append("Hot subjects: " + hotTopics.prefix(4).map(\.name).joined(separator: ", "))
        }
        if let captionLengthNote { lines.append(captionLengthNote) }
        return lines
    }
}
