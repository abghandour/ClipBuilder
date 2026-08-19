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

    /// Probe format version. v3 reports display (rotation-applied)
    /// dimensions — rows probed earlier may carry sideways width/height and a
    /// wrong `wide` flag, so bumping this forces one full re-probe per DB.
    static let probeVersion = 3

    /// Register every video file in the profile's source folder (recursive),
    /// keyed by content fingerprint so renames/moves don't duplicate rows.
    /// Returns the number of newly discovered videos.
    @discardableResult
    func scanSourceFolder(profile: BrandProfile, database: Database) async throws -> Int {
        let folder = profile.sourceFolderURL
        let probeVersionKey = "analyzer.probeVersion.\(profile.profileName)"
        let reprobeAll = UserDefaults.standard.integer(forKey: probeVersionKey) < Self.probeVersion
        let known = Dictionary(try await database.fetchVideos().map { ($0.hash, ($0.path, $0.duration)) },
                               uniquingKeysWith: { first, _ in first })
        var candidates: [(url: URL, hash: String)] = []
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let item = enumerator?.nextObject() as? URL {
            guard Self.videoExtensions.contains(item.pathExtension.lowercased()) else { continue }
            guard let hash = try? ContentHash.fingerprint(of: item) else { continue }
            // Known and unmoved — skip the probes; rescans fire on every
            // folder event, so this must be cheap for existing files. A zero
            // duration means the registration probe failed (e.g. ffmpeg was
            // missing), so those rows get re-probed.
            if !reprobeAll, let (path, duration) = known[hash], path == item.path, duration > 0 { continue }
            candidates.append((item, hash))
        }
        let probed = try await BoundedConcurrency.map(candidates, limit: FFmpeg.jobLimit) { _, candidate in
            (candidate, await FFmpeg.info(of: candidate.url))
        }
        var discovered = 0
        for (candidate, info) in probed {
            let wide = info.width > 0 && info.height > 0 && info.width > info.height
            if known[candidate.hash] == nil { discovered += 1 }
            try await database.registerVideo(hash: candidate.hash, filename: candidate.url.lastPathComponent,
                                             path: candidate.url.path, duration: info.duration,
                                             width: info.width, height: info.height, wide: wide)
        }
        // Only after every row was rewritten — a thrown probe retries the
        // full pass on the next scan.
        if reprobeAll {
            UserDefaults.standard.set(Self.probeVersion, forKey: probeVersionKey)
        }
        return discovered
    }

    // MARK: - Frame sampling

    /// A user-chosen interval may sample denser than the automatic mode.
    static let maxCustomFrames = 60

    /// Variable-interval sampling matching analyzer.py: 1s (≤10s),
    /// 2s (≤60s), 3s (>60s); from 0.5s to duration−0.3s; max 30 frames.
    /// A non-nil `interval` overrides the automatic choice (capped at 60
    /// frames so a dense interval on long footage can't explode the call).
    static func frameTimestamps(duration: Double, interval custom: Double? = nil) -> [Double] {
        let interval = custom ?? (duration <= 10 ? 1.0 : (duration <= 60 ? 2.0 : 3.0))
        let cap = custom == nil ? maxFrames : maxCustomFrames
        var timestamps: [Double] = []
        var t = 0.5
        while t < duration - 0.3 && timestamps.count < cap {
            timestamps.append(t)
            t += max(0.2, interval)
        }
        if timestamps.isEmpty && duration > 0 {
            timestamps.append(min(0.5, duration / 2))
        }
        return timestamps
    }

    private func extractFrames(url: URL, duration: Double, interval: Double?,
                               log: @Sendable (String) -> Void) async -> [AIFrame] {
        let timestamps = Self.frameTimestamps(duration: duration, interval: interval)
        if let interval {
            let wanted = Int(((duration - 0.8) / max(0.2, interval)).rounded(.up))
            if wanted > timestamps.count {
                log(String(format: "Sampling every %.1fs capped at %d frames", interval, timestamps.count))
            } else {
                log(String(format: "Sampling every %.1fs (%d frames)", interval, timestamps.count))
            }
        }
        let frames = (try? await BoundedConcurrency.map(timestamps, limit: FFmpeg.jobLimit) { _, timestamp in
            await ThumbnailService.jpegFrame(url: url, at: timestamp).map {
                AIFrame(jpeg: $0, label: String(format: "%.1fs", timestamp))
            }
        }) ?? []
        return frames.compactMap { $0 }
    }

    // MARK: - Prompts (verbatim from analyzer.py)

    private static func tagList(_ tags: [String: [String]]) -> String {
        tags.sorted { $0.key < $1.key }
            .map { "  \($0.key.uppercased()): \($0.value.joined(separator: ", "))" }
            .joined(separator: "\n") + "\n"
    }

    /// User-supplied context injected ahead of the tagging rules.
    private static func instructionsBlock(_ instructions: String) -> String {
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return """

        ## USER CONTEXT (HIGHEST PRIORITY — apply this when tagging and noting moments)
        \(trimmed)

        If this context RESTRICTS what footage to include (e.g. "only scenes with a particular person"), treat it as a HARD FILTER: omit every time range where the restriction is not met, even if tags would otherwise apply there. Returning fewer ranges — or none at all — is the correct behavior when little or nothing matches. Never tag excluded footage "just in case".

        """
    }

    /// Timestamped, per-video notes — the model relates each to the nearest
    /// sampled frames. When `withReferenceFrames`, each note's exact anchor
    /// frame rides along so the model can resolve what the note points at.
    private static func notesBlock(_ notes: [VideoNote], withReferenceFrames: Bool) -> String {
        guard !notes.isEmpty else { return "" }
        let lines = notes
            .sorted { $0.atTime < $1.atTime }
            .map { String(format: "- at %.1fs: %@", $0.atTime, $0.note) }
            .joined(separator: "\n")
        let referenceGuidance = withReferenceFrames ? """
        Each note has a matching image labeled "REFERENCE for note at Xs" — the exact frame the user was looking at when they wrote it. Use it to resolve what the note refers to (e.g. which person "this guy" is), then apply the note.
        """ : ""
        return """

        ## USER NOTES FOR THIS VIDEO (HIGHEST PRIORITY — each anchored at a video timestamp)
        \(lines)
        \(referenceGuidance)
        Relate each note to the frames nearest its timestamp and let it guide your tagging and moments around that part of the video. If a note states a video-wide restriction (e.g. "only include scenes with this person"), treat it as a HARD FILTER for the whole video: omit every time range where the restriction is not met.

        """
    }

    /// VIP subjects marked by the user — each rides with reference frame(s)
    /// showing a colored box around the person, and the model is asked to
    /// return per-subject time ranges alongside the tags.
    private static func subjectsBlock(_ subjects: [VideoSubject]) -> String {
        guard !subjects.isEmpty else { return "" }
        let lines = subjects.map { subject in
            let times = subject.rects.map { String(format: "%.1fs", $0.at) }.joined(separator: ", ")
            return "- \"\(subject.name)\" — \(subject.colorName) box; reference frame(s) at \(times)"
        }.joined(separator: "\n")
        let example = subjects[0].name
        return """

        ## VIP SUBJECTS (user-marked people — identify them from their reference boxes)
        \(lines)
        Each subject has reference image(s) labeled "SUBJECT <name> (<color> box) at Xs" — the colored rectangle marks exactly who that name refers to. Learn each subject's appearance (build, clothing, hair, position) from their reference image(s), then track them across ALL sampled frames.
        In your JSON response, ALSO include a top-level "subjects" object mapping each subject's exact name to the time ranges where that person is clearly visible:
        "subjects": {"\(example)": [{"start": 0.0, "end": 5.2}]}
        Only include ranges where you can identify the person with confidence; omit a subject entirely if they never appear. If the user context or notes restrict footage to a subject (e.g. "only include scenes with \(example)"), treat that restriction as a HARD FILTER on the tag ranges too.

        """
    }

    private static func fullAnalysisPrompt(domain: String, duration: Double, tags: [String: [String]],
                                           instructions: String, notes: [VideoNote],
                                           notesHaveReferenceFrames: Bool,
                                           subjects: [VideoSubject]) -> String {
        """
        You are analyzing frames from a \(domain) video.
        Video duration: \(String(format: "%.1f", duration))s. Frames are shown at their timestamps.
        \(instructionsBlock(instructions))\(notesBlock(notes, withReferenceFrames: notesHaveReferenceFrames))\(subjectsBlock(subjects))
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

    private static func incrementalPrompt(domain: String, duration: Double, newTags: [String],
                                          instructions: String, notes: [VideoNote],
                                          notesHaveReferenceFrames: Bool) -> String {
        """
        You are analyzing frames from a \(domain) video.
        Video duration: \(String(format: "%.1f", duration))s. Frames are shown at their timestamps.
        \(instructionsBlock(instructions))\(notesBlock(notes, withReferenceFrames: notesHaveReferenceFrames))
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
    /// incremental pass instead. Returns the id of the analyze batch the
    /// results were stored under (nil when the pass was skipped).
    @discardableResult
    func analyzeVisual(video: VideoRecord,
                       profile: BrandProfile,
                       database: Database,
                       runName: String,
                       provider: String? = nil,
                       model: String? = nil,
                       instructions: String = "",
                       notes: [VideoNote] = [],
                       subjects: [VideoSubject] = [],
                       sampleInterval: Double? = nil,
                       force: Bool = false,
                       log: @escaping @Sendable (String) -> Void,
                       progress: @escaping @Sendable (Double, String) -> Void) async throws -> Int64? {
        guard FFmpeg.isAvailable else { throw FFmpegError.toolNotFound("ffmpeg") }
        let tags = profile.effectiveTags
        let allTags = Set(tags.values.flatMap { $0 })
        let domain = profile.effectiveDomain
        let duration = video.duration > 0 ? video.duration : await FFmpeg.duration(of: video.url)

        let alreadyAnalyzed = try await database.analyzedTags(videoID: video.id)
        let newTags = allTags.subtracting(alreadyAnalyzed)
        // A forced re-run always does the full pass, ignoring what was
        // analyzed before (the caller decides whether old scenes survive).
        let isIncremental = !force && video.visualAnalyzedAt != nil && !alreadyAnalyzed.isEmpty
        if !force && isIncremental && newTags.isEmpty {
            log("\(video.filename): all tags already analyzed — skipping")
            return nil
        }

        progress(0.05, "extracting frames")
        log("Extracting frames from \(video.filename)...")
        let frames = await extractFrames(url: video.url, duration: duration,
                                         interval: sampleInterval, log: log)
        guard !frames.isEmpty else {
            throw FFmpegError.commandFailed(tool: "frame extraction", exitCode: 1,
                                            stderr: "no frames could be extracted from \(video.filename)")
        }

        // Each note also sends the exact frame the user paused on when
        // writing it — the sampled grid can miss that moment, and deictic
        // notes ("this guy") are unresolvable without it.
        var referenceFrames: [AIFrame] = []
        if !notes.isEmpty {
            referenceFrames = ((try? await BoundedConcurrency.map(notes, limit: FFmpeg.jobLimit) { _, note in
                let at = min(max(0, note.atTime), max(0, duration - 0.1))
                return await ThumbnailService.jpegFrame(url: video.url, at: at).map {
                    AIFrame(jpeg: $0, label: String(format: "REFERENCE for note at %.1fs", note.atTime))
                }
            }) ?? []).compactMap { $0 }
            if !referenceFrames.isEmpty {
                log("Attached \(referenceFrames.count) reference frame(s) for the video notes")
            }
        }

        // Each VIP subject's boxes ride as annotated frames — the model can't
        // learn who "Person A" is from a name alone.
        var subjectFrames: [AIFrame] = []
        if !subjects.isEmpty {
            let boxes = subjects.flatMap { subject in
                subject.rects.prefix(4).map { (subject: subject, rect: $0) }
            }
            subjectFrames = ((try? await BoundedConcurrency.map(boxes, limit: FFmpeg.jobLimit) { _, box in
                let at = min(max(0, box.rect.at), max(0, duration - 0.1))
                return await ThumbnailService.subjectReferenceJPEG(url: video.url, at: at,
                                                                   rect: box.rect,
                                                                   colorIndex: box.subject.colorIndex).map {
                    AIFrame(jpeg: $0, label: String(format: "SUBJECT %@ (%@ box) at %.1fs",
                                                    box.subject.name, box.subject.colorName, box.rect.at))
                }
            }) ?? []).compactMap { $0 }
            if !subjectFrames.isEmpty {
                log("Attached \(subjectFrames.count) VIP reference frame(s) for "
                    + subjects.map(\.name).joined(separator: ", "))
            }
        }

        let prompt: String
        let tagsToRecord: [String]
        if isIncremental {
            prompt = Self.incrementalPrompt(domain: domain, duration: duration, newTags: Array(newTags),
                                            instructions: instructions, notes: notes,
                                            notesHaveReferenceFrames: !referenceFrames.isEmpty)
            tagsToRecord = Array(newTags)
            progress(0.25, "tagging \(newTags.count) new tags")
            log("Extracted \(frames.count) frames, checking \(newTags.count) new tags...")
        } else {
            prompt = Self.fullAnalysisPrompt(domain: domain, duration: duration, tags: tags,
                                             instructions: instructions, notes: notes,
                                             notesHaveReferenceFrames: !referenceFrames.isEmpty,
                                             subjects: subjects)
            tagsToRecord = Array(allTags)
            progress(0.25, "tagging (\(frames.count) frames)")
            log("Extracted \(frames.count) frames, sending for full analysis...")
        }

        let response = try await ai.call(prompt: prompt, task: "analysis",
                                         frames: referenceFrames + subjectFrames + frames,
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

        // Subject ranges land as "vip:<name>" scene tags — filterable in the
        // Scenes browser and referenceable by name from wizard instructions.
        if !subjects.isEmpty, let rawSubjects = object["subjects"] as? [String: Any] {
            let byLowerName = Dictionary(subjects.map { ($0.name.lowercased(), $0) },
                                         uniquingKeysWith: { first, _ in first })
            for (name, value) in rawSubjects {
                guard let subject = byLowerName[name.trimmingCharacters(in: .whitespaces).lowercased()],
                      let ranges = value as? [[String: Any]] else { continue }
                var clean: [(Double, Double)] = []
                for range in ranges {
                    let start = max(0, ((range["start"] as? NSNumber)?.doubleValue ?? 0).rounded(toPlaces: 1))
                    let end = min(duration, ((range["end"] as? NSNumber)?.doubleValue ?? duration).rounded(toPlaces: 1))
                    if end > start { clean.append((start, end)) }
                }
                if !clean.isEmpty { cleanTags[subject.tag, default: []].append(contentsOf: clean) }
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
        // Notes live on the video and can change later — snapshot the set
        // this run actually used so the batch info stays truthful.
        let noteSnapshot = notes
            .sorted { $0.atTime < $1.atTime }
            .map { AnalysisRunNote(at: $0.atTime, note: $0.note) }
        let notesJSON = (try? JSONEncoder().encode(noteSnapshot))
            .flatMap { String(data: $0, encoding: .utf8) }
        let runID = try await database.saveAnalysis(videoID: video.id,
                                                    runName: runName,
                                                    instructions: instructions,
                                                    sampleInterval: sampleInterval,
                                                    notesJSON: notesJSON,
                                                    tagRanges: cleanTags,
                                                    moments: cleanMoments,
                                                    analyzedTags: tagsToRecord,
                                                    provider: attribution.provider,
                                                    model: attribution.model,
                                                    mode: "visual")
        progress(1.0, "done")
        return runID
    }
}

nonisolated extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
