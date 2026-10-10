import AppKit
import Foundation
import UniformTypeIdentifiers

extension AppStore {
    // MARK: - Overlay wizard

    /// Read the overlay elements out of a reference image (text, logos,
    /// badges — people and background are discarded) and save them as a new
    /// overlay template. Logo/badge regions are cropped out of the image
    /// into the Images library so the template can render them.
    /// Returns the created template's name.
    func extractOverlayTemplate(from imageURL: URL, provider: String?, model: String?,
                                log: @escaping @Sendable (String) -> Void) async throws -> String {
        let imageData = try await AppJobWork.run { try Data(contentsOf: imageURL) }
        try Task.checkCancellation()
        let prompt = """
        You are extracting the OVERLAY DESIGN from one frame of a social video so it can be recreated as a reusable overlay template.

        Identify ONLY overlay elements: text captions/titles, name plates, logos, channel badges, watermarks, stickers. DISCARD everything that is part of the footage itself — people, background, scenery.

        Return a JSON object:
        {"overlays": [
          {"kind": "text", "text": "<exact text>", "x": <0-1 center x>, "y": <0-1 center y>, "w": <0-1 width>, "h": <0-1 height>, "fontcolor": "#hex", "bold": true|false, "italic": true|false, "bgcolor": "#hex or null", "box_opacity": <0-1, 0 when no background plate>, "dynamic": true|false},
          {"kind": "image", "x": ..., "y": ..., "w": ..., "h": ..., "description": "<what it is, e.g. 'UFC logo'>"}
        ]}

        Rules:
        - Coordinates are fractions of the full frame; x/y are the element's CENTER.
        - "kind":"text" for anything that is essentially styled text — recreate it as text, estimating color/bold/italic and any background plate.
        - "kind":"image" for graphical marks (logos, badges, icons) that cannot be recreated as plain text. Make the box tight around the mark.
        - "dynamic": true for the main caption-style text a future video would replace with its own words; false for names/labels/branding.
        - 2-8 elements typical. Return ONLY the JSON object.
        """
        let frame = AIFrame(jpeg: imageData, label: "reference frame")
        let response = try await ai.call(prompt: prompt, task: .overlay, frames: [frame],
                                         model: model, provider: provider, timeout: 180, log: log)
        try Task.checkCancellation()
        return try await AppJobWork.run {
            try OverlayTemplateFiles.write(response: response.text, provenance: response.provenance,
                                           imageData: imageData, imageURL: imageURL, log: log)
        }
    }

    // MARK: - File Name Wizard

    /// Build a descriptive filename proposal for each video from the
    /// metadata already on record — people detection, video type, fight
    /// outcome/research, scene narratives, moments, transcript — one
    /// text-only AI call per video (no frame extraction). Returns sanitized
    /// proposals for the review sheet; a video whose best name is its
    /// current one is skipped. Applying a proposal goes through
    /// `renameVideo`, so derived analyze-batch labels follow (scene titles
    /// join the videos table and follow automatically).
    func suggestFileNames(for videos: [VideoRecord], provider: String?, model: String?,
                          log: @escaping @Sendable (String) -> Void) async throws -> [RenameSuggestion] {
        let useLocal = OnDevicePolicy.isEnabled(item: "file-naming", config: settings.ai)
        guard let database else { throw AIError.notConfigured("No profile is open.") }
        let research = fightResearch
        // Latest outcome per video, fetched once for the whole batch.
        let outcomes = (try? await database.fetchOutcomes()) ?? []
        var suggestions: [RenameSuggestion] = []
        var lastError: Error?
        for (index, video) in videos.enumerated() {
            try Task.checkCancellation()
            log("PROGRESS:\(Double(index) / Double(max(1, videos.count)))")
            log("Naming \(video.filename) (\(index + 1)/\(videos.count))…")
            let scenes = (try? await database.fetchScenes(videoID: video.id)) ?? []
            let people = (try? await database.fetchVideoPeople(videoID: video.id)) ?? []
            if useLocal, let stem = MetadataFileNamer.stem(people: people.map(\.name),
                hasResearch: research[video.id] != nil, fightDate: research[video.id]?.fightDate) {
                log("\(video.filename): named from people and fight date")
                if let name = Analyzer.sanitizedFilenameSuggestion(stem, currentFilename: video.filename) {
                    suggestions.append(RenameSuggestion(videoID: video.id, currentFilename: video.filename,
                        suggestedName: name, provenance: .local(technique: "metadata-filename")))
                }
                continue
            }
            log("\(video.filename): naming — asking the model")
            let moments = (try? await database.moments(videoID: video.id)) ?? []
            let transcripts = (try? await database.fetchTranscripts(videoID: video.id)) ?? []
            let prompt = FileNamer.prompt(video: video, scenes: scenes, people: people,
                                          outcome: outcomes.first { $0.videoID == video.id },
                                          research: research[video.id],
                                          moments: moments, transcripts: transcripts)
            do {
                let response = try await ai.call(prompt: prompt, task: .naming,
                                                 model: model, provider: provider,
                                                 timeout: 180, log: log)
                guard let (name, reason) = FileNamer.parseSuggestion(from: response.text) else {
                    log("\(video.filename): the model returned no usable name")
                    continue
                }
                let currentBase = (video.filename as NSString).deletingPathExtension
                guard name.caseInsensitiveCompare(currentBase) != .orderedSame else {
                    log("\(video.filename): the current name is already the best fit")
                    continue
                }
                if let reason { log("\(video.filename) → \(name) (\(reason))") }
                suggestions.append(RenameSuggestion(videoID: video.id,
                                                    currentFilename: video.filename,
                                                    suggestedName: name,
                                                    provenance: response.provenance))
            } catch let error as AIError {
                // A dead quota dooms every remaining call — stop the batch.
                if case .quotaExhausted = error { throw error }
                lastError = error
                log("\(video.filename): \(error)")
            }
        }
        // Partial results beat an error; an error beats silently proposing
        // nothing.
        if suggestions.isEmpty, let lastError { throw lastError }
        return suggestions
    }

    // MARK: - AI Favorites

    /// Judge the given non-favorite scenes against the taste rubric (with the
    /// user's grading history and existing Favorite picks as worked examples)
    /// and return proposed promotions for review. Chunked so any library
    /// size fits in the model's context.
    func proposeFavorites(for candidates: [SceneRecord], provider: String?, model: String?,
                         log: @escaping @Sendable (String) -> Void) async throws
        -> AIOutcome<[SceneCurator.Proposal]> {
        let candidates = candidates.filter { !$0.favorite && !$0.excluded && !$0.ignored }
        let profile = activeProfile
        let graded = scenes.filter { $0.lastGrade != nil }
        let favoriteExamples = scenes.filter(\.favorite)
        var proposals: [SceneCurator.Proposal] = []
        var provenance: AIProvenance?
        var start = 0
        while start < candidates.count {
            try Task.checkCancellation()
            log("PROGRESS:\(Double(start) / Double(max(1, candidates.count)))")
            let chunk = Array(candidates[start..<min(start + SceneCurator.batchSize, candidates.count)])
            if candidates.count > SceneCurator.batchSize {
                log("Judging scenes \(start + 1)–\(start + chunk.count) of \(candidates.count)…")
            }
            let prompt = SceneCurator.prompt(candidates: chunk, rubric: profile.tasteRubric,
                                             categories: profile.tasteCategories,
                                             graded: graded, favoriteExamples: favoriteExamples)
            let response = try await ai.call(prompt: prompt, task: .curate,
                                             model: model, provider: provider,
                                             timeout: 240, log: log)
            proposals += SceneCurator.parse(response.text, validIDs: Set(chunk.map(\.id)))
            provenance = response.provenance
            start += SceneCurator.batchSize
        }
        return AIOutcome(value: proposals,
                         provenance: provenance
                             ?? AIProvenance(provider: provider ?? "claude", model: model, task: "curate"))
    }

    /// Apply the reviewed curator picks in one pass — batched DB writes and
    /// a single refresh, unlike per-scene `favoriteScene`. `provenance` is the
    /// curator that proposed them, stamped on each scene.
    func applyFavorites(sceneIDs: [Int64], provenance: AIProvenance?) {
        setScenesFavorite(scenes.filter { sceneIDs.contains($0.id) }, favorite: true,
                          provenance: provenance)
    }

    // MARK: - Natural-language scene search

    /// "The moment Ulberg hurts Błachowicz against the fence" → ranked scene
    /// ids from the candidate set, matched by the model on narratives, tags,
    /// people, and timing.
    func findScenes(matching query: String, in candidates: [SceneRecord],
                    provider: String?, model: String?,
                    log: @escaping @Sendable (String) -> Void) async throws -> AIOutcome<[Int64]> {
        let useLocal = OnDevicePolicy.isEnabled(item: "scene-search", config: settings.ai)
        // Most recent scenes win when the library outgrows one call.
        var scoped = candidates.count > SceneFinder.maxCandidates
            ? Array(candidates.sorted { $0.id > $1.id }.prefix(SceneFinder.maxCandidates))
            : candidates
        if scoped.count < candidates.count {
            log("Searching the \(scoped.count) most recent of \(candidates.count) scenes")
        }
        var tasteLines: [String] = []
        if let modelStore = reelModelStore,
           let taste = try? modelStore.predictor(item: .taste, config: settings.ai, trainer: CreateMLReelModelTrainer()) {
            for scene in scoped {
                if let image = await ThumbnailService.jpegFrame(url: scene.videoURL, at: (scene.startTime + scene.endTime) / 2),
                   let score = try? await TasteSimilarity.scoreOnDevice(image: image, predictor: taste) {
                    let line = "Scene \(scene.id) looks like ours: \((score * 100).formatted(.number.precision(.fractionLength(0))))%"
                    tasteLines.append(line); log(line)
                }
            }
        }
        if useLocal {
            let names = Dictionary(uniqueKeysWithValues: people.map { ($0.tag, $0.name) })
            let vocabularyOnly = LocalSceneSearch.vocabularyOnly(query, vocabulary: activeProfile.effectiveTags.values.flatMap(\.self) + people.map(\.name))
            let rows = scoped.map { scene in
                LocalTextMatcher.Row(id: String(scene.id),
                    fields: scene.tags + scene.tags.compactMap { names[$0] } + (vocabularyOnly ? [] : [scene.narrative ?? ""]),
                    date: AIProvenance.parseDate(analysisRuns.first { $0.id == scene.runID }?.createdAt) ?? .distantPast)
            }
            if vocabularyOnly {
                let ids = LocalTextMatcher.rank(query: query, rows: rows, useEmbedding: false)
                    .filter { $0.score >= 3 }.prefix(SceneFinder.maxMatches).compactMap { Int64($0.row.id) }
                log("Scene search answered by tags and people")
                return AIOutcome(value: ids, provenance: .local(technique: "keyword-match"))
            }
            let ids = Set(LocalSceneSearch.narrow(query: query, rows: rows))
            scoped = scoped.filter { ids.contains(String($0.id)) }
        }
        log(useLocal ? "Scene candidates narrowed by keywords — asking the model" : "Scene search — asking the model")
        let prompt = SceneFinder.prompt(query: query, scenes: scoped, people: people)
            + (tasteLines.isEmpty ? "" : "\n" + tasteLines.joined(separator: "\n"))
        let response = try await ai.call(prompt: prompt, task: .search,
                                         model: model, provider: provider,
                                         timeout: 120, log: log)
        var provenance = response.provenance
        if useLocal { provenance.technique = "keyword-narrowing" }
        return AIOutcome(value: SceneFinder.parse(response.text, validIDs: Set(scoped.map(\.id))),
                         provenance: provenance)
    }

    // MARK: - Soundbite finder

    /// Mine a video's transcript for its most quotable self-contained
    /// moments. Throws a friendly error when the video has no transcript.
    func findSoundbites(in video: VideoRecord, provider: String?, model: String?,
                        log: @escaping @Sendable (String) -> Void) async throws
        -> AIOutcome<[SoundbiteFinder.Soundbite]> {
        guard let database else { throw AIError.notConfigured("No profile is open.") }
        let transcript = ((try? await database.fetchTranscripts(videoID: video.id)) ?? [])
            .filter { !$0.isTranslation }
        guard !transcript.isEmpty else {
            throw AIError.notConfigured("\(video.filename) has no transcript yet — run Transcribe on it first.")
        }
        let prompt = SoundbiteFinder.prompt(video: video, transcript: transcript)
        let response = try await ai.call(prompt: prompt, task: .soundbites,
                                         model: model, provider: provider,
                                         timeout: 180, log: log)
        let soundbites = SoundbiteFinder.parse(response.text, duration: video.duration)
        guard !soundbites.isEmpty else {
            throw AIError.unusableResponse("The model found no usable soundbites in the transcript.")
        }
        return AIOutcome(value: soundbites, provenance: response.provenance)
    }

    // MARK: - Cover frame picker

    /// Sample frames across a rendered reel and have a multimodal model rank
    /// the best thumbnail candidates for the Library card.
    func proposeCoverFrames(for video: GeneratedVideoRecord, provider: String?, model: String?,
                            log: @escaping @Sendable (String) -> Void) async throws
        -> AIOutcome<[CoverFramePicker.Candidate]> {
        let useLocal = OnDevicePolicy.isEnabled(item: "cover-frames", config: settings.ai)
        var sampledTimes: [Double] = []
        let times = CoverFramePicker.sampleTimes(duration: video.duration)
        log("Sampling \(times.count) frames…")
        var frames: [AIFrame] = []
        for (index, time) in times.enumerated() {
            try Task.checkCancellation()
            log("PROGRESS:\(0.5 * Double(index) / Double(max(1, times.count)))")
            if let jpeg = await ThumbnailService.jpegFrame(url: video.url, at: time,
                                                          maxDimension: 768) {
                sampledTimes.append(time)
                frames.append(AIFrame(jpeg: jpeg, label: String(format: "%.1fs", time)))
            }
        }
        guard !frames.isEmpty else {
            throw AIError.notConfigured("No frames could be read from \(video.filename).")
        }
        if useLocal {
            let data = frames.map(\.jpeg)
            let metrics = await Task.detached { data.map { FrameQuality.metrics($0) ?? .init(luminance: 0.5, variance: .greatestFiniteMagnitude) } }.value
            let indices = FrameQuality.survivingIndices(metrics)
            frames = indices.map { frames[$0] }
            sampledTimes = indices.map { sampledTimes[$0] }
        }
        log(useLocal ? "Cover frames filtered by luminance/sharpness — asking the model" : "Cover selection — asking the model")
        let response = try await ai.call(prompt: CoverFramePicker.prompt(filename: video.filename,
                                                                         duration: video.duration),
                                         task: .cover, frames: frames,
                                         model: model, provider: provider,
                                         timeout: 180, log: log)
        var candidates = CoverFramePicker.parse(response.text, sampledTimes: sampledTimes)
        if let modelStore = reelModelStore,
           let taste = try? modelStore.predictor(item: .taste, config: settings.ai, trainer: CreateMLReelModelTrainer()) {
            for index in candidates.indices {
                if let frame = sampledTimes.firstIndex(of: candidates[index].time),
                   let score = try? await TasteSimilarity.scoreOnDevice(image: frames[frame].jpeg, predictor: taste) {
                    candidates[index].reason += " · Looks like ours: \((score * 100).formatted(.number.precision(.fractionLength(0))))%"
                }
            }
        }
        guard !candidates.isEmpty else {
            throw AIError.unusableResponse("The model returned no usable cover picks.")
        }
        var provenance = response.provenance
        if useLocal { provenance.technique = "frame-quality-filter" }
        return AIOutcome(value: candidates, provenance: provenance)
    }

    /// Remember the picked cover frame and patch the card in place.
    /// `provenance` is the model that ranked it; nil for a hand pick.
    func setCoverFrame(_ video: GeneratedVideoRecord, time: Double, provenance: AIProvenance? = nil) {
        guard let database else { return }
        Task {
            do {
                try await database.updateGeneratedCover(id: video.id, time: time, provenance: provenance)
                if let index = generatedVideos.firstIndex(where: { $0.id == video.id }) {
                    generatedVideos[index].coverTime = time
                    generatedVideos[index].coverProvider = provenance?.provider
                    generatedVideos[index].coverModel = provenance?.model
                }
            } catch {
                presentError("Could not save the cover frame", error)
            }
        }
    }

    // MARK: - Trim suggestion

    /// AI skim of the whole video proposing the section worth analyzing —
    /// fills the plan sheet's trim slider.
    func suggestTrim(for video: VideoRecord, log: (@Sendable (String) -> Void)? = nil) async throws
        -> (start: Double, end: Double, reason: String, provenance: AIProvenance) {
        let useLocal = OnDevicePolicy.isEnabled(item: "trim", config: settings.ai)
        let detectors = useLocal ? await cachedDetectors(for: video) : nil
        return try await analyzer.suggestTrim(video: video, log: log ?? logSink(\.analysisLog), useLocal: useLocal, detectors: detectors)
    }

    /// ffmpeg black/freeze/cut detectors for a video, computed once per file
    /// (size + modification date) and kept in `video_detectors`. Shared by
    /// the trim suggestion and long-recording classification so a 30-minute
    /// recording is decoded once, not once per consumer.
    func cachedDetectors(for video: VideoRecord) async -> VideoDetectors? {
        guard let database,
              let values = try? video.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return nil }
        let fingerprint = "1:\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if let cached = try? await database.cachedDetectors(videoID: video.id, fingerprint: fingerprint) { return cached }
        guard let fresh = try? await FFmpeg.detectors(of: video.url, duration: video.duration) else { return nil }
        try? await database.cacheDetectors(fresh, videoID: video.id, fingerprint: fingerprint)
        return fresh
    }

    // MARK: - Duplicate detection

    /// Scan the library for the same footage imported more than once —
    /// metadata plus one mid-video frame per video, grouped with a keep
    /// recommendation. Report-only; an empty result means no duplicates.
    func findDuplicateVideos(provider: String?, model: String?,
                             log: @escaping @Sendable (String) -> Void) async throws
        -> AIOutcome<[DuplicateFinder.Group]> {
        let useLocal = OnDevicePolicy.isEnabled(item: "duplicates", config: settings.ai)
        guard let database else { throw AIError.notConfigured("No profile is open.") }
        let research = fightResearch
        guard videos.count >= 2 else {
            throw AIError.notConfigured("Fewer than two videos in the library — nothing to compare.")
        }
        var scoped = Array(videos.prefix(DuplicateFinder.maxVideos))
        if scoped.count < videos.count {
            log("Comparing the first \(scoped.count) of \(videos.count) videos")
        }
        var localGroups: [DuplicateFinder.Group] = []
        if useLocal {
            localGroups = try await DuplicateFinder.local(videos: scoped)
            let grouped = Set(localGroups.flatMap(\.videoIDs))
            scoped.removeAll { grouped.contains($0.id) }
            if scoped.count < 2 {
                log("Duplicate scan answered by file and frame hashes")
                return AIOutcome(value: localGroups, provenance: .local(technique: "sha256-dhash"))
            }
        }
        log(useLocal ? "Local duplicate groups excluded — asking the model" : "Duplicate scan — asking the model")
        var lines: [String] = []
        var frames: [AIFrame] = []
        for (index, video) in scoped.enumerated() {
            try Task.checkCancellation()
            log("PROGRESS:\(Double(index) / Double(max(1, scoped.count)))")
            let people = ((try? await database.fetchVideoPeople(videoID: video.id)) ?? [])
                .map(\.displayName)
            var line = "- id \(video.id) | \(video.filename) | \(Int(video.duration))s | \(video.width)×\(video.height)"
            if let type = video.type?.label { line += " | \(type)" }
            if !people.isEmpty { line += " | people: \(people.joined(separator: ", "))" }
            if let research = research[video.id] { line += " | fight: \(research.fightLabel)" }
            lines.append(line)
            if let jpeg = await ThumbnailService.jpegFrame(url: video.url, at: video.duration / 2,
                                                          maxDimension: 512) {
                frames.append(AIFrame(jpeg: jpeg, label: "id \(video.id): \(video.filename)"))
            }
        }
        let response = try await ai.call(prompt: DuplicateFinder.prompt(inventory: lines.joined(separator: "\n")),
                                         task: .dedupe, frames: frames,
                                         model: model, provider: provider,
                                         timeout: 240, log: log)
        var provenance = response.provenance
        if useLocal { provenance.technique = "sha256-dhash" }
        return AIOutcome(value: DuplicateFinder.merge(localGroups + DuplicateFinder.parse(response.text, validIDs: Set(scoped.map(\.id)))),
                         provenance: provenance)
    }

    // MARK: - Content gap report

    /// A strategist's pass over the whole pipeline — what to post next,
    /// what's sitting unused, what's blocking output — as a checklist
    /// referencing actual files.
    func generateGapReport(provider: String?, model: String?,
                           log: @escaping @Sendable (String) -> Void) async throws
        -> AIOutcome<[GapReporter.Section]> {
        guard let database else { throw AIError.notConfigured("No profile is open.") }
        // Keep the inventory on its originating project while the user keeps working.
        let generatedVideos = generatedVideos, scenes = scenes, people = people
        let activeProfile = activeProfile, igAccounts = igAccounts, igBenchmarks = igBenchmarks
        let igReport = igReport, lessons = lessons
        var sceneCounts: [Int64: (total: Int, favorite: Int)] = [:]
        for scene in scenes where !scene.excluded {
            sceneCounts[scene.videoID, default: (0, 0)].total += 1
            if scene.favorite { sceneCounts[scene.videoID, default: (0, 0)].favorite += 1 }
        }
        let batchCounts = Dictionary(grouping: analysisRuns, by: \.videoID).mapValues(\.count)
        var inventory: [String] = []
        let videoLines = videos.map { video in
            var line = "- \(video.filename) | \(Int(video.duration))s | \(video.type?.label ?? "unclassified")"
            let counts = sceneCounts[video.id] ?? (0, 0)
            line += " | \(batchCounts[video.id] ?? 0) analyze batch(es), \(counts.total) scenes, \(counts.favorite) favorites"
            if fightResearch[video.id] != nil { line += " | fight research done" }
            return line
        }
        inventory.append("## SOURCE VIDEOS (\(videos.count))\n" + (videoLines.isEmpty ? "(none)" : videoLines.joined(separator: "\n")))

        let generatedLines = generatedVideos.map { video in
            var line = "- \(video.filename) | \(Int(video.duration))s | generated \(video.generatedAt ?? "?")"
            if let critique = video.critique { line += " | critic \(critique.score)/100" }
            if let stats = video.instagramStats {
                line += " | PUBLISHED — \(ReelPerformance.label(stats, duration: video.duration))"
            } else if video.instagramMediaID != nil {
                line += " | published (no insights yet)"
            } else {
                line += " | NOT published"
            }
            return line
        }
        inventory.append("## GENERATED REELS (\(generatedVideos.count))\n" + (generatedLines.isEmpty ? "(none yet)" : generatedLines.joined(separator: "\n")))

        for account in igAccounts where account.isOwn {
            let media = (try? await database.fetchIGMedia(accountID: account.id)) ?? []
            let latest = media.compactMap(\.postedAt).max()
            var line = "@\(account.username): \(media.count) reels fetched"
            if let latest {
                line += ", most recent posted \(latest.formatted(date: .abbreviated, time: .omitted))"
            }
            inventory.append("## INSTAGRAM ACCOUNT\n" + line)
        }
        if let benchmarks = igBenchmarks {
            inventory.append("## INSTAGRAM BENCHMARKS (measured from the account's reels)\n"
                             + benchmarks.summaryLines.map { "- \($0)" }.joined(separator: "\n"))
        }
        let traits = (try? await database.fetchGeneratedTraits()) ?? [:]
        let editing = PerformanceAnalytics.build(
            videos: generatedVideos, traits: traits, people: people,
            followersGained: igReport?.overview.newFollowersTotal ?? 0
        )
        if !editing.athletes.isEmpty || !editing.patterns.isEmpty {
            let athleteLines = editing.athletes.prefix(5).map {
                "- \($0.name): \(Int($0.reach)) reach, \(Int($0.views)) views, \(Int($0.shares)) shares per appearance"
            }
            inventory.append("## EDITING AND ATHLETE RETURN\n"
                + "Suggested hook: \(editing.suggestedHook ?? "unknown"); layout: \(editing.suggestedLayout ?? "unknown"); cadence: \(editing.suggestedCadence.map { "\(Int($0)) cuts/min" } ?? "unknown")\n"
                + athleteLines.joined(separator: "\n"))
        }
        let assetMetadata = (try? await database.fetchAssetMetadata()) ?? []
        let taggedPhotos = assetMetadata.count(where: {
            $0.kind == AssetKind.images.rawValue && !$0.subjects.isEmpty
        })
        let bRollAssets = assetMetadata.count(where: \.isBRoll) + scenes.count(where: \.isBRoll)
        let untaggedPhotos = assetMetadata.count(where: {
            $0.kind == AssetKind.images.rawValue && $0.subjects.isEmpty
        })
        inventory.append("## OWNED MEDIA SUGGESTIONS\n- \(taggedPhotos) searchable subject-tagged photos\n- \(bRollAssets) B-roll assets/scenes\n- \(untaggedPhotos) photos still needing subject tags\nUse available owned media as concrete edit suggestions; call out missing B-roll or photos by subject as gaps.")
        inventory.append("## TRAINING\n\(lessons.count) learned lesson(s), taste rubric \(activeProfile.tasteRubric.isEmpty ? "EMPTY" : "written"), house style \(activeProfile.houseStyle.isEmpty ? "EMPTY" : "written")")

        let response = try await ai.call(prompt: GapReporter.prompt(inventory: inventory.joined(separator: "\n\n"),
                                                                    domain: activeProfile.effectiveDomain),
                                         task: .gap, model: model, provider: provider,
                                         timeout: 240, log: log)
        let sections = GapReporter.parse(response.text)
        guard !sections.isEmpty else {
            throw AIError.unusableResponse("The report couldn't be read from the model's reply.")
        }
        return AIOutcome(value: sections, provenance: response.provenance)
    }

    // MARK: - Instagram performance lessons


    /// Correlate published reels' Instagram insights (and the account's own
    /// reels) with their traits, and distill lessons the wizard's planner
    /// treats as guidance. Replaces only its own previous batch of lessons.
    func distillPerformanceLessons() {
        guard let database, !isDistillingPerformanceLessons else { return }
        isDistillingPerformanceLessons = true
        Task {
            do {
                let published = generatedVideos.filter { $0.instagramStats != nil }
                var ownMedia: [IGMediaRecord] = []
                for account in igAccounts where account.isOwn {
                    ownMedia += (try? await database.fetchIGMedia(accountID: account.id)) ?? []
                }
                guard published.count >= 3 || ownMedia.count >= 5 || igBenchmarks != nil else {
                    throw AIError.notConfigured("Not enough performance data yet — publish reels or refresh an owned Instagram account first.")
                }
                appendLog(\.igLog, ["Distilling lessons from \(published.count) published reel(s) and \(ownMedia.count) account reel(s)…"])
                let response = try await ai.call(
                    prompt: PerformanceLessons.prompt(published: published, ownMedia: ownMedia,
                                                      benchmarks: igBenchmarks),
                    task: .distill, timeout: 240,
                    log: logSink(\.igLog))
                let distilled = PerformanceLessons.parse(response.text)
                guard !distilled.isEmpty else {
                    throw AIError.unusableResponse("No lessons came back from the model.")
                }
                // Replace only this pass's previous lessons — review-distilled
                // and pinned lessons are untouched.
                for lesson in (try? await database.fetchLessons()) ?? []
                where !lesson.pinned && lesson.evidence.hasPrefix(PerformanceLessons.evidencePrefix) {
                    try? await database.deleteLesson(id: lesson.id)
                }
                for lesson in distilled.prefix(PerformanceLessons.maxLessons) {
                    _ = try? await database.addLesson(
                        text: lesson.text, pinned: false,
                        evidence: "\(PerformanceLessons.evidencePrefix): \(lesson.evidence)",
                        provenance: response.provenance)
                }
                lessons = (try? await database.fetchLessons()) ?? lessons
                appendLog(\.igLog, ["Added \(min(PerformanceLessons.maxLessons, distilled.count)) performance lesson(s) — manage them in Settings → AI → Learned Rules."])
            } catch {
                presentError("Could not distill performance lessons", error)
            }
            isDistillingPerformanceLessons = false
        }
    }

    // MARK: - Profile starter

    /// Turn the brand interview into a founding taste rubric, house style,
    /// and starter categories — reviewed in the sheet before applying.
    func generateProfileStarter(audience: String, tone: String, inspiration: String, avoid: String,
                                provider: String?, model: String?,
                                log: @escaping @Sendable (String) -> Void) async throws
        -> AIOutcome<ProfileStarter.Result> {
        let prompt = ProfileStarter.prompt(domain: activeProfile.effectiveDomain,
                                           brand: activeProfile.brandName,
                                           audience: audience, tone: tone,
                                           inspiration: inspiration, avoid: avoid)
        let response = try await ai.call(prompt: prompt, task: .onboard,
                                         model: model, provider: provider,
                                         timeout: 240, log: log)
        guard let result = ProfileStarter.parse(response.text) else {
            throw AIError.unusableResponse("The style documents couldn't be read from the model's reply.")
        }
        return AIOutcome(value: result, provenance: response.provenance)
    }

    /// Write the reviewed starter into the profile. New categories are
    /// appended; an existing key is never overwritten (studying may have
    /// refined it already). `provenance` is stamped on whichever documents
    /// are written.
    func applyProfileStarter(_ result: ProfileStarter.Result,
                             rubric: Bool, houseStyle: Bool, categories: Bool,
                             provenance: AIProvenance?) {
        if rubric {
            activeProfile.tasteRubric = result.rubric
            activeProfile.tasteRubricProvenance = provenance
        }
        if houseStyle {
            activeProfile.houseStyle = result.houseStyle
            activeProfile.houseStyleProvenance = provenance
        }
        if categories {
            let existing = Set(activeProfile.tasteCategories.map(\.key))
            activeProfile.tasteCategories += result.categories.filter { !existing.contains($0.key) }
        }
        saveActiveProfile()
    }

    /// User pick from the Analyze table's Type column — the manual value
    /// sticks (analysis only fills the type in when it's empty).
    func setVideoType(_ video: VideoRecord, type: VideoType?) {
        guard let database else { return }
        Task {
            do {
                try await database.setVideoType(id: video.id, type: type?.rawValue)
                if let index = videos.firstIndex(where: { $0.id == video.id }) {
                    videos[index].videoType = type?.rawValue
                }
            } catch {
                presentError("Could not save the video type", error)
            }
        }
    }

    /// No UI wrappers, one-shot defaults, rename review, or error sheets. Every
    /// service below is bound to the captured DB and immutable settings.
    func captureBuilderPrerequisites() -> BuilderPrerequisiteContext? {
        guard let database else { return nil }
        let profile = activeProfile
        let project = activeProjectID
        let generation = profileGeneration
        let settings = settings
        let editingDefaults = editingDefaults
        let podcastEditingSettings = podcastEditingSettings
        let ai = AIService(config: effectiveAIConfig)
        let analyzer = Analyzer(ai: ai)
        let transcription = TranscriptionService(
            cacheDirectory: SettingsStore.cacheDirectory.appendingPathComponent("transcripts", isDirectory: true),
            podcastSettings: podcastEditingSettings, strictEnrichment: true)
        let podcast = PodcastAnalysisService(ai: ai)
        return BuilderPrerequisiteContext(database: database, profile: profile, projectID: project,
            language: editingDefaults.footage.language, isCurrent: { [weak self] in
                guard let self else { return false }
                return self.database === database && self.profileGeneration == generation
                    && self.activeProjectID == project
            }, perform: { kind, video in
                try Task.checkCancellation()
                switch kind {
                case .transcript:
                    _ = try await transcription.transcribeForVideo(video: video, database: database,
                        languageCode: editingDefaults.footage.language, force: false, log: { _ in })
                case .people:
                    _ = try await analyzer.detectPeopleOnly(video: video, profile: profile,
                        database: database, log: { _ in })
                case .analysis:
                    var video = video
                    if video.type == nil, video.duration >= 300,
                       let type = try await analyzer.classifyLongRecording(video: video, provider: nil, model: nil, log: { _ in }) {
                        try Task.checkCancellation()
                        video.videoType = type.rawValue
                        try await database.setVideoType(id: video.id, type: type.rawValue)
                    }
                    let name = "Builder prerequisite: " + video.filename
                    if video.type?.usesPodcastPass == true {
                        _ = try await podcast.analyze(video: video, profile: profile, database: database,
                            runName: name, provider: nil, model: nil, languageCode: editingDefaults.footage.language,
                            analyzer: analyzer, transcription: transcription,
                            highlightThreshold: editingDefaults.podcast.highlightThreshold,
                            holdSeconds: editingDefaults.podcast.speakerHoldSeconds, log: { _ in }, progress: { _, _ in },
                            useLocal: OnDevicePolicy.isEnabled(item: "podcast-exchanges", config: settings.ai),
                            capturedSettings: podcastEditingSettings)
                    } else {
                        let people = try await database.fetchPeople()
                        let markers = try await database.personMarkers(videoID: video.id)
                        let notes = try await database.videoNotes(videoID: video.id)
                        try Task.checkCancellation()
                        _ = try await analyzer.analyzeVisual(video: video, profile: profile, database: database,
                            runName: name, notes: notes, knownPeople: people, personMarkers: markers,
                            // The ensure gate already ruled out a successful
                            // result. A partial failed batch must not trigger the
                            // analyzer's incremental all-tags-present no-op.
                            detectPeople: true, smartSampling: true, force: true,
                            log: { _ in }, progress: { _, _ in })
                    }
                }
            })
    }

    func transcribe(video: VideoRecord, force: Bool = false) {
        guard video.isPresent else { presentError(VideoRecord.notPresentReason); return }
        guard let database, !transcribingVideoIDs.contains(video.id) else { return }
        transcribingVideoIDs.insert(video.id)
        let transcription = transcription
        let language = editingDefaults.footage.language
        transcriptionTasks[video.id] = Task {
            defer {
                transcribingVideoIDs.remove(video.id)
                transcriptionTasks[video.id] = nil
                refreshAll()
            }
            do {
                _ = try await transcription.transcribeForVideo(video: video, database: database,
                                                       languageCode: language, force: force,
                                                       log: logSink(\.analysisLog))
                appendLog(\.analysisLog, ["\(video.filename): transcription saved"])
                enqueueAutoTranslation(videoID: video.id)
            } catch is CancellationError {
                appendLog(\.analysisLog, ["\(video.filename): transcription stopped"])
            } catch {
                presentError("Transcription failed", error)
            }
        }
    }

    func cancelTranscription(videoID: Int64) {
        transcriptionTasks[videoID]?.cancel()
    }
}
