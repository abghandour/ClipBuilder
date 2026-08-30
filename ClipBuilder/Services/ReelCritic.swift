import Foundation

/// The AI critic's verdict on one rendered reel. Unlike ReelQualityGate's
/// deterministic checks, this judges the actual rendered pixels — cuts,
/// framing, text legibility, hook impact — against the profile's taste.
nonisolated struct ReelCritique: Codable, Sendable, Hashable {
    /// 0–100. 85+ reads as "publish as is".
    var score: Int
    /// One-line verdict for cards and logs.
    var summary: String
    var strengths: [String]
    var issues: [String]
    /// Planner-facing improvement notes — these ride into the re-plan prompt.
    var notes: [String]
    /// The critic's recommendation to build another version.
    var regenerate: Bool
    /// 0–100: how the critic expects THIS account's audience to respond
    /// (saves, shares, watch-through), judged against the account
    /// benchmarks. Nil when no benchmarks were available.
    var forecast: Int? = nil
    var forecastReasons: [String]? = nil
    /// Which judge produced this review.
    var provider: String?
    var model: String?

    var shortLabel: String {
        "AI critique \(score)/100" + (forecast.map { " · forecast \($0)" } ?? "")
    }
}

/// Watches a rendered reel (sampled frames + the plan that produced it) and
/// returns a structured review. The judge task ("critique") is dispatched
/// through the normal model chain, which deliberately leads with a different
/// model than planning so the planner never grades its own work.
nonisolated enum ReelCritic {

    /// Frame timestamps: the hook is sampled densely (the first 2 seconds
    /// decide whether a viewer stays), then the body evenly, capped so the
    /// payload stays affordable.
    static func sampleTimes(duration: Double) -> [Double] {
        guard duration > 0.5 else { return [max(0, duration / 2)] }
        var times: [Double] = [0.3, 1.0, 1.8].filter { $0 < duration - 0.1 }
        let bodyStart = 2.5
        if duration > bodyStart + 0.5 {
            let bodyCount = 9
            let span = duration - 0.3 - bodyStart
            let step = max(span / Double(bodyCount - 1), 0.5)
            var t = bodyStart
            while t < duration - 0.2, times.count < 12 {
                times.append(t)
                t += step
            }
        }
        // Always include the ending — a flat last second is a common miss.
        if let last = times.last, duration - 0.4 - last > 0.5 {
            times.append(duration - 0.4)
        }
        return times
    }

    /// Review one rendered version. `attempt` is 1-based; earlier critiques
    /// ride along so the judge knows what was already tried and doesn't ask
    /// for the same fix twice.
    static func critique(video: URL, duration: Double,
                         plan: WizardPlan, sceneMap: [Int64: SceneRecord],
                         options: WizardOptions, profile: BrandProfile,
                         attempt: Int, previous: [ReelCritique],
                         ai: AIService,
                         emit: @escaping @Sendable (String) -> Void) async throws -> ReelCritique {
        var frames: [AIFrame] = []
        for time in sampleTimes(duration: duration) {
            if let jpeg = await ThumbnailService.jpegFrame(url: video, at: time,
                                                          maxDimension: 512, quality: 0.7) {
                frames.append(AIFrame(jpeg: jpeg, label: String(format: "%.1fs", time)))
            }
        }
        guard !frames.isEmpty else {
            throw AIError.unusableResponse("Could not sample frames from the rendered reel for critique.")
        }
        emit("Critique: reviewing \(frames.count) frames of the rendered reel...")

        let response = try await ai.call(prompt: prompt(duration: duration, plan: plan,
                                                        sceneMap: sceneMap, options: options,
                                                        profile: profile, attempt: attempt,
                                                        previous: previous),
                                         task: "critique", frames: frames,
                                         timeout: 180, log: emit)
        guard let object = AIResponseParser.jsonObject(from: response.text) else {
            throw AIError.unusableResponse("The critic's response was not valid JSON.")
        }
        func strings(_ key: String) -> [String] {
            (object[key] as? [Any])?.compactMap { $0 as? String } ?? []
        }
        let score = max(0, min(100, (object["score"] as? NSNumber)?.intValue ?? 0))
        var critique = ReelCritique(
            score: score,
            summary: (object["summary"] as? String) ?? "",
            strengths: strings("strengths"),
            issues: strings("issues"),
            notes: strings("notes"),
            regenerate: (object["regenerate"] as? Bool)
                ?? ((object["regenerate"] as? NSNumber)?.boolValue ?? false),
            forecast: options.accountBenchmarks == nil ? nil
                : (object["engagement_forecast"] as? NSNumber).map { max(0, min(100, $0.intValue)) },
            forecastReasons: strings("forecast_reasons").isEmpty ? nil : strings("forecast_reasons"),
            provider: response.provider,
            model: response.model)
        // A judge that likes the reel doesn't get to demand a rebuild, and a
        // rebuild request without notes gives the planner nothing to fix.
        if critique.score >= 85 { critique.regenerate = false }
        if critique.regenerate && critique.notes.isEmpty && critique.issues.isEmpty {
            critique.regenerate = false
        }
        // A weak engagement forecast is a reason to try again even when the
        // craft is fine; its reasons ride into the re-plan as notes.
        if let reasons = critique.forecastReasons, !reasons.isEmpty {
            critique.notes += reasons.map { "Engagement: \($0)" }
        }
        if let forecast = critique.forecast, forecast < 55, critique.score < 92, !critique.notes.isEmpty {
            critique.regenerate = true
        }
        return critique
    }

    private static func prompt(duration: Double, plan: WizardPlan,
                               sceneMap: [Int64: SceneRecord],
                               options: WizardOptions, profile: BrandProfile,
                               attempt: Int, previous: [ReelCritique]) -> String {
        var lines: [String] = []
        lines.append("""
        You are a ruthless short-form editor reviewing a rendered Instagram fight reel \
        before it ships. The attached images are frames sampled from the FINAL rendered \
        video (labels are timestamps). Judge the rendered result, not the intent: hook \
        impact in the first 2 seconds, pacing and cut rhythm, 9:16 framing (are the \
        fighters fully in frame?), text overlay legibility over the footage, escalation \
        toward a payoff, and the ending. Be specific and be strict — a mediocre reel \
        should not score above 70.
        """)
        lines.append("\n## The reel")
        lines.append("- Rendered duration: \(String(format: "%.1f", duration))s"
            + (options.targetDurationSeconds.map { " (target \($0)s)" } ?? ""))
        lines.append("- Music: \(plan.musicName ?? "none") · Captions: \(options.addCaptions ? "on" : "off") · Text overlays: \(options.enableTextOverlays ? "on" : "off")")
        lines.append("- Planner's strategy: \(plan.rationale)")
        lines.append("\n## Planned clips (what each moment is supposed to be)")
        for (index, clip) in plan.clips.enumerated() {
            let scene = sceneMap[clip.sceneID]
            var line = "\(index + 1). \(String(format: "%.1f", (clip.end - clip.start) / clip.speed))s"
            if clip.speed != 1 { line += " at \(clip.speed)×" }
            if let tags = scene?.tags, !tags.isEmpty {
                line += " — \(tags.prefix(6).joined(separator: ", "))"
            }
            if let reason = clip.reason, !reason.isEmpty { line += " — planner: \(reason)" }
            lines.append(line)
        }
        if !profile.tasteRubric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("\n## The owner's taste (judge against THIS, not your own)")
            lines.append(profile.tasteRubric)
        }
        if !profile.houseStyle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("\n## House style")
            lines.append(profile.houseStyle)
        }
        if let benchmarks = options.accountBenchmarks {
            lines.append("\n## This account's audience (forecast against THIS, not generic best practice)")
            lines.append(benchmarks.criticBlock())
        }
        if !previous.isEmpty {
            lines.append("\n## Earlier versions of this same run")
            for (index, earlier) in previous.enumerated() {
                lines.append("Version \(index + 1) scored \(earlier.score)/100 — issues then: "
                    + (earlier.issues.isEmpty ? "none listed" : earlier.issues.joined(separator: "; ")))
            }
            lines.append("This is version \(attempt). Score it absolutely (do not grade on improvement), and only request regeneration if a MATERIALLY better reel is plausible from the same footage.")
        }
        lines.append("""

        ## Answer with STRICT JSON only — no prose outside the JSON
        {
          "score": <0-100>,
          "summary": "<one sentence verdict>",
          "strengths": ["<what genuinely works>"],
          "issues": ["<specific problems visible in the rendered frames>"],
          "notes": ["<concrete, actionable instructions for the planner's next attempt — name clips by number>"],
          "regenerate": <true only if score < 85 AND the issues are fixable by re-planning from the same footage>,
          "engagement_forecast": <0-100: how THIS account's audience will respond (saves, shares, watch-through), judged against the account benchmarks above — 50 = a typical reel for the account, 75+ = top quartile; omit when no benchmarks were given>,
          "forecast_reasons": ["<what in the rendered reel drives or drags the forecast, tied to the top/bottom-quartile traits — specific, actionable for the planner>"]
        }
        """)
        return lines.joined(separator: "\n")
    }
}
