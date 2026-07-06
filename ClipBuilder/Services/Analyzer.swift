import Foundation

/// Visual analysis pipeline — the Swift port of analyzer.py's visual mode:
/// sample frames, ask the AI for tag time-ranges + moments, persist scenes.
actor Analyzer {
    static let videoExtensions: Set<String> = ["mp4", "mov", "avi", "mkv", "webm"]
    static let maxFrames = 30

    private let ai: AIService

    init(ai: AIService) {
        self.ai = ai
    }

    // MARK: - Discovery

    /// Register every video file in the profile's source folder (recursive),
    /// keyed by content fingerprint so renames/moves don't duplicate rows.
    /// Returns the number of newly discovered videos.
    @discardableResult
    func scanSourceFolder(profile: BrandProfile, database: Database) async throws -> Int {
        let folder = profile.sourceFolderURL
        let known = Set(try await database.fetchVideos().map(\.hash))
        var discovered = 0
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let item = enumerator?.nextObject() as? URL {
            guard Self.videoExtensions.contains(item.pathExtension.lowercased()) else { continue }
            guard let hash = try? ContentHash.fingerprint(of: item) else { continue }
            let duration = await FFmpeg.duration(of: item)
            let (width, height) = await FFmpeg.dimensions(of: item)
            let wide = width > 0 && height > 0 && width > height
            if !known.contains(hash) { discovered += 1 }
            try await database.registerVideo(hash: hash, filename: item.lastPathComponent,
                                             path: item.path, duration: duration,
                                             width: width, height: height, wide: wide)
        }
        return discovered
    }

    // MARK: - Frame sampling

    /// Variable-interval sampling matching analyzer.py: 1s (≤10s),
    /// 2s (≤60s), 3s (>60s); from 0.5s to duration−0.3s; max 30 frames.
    static func frameTimestamps(duration: Double) -> [Double] {
        let interval: Double = duration <= 10 ? 1.0 : (duration <= 60 ? 2.0 : 3.0)
        var timestamps: [Double] = []
        var t = 0.5
        while t < duration - 0.3 && timestamps.count < maxFrames {
            timestamps.append(t)
            t += interval
        }
        if timestamps.isEmpty && duration > 0 {
            timestamps.append(min(0.5, duration / 2))
        }
        return timestamps
    }

    private func extractFrames(url: URL, duration: Double,
                               log: @Sendable (String) -> Void) async -> [AIFrame] {
        var frames: [AIFrame] = []
        for timestamp in Self.frameTimestamps(duration: duration) {
            if let jpeg = await ThumbnailService.jpegFrame(url: url, at: timestamp) {
                frames.append(AIFrame(jpeg: jpeg, label: String(format: "%.1fs", timestamp)))
            }
        }
        return frames
    }

    // MARK: - Prompts (verbatim from analyzer.py)

    private static func tagList(_ tags: [String: [String]]) -> String {
        tags.sorted { $0.key < $1.key }
            .map { "  \($0.key.uppercased()): \($0.value.joined(separator: ", "))" }
            .joined(separator: "\n") + "\n"
    }

    private static func fullAnalysisPrompt(domain: String, duration: Double, tags: [String: [String]]) -> String {
        """
        You are analyzing frames from a \(domain) video.
        Video duration: \(String(format: "%.1f", duration))s. Frames are shown at their timestamps.

        Your job: produce a TAG-CENTRIC analysis. For each tag that applies to this
        video, provide the TIME RANGES where that tag is present. Also note any
        important moments (dialog, key events).

        AVAILABLE TAGS (only use tags from this list):
        \(tagList(tags))
        Return a JSON object with this exact structure:
        {
          "tags": {
            "tag_name": [{"start": 0.0, "end": 5.2}, {"start": 12.0, "end": 18.5}],
            "another_tag": [{"start": 0.0, "end": 30.0}]
          },
          "moments": [
            {"at": 3.5, "note": "clean right hook lands", "dialog": null},
            {"at": 15.0, "note": "coach gives instructions", "dialog": "Mao na cara dele [EN: Hand on his face]"}
          ]
        }

        RULES:
        - Only include tags that actually appear in the video
        - Time ranges can overlap -- e.g. "striking" and "high-energy" can cover different ranges
        - A tag can have multiple ranges if it appears at different times
        - Be precise with timestamps -- use the frame timestamps as anchors
        - Ranges must be within 0.0 to \(String(format: "%.1f", duration))
        - A broad tag like "cage" can span the entire video if applicable
        - For "moments": include dialog/speech (with English translation if not English),
          key events, visible on-screen text, and any notable points useful for montage editing
        - Apply "low-quality" to ranges that are unusable for a highlight reel:
          badly out-of-focus, motion-blurred to the point of being unreadable,
          black/blank/transition frames, severe shaky-cam, accidental footage
          (filmer's feet, lens cap), or visually broken (compression artifacts).
          Do NOT apply "low-quality" just because the action is calm or boring --
          only when the FOOTAGE itself is unusable.
        - Return ONLY the JSON object, no markdown fences, no explanation
        """
    }

    private static func incrementalPrompt(domain: String, duration: Double, newTags: [String]) -> String {
        """
        You are analyzing frames from a \(domain) video.
        Video duration: \(String(format: "%.1f", duration))s. Frames are shown at their timestamps.

        This video has already been analyzed for some tags. Now I need you to check
        for ONLY these NEW tags:
        \(newTags.sorted().joined(separator: ", "))

        For each of these tags that appears in the video, provide the time ranges
        where it is present. Skip any tag that doesn't apply.

        Return a JSON object:
        {
          "tags": {
            "tag_name": [{"start": 0.0, "end": 5.2}, ...],
            ...
          }
        }

        RULES:
        - Only check for the tags listed above -- ignore everything else
        - Time ranges must be within 0.0 to \(String(format: "%.1f", duration))
        - Be precise with timestamps using the frame timestamps as anchors
        - Return ONLY the JSON object, no markdown fences, no explanation
        - If NONE of the new tags apply, return: {"tags": {}}
        """
    }

    // MARK: - Analysis

    /// Full visual analysis of one video. If the video was analyzed before
    /// and only new tags were added to the schema, runs the cheaper
    /// incremental pass instead.
    func analyzeVisual(video: VideoRecord,
                       profile: BrandProfile,
                       database: Database,
                       provider: String? = nil,
                       model: String? = nil,
                       log: @escaping @Sendable (String) -> Void,
                       progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let tags = profile.effectiveTags
        let allTags = Set(tags.values.flatMap { $0 })
        let domain = profile.effectiveDomain
        let duration = video.duration > 0 ? video.duration : await FFmpeg.duration(of: video.url)

        let alreadyAnalyzed = try await database.analyzedTags(videoID: video.id)
        let newTags = allTags.subtracting(alreadyAnalyzed)
        let isIncremental = video.visualAnalyzedAt != nil && !alreadyAnalyzed.isEmpty
        if isIncremental && newTags.isEmpty {
            log("\(video.filename): all tags already analyzed — skipping")
            return
        }

        progress(0.05, "extracting frames")
        log("Extracting frames from \(video.filename)...")
        let frames = await extractFrames(url: video.url, duration: duration, log: log)
        guard !frames.isEmpty else {
            throw FFmpegError.commandFailed(tool: "frame extraction", exitCode: 1,
                                            stderr: "no frames could be extracted from \(video.filename)")
        }

        let prompt: String
        let tagsToRecord: [String]
        if isIncremental {
            prompt = Self.incrementalPrompt(domain: domain, duration: duration, newTags: Array(newTags))
            tagsToRecord = Array(newTags)
            progress(0.25, "tagging \(newTags.count) new tags")
            log("Extracted \(frames.count) frames, checking \(newTags.count) new tags...")
        } else {
            prompt = Self.fullAnalysisPrompt(domain: domain, duration: duration, tags: tags)
            tagsToRecord = Array(allTags)
            progress(0.25, "tagging (\(frames.count) frames)")
            log("Extracted \(frames.count) frames, sending for full analysis...")
        }

        let response = try await ai.call(prompt: prompt, task: "analysis", frames: frames,
                                         model: model, provider: provider, timeout: 300, log: log)
        guard let object = AIResponseParser.jsonObject(from: response) else {
            throw AIError.emptyResponse("analysis (unparseable JSON)")
        }

        // Clamp + validate ranges against the tag vocabulary.
        var cleanTags: [String: [(start: Double, end: Double)]] = [:]
        if let rawTags = object["tags"] as? [String: Any] {
            for (tag, value) in rawTags {
                guard allTags.contains(tag), let ranges = value as? [[String: Any]] else { continue }
                var clean: [(Double, Double)] = []
                for range in ranges {
                    let start = max(0, ((range["start"] as? NSNumber)?.doubleValue ?? 0).rounded(toPlaces: 1))
                    let end = min(duration, ((range["end"] as? NSNumber)?.doubleValue ?? duration).rounded(toPlaces: 1))
                    if end > start { clean.append((start, end)) }
                }
                if !clean.isEmpty { cleanTags[tag] = clean }
            }
        }

        var cleanMoments: [(at: Double, note: String, dialog: String?)] = []
        if let rawMoments = object["moments"] as? [[String: Any]] {
            for moment in rawMoments {
                let at = ((moment["at"] as? NSNumber)?.doubleValue ?? -1).rounded(toPlaces: 1)
                guard at >= 0, at <= duration else { continue }
                cleanMoments.append((at, moment["note"] as? String ?? "", moment["dialog"] as? String))
            }
        }

        progress(0.95, "saving")
        log("Got \(cleanTags.count) tags, \(cleanMoments.count) moments")
        let attribution = await ai.resolveProviderModel(task: "analysis", provider: provider, model: model)
        try await database.saveAnalysis(videoID: video.id,
                                        tagRanges: cleanTags,
                                        moments: cleanMoments,
                                        analyzedTags: tagsToRecord,
                                        provider: attribution.provider,
                                        model: attribution.model,
                                        mode: "visual")
        progress(1.0, "done")
    }
}

nonisolated extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
