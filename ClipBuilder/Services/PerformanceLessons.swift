import Foundation

/// Instagram performance → wizard lessons: correlates published reels'
/// insights (and the account's own reels) with their traits and distills
/// short lessons about what actually performs for THIS account. Lessons land
/// in the wizard's Learned Lessons, tagged so a re-distill replaces only its
/// own previous batch.
nonisolated enum PerformanceLessons {

    /// Evidence prefix marking lessons this pass owns — replaced wholesale
    /// on the next distill, never touching review-distilled or pinned ones.
    static let evidencePrefix = "Instagram performance"
    static let maxLessons = 5

    static func prompt(published: [GeneratedVideoRecord], ownMedia: [IGMediaRecord],
                       benchmarks: AccountBenchmarks? = nil) -> String {
        var sections: [String] = []
        if let benchmarks {
            sections.append(benchmarks.lessonsBlock())
        }

        if !published.isEmpty {
            let lines = published.map { video in
                var line = "- \(video.filename) | \(Int(video.duration))s"
                if let stats = video.instagramStats {
                    line += String(format: " | quality %.1f", ReelPerformance.score(stats))
                    if let views = stats.views { line += " | \(views) views" }
                    if let saves = stats.saves { line += " | \(saves) saves" }
                    if let shares = stats.shares { line += " | \(shares) shares" }
                    if let watch = stats.avgWatchTime, video.duration > 0 {
                        line += String(format: " | %.0f%% avg watch", min(200, watch / video.duration * 100))
                    }
                }
                if let critique = video.critique {
                    line += " | critic \(critique.score)/100"
                }
                if let rationale = video.rationale, !rationale.isEmpty {
                    line += " | plan: \(String(rationale.prefix(160)))"
                }
                if !video.caption.isEmpty {
                    line += " | caption: \(String(video.caption.prefix(100)))"
                }
                return line
            }
            sections.append("## REELS THIS APP GENERATED AND PUBLISHED (with their Instagram insights)\n"
                            + lines.joined(separator: "\n"))
        }

        if !ownMedia.isEmpty {
            let ranked = ownMedia
                .sorted { ReelPerformance.score($0.stats) > ReelPerformance.score($1.stats) }
            let top = ranked.prefix(10)
            let bottom = ranked.count > 12 ? ranked.suffix(5) : []
            func line(_ media: IGMediaRecord) -> String {
                var line = String(format: "- quality %.1f | %ds", ReelPerformance.score(media.stats),
                                  Int(media.duration))
                if let views = media.stats.views { line += " | \(views) views" }
                if !media.caption.isEmpty { line += " | \(String(media.caption.prefix(120)))" }
                return line
            }
            sections.append("## THE ACCOUNT'S STRONGEST REELS (normalized save/share/comment quality)\n"
                            + top.map(line).joined(separator: "\n"))
            if !bottom.isEmpty {
                sections.append("## THE ACCOUNT'S WEAKEST REELS\n"
                                + bottom.map(line).joined(separator: "\n"))
            }
        }

        return """
        You are studying what performs on ONE specific Instagram account so a reel-planning AI can build more of it. Correlate the performance numbers below with the reels' traits — length, hook type, cut cadence, content type, people, caption style, hashtags, posting time — and distill what actually drives saves, shares, and watch time HERE. Where the measured benchmarks and the individual reels disagree, trust the benchmarks (they cover more reels).

        \(sections.joined(separator: "\n\n"))

        Return ONLY a JSON object with at most \(maxLessons) lessons:
        {"lessons": [{"text": "<one imperative sentence the planner can follow>", "evidence": "<the specific numbers/reels backing it>"}]}
        Every lesson must be backed by the data above — no generic social-media advice. Fewer, better-evidenced lessons beat filler.
        """
    }

    static func parse(_ response: String) -> [(text: String, evidence: String)] {
        guard let object = AIResponseParser.jsonObject(from: response),
              let raw = object["lessons"] as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let text = (entry["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return (text, (entry["evidence"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
    }
}
