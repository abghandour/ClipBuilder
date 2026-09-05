import Foundation

nonisolated enum PerformanceAnalytics {
    static func build(
        videos: [GeneratedVideoRecord], traits: [Int64: PublishedEditTraits],
        people: [PersonRecord], followersGained: Int
    ) -> EditingPerformanceInsights {
        let linked = videos.compactMap { video -> (GeneratedVideoRecord, PublishedEditTraits, IGStats)? in
            guard let trait = traits[video.id], let stats = video.instagramStats else { return nil }
            return (video, trait, stats)
        }
        let names = Dictionary(uniqueKeysWithValues: people.map { ($0.key, $0.displayName) })
        let totalReach = max(1, linked.reduce(0) { $0 + Double($1.2.reach ?? 0) })
        var athletes: [String: EditingPerformanceInsights.Athlete] = [:]
        for (_, trait, stats) in linked {
            for key in trait.peopleKeys {
                var row =
                    athletes[key]
                    ?? .init(
                        key: key, name: names[key] ?? key,
                        appearances: 0, followersGained: 0,
                        views: 0, reach: 0, watchTime: 0,
                        shares: 0, saves: 0, comments: 0)
                row.appearances += 1
                let reach = Double(stats.reach ?? 0)
                row.followersGained += Double(followersGained) * reach / totalReach
                row.views += Double(stats.views ?? 0)
                row.reach += reach
                row.watchTime += stats.avgWatchTime ?? 0
                row.shares += Double(stats.shares ?? 0)
                row.saves += Double(stats.saves ?? 0)
                row.comments += Double(stats.comments ?? 0)
                athletes[key] = row
            }
        }
        let normalized: [EditingPerformanceInsights.Athlete] = athletes.values.map { row in
            let count = Double(max(1, row.appearances))
            let followers = row.followersGained / count
            let views = row.views / count
            let reach = row.reach / count
            let watchTime = row.watchTime / count
            let shares = row.shares / count
            let saves = row.saves / count
            let comments = row.comments / count
            return EditingPerformanceInsights.Athlete(
                key: row.key, name: row.name, appearances: row.appearances,
                followersGained: followers, views: views, reach: reach,
                watchTime: watchTime, shares: shares, saves: saves, comments: comments
            )
        }.sorted { $0.reach > $1.reach }

        var buckets: [String: [(IGStats, PublishedEditTraits)]] = [:]
        for (_, trait, stats) in linked {
            buckets["Hook|\(trait.hookType)", default: []].append((stats, trait))
            let hookLength =
                trait.hookLength < 1.5
                ? "Under 1.5s"
                : trait.hookLength <= 2.5 ? "1.5–2.5s" : "Over 2.5s"
            buckets["Hook length|\(hookLength)", default: []].append((stats, trait))
            let layout = trait.screenSeconds.max(by: { $0.value < $1.value })?.key ?? "full"
            buckets["Screen|\(layout)", default: []].append((stats, trait))
            let cadence =
                trait.cutCadence >= 25
                ? "Fast · 25+ cuts/min"
                : trait.cutCadence >= 17 ? "Medium · 17–24 cuts/min" : "Measured · under 17 cuts/min"
            buckets["Cadence|\(cadence)", default: []].append((stats, trait))
            buckets["Pace curve|\(trait.paceCurve)", default: []].append((stats, trait))
            for personKey in trait.peopleKeys {
                buckets["Athlete|\(names[personKey] ?? personKey)", default: []].append((stats, trait))
            }
            for (target, count) in trait.cutTargets where count > 0 {
                buckets["Cut target|\(target)", default: []].append((stats, trait))
            }
        }
        let patterns = buckets.map { key, rows -> EditingPerformanceInsights.Pattern in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            return .init(
                dimension: parts[0], value: parts[1], reels: rows.count,
                averageWatchTime: rows.reduce(0) { $0 + ($1.0.avgWatchTime ?? 0) } / Double(rows.count),
                averageReach: rows.reduce(0) { $0 + Double($1.0.reach ?? 0) } / Double(rows.count))
        }.sorted { ($0.dimension, -$0.averageReach) < ($1.dimension, -$1.averageReach) }
        func winner(_ dimension: String) -> EditingPerformanceInsights.Pattern? {
            patterns.filter { $0.dimension == dimension }
                .max { lhs, rhs in
                    lhs.averageWatchTime == rhs.averageWatchTime
                        ? lhs.averageReach < rhs.averageReach
                        : lhs.averageWatchTime < rhs.averageWatchTime
                }
        }
        let cadenceWinner = linked.max { lhs, rhs in
            let lhsWatch = lhs.2.avgWatchTime ?? 0
            let rhsWatch = rhs.2.avgWatchTime ?? 0
            return lhsWatch == rhsWatch
                ? (lhs.2.reach ?? 0) < (rhs.2.reach ?? 0)
                : lhsWatch < rhsWatch
        }
        return .init(
            athletes: normalized, patterns: patterns,
            suggestedHook: winner("Hook")?.value,
            suggestedLayout: winner("Screen")?.value,
            suggestedCadence: cadenceWinner?.1.cutCadence)
    }
}
