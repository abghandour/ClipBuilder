import Foundation

nonisolated enum CriticAgreement {
    struct Pair: Sendable, Hashable {
        var chosen: Int64
        var rejected: Int64
    }

    struct Row: Codable, Sendable {
        var id: Int64
        var favorite: Bool
        var audience: Int?
        var without: ReelCritique
        var with: ReelCritique
    }

    struct Metrics: Sendable {
        var pairCount: Int
        var pairwise: Double?
        var scoreSpearman: Double?
        var forecastSpearman: Double?
        var favoriteGap: Double?
    }

    struct Decision: Codable, Sendable {
        var briefKey: String
        var measuredAt: Date
        var passed: Bool
        var reportPath: String
        var briefBuiltAt: Date? = nil
    }

    static func metrics(rows: [Row], pairs: [Pair], withBrief: Bool) -> Metrics {
        let scores = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, withBrief ? $0.with : $0.without) })
        let validPairs = pairs.compactMap { pair -> (Int, Int)? in
            guard let chosen = scores[pair.chosen], let rejected = scores[pair.rejected] else { return nil }
            return (chosen.score, rejected.score)
        }
        let wins = validPairs.filter { $0.0 > $0.1 }.count
        let audienceRows = rows.compactMap { row -> (Double, ReelCritique)? in
            guard let audience = row.audience else { return nil }
            return (Double(audience), withBrief ? row.with : row.without)
        }
        let scoreCorrelation = spearman(audienceRows.map { $0.0 }, audienceRows.map { Double($0.1.score) })
        let forecasts = audienceRows.compactMap { item -> (Double, Double)? in
            item.1.forecast.map { (item.0, Double($0)) }
        }
        let forecastCorrelation = spearman(forecasts.map { $0.0 }, forecasts.map { $0.1 })
        let starred = rows.filter(\.favorite).map { Double((withBrief ? $0.with : $0.without).score) }
        let unstarred = rows.filter { !$0.favorite }.map { Double((withBrief ? $0.with : $0.without).score) }
        return Metrics(pairCount: validPairs.count,
            pairwise: validPairs.isEmpty ? nil : Double(wins) / Double(validPairs.count),
            scoreSpearman: scoreCorrelation, forecastSpearman: forecastCorrelation,
            favoriteGap: starred.isEmpty || unstarred.isEmpty ? nil
                : starred.reduce(0, +) / Double(starred.count) - unstarred.reduce(0, +) / Double(unstarred.count))
    }

    /// Average ranks for ties, then Pearson correlation of ranks.
    static func spearman(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 2, (x + y).allSatisfy(\.isFinite) else { return nil }
        func ranks(_ values: [Double]) -> [Double] {
            let indices = values.indices.sorted { values[$0] < values[$1] }
            var result = Array(repeating: 0.0, count: values.count)
            var first = 0
            while first < indices.count {
                var end = first + 1
                while end < indices.count && values[indices[end]] == values[indices[first]] { end += 1 }
                let rank = Double(first + end - 1) / 2
                for index in first..<end { result[indices[index]] = rank }
                first = end
            }
            return result
        }
        let a = ranks(x), b = ranks(y)
        let mean = Double(x.count - 1) / 2
        var covariance = 0.0, aa = 0.0, bb = 0.0
        for index in a.indices {
            let dx = a[index] - mean, dy = b[index] - mean
            covariance += dx * dy; aa += dx * dx; bb += dy * dy
        }
        guard aa > 0, bb > 0 else { return nil }
        return covariance / sqrt(aa * bb)
    }

    static func keep(without: Metrics, with: Metrics) -> Bool {
        if without.pairCount >= 8 {
            guard let before = without.pairwise, let after = with.pairwise else { return false }
            return after - before >= 0.10 - 1e-12
        }
        guard let before = without.scoreSpearman, let after = with.scoreSpearman else { return false }
        return after - before >= 0.15 - 1e-12
    }

    static func holdout(videos: [GeneratedVideoRecord], exemplarIDs: Set<String>,
                        existingPaths: Set<String>, exemplarPaths: Set<String> = [], limit: Int = 24) -> [GeneratedVideoRecord] {
        let teacherBatches = Set(videos.filter { exemplarIDs.contains("generated:\($0.id)") }.compactMap(\.batchID))
        // Favorite is the binary label present on every generated row, including false.
        var seen: Set<Int64> = []
        return Array(videos.filter {
            existingPaths.contains($0.path) && !exemplarPaths.contains($0.path) && !exemplarIDs.contains("generated:\($0.id)")
                && !($0.batchID.map { teacherBatches.contains($0) } ?? false)
        }.sorted {
            if $0.generatedAt != $1.generatedAt { return ($0.generatedAt ?? "") > ($1.generatedAt ?? "") }
            return $0.id > $1.id
        }.filter { seen.insert($0.id).inserted }.prefix(max(0, limit)))
    }

    static func report(rows: [Row], pairs: [Pair], brief: CriticBrief) -> (text: String, passed: Bool) {
        let without = metrics(rows: rows, pairs: pairs, withBrief: false)
        let with = metrics(rows: rows, pairs: pairs, withBrief: true)
        let passed = keep(without: without, with: with)
        func number(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "unavailable" }
        var lines = ["# Critic agreement", "", "Brief: \(brief.key)",
            "Exemplars: " + brief.exemplars.map(\.id).joined(separator: ", "),
            "", passed ? "Keep rule passed: critique loops use this brief by default."
                : "Keep rule did not pass: brief remains available; critique loops default to without brief.",
            "", "| Metric | Without brief | With brief |", "| --- | ---: | ---: |",
            "| Pairwise agreement (\(without.pairCount) pairs) | \(number(without.pairwise)) | \(number(with.pairwise)) |",
            "| Spearman: audience / score | \(number(without.scoreSpearman)) | \(number(with.scoreSpearman)) |",
            "| Spearman: audience / forecast | \(number(without.forecastSpearman)) | \(number(with.forecastSpearman)) |",
            "| Mean starred − unstarred score | \(number(without.favoriteGap)) | \(number(with.favoriteGap)) |",
            "", "Keep rule: ≥10 percentage points pairwise improvement with ≥8 pairs; otherwise ≥0.15 audience/score Spearman improvement. Tied pair scores are not wins.",
            "", "| Reel | Starred | Audience | Score without / with | Forecast without / with | Judge without / with |",
            "| --- | --- | ---: | --- | --- | --- |"]
        for row in rows {
            func judge(_ c: ReelCritique) -> String { "\(c.provider ?? "unknown") / \(c.model ?? "default")" }
            lines.append("| \(row.id) | \(row.favorite) | \(row.audience.map(String.init) ?? "—") | \(row.without.score) / \(row.with.score) | \(row.without.forecast.map(String.init) ?? "—") / \(row.with.forecast.map(String.init) ?? "—") | \(judge(row.without)) / \(judge(row.with)) |")
        }
        return (lines.joined(separator: "\n") + "\n", passed)
    }
}
