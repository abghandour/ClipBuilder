import Foundation

/// A deterministic release gate for Wizard renders. It deliberately avoids
/// asking another model to judge its own work: factual, framing and source
/// quality signals are already available from analysis and the final file.
nonisolated struct ReelQualityReport: Codable, Sendable, Hashable {
    enum Verdict: String, Codable, Sendable {
        case publishable
        case reviewRequired = "review_required"
        case blocked
    }

    var score: Int
    var verdict: Verdict
    var checks: [String]
    var warnings: [String]
    var failures: [String]

    var summary: String {
        "Quality \(score)/100 · \(verdict.rawValue.replacingOccurrences(of: "_", with: " "))"
    }
}

nonisolated enum ReelQualityGate {
    /// Safe, repeatable checks that can run on every render. A report does
    /// not claim that a reel will perform well; it prevents clearly weak or
    /// technically invalid output from being silently published.
    static func evaluate(plan: WizardPlan, scenes: [Int64: SceneRecord],
                         output: URL, duration: Double, options: WizardOptions) -> ReelQualityReport {
        var score = 100
        var checks: [String] = []
        var warnings: [String] = []
        var failures: [String] = []

        if FileManager.default.fileExists(atPath: output.path), duration >= 3, duration <= 900 {
            checks.append("Playable vertical reel duration: \(String(format: "%.1f", duration))s")
        } else {
            failures.append("Rendered file is missing, empty, or outside Instagram's supported reel duration.")
        }
        guard let hook = plan.clips.first, let hookScene = scenes[hook.sceneID] else {
            failures.append("No verified opening clip was produced.")
            return ReelQualityReport(score: 0, verdict: .blocked, checks: checks,
                                     warnings: warnings, failures: failures)
        }

        let hookScore = hookScene.score ?? 0
        if hookScore >= 7 || hookScene.tags.contains("highlight") {
            checks.append("Opening uses a high-impact analyzed moment")
        } else {
            score -= 18
            warnings.append("Opening clip is not tagged as a strong highlight; review the first 1–2 seconds.")
        }

        let selected = plan.clips.compactMap { scenes[$0.sceneID] }
        let lowQuality = selected.filter { $0.tags.contains("low-quality") }
        if !lowQuality.isEmpty {
            score -= min(30, lowQuality.count * 10)
            warnings.append("\(lowQuality.count) selected clip(s) were analyzed as low-quality footage.")
        } else {
            checks.append("No selected source range is marked low-quality")
        }
        let riskyWide = selected.filter { $0.wide && $0.tags.contains("portrait-fit:poor") }
        if !riskyWide.isEmpty && !options.centerStageWide && !options.allowWideSplit {
            score -= min(20, riskyWide.count * 8)
            warnings.append("\(riskyWide.count) wide clip(s) may crop fighters out in 9:16; use Center Stage or replace them.")
        } else if !riskyWide.isEmpty {
            checks.append("Risky wide framing is mitigated by Center Stage or split-screen")
        }

        if options.enableTextOverlays && plan.clips.contains(where: { $0.textOverlay != nil }) {
            checks.append("Hook/context text is rendered in the top safe area")
        }
        if options.addCaptions { checks.append("Spoken captions are burned in") }
        if plan.musicName != nil { checks.append("Music selected with beat-aware cut planning") }
        if plan.clips.contains(where: \.replay) { checks.append("Single payoff replay is present") }

        score = max(0, min(100, score))
        let verdict: ReelQualityReport.Verdict = !failures.isEmpty ? .blocked
            : score >= 85 ? .publishable : .reviewRequired
        return ReelQualityReport(score: score, verdict: verdict, checks: checks,
                                 warnings: warnings, failures: failures)
    }
}

/// Normalized performance, so a small account's great reel can teach the
/// wizard alongside a large account's high-view reel. It intentionally uses
/// only metrics supplied by the official Graph integration.
nonisolated enum ReelPerformance {
    static func score(_ stats: IGStats) -> Double {
        let denominator = Double(max(stats.reach ?? stats.views ?? 0, 1))
        let saves = Double(stats.saves ?? 0) / denominator
        let shares = Double(stats.shares ?? 0) / denominator
        let comments = Double(stats.comments ?? 0) / denominator
        let likes = Double(stats.likes ?? 0) / denominator
        // Weighted toward the actions that indicate durable value/discovery.
        return (saves * 45 + shares * 35 + comments * 12 + likes * 8) * 100
    }

    static func label(_ stats: IGStats, duration: Double) -> String {
        var parts: [String] = [String(format: "%.1f quality score", score(stats))]
        if let reach = stats.reach { parts.append("\(reach.formatted()) reach") }
        if let saves = stats.saves { parts.append("\(saves.formatted()) saves") }
        if let shares = stats.shares { parts.append("\(shares.formatted()) shares") }
        if let watch = stats.avgWatchTime, duration > 0 {
            parts.append(String(format: "%.0f%% avg watch", min(200, watch / duration * 100)))
        }
        return parts.joined(separator: " · ")
    }
}
