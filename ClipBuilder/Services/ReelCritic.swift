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
    var briefKey: String? = nil
    var scope: ReelCritic.Scope? = nil

    var shortLabel: String {
        (scope.map { $0 == .content ? "Content " : "Presentation " } ?? "AI critique ") + "\(score)/100" + (forecast.map { " · forecast \($0)" } ?? "")
    }
}

/// Watches a rendered reel (sampled frames + the plan that produced it) and
/// returns a structured review. The judge task ("critique") is dispatched
/// through the normal model chain, which deliberately leads with a different
/// model than planning so the planner never grades its own work.
nonisolated enum ReelCritic {
    enum Scope: String, Codable, Sendable {
        case content, presentation

        var rubric: String {
            switch self {
            case .content:
                "Selection: choose compelling, relevant footage.\nStory: a strong opening hook, clear progression, complete exchanges and a satisfying payoff.\nTiming: source in/out points, order and purposeful replays."
            case .presentation:
                "Framing: keep subjects visible and camera movement comfortable.\nCaptions: accurate, readable and within safe areas when enabled.\nOverlays: legible placement, animation and contrast when enabled.\nBranding: consistent identity and unobtrusive bumpers when enabled.\nFinish: transitions, audio balance and encode quality."
            }
        }

        /// Learned taste is free-form text. Drop lines belonging to the other
        /// stage, including mixed lines, instead of leaking its rubric back in.
        func filtered(_ text: String) -> String {
            let excluded = self == .content
                ? ["caption", "branding", "brand", "watermark", "overlay", "font", "typograph", "safe area", "safe-area", "framing", "camera", "transition", "music", "audio", "bumper", "color", "colour", "legib", "resolution", "encode"]
                : ["selection", "story", "hook", "payoff", "narrative", "escalat", "footage choice", "choose footage", "clip choice", "opening", "ending", "exchange", "replay", "pacing", "cut rhythm"]
            return text.components(separatedBy: .newlines).filter { line in
                !excluded.contains { line.localizedCaseInsensitiveContains($0) }
            }.joined(separator: "\n")
        }
    }


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
                         emit: @escaping @Sendable (String) -> Void,
                         database: Database? = nil, generatedID: Int64? = nil,
                         brief: CriticBrief? = nil, referenceFrames: [AIFrame] = [],
                         scope: Scope = .presentation) async throws -> ReelCritique {
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
        emit("Critique: reviewing \(frames.count) frames for \(scope.rawValue)...")

        var learnedLines: [String] = []
        if let database {
            let config = await ai.config
            let models = ReelModelStore(databasePath: database.path,
                reports: database.path.deletingLastPathComponent().appendingPathComponent("on-device-agreement"))
            let traits: ReelTraits?
            if let generatedID { traits = try? await database.reelTraits(kind: "generated", videoID: String(generatedID)) }
            else { traits = nil }
            do {
                learnedLines = try await ReelModelScoring.criticLines(config: config, store: models, traits: traits, frames: frames.map(\.jpeg))
            } catch { emit("Trained scoring unavailable: \(error.localizedDescription)") }
        }
        learnedLines = learnedLines.map { scope.filtered($0) }.filter { !$0.isEmpty }
        let learnedBlock = learnedLines.isEmpty ? "" : "\n" + learnedLines.joined(separator: "\n")
        if let brief {
            let references: [AIFrame]
            if referenceFrames.isEmpty {
                references = try await AppJobWork.run { try CriticBriefStore(profile: profile).frames(for: brief) }
            } else { references = referenceFrames }
            frames[0].label = "REEL UNDER REVIEW — " + frames[0].label
            frames = references + frames
        }
        let response = try await ai.call(prompt: prompt(duration: duration, plan: plan,
                                                        sceneMap: sceneMap, options: options,
                                                        profile: profile, attempt: attempt,
                                                        previous: previous, brief: brief, scope: scope) + learnedBlock,
                                         task: .critique, frames: frames,
                                         timeout: 180, log: emit)
        var critique = try parse(response.text, options: options, provider: response.provider,
                                 model: response.model, briefKey: brief?.key, scope: scope)
        critique.strengths += learnedLines
        return critique
    }

    static func parse(_ text: String, options: WizardOptions, provider: String? = nil,
                      model: String? = nil, briefKey: String? = nil, scope: Scope = .content) throws -> ReelCritique {
        guard let object = AIResponseParser.jsonObject(from: text) else {
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
            forecast: scope == .presentation || options.accountBenchmarks == nil ? nil
                : (object["engagement_forecast"] as? NSNumber).map { max(0, min(100, $0.intValue)) },
            forecastReasons: scope == .presentation || strings("forecast_reasons").isEmpty ? nil : strings("forecast_reasons"),
            provider: provider,
            model: model, briefKey: briefKey, scope: scope)
        if briefKey != nil {
            critique.notes += strings("reference_gap").map { "Reference gap: \($0)" }
        }
        // A judge that likes the reel doesn't get to demand a rebuild, and a
        // rebuild request without notes gives the planner nothing to fix.
        if critique.score >= options.critiqueTargetScore { critique.regenerate = false }
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
        if scope == .presentation { critique.regenerate = false }
        return critique
    }

    static func prompt(duration: Double, plan: WizardPlan,
                       sceneMap: [Int64: SceneRecord],
                       options: WizardOptions, profile: BrandProfile,
                       attempt: Int, previous: [ReelCritique], brief: CriticBrief? = nil,
                       scope: Scope = .content) -> String {
        var lines = ["You are a strict short-form editor. Review only \(scope.rawValue). A mediocre result should not score above 70."]
        switch scope {
        case .content:
            lines.append("The timestamped frames come from a reduced-quality proxy of a take. Judge the selected moments and their order. Ignore missing finishing treatments and proxy image quality; these are applied in step 2.")
        case .presentation:
            lines.append("The timestamped frames come from the FINAL rendered reel. Judge only the finishing treatment. The accepted moments are fixed; annotate improvements to the look without requesting different footage or a re-plan. Disabled treatments are intentional, never omissions.")
        }
        lines.append("\n## Rubric\n" + scope.rubric)
        lines.append("- Duration: \(String(format: "%.1f", duration))s")
        if scope == .content {
            lines.append("- Planner's strategy: \(plan.rationale)")
            lines.append("\n## Selected moments")
            for (index, clip) in plan.clips.enumerated() {
                let tags = sceneMap[clip.sceneID]?.tags.prefix(6).joined(separator: ", ") ?? ""
                lines.append("\(index + 1). \(String(format: "%.1f", (clip.end - clip.start) / clip.speed))s — \(tags) — \(clip.reason ?? "")")
            }
        } else {
            lines.append("- Music: \(plan.musicName ?? "none") · Captions: \(options.addCaptions ? "on" : "off") · Text overlays: \(options.enableTextOverlays ? "on" : "off")")
            lines.append("- Branding: watermark \(options.includeWatermark), headline \(options.includeHeadline), outro \(options.includeOutro)")
        }
        func appendContext(_ title: String, _ text: String) {
            let filtered = scope.filtered(text).trimmingCharacters(in: .whitespacesAndNewlines)
            if !filtered.isEmpty { lines.append("\n## \(title)\n" + filtered) }
        }
        appendContext("The owner's taste", profile.tasteRubric)
        appendContext("House style", profile.houseStyle)
        if let brief {
            lines.append("\n## Reference reels — COMPARE, do not reward copying")
            lines.append("Apply only the current rubric to the REFERENCE images and these filtered notes.")
            appendContext("Reference rules", brief.rules)
            for exemplar in brief.exemplars { appendContext("Reference", exemplar.summary) }
        }
        if scope == .content, let benchmarks = options.accountBenchmarks {
            appendContext("This account's audience", benchmarks.criticBlock())
        }
        if scope == .content, !previous.isEmpty {
            lines.append("\n## Earlier takes in this run")
            for (index, earlier) in previous.enumerated() {
                lines.append("Attempt \(index + 1) scored \(earlier.score)/100 — \(earlier.issues.joined(separator: "; "))")
            }
            lines.append("This is attempt \(attempt). Score absolutely, not on improvement.")
        }
        let notes = scope == .content
            ? "concrete instructions for the planner's next take — name clips by number"
            : "concrete finishing observations for the accepted reel; never request a re-plan"
        let regenerate = scope == .content
            ? "<true only if score < \(options.critiqueTargetScore) AND the issues are fixable by re-planning from the same footage>"
            : "false"
        lines.append("""

        ## Answer with STRICT JSON only — no prose outside the JSON
        {
          "score": <0-100>,
          "summary": "<one sentence verdict>",
          "strengths": ["<what works within this rubric>"],
          "issues": ["<specific problems within this rubric>"],
          "notes": ["<\(notes)>"],
          "regenerate": \(regenerate)
        }
        """)
        if scope == .content, options.accountBenchmarks != nil {
            lines.append("Also include engagement_forecast (0–100 against the account benchmarks) and forecast_reasons (specific reasons).")
        }
        if brief != nil { lines.append("Also include \"reference_gap\": an array of specific gaps within the current rubric.") }
        return lines.joined(separator: "\n")
    }
}
