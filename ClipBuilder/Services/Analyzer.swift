import AppKit
import Foundation
import Vision

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
    static let maxCustomFrames = 120

    /// Variable-interval sampling matching analyzer.py: 1s (≤10s),
    /// 2s (≤60s), 3s (>60s); from 0.5s to duration−0.3s; max 30 frames.
    /// A non-nil `interval` overrides the automatic choice, capped at 120
    /// frames — when the requested density exceeds the cap, the interval is
    /// stretched so the frames still cover the WHOLE video evenly instead of
    /// only its first seconds.
    static func frameTimestamps(duration: Double, interval custom: Double? = nil) -> [Double] {
        var interval = custom ?? (duration <= 10 ? 1.0 : (duration <= 60 ? 2.0 : 3.0))
        let cap = custom == nil ? maxFrames : maxCustomFrames
        let span = max(0, duration - 0.8)
        if span / max(0.2, interval) >= Double(cap) {
            interval = span / Double(cap - 1)
        }
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
            if wanted > timestamps.count, timestamps.count > 1 {
                log(String(format: "Sampling every %.1fs exceeds the %d-frame budget — stretched to every %.1fs across the whole video",
                           interval, timestamps.count, timestamps[1] - timestamps[0]))
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

    /// The people breakdown: every distinct person gets a stable key. Known
    /// people from earlier videos ride along (with the user's names) so the
    /// same person keeps one identity across the whole library. The filename
    /// often carries the subjects' real names — offered for matching known
    /// people and for suggesting names on new ones.
    /// nil = people detection off for this run: no block at all.
    private static func peopleBlock(_ knownPeople: [PersonRecord]?, filename: String) -> String {
        guard let knownPeople else { return "" }
        let known = knownPeople.isEmpty ? "None yet — every person you find is new." :
            knownPeople.map { person in
                let named = person.name.isEmpty ? "" : " (the user calls them \"\(person.name)\")"
                return "  - key \"\(person.key)\": \(person.descriptor)\(named)"
            }.joined(separator: "\n")
        return """

        ## PEOPLE BREAKDOWN (always include)
        Identify each DISTINCT person who appears clearly in the video (skip incidental background passers-by).
        KNOWN PEOPLE from this library — when someone in the frames is visually the same person, REUSE their exact key:
        \(known)
        The video's filename is "\(filename)". Filenames often carry the real names of the people in the footage — use them two ways:
        - If a filename name matches a KNOWN person's name above, that is strong evidence to reuse their key.
        - For a person you invent a NEW key for, set "suggested_name" to the filename name you are confident belongs to them (null when unsure or when the filename has no names). Copy names verbatim; never invent one.
        In your JSON response, ALSO include a top-level "people" array:
        "people": [{"key": "<known key, or a new kebab-case slug you invent>", "description": "<concise visual description: build, hair, clothing, distinguishing marks>", "suggested_name": "<name from the filename, or null>", "ranges": [{"start": 0.0, "end": 5.2}]}]
        Rules: reuse a known key ONLY when confident it is the same person; invent a new key otherwise; one entry per person; ranges cover where that person is clearly visible.

        """
    }

    /// The ground-truth block for user-drawn identity boxes: each marker has
    /// a matching cropped portrait image riding along with the frames.
    private static func markerBlock(_ markers: [(marker: PersonMarker, person: PersonRecord)]) -> String {
        guard !markers.isEmpty else { return "" }
        let lines = markers.map { entry in
            String(format: "- At %.1fs: \"%@\" — REUSE their exact key \"%@\"",
                   entry.marker.atTime, entry.person.displayName, entry.person.key)
        }.joined(separator: "\n")
        return """

        ## PERSON MARKERS (ground truth from the user — absolute)
        The user drew a box around specific people. Each marker below has a matching image labeled "PERSON MARKER: <name> at <time>s" — a crop showing EXACTLY that person at that moment.
        \(lines)
        Treat these identities as fact: study each portrait, recognize the same person everywhere they appear in the frames, and use their exact key in the people breakdown and tag ranges. Never assign a marker's key to someone who doesn't match its portrait, and never invent a new key for a marked person.

        """
    }

    private static func fullAnalysisPrompt(domain: String, duration: Double, tags: [String: [String]],
                                           instructions: String, notes: [VideoNote],
                                           notesHaveReferenceFrames: Bool,
                                           knownPeople: [PersonRecord]?,
                                           markers: [(marker: PersonMarker, person: PersonRecord)],
                                           filename: String) -> String {
        """
        You are analyzing frames from a \(domain) video.
        Video duration: \(String(format: "%.1f", duration))s. Frames are shown at their timestamps.
        \(instructionsBlock(instructions))\(notesBlock(notes, withReferenceFrames: notesHaveReferenceFrames))\(peopleBlock(knownPeople, filename: filename))\(markerBlock(markers))
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
    /// results were stored under (nil when the pass was skipped) plus the
    /// people first detected in this pass, for the end-of-run review sheet.
    @discardableResult
    func analyzeVisual(video: VideoRecord,
                       profile: BrandProfile,
                       database: Database,
                       runName: String,
                       provider: String? = nil,
                       model: String? = nil,
                       instructions: String = "",
                       notes: [VideoNote] = [],
                       knownPeople: [PersonRecord] = [],
                       personMarkers: [PersonMarker] = [],
                       detectPeople: Bool = true,
                       sampleInterval: Double? = nil,
                       force: Bool = false,
                       log: @escaping @Sendable (String) -> Void,
                       progress: @escaping @Sendable (Double, String) -> Void) async throws
        -> (runID: Int64?, newPeople: [DetectedNewPerson]) {
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
            return (nil, [])
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

        // User-drawn identity boxes become ground-truth portraits: each
        // marker's crop shows exactly who the user says it is, so the model
        // stops guessing at people recognition.
        let peopleByID = Dictionary(uniqueKeysWithValues: knownPeople.map { ($0.id, $0) })
        let namedMarkers: [(marker: PersonMarker, person: PersonRecord)] = detectPeople
            ? personMarkers.compactMap { marker in
                marker.personID.flatMap { peopleByID[$0] }.map { (marker, $0) }
            }
            : []
        var markerFrames: [AIFrame] = []
        if !namedMarkers.isEmpty {
            markerFrames = ((try? await BoundedConcurrency.map(namedMarkers, limit: FFmpeg.jobLimit) { _, entry in
                let at = min(max(0, entry.marker.atTime), max(0, duration - 0.1))
                guard let data = await ThumbnailService.jpegFrame(url: video.url, at: at),
                      let portrait = Self.markerPortrait(from: data, marker: entry.marker) else {
                    return nil as AIFrame?
                }
                return AIFrame(jpeg: portrait,
                               label: String(format: "PERSON MARKER: %@ at %.1fs",
                                             entry.person.displayName, entry.marker.atTime))
            }) ?? []).compactMap { $0 }
            if !markerFrames.isEmpty {
                log("Attached \(markerFrames.count) person marker portrait(s): "
                    + namedMarkers.map(\.person.displayName).joined(separator: ", "))
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
                                             knownPeople: detectPeople ? knownPeople : nil,
                                             markers: namedMarkers,
                                             filename: video.filename)
            tagsToRecord = Array(allTags)
            progress(0.25, "tagging (\(frames.count) frames)")
            log("Extracted \(frames.count) frames, sending for full analysis...")
        }

        let response = try await ai.call(prompt: prompt, task: "analysis",
                                         frames: referenceFrames + markerFrames + frames,
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

        // People breakdown: each detected person becomes a registry upsert
        // plus "person:<key>" tag ranges (searchable exactly like other tags).
        var detectedPeople: [(key: String, description: String,
                              suggestedName: String?, firstSeen: (start: Double, end: Double))] = []
        if detectPeople, !isIncremental, let rawPeople = object["people"] as? [[String: Any]] {
            var seenKeys = Set<String>()
            for entry in rawPeople {
                let rawKey = (entry["key"] as? String ?? "").lowercased()
                var key = rawKey.map { $0.isLetter || $0.isNumber ? $0 : "-" }
                    .reduce(into: "") { result, character in
                        if character != "-" || result.last != "-" { result.append(character) }
                    }
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                if key.isEmpty { key = "person-\(seenKeys.count + 1)" }
                guard !seenKeys.contains(key) else { continue }
                seenKeys.insert(key)
                let description = (entry["description"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let suggestedName = (entry["suggested_name"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var clean: [(Double, Double)] = []
                for range in entry["ranges"] as? [[String: Any]] ?? [] {
                    let start = max(0, ((range["start"] as? NSNumber)?.doubleValue ?? 0).rounded(toPlaces: 1))
                    let end = min(duration, ((range["end"] as? NSNumber)?.doubleValue ?? 0).rounded(toPlaces: 1))
                    if end > start { clean.append((start, end)) }
                }
                guard !clean.isEmpty else { continue }
                detectedPeople.append((key, description,
                                       suggestedName?.isEmpty == false ? suggestedName : nil,
                                       clean[0]))
                cleanTags["person:\(key)", default: []].append(contentsOf: clean)
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
        var newPeople: [DetectedNewPerson] = []
        if !detectedPeople.isEmpty {
            let known = Set(knownPeople.map(\.key))
            let namesByKey = Dictionary(uniqueKeysWithValues: knownPeople.map { ($0.key, $0.displayName) })
            let new = detectedPeople.filter { !known.contains($0.key) }
            let summary = detectedPeople.map { person in
                let sceneCount = cleanTags["person:\(person.key)"]?.count ?? 0
                let name = known.contains(person.key)
                    ? (namesByKey[person.key] ?? person.key)
                    : "NEW: \(person.suggestedName ?? person.key)"
                return "\(name) (\(sceneCount) scene\(sceneCount == 1 ? "" : "s"))"
            }.joined(separator: ", ")
            log("People: \(detectedPeople.count) detected"
                + (new.isEmpty ? "" : " (\(new.count) new)")
                + " — \(summary)")
            for person in detectedPeople {
                try await database.upsertPerson(key: person.key, descriptor: person.description)
            }
            newPeople = new.map { person in
                DetectedNewPerson(key: person.key, descriptor: person.description,
                                  suggestedName: person.suggestedName,
                                  videoURL: video.url, videoFilename: video.filename,
                                  sampleTime: (person.firstSeen.start + person.firstSeen.end) / 2)
            }
        }
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

        // Local portrait-fit pass on wide footage: score how well each new
        // scene's people fit a 9:16 crop, so the wizard can prefer moments
        // where nobody gets cut off. Pure Vision — no AI cost.
        if video.wide {
            progress(0.97, "portrait fit")
            let ranges = (try? await database.sceneRanges(runID: runID)) ?? []
            var good = 0, poor = 0
            for range in ranges {
                try Task.checkCancellation()
                guard let fits = await Self.portraitFit(url: video.url,
                                                        start: range.start, end: range.end,
                                                        videoWidth: video.width,
                                                        videoHeight: video.height) else { continue }
                try? await database.addSceneTag(sceneID: range.id,
                                                tag: fits ? "portrait-fit:good" : "portrait-fit:poor")
                if fits { good += 1 } else { poor += 1 }
            }
            if good + poor > 0 {
                log("Portrait fit: \(good) scene(s) crop-friendly for 9:16, \(poor) too spread out")
            }
        }
        progress(1.0, "done")
        return (runID, newPeople)
    }

    /// Whether the people in [start, end] sit close enough together for a
    /// full-height 9:16 crop to hold them all. Samples three frames, unions
    /// the detected human boxes per frame, majority-votes; nil when no
    /// people are detected at all.
    nonisolated static func portraitFit(url: URL, start: Double, end: Double,
                                        videoWidth: Int, videoHeight: Int) async -> Bool? {
        guard videoWidth > 0, videoHeight > 0 else { return nil }
        // Fraction of the frame width a full-height 9:16 crop covers.
        let cropFraction = (9.0 / 16.0) * Double(videoHeight) / Double(videoWidth)
        let duration = end - start
        var good = 0, judged = 0
        for fraction in [0.25, 0.5, 0.75] {
            guard let data = await ThumbnailService.jpegFrame(url: url, at: start + duration * fraction,
                                                              maxDimension: 720) else { continue }
            let request = VNDetectHumanRectanglesRequest()
            request.upperBodyOnly = false
            try? VNImageRequestHandler(data: data).perform([request])
            let boxes = (request.results ?? []).map(\.boundingBox)
            guard !boxes.isEmpty else { continue }
            judged += 1
            let union = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
            // 10% slack: the crop pans onto the action (auto-crop and Center
            // Stage alike), so near-fits still frame everyone.
            if Double(union.width) <= cropFraction * 1.1 { good += 1 }
        }
        guard judged > 0 else { return nil }
        return good * 2 >= judged
    }
}

nonisolated extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}

extension Analyzer {
    /// Crop a frame to a marker's box (with breathing room) — the portrait
    /// the model gets as ground truth for that person.
    nonisolated static func markerPortrait(from data: Data, marker: PersonMarker) -> Data? {
        guard let image = NSImage(data: data),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        let pad = 0.2
        let rect = CGRect(x: (marker.x - marker.width * pad) * width,
                          y: (marker.y - marker.height * pad) * height,
                          width: marker.width * (1 + 2 * pad) * width,
                          height: marker.height * (1 + 2 * pad) * height)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !rect.isEmpty, let cropped = cg.cropping(to: rect) else { return nil }
        return NSBitmapImageRep(cgImage: cropped)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
