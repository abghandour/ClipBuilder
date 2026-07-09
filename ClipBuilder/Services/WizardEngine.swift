import Foundation

nonisolated struct WizardOptions: Sendable {
    var numberOfVideos = 1
    var variationsPerVideo = 1
    var muteSource = false
    var addCaptions = false
    var autoCropWide = true
    var enableTextOverlays = false
    var useMusic = true
    var aiInstructions = ""
    /// Restrict scene selection to these source videos (empty = all).
    var selectedVideoIDs: Set<Int64> = []
    var modelOverride: String?
}

nonisolated struct WizardPlanClip: Sendable {
    var sceneID: Int64
    var start: Double
    var end: Double
    var wideSplit: Bool
    var textOverlay: String?
}

nonisolated struct WizardPlan: Sendable {
    var targetDuration: Double
    var rationale: String
    var musicName: String?
    var musicVolume: Int
    var clips: [WizardPlanClip]
    var transitions: [String]
}

/// Autonomous Reels generator — the Swift port of wizard.py: cached research
/// → AI plan → validation → linear assembly → AI caption.
actor WizardEngine {
    static let researchTopic = "instagram_reels"
    static let researchTTL: TimeInterval = 7 * 24 * 3600

    private let ai: AIService
    private let render: RenderEngine

    init(ai: AIService, render: RenderEngine) {
        self.ai = ai
        self.render = render
    }

    /// Music library: ~/Documents/ClipBuilder/assets/music (per-user, shared
    /// across profiles — the app-tree equivalent of the repo's assets/music).
    static var musicDirectory: URL {
        ProfileStore.profilesDirectory.appendingPathComponent("assets/music", isDirectory: true)
    }

    static func availableMusic() -> [(name: String, url: URL)] {
        let extensions: Set<String> = ["mp3", "m4a", "wav", "aac", "flac"]
        let files = (try? FileManager.default.contentsOfDirectory(at: musicDirectory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .map { ($0.deletingPathExtension().lastPathComponent, $0) }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    // MARK: - Research phase

    private static let researchDefaults: [String: Any] = [
        "ideal_duration_range": ["min": 15, "max": 30],
        "optimal_duration": 22,
        "aspect_ratio": "9:16",
        "hook_strategy": "Open with the most explosive moment in the first 1-2 seconds.",
        "pacing_cuts_per_minute": 20,
        "content_structure": ["hook", "rising action", "payoff"],
        "music_strategy": "High-energy track that matches the action.",
        "transition_strategy": "Fast cuts with occasional fades.",
        "engagement_tips": ["Keep it short", "End strong"],
        "avoid": ["Dead time", "Slow intros"],
        "opening_types": ["explosive action"],
        "closing_strategy": "End on a high note that invites a replay.",
    ]

    private func researchPrompt(domain: String) -> String {
        """
        You are an expert social media strategist specializing in Instagram Reels for \(domain) content.

        Based on your knowledge of the current Instagram Reels algorithm and best practices (2025-2026), provide detailed, actionable recommendations for creating \(domain) highlight reels that MAXIMIZE engagement (views, likes, shares, saves, and follows).

        Consider: optimal video duration, pacing, hook strategy (first 1-3s), content structure, music usage, transition style, and what makes \(domain) content go viral on Reels.

        Return a JSON object with EXACTLY this structure:
        {
          "ideal_duration_range": {"min": <seconds>, "max": <seconds>},
          "optimal_duration": <seconds>,
          "aspect_ratio": "9:16",
          "hook_strategy": "<detailed strategy for first 1-3 seconds>",
          "pacing_cuts_per_minute": <number>,
          "content_structure": ["<phase1>", "<phase2>", ...],
          "music_strategy": "<how to use music for maximum engagement>",
          "transition_strategy": "<recommended transition approach for \(domain) content>",
          "engagement_tips": ["<tip1>", "<tip2>", ...],
          "avoid": ["<thing to avoid 1>", ...],
          "opening_types": ["<best hook types for \(domain)>", ...],
          "closing_strategy": "<how to end for max engagement>"
        }

        Return ONLY the JSON object. No explanation, no markdown fences.
        """
    }

    private func getResearch(profile: BrandProfile, database: Database, model: String?,
                             emit: @escaping @Sendable (String) -> Void) async -> [String: Any] {
        if let cached = try? await database.latestResearch(topic: Self.researchTopic),
           let researchedAt = cached.researchedAt,
           Date().timeIntervalSince(researchedAt) <= Self.researchTTL,
           let object = AIResponseParser.jsonObject(from: cached.resultJSON) {
            emit("Using cached Instagram Reels research (less than 7 days old)")
            return object
        }
        emit("Researching Instagram Reels best practices...")
        do {
            let response = try await ai.call(prompt: researchPrompt(domain: profile.effectiveDomain),
                                             task: "wizard", model: model, timeout: 300, log: emit)
            if let object = AIResponseParser.jsonObject(from: response),
               let data = AIResponseParser.jsonData(from: response),
               let json = String(data: data, encoding: .utf8) {
                let attribution = await ai.resolveProviderModel(task: "wizard", model: model)
                try? await database.saveResearch(topic: Self.researchTopic, resultJSON: json,
                                                 provider: attribution.provider, model: attribution.model)
                emit("Research complete — cached for future runs")
                return object
            }
        } catch {
            emit("Research failed (\(error)) — using built-in defaults")
        }
        return Self.researchDefaults
    }

    // MARK: - Planning phase

    private func sceneLine(_ scene: SceneRecord) -> String {
        var line = "#\(scene.id): \(scene.videoFilename) " +
            String(format: "[%.1f-%.1f] %.1fs", scene.startTime, scene.endTime, scene.duration) +
            " tags:\(scene.tags.prefix(8).joined(separator: ","))"
        if scene.wide { line += " WIDE" }
        if let average = scene.gradeAverage, scene.gradeCount > 0 {
            line += String(format: " grade:%.1f/5", average)
        }
        return line
    }

    private func feedbackBlock(_ feedback: [FeedbackRecord]) -> String {
        guard !feedback.isEmpty else {
            return "No feedback yet — this is the first generation."
        }
        return feedback.enumerated().map { index, entry in
            let recency = index == 0 ? "most recent" : (index < 5 ? "recent" : "older")
            let file = entry.videoPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?"
            let duration = entry.videoDuration.map { String(format: "%.0fs", $0) } ?? "?"
            return "- [\(recency)] \"\(entry.feedback)\" (video: \(file), \(duration), \(entry.createdAt ?? ""))"
        }.joined(separator: "\n")
    }

    private func planPrompt(profile: BrandProfile,
                            research: [String: Any],
                            scenes: [SceneRecord],
                            musicNames: [String],
                            feedback: [FeedbackRecord],
                            options: WizardOptions,
                            variation: (number: Int, total: Int, previousRationales: [String])?) -> String {
        let domain = profile.effectiveDomain
        let brand = profile.brandName

        let range = research["ideal_duration_range"] as? [String: Any]
        let durationMin = (range?["min"] as? NSNumber)?.intValue ?? 15
        let durationMax = (range?["max"] as? NSNumber)?.intValue ?? 30
        let targetDuration = (research["optimal_duration"] as? NSNumber)?.intValue ?? 22
        let cutsPerMinute = (research["pacing_cuts_per_minute"] as? NSNumber)?.intValue ?? 20

        let researchJSON = (try? JSONSerialization.data(withJSONObject: research, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        var userInstructions = ""
        if !options.aiInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            userInstructions = """


            ## USER AI INSTRUCTIONS (HIGHEST PRIORITY — OVERRIDES ALL OTHER GUIDANCE BELOW)
            \(options.aiInstructions)
            These are hard requirements. Follow them even when they conflict with the research, feedback, or rules below.
            """
        }

        var variationInfo = ""
        if let variation, variation.total > 1 {
            variationInfo = """
            ## VARIATION MODE
            This is variation \(variation.number) of \(variation.total). You MUST create a DIFFERENT creative approach than previous variations.
            """
            if !variation.previousRationales.isEmpty {
                let previous = variation.previousRationales.enumerated()
                    .map { "Variation \($0.offset + 1): \($0.element)" }
                    .joined(separator: ", ")
                variationInfo += "\nPrevious variation strategies (DO NOT repeat these): \(previous)"
            }
            variationInfo += "\nUse a different hook, scene selection, pacing, and/or music than previous variations."
        }

        let textOverlayInstruction: String
        if options.enableTextOverlays {
            textOverlayInstruction = """
            - Text overlays are ENABLED. Insert punchy ALL-CAPS text ONLY where it improves engagement: the hook (first clip), a payoff/reveal, the climax, or an ending CTA. 2-6 words max, one line each, about 3-5 overlays across the whole reel.
            """
        } else {
            textOverlayInstruction = "- Text overlays are DISABLED. Set \"text_overlay\" to null for every clip."
        }

        let sceneList = scenes.map(sceneLine).joined(separator: "\n")
        let musicList = musicNames.isEmpty ? "No music available" : musicNames.joined(separator: ", ")
        let beatInfo = "Beat detection found no clear beats. Use your judgment for cut timing."

        return """
        You are an expert video editor creating an Instagram Reel for a \(domain) channel called \(brand). Your ONLY goal: MAXIMIZE ENGAGEMENT (views, likes, shares, saves).
        \(userInstructions)

        ## Instagram Reels Research
        \(researchJSON)

        ## Available Scenes
        \(sceneList)

        ## Available Music
        \(musicList)

        ## Available Transitions
        \(RenderEngine.transitions.joined(separator: ", "))

        ## Music Beat Analysis
        \(beatInfo)

        ## User Feedback History (CRITICAL — read every entry)
        \(feedbackBlock(feedback))

        \(variationInfo)

        ## Instructions
        Create a video plan optimized for maximum Instagram Reel engagement.

        FEEDBACK IS YOUR MOST IMPORTANT INPUT. The user's feedback above represents hard-learned lessons from previous generations. You MUST:
        - Identify recurring themes in the feedback (e.g. "too long", "bad transitions")
        - Treat repeated feedback as hard constraints — never repeat a criticized mistake
        - Amplify what the user praised — if they liked something, do more of it
        - Recent feedback takes priority over older feedback if they conflict
        - In your "rationale" field, explicitly mention which feedback items shaped your decisions

        KEY PRINCIPLES:
        1. HOOK — First 1-2 seconds must grab attention (most explosive/dramatic moment)
        2. PACING — Tight cuts, no dead time. Target ~\(cutsPerMinute) cuts per minute
        3. ARC — Even a 20-second video needs rising action
        4. MUSIC — Choose music that amplifies energy. SYNC cuts to beat positions when possible.
        5. ENDING — Strong close that makes viewers replay or share
        6. DURATION — Target \(targetDuration)s (within \(durationMin)-\(durationMax)s range)
        7. BEATS — If beat positions are provided, align clip start/end times to land on or near beat positions. Viewers subconsciously feel beat-synced cuts as more professional.

        For each clip, specify a sub-range within the scene. Keep clips tight (1.5-5s each).
        Prefer scenes tagged "high-energy" or with action/impact tags from the available list.

        Output a JSON object with EXACTLY this structure:
        {
          "target_duration": <seconds>,
          "rationale": "<brief creative strategy explanation>",
          "music": {"name": "<music name from list, or null>", "volume": <1-5>},
          "clips": [
            {
              "scene_id": <id>,
              "start": <start seconds>,
              "end": <end seconds>,
              "wide_split": <true if this WIDE scene should use split-screen>,
              "text_overlay": "<optional text to overlay on this clip, or null>",
              "reason": "<why this clip, why this position>"
            }
          ],
          "transitions": ["<transition name>", ...]
        }

        RULES:
        - "transitions" array must have exactly len(clips) - 1 elements
        - clip start/end must be within the scene's time range
        - each clip duration should be 1.5-5 seconds
        - total clip duration should approximate target_duration
        - only use scene IDs from the list above
        - only use music names from the list above (or null)
        - only use transition names from the list above
        - For WIDE scenes: set "wide_split": true to display as split-screen (top + bottom halves, filling the full 9:16 frame with no black bars)
        - "text_overlay": only include if text overlays are enabled (see below). Use short punchy text (max 6 words) for impact moments, fighter names, or engagement hooks. null if no text needed for this clip.
        \(textOverlayInstruction)
        - Return ONLY the JSON object
        """
    }

    /// Parse + validate the AI's plan per wizard.py rules: clamp clips to
    /// scene bounds, drop sub-0.5s clips, sanitize music and transitions.
    private func validatePlan(_ raw: [String: Any],
                              scenes: [Int64: SceneRecord],
                              musicNames: Set<String>) -> WizardPlan? {
        var musicName: String?
        var musicVolume = 3
        if let music = raw["music"] as? [String: Any] {
            if let name = music["name"] as? String, musicNames.contains(name) {
                musicName = name
            }
            musicVolume = (music["volume"] as? NSNumber)?.intValue ?? 3
        }

        var clips: [WizardPlanClip] = []
        for clipObject in raw["clips"] as? [[String: Any]] ?? [] {
            guard let sceneID = (clipObject["scene_id"] as? NSNumber)?.int64Value,
                  let scene = scenes[sceneID] else { continue }
            var start = max(scene.startTime, (clipObject["start"] as? NSNumber)?.doubleValue ?? scene.startTime)
            var end = min(scene.endTime, (clipObject["end"] as? NSNumber)?.doubleValue ?? scene.endTime)
            if end - start < 0.5 {
                start = scene.startTime
                end = min(scene.endTime, start + 3.0)
            }
            guard end - start >= 0.5 else { continue }
            let overlayText = (clipObject["text_overlay"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            clips.append(WizardPlanClip(sceneID: sceneID,
                                        start: start.rounded(toPlaces: 2),
                                        end: end.rounded(toPlaces: 2),
                                        wideSplit: (clipObject["wide_split"] as? Bool ?? false) && scene.wide,
                                        textOverlay: overlayText?.isEmpty == false ? overlayText : nil))
        }
        guard !clips.isEmpty else { return nil }

        let needed = max(0, clips.count - 1)
        var transitions = (raw["transitions"] as? [String] ?? []).map {
            RenderEngine.transitions.contains($0) ? $0 : "fade"
        }
        if transitions.count > needed { transitions = Array(transitions.prefix(needed)) }
        while transitions.count < needed { transitions.append("fade") }

        return WizardPlan(targetDuration: (raw["target_duration"] as? NSNumber)?.doubleValue ?? 22,
                          rationale: raw["rationale"] as? String ?? "",
                          musicName: musicName,
                          musicVolume: musicVolume,
                          clips: clips,
                          transitions: transitions)
    }

    // MARK: - Caption phase

    private func captionPrompt(profile: BrandProfile, plan: WizardPlan,
                               duration: Double, tags: [String]) -> String {
        let handle = profile.socials["instagram"]?.handle ?? ""
        let domain = profile.effectiveDomain
        return """
        You are a social media expert for a \(domain) Instagram channel called \(profile.brandName) (\(handle)).

        Generate an Instagram Reel caption + hashtags for a video with these details:
        - Duration: \(String(format: "%.0f", duration))s
        - Creative strategy: \(plan.rationale)
        - Tags/content: \(tags.joined(separator: ", "))
        - Music: \(plan.musicName ?? "none")

        Requirements:
        - Caption should be 1-3 punchy lines that drive engagement (likes, comments, saves, shares)
        - Include a hook or question to encourage comments
        - Add 5-10 relevant hashtags (mix of broad \(domain) hashtags + niche + trending)
        - Format: caption text first, then hashtags on a new line
        - Keep it authentic to \(domain) culture
        - Do NOT use emojis excessively (max 2-3)

        Return ONLY the caption text + hashtags, nothing else.
        """
    }

    // MARK: - Run

    /// Full wizard run. Emits progress lines (same formats as wizard.py's
    /// SSE stream, ending with "DONE:ok"/"DONE:error").
    func run(options: WizardOptions,
             profile: BrandProfile,
             database: Database,
             emit: @escaping @Sendable (String) -> Void) async {
        do {
            try await runThrowing(options: options, profile: profile, database: database, emit: emit)
            emit("DONE:ok")
        } catch {
            emit("Error: \(error)")
            emit("DONE:error")
        }
    }

    private func runThrowing(options: WizardOptions,
                             profile: BrandProfile,
                             database: Database,
                             emit: @escaping @Sendable (String) -> Void) async throws {
        emit("Phase 1: Instagram Reels research...")
        let research = await getResearch(profile: profile, database: database,
                                         model: options.modelOverride, emit: emit)

        emit("Loading scenes and music...")
        var scenes = try await database.fetchScenes(includeExcluded: false).filter { !$0.ignored }
        if !options.selectedVideoIDs.isEmpty {
            let before = scenes.count
            scenes = scenes.filter { options.selectedVideoIDs.contains($0.videoID) }
            emit("Filtered to \(scenes.count) scenes from \(options.selectedVideoIDs.count) selected file(s) (was \(before))")
        }
        guard !scenes.isEmpty else {
            throw AIError.notConfigured("No analyzed scenes available. Analyze some videos first.")
        }
        let music = options.useMusic ? Self.availableMusic() : []
        if !options.useMusic { emit("No-music mode: original audio only.") }
        if options.muteSource { emit("Source audio will be muted (music only)") }
        if options.enableTextOverlays { emit("Text overlays enabled") }
        let feedback = (try? await database.fetchAllFeedback()) ?? []
        emit("Found \(scenes.count) scenes, \(music.count) music tracks, \(feedback.count) feedback entries")
        if options.variationsPerVideo > 1 {
            emit("Generating \(options.variationsPerVideo) A/B variations per video")
        }

        let sceneMap = Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0) })
        let musicNames = Set(music.map(\.name))
        var generatedCount = 0

        // Normalize the profile's intro/outro once for the whole run — the
        // result is identical for every video/variation assembled below.
        let runScratch = try await render.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: runScratch) }
        var normalizedIntro: URL?
        if let intro = assetURL(profile.introVideo) {
            emit("Normalizing intro...")
            let output = runScratch.appendingPathComponent("intro.mp4")
            try await render.normalizeClip(source: intro, output: output)
            normalizedIntro = output
        }
        var normalizedOutro: URL?
        if let outro = assetURL(profile.outroVideo) {
            emit("Normalizing outro...")
            let output = runScratch.appendingPathComponent("outro.mp4")
            try await render.normalizeClip(source: outro, output: output)
            normalizedOutro = output
        }

        for videoNumber in 1...options.numberOfVideos {
            var previousRationales: [String] = []
            for variationNumber in 1...options.variationsPerVideo {
                let variationLabel = options.variationsPerVideo > 1
                    ? "\(videoNumber).\(variationNumber)" : "\(videoNumber)"
                emit("\nPhase 2: Planning Video \(variationLabel)/\(options.numberOfVideos)...")

                let prompt = planPrompt(profile: profile, research: research, scenes: scenes,
                                        musicNames: music.map(\.name), feedback: feedback,
                                        options: options,
                                        variation: (variationNumber, options.variationsPerVideo, previousRationales))
                let response = try await ai.call(prompt: prompt, task: "wizard",
                                                 model: options.modelOverride, timeout: 300, log: emit)
                guard let rawPlan = AIResponseParser.jsonObject(from: response),
                      let plan = validatePlan(rawPlan, scenes: sceneMap, musicNames: musicNames) else {
                    emit("Plan for video \(variationLabel) could not be parsed — skipping")
                    continue
                }
                emit("Plan: \(plan.clips.count) clips, ~\(Int(plan.targetDuration))s, music: \(plan.musicName ?? "none")")
                emit("Strategy: \(plan.rationale)")
                previousRationales.append(plan.rationale)

                emit("\nPhase 3: Assembling Video \(variationLabel)/\(options.numberOfVideos)...")
                let result = try await assemble(plan: plan, music: music, options: options,
                                                profile: profile, database: database,
                                                sceneMap: sceneMap, label: variationLabel,
                                                normalizedIntro: normalizedIntro,
                                                normalizedOutro: normalizedOutro, emit: emit)
                generatedCount += 1

                emit("Generating Instagram caption...")
                let tagsUsed = Array(Set(plan.clips.flatMap { sceneMap[$0.sceneID]?.tags ?? [] })).sorted()
                do {
                    let caption = try await ai.call(
                        prompt: captionPrompt(profile: profile, plan: plan,
                                              duration: result.duration, tags: tagsUsed),
                        task: "captions", timeout: 60, log: emit)
                    let attribution = await ai.resolveProviderModel(task: "captions")
                    try await database.updateGeneratedCaption(id: result.recordID,
                                                              caption: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                                                              provider: attribution.provider,
                                                              model: attribution.model)
                    emit("Caption generated!")
                } catch {
                    emit("Caption generation failed: \(error)")
                }

                emit("VIDEO:\(result.url.lastPathComponent):\(String(format: "%.1f", result.duration))")
                emit("Video \(variationLabel) complete! \(String(format: "%.1f", result.duration))s -> \(result.url.lastPathComponent)")
            }
        }
        emit("\nAll done! Generated \(generatedCount) video(s)")
    }

    // MARK: - Assembly

    private struct AssemblyResult {
        var url: URL
        var duration: Double
        var recordID: Int64
    }

    private func assemble(plan: WizardPlan,
                          music: [(name: String, url: URL)],
                          options: WizardOptions,
                          profile: BrandProfile,
                          database: Database,
                          sceneMap: [Int64: SceneRecord],
                          label: String,
                          normalizedIntro: URL?,
                          normalizedOutro: URL?,
                          emit: @escaping @Sendable (String) -> Void) async throws -> AssemblyResult {
        let scratch = try await render.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        var clipURLs: [URL] = []
        var clipTransitions: [String] = []

        // Intro (profile asset, normalized once per run) — joined with a hard fade.
        if let normalizedIntro {
            clipURLs.append(normalizedIntro)
        }

        // Extract every planned clip concurrently — captions, text overlay
        // and mute are burned in ONE encode pass per clip (they used to be
        // up to three extra full re-encodes each).
        let jobs: [(index: Int, clip: WizardPlanClip, scene: SceneRecord)] =
            plan.clips.enumerated().compactMap { index, clip in
                sceneMap[clip.sceneID].map { (index, clip, $0) }
            }
        let clipCount = plan.clips.count
        let captionStyle = profile.captions
        let extracted = try await BoundedConcurrency.map(jobs, limit: FFmpeg.jobLimit) { _, job in
            try await self.extractPlannedClip(job.clip, index: job.index, of: clipCount,
                                              scene: job.scene, options: options,
                                              captionStyle: captionStyle,
                                              database: database, scratch: scratch,
                                              label: label, emit: emit)
        }

        for url in extracted {
            if clipURLs.count > clipTransitions.count && !clipURLs.isEmpty {
                // Boundary after intro or a previous clip: planner transition
                // if available, else hard fade.
                let planIndex = clipURLs.count - (normalizedIntro != nil ? 2 : 1)
                clipTransitions.append(plan.transitions[safe: planIndex] ?? "fade")
            }
            clipURLs.append(url)
        }

        if let normalizedOutro {
            clipTransitions.append("fade")
            clipURLs.append(normalizedOutro)
        }

        guard !clipURLs.isEmpty else {
            throw AIError.notConfigured("No clips could be extracted for this plan")
        }

        emit("Video \(label): assembling \(clipURLs.count) segments...")
        let assembled = scratch.appendingPathComponent("assembled.mp4")
        try await render.concatenate(clips: clipURLs, transitions: clipTransitions.map { Optional($0) },
                                     output: assembled)

        let outputURL = try outputFile(profile: profile, plan: plan)
        if let musicName = plan.musicName,
           let track = music.first(where: { $0.name == musicName }) {
            emit("Video \(label): adding music (\(musicName))...")
            try await render.overlayMusic(video: assembled, music: track.url, output: outputURL)
        } else {
            try FileManager.default.copyItemReplacing(at: assembled, to: outputURL)
        }

        let finalDuration = await FFmpeg.duration(of: outputURL)

        // Timeline JSON matching the Python builder's flat format.
        var timeline: [[String: Any]] = []
        if let musicName = plan.musicName {
            timeline.append(["type": "music", "name": musicName, "volume": plan.musicVolume])
        }
        for (index, clip) in plan.clips.enumerated() {
            if index > 0, let transition = plan.transitions[safe: index - 1] {
                timeline.append(["type": "transition", "name": transition])
            }
            timeline.append(["type": "clip",
                             "id": clip.sceneID,
                             "video_file": sceneMap[clip.sceneID]?.videoPath ?? "",
                             "start": clip.start,
                             "end": clip.end])
        }
        let timelineJSON = (try? JSONSerialization.data(withJSONObject: timeline))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let attribution = await ai.resolveProviderModel(task: "wizard", model: options.modelOverride)
        let recordID = try await database.insertGeneratedVideo(path: outputURL.path,
                                                               duration: finalDuration.rounded(toPlaces: 1),
                                                               timelineJSON: timelineJSON,
                                                               wizardProvider: attribution.provider,
                                                               wizardModel: attribution.model)
        return AssemblyResult(url: outputURL, duration: finalDuration, recordID: recordID)
    }

    /// One planned clip → one normalized file in a single decode→encode pass:
    /// wide handling, caption overlays, text overlay and mute all ride the
    /// same ffmpeg filter graph.
    private func extractPlannedClip(_ clip: WizardPlanClip, index: Int, of total: Int,
                                    scene: SceneRecord, options: WizardOptions,
                                    captionStyle: CaptionStyle,
                                    database: Database, scratch: URL,
                                    label: String,
                                    emit: @escaping @Sendable (String) -> Void) async throws -> URL {
        let duration = clip.end - clip.start
        let mode = clip.wideSplit ? "split-screen" : (options.autoCropWide && scene.wide ? "auto-crop" : "")
        emit("Video \(label): clip \(index + 1)/\(total) " +
             String(format: "[%.1fs +%.1fs]", clip.start, duration) +
             " from \(scene.videoFilename)\(mode.isEmpty ? "" : " (\(mode))")")

        var overlays: [RenderEngine.ClipOverlay] = []
        if options.addCaptions {
            // Transcript times are in source-video time; shift into clip time.
            let renderer = CaptionRenderer(videoWidth: RenderEngine.outputWidth,
                                           videoHeight: RenderEngine.outputHeight,
                                           style: captionStyle)
            let sourceSegments = (try? await database.transcriptSegments(
                videoID: scene.videoID, start: clip.start, end: clip.end)) ?? []
            for segment in sourceSegments {
                let start = max(0, segment.start - clip.start)
                let end = min(duration, segment.end - clip.start)
                guard end > start + 0.1 else { continue }
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                guard let rendered = try? renderer.render(text: text, to: scratch) else { continue }
                let (x, y) = renderer.position(for: rendered)
                overlays.append(RenderEngine.ClipOverlay(png: rendered.pngURL, x: x, y: y,
                                                         start: start, end: end))
            }
        }
        if let overlayText = clip.textOverlay, options.enableTextOverlays {
            // Punchy full-clip text overlay — bigger type, upper third.
            let renderer = CaptionRenderer(videoWidth: RenderEngine.outputWidth,
                                           videoHeight: RenderEngine.outputHeight,
                                           style: CaptionStyle())
            if let rendered = try? renderer.render(text: overlayText.uppercased(), to: scratch,
                                                   fontSize: CGFloat(RenderEngine.outputWidth) / 14) {
                overlays.append(RenderEngine.ClipOverlay(
                    png: rendered.pngURL,
                    x: (RenderEngine.outputWidth - rendered.width) / 2,
                    y: RenderEngine.outputHeight / 5,
                    start: nil, end: nil))
            }
        }

        let output = scratch.appendingPathComponent("clip_\(index).mp4")
        if clip.wideSplit && scene.wide {
            try await render.extractClip(source: scene.videoURL, start: clip.start,
                                         duration: duration, wide: .split,
                                         overlays: overlays, mute: options.muteSource,
                                         output: output)
        } else if options.autoCropWide && scene.wide {
            let xFraction = await render.autoCropXFraction(source: scene.videoURL,
                                                           start: clip.start, duration: duration)
            do {
                try await render.extractClip(source: scene.videoURL, start: clip.start,
                                             duration: duration, wide: .autoCrop(xFraction),
                                             overlays: overlays, mute: options.muteSource,
                                             output: output)
            } catch {
                try await render.extractClip(source: scene.videoURL, start: clip.start,
                                             duration: duration,
                                             overlays: overlays, mute: options.muteSource,
                                             output: output)
            }
        } else {
            try await render.extractClip(source: scene.videoURL, start: clip.start,
                                         duration: duration,
                                         overlays: overlays, mute: options.muteSource,
                                         output: output)
        }
        return output
    }

    private func assetURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
    }

    /// Output naming per wizard.py: <output>/<YYYY-MM-DD>/wiz-<dur>-<n>.mp4.
    private func outputFile(profile: BrandProfile, plan: WizardPlan) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let directory = profile.outputFolderURL.appendingPathComponent(formatter.string(from: Date()),
                                                                       isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let totalDuration = Int(plan.clips.reduce(0) { $0 + ($1.end - $1.start) }.rounded())
        let existing = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: nil)) ?? []
        let counter = (existing
            .filter { $0.lastPathComponent.hasPrefix("wiz-") }
            .compactMap { Int($0.deletingPathExtension().lastPathComponent.split(separator: "-").last ?? "") }
            .max() ?? 0) + 1
        return directory.appendingPathComponent("wiz-\(totalDuration)-\(counter).mp4")
    }
}
