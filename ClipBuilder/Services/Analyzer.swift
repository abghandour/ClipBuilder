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

    /// Scenes shorter than this aren't worth a breakdown pass — they're
    /// already about one action long.
    static let minBreakdownDuration = 8.0

    /// Variable-interval sampling matching analyzer.py: 1s (≤10s),
    /// 2s (≤60s), 3s (>60s); from 0.5s to duration−0.3s; max 30 frames.
    /// A non-nil `interval` overrides the automatic choice, capped at 120
    /// frames — when the requested density exceeds the cap, the interval is
    /// stretched so the frames still cover the WHOLE video evenly instead of
    /// only its first seconds.
    static func frameTimestamps(duration: Double, interval custom: Double? = nil) -> [Double] {
        frameTimestamps(start: 0, end: duration, interval: custom)
    }

    /// Windowed variant: samples only [start, end] (a trim range).
    static func frameTimestamps(start: Double, end: Double,
                                interval custom: Double? = nil) -> [Double] {
        let windowSpan = end - start
        var interval = custom ?? (windowSpan <= 10 ? 1.0 : (windowSpan <= 60 ? 2.0 : 3.0))
        let cap = custom == nil ? maxFrames : maxCustomFrames
        let span = max(0, windowSpan - 0.8)
        if span / max(0.2, interval) >= Double(cap) {
            interval = span / Double(cap - 1)
        }
        var timestamps: [Double] = []
        var t = start + 0.5
        while t < end - 0.3 && timestamps.count < cap {
            timestamps.append(t)
            t += max(0.2, interval)
        }
        if timestamps.isEmpty && windowSpan > 0 {
            timestamps.append(start + min(0.5, windowSpan / 2))
        }
        return timestamps
    }

    private func extractFrames(url: URL, start: Double, end: Double, interval: Double?,
                               log: @Sendable (String) -> Void) async -> [AIFrame] {
        let timestamps = Self.frameTimestamps(start: start, end: end, interval: interval)
        if let interval {
            let wanted = Int(((end - start - 0.8) / max(0.2, interval)).rounded(.up))
            if wanted > timestamps.count, timestamps.count > 1 {
                log(String(format: "Sampling every %.1fs exceeds the %d-frame budget — stretched to every %.1fs across the whole video",
                           interval, timestamps.count, timestamps[1] - timestamps[0]))
            } else {
                log(String(format: "Sampling every %.1fs (%d frames)", interval, timestamps.count))
            }
        }
        return await extractFrames(url: url, timestamps: timestamps)
    }

    private func extractFrames(url: URL, timestamps: [Double]) async -> [AIFrame] {
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

    /// The profile's taste rubric — distilled from exemplar reels the user
    /// picked. Matching moments additionally get the "highlight" tag.
    /// `exampleCount` = attached "TASTE EXAMPLE" frames riding along.
    private static func tasteBlock(_ rubric: String, exampleCount: Int) -> String {
        let trimmed = rubric.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let examples = exampleCount > 0 ? """
        \(exampleCount) image(s) labeled "TASTE EXAMPLE n — a keeper moment" ride along with the frames — actual moments from the user's exemplar reels. Treat them as visual definitions of the rubric: moments in THIS video that resemble them deserve the "highlight" tag.
        """ : ""
        return """

        ## TASTE RUBRIC (what a keeper moment looks like for this user)
        \(trimmed)
        \(examples)
        In ADDITION to the tag vocabulary below, tag every time range matching one or more of these rubric rules with the tag "highlight". Be selective — "highlight" marks the genuinely strong moments, not everything that vaguely qualifies.

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
        Skip officials and support staff — referees, judges, cornermen, ring/production staff, commentators — unless the user context explicitly asks for them: they get no people entry and no person tags. The subjects are the people the footage is ABOUT.
        KNOWN PEOPLE from this library — when someone in the frames is visually the same person, REUSE their exact key:
        \(known)
        The video's filename is "\(filename)". Filenames often carry the real names of the people in the footage — use them two ways:
        - If a filename name matches a KNOWN person's name above, that is strong evidence to reuse their key.
        - For a person you invent a NEW key for, set "suggested_name" to the filename name you are confident belongs to them (null when unsure or when the filename has no names). Copy names verbatim; never invent one.
        In your JSON response, ALSO include a top-level "people" array:
        "people": [{"key": "<known key, or a new kebab-case slug you invent>", "description": "<concise visual description: build, hair, clothing, distinguishing marks>", "suggested_name": "<name from the filename, or null>", "ranges": [{"start": 0.0, "end": 5.2}]}]
        Rules: reuse a known key ONLY when confident it is the same person; invent a new key otherwise; one entry per person; ranges cover where that person is clearly visible.
        Every time range you return in "tags" that shows a person MUST be covered by that person's ranges here — footage with people but no person attribution is an error. (Footage with nobody in it may still be tagged normally.)
        AND include a top-level "outcome" object IF this video shows a fight/match RESULT — signals: the referee stopping the action, a fighter unconscious or tapping, the hand raise, a victory celebration, broadcast result graphics:
        "outcome": {"method": "<ko|tko|submission|decision|draw|no-contest>", "winner_key": "<person key of the winner, or null if unsure>", "loser_key": "<person key, or null>", "event": "<event name from broadcast graphics/filename (e.g. \"UFC 330\"), or null>"}
        Use "outcome": null when the video shows no result (training, interview, preview). Never guess the winner — null beats wrong.

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

    /// The boxed people the user excluded — their portraits ride along.
    private static func ignoreBlock(_ count: Int) -> String {
        guard count > 0 else { return "" }
        return """

        ## IGNORE MARKERS (absolute)
        The user boxed \(count) person(s) to EXCLUDE — each has a matching image labeled "IGNORE MARKER at Xs". These are officials, staff, or bystanders: never create a people entry for them, never tag ranges for them, and never let their presence influence which footage is kept. Treat them as background.

        """
    }

    private static func fullAnalysisPrompt(domain: String, duration: Double, tags: [String: [String]],
                                           instructions: String, notes: [VideoNote],
                                           notesHaveReferenceFrames: Bool,
                                           knownPeople: [PersonRecord]?,
                                           markers: [(marker: PersonMarker, person: PersonRecord)],
                                           filename: String,
                                           tasteRubric: String = "",
                                           tasteExampleCount: Int = 0,
                                           ignoreCount: Int = 0) -> String {
        """
        You are analyzing frames from a \(domain) video.
        Video duration: \(String(format: "%.1f", duration))s. Frames are shown at their timestamps.
        \(instructionsBlock(instructions))\(tasteBlock(tasteRubric, exampleCount: tasteExampleCount))\(notesBlock(notes, withReferenceFrames: notesHaveReferenceFrames))\(peopleBlock(knownPeople, filename: filename))\(markerBlock(markers))\(ignoreBlock(ignoreCount))
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

    /// Second-pass prompt: split one coarse scene into its individual
    /// actions, using the same tag vocabulary and JSON shape as the main
    /// pass so the results merge straight into it.
    static func breakdownPrompt(domain: String, start: Double, end: Double,
                                tags: [String: [String]]) -> String {
        String(format: """
        You are analyzing ONE continuous scene from a %@ video, running from %.1fs to %.1fs. \
        The attached frames are labeled with their absolute timestamps within that window.

        Break this scene down into its individual actions. Each distinct exchange — a strike \
        combination, a takedown attempt, a scramble, a submission attempt, or any other \
        self-contained action — must be its OWN time range: start when the action begins, end \
        when it resolves or the participants reset. Never return one range spanning several \
        exchanges.

        TAGS (tag each range with every tag that applies):
        %@
        Rules:
        - All time ranges must be within %.1f to %.1f
        - Typical actions last 1–8 seconds; quiet stretches between actions may be left untagged
        - Ranges for the same tag must not overlap
        - Anchor timestamps on the frame labels
        - Return ONLY a JSON object of the form {"tags": {"tag-name": [{"start": 12.0, "end": 15.5}]}} — no markdown fences, no explanation
        - If nothing distinct happens, return: {"tags": {}}
        """, domain, start, end, tagList(tags), start, end)
    }

    /// One dense look at a single scene's window: up to 120 frames at ≥0.25s
    /// spacing, returning validated tag ranges (absolute timestamps) for the
    /// individual actions inside it.
    private func breakdownScene(url: URL, window: (start: Double, end: Double),
                                domain: String, tags: [String: [String]], allTags: Set<String>,
                                provider: String?, model: String?,
                                log: @escaping @Sendable (String) -> Void) async throws
        -> [String: [(start: Double, end: Double)]] {
        let span = window.end - window.start
        let interval = max(0.25, span / Double(Self.maxCustomFrames))
        var timestamps: [Double] = []
        var t = window.start + 0.1
        while t < window.end - 0.1 && timestamps.count < Self.maxCustomFrames {
            timestamps.append(t.rounded(toPlaces: 1))
            t += interval
        }
        let frames = await extractFrames(url: url, timestamps: timestamps)
        guard !frames.isEmpty else { return [:] }
        log(String(format: "Re-examining %.1f–%.1fs with %d dense frames…",
                   window.start, window.end, frames.count))
        let prompt = Self.breakdownPrompt(domain: domain, start: window.start, end: window.end,
                                          tags: tags)
        let response = try await ai.call(prompt: prompt, task: "analysis", frames: frames,
                                         model: model, provider: provider, timeout: 300, log: log)
        guard let object = AIResponseParser.jsonObject(from: response),
              let rawTags = object["tags"] as? [String: Any] else { return [:] }
        var cleanTags: [String: [(start: Double, end: Double)]] = [:]
        for (tag, value) in rawTags {
            guard allTags.contains(tag), let ranges = value as? [[String: Any]] else { continue }
            var clean: [(Double, Double)] = []
            for range in ranges {
                let start = max(window.start,
                                ((range["start"] as? NSNumber)?.doubleValue ?? 0).rounded(toPlaces: 1))
                let end = min(window.end,
                              ((range["end"] as? NSNumber)?.doubleValue ?? 0).rounded(toPlaces: 1))
                if end > start { clean.append((start, end)) }
            }
            if !clean.isEmpty { cleanTags[tag] = clean }
        }
        return cleanTags
    }

    // MARK: - People-only pass

    private static func peopleOnlyPrompt(domain: String, duration: Double,
                                         knownPeople: [PersonRecord],
                                         markers: [(marker: PersonMarker, person: PersonRecord)],
                                         ignoreCount: Int, filename: String) -> String {
        let known = knownPeople.isEmpty ? "None yet — every person you find is new." :
            knownPeople.map { person in
                let named = person.name.isEmpty ? "" : " (the user calls them \"\(person.name)\")"
                return "  - key \"\(person.key)\": \(person.descriptor)\(named)"
            }.joined(separator: "\n")
        return """
        You are identifying the PEOPLE in a \(domain) video — nothing else.
        Video duration: \(String(format: "%.1f", duration))s. Frames are shown at their timestamps.
        \(markerBlock(markers))\(ignoreBlock(ignoreCount))
        Identify each DISTINCT person who appears clearly in the video (skip incidental background passers-by).
        Skip officials and support staff — referees, judges, cornermen, ring/production staff, commentators — they are not subjects.
        KNOWN PEOPLE from this library — when someone in the frames is visually the same person, REUSE their exact key:
        \(known)
        The video's filename is "\(filename)". Filenames often carry the subjects' real names — if a name matches a KNOWN person, that supports reusing their key; for a NEW person, offer it as "suggested_name" (null when unsure).

        Return ONLY a JSON object, no markdown fences:
        {"people": [{"key": "<known key, or a new kebab-case slug>", "description": "<concise visual description: build, hair, clothing, marks>", "suggested_name": "<name from the filename, or null>", "ranges": [{"start": 0.0, "end": 5.2}], "portrait": {"at": <timestamp of a frame where this person is clearly and fully visible>, "x": 0.1, "y": 0.2, "w": 0.25, "h": 0.6}}]}
        "portrait" is a normalized top-left box tightly around that person at that frame — it becomes their avatar, so prefer a moment where they are unobstructed and facing the camera.
        """
    }

    /// People-only pass: identify everyone in the video (reusing known
    /// identities, honoring person and ignore markers), upsert the registry,
    /// and record the roster on the video with portrait boxes for avatars.
    /// No tagging happens. Returns the fresh roster.
    func detectPeopleOnly(video: VideoRecord, profile: BrandProfile, database: Database,
                          provider: String? = nil, model: String? = nil,
                          log: @escaping @Sendable (String) -> Void) async throws
        -> [VideoPersonRecord] {
        guard FFmpeg.isAvailable else { throw FFmpegError.toolNotFound("ffmpeg") }
        let duration = video.duration > 0 ? video.duration : await FFmpeg.duration(of: video.url)
        let frames = await extractFrames(url: video.url, start: 0, end: duration,
                                         interval: nil, log: log)
        guard !frames.isEmpty else {
            throw FFmpegError.commandFailed(tool: "frame extraction", exitCode: 1,
                                            stderr: "no frames could be extracted from \(video.filename)")
        }
        let knownPeople = (try? await database.fetchPeople()) ?? []
        let peopleByID = Dictionary(uniqueKeysWithValues: knownPeople.map { ($0.id, $0) })
        let allMarkers = (try? await database.personMarkers(videoID: video.id)) ?? []
        let namedMarkers: [(marker: PersonMarker, person: PersonRecord)] = allMarkers
            .compactMap { marker in
                guard !marker.ignored else { return nil }
                return marker.personID.flatMap { peopleByID[$0] }.map { (marker, $0) }
            }
        let markerFrames: [AIFrame] = await withPortraits(url: video.url, duration: duration,
                                                          markers: namedMarkers.map(\.marker)) {
            String(format: "PERSON MARKER: %@ at %.1fs",
                   namedMarkers[$0].person.displayName, namedMarkers[$0].marker.atTime)
        }
        let ignoreMarkers = allMarkers.filter(\.ignored)
        let ignoreFrames: [AIFrame] = await withPortraits(url: video.url, duration: duration,
                                                          markers: ignoreMarkers) {
            String(format: "IGNORE MARKER at %.1fs", ignoreMarkers[$0].atTime)
        }

        log("Detecting people in \(video.filename) (\(frames.count) frames)…")
        let prompt = Self.peopleOnlyPrompt(domain: profile.effectiveDomain, duration: duration,
                                           knownPeople: knownPeople, markers: namedMarkers,
                                           ignoreCount: ignoreFrames.count,
                                           filename: video.filename)
        let response = try await ai.call(prompt: prompt, task: "analysis",
                                         frames: markerFrames + ignoreFrames + frames,
                                         model: model, provider: provider, timeout: 300, log: log)
        guard let object = AIResponseParser.jsonObject(from: response),
              let rawPeople = object["people"] as? [[String: Any]] else {
            throw AIError.emptyResponse("people detection (unparseable JSON)")
        }

        var entries: [(key: String, descriptor: String, portraitAt: Double,
                       portraitJSON: String?, rangesJSON: String?)] = []
        var seenKeys = Set<String>()
        for raw in rawPeople {
            let rawKey = (raw["key"] as? String ?? "").lowercased()
            var key = rawKey.map { $0.isLetter || $0.isNumber ? $0 : "-" }
                .reduce(into: "") { result, character in
                    if character != "-" || result.last != "-" { result.append(character) }
                }
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if key.isEmpty { key = "person-\(seenKeys.count + 1)" }
            guard !seenKeys.contains(key) else { continue }
            seenKeys.insert(key)
            let descriptor = (raw["description"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var portraitAt = duration / 2
            var portraitJSON: String?
            if let portrait = raw["portrait"] as? [String: Any] {
                portraitAt = min(max(0, (portrait["at"] as? NSNumber)?.doubleValue ?? portraitAt),
                                 max(0, duration - 0.1))
                let box = VideoPersonRecord.PortraitBox(
                    x: min(max(0, (portrait["x"] as? NSNumber)?.doubleValue ?? 0), 1),
                    y: min(max(0, (portrait["y"] as? NSNumber)?.doubleValue ?? 0), 1),
                    w: min(max(0.02, (portrait["w"] as? NSNumber)?.doubleValue ?? 0.3), 1),
                    h: min(max(0.02, (portrait["h"] as? NSNumber)?.doubleValue ?? 0.6), 1))
                portraitJSON = (try? JSONEncoder().encode(box))
                    .flatMap { String(data: $0, encoding: .utf8) }
            }
            let ranges = (raw["ranges"] as? [[String: Any]] ?? []).compactMap { range -> [String: Double]? in
                let start = max(0, ((range["start"] as? NSNumber)?.doubleValue ?? 0))
                let end = min(duration, ((range["end"] as? NSNumber)?.doubleValue ?? 0))
                return end > start ? ["start": start, "end": end] : nil
            }
            let rangesJSON = (try? JSONSerialization.data(withJSONObject: ranges))
                .flatMap { String(data: $0, encoding: .utf8) }
            entries.append((key, descriptor, portraitAt, portraitJSON, rangesJSON))
        }

        for entry in entries {
            try await database.upsertPerson(key: entry.key, descriptor: entry.descriptor)
        }
        let idsByKey = Dictionary(uniqueKeysWithValues:
            ((try? await database.fetchPeople()) ?? []).map { ($0.key, $0.id) })
        try await database.replaceVideoPeople(videoID: video.id, entries: entries.compactMap { entry in
            idsByKey[entry.key].map { ($0, entry.portraitAt, entry.portraitJSON, entry.rangesJSON) }
        })
        log("People: \(entries.count) found in \(video.filename)")
        return (try? await database.fetchVideoPeople(videoID: video.id)) ?? []
    }

    /// Portrait AIFrames for a list of markers, labeled by index.
    private func withPortraits(url: URL, duration: Double, markers: [PersonMarker],
                               label: (Int) -> String) async -> [AIFrame] {
        var frames: [AIFrame] = []
        for (index, marker) in markers.enumerated() {
            let at = min(max(0, marker.atTime), max(0, duration - 0.1))
            guard let data = await ThumbnailService.jpegFrame(url: url, at: at),
                  let portrait = Self.markerPortrait(from: data, marker: marker) else { continue }
            frames.append(AIFrame(jpeg: portrait, label: label(index)))
        }
        return frames
    }

    // MARK: - Taste rubric distillation

    private static func tasteRubricPrompt(domain: String, label: String,
                                          existingRubric: String) -> String {
        let existing = existingRubric.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        You are studying a reference reel ("\(label)")\(domain.isEmpty ? "" : " from the \(domain) domain"). The user hand-picked it because its moments are exactly what they want detected in their own raw footage.

        CURRENT RUBRIC (refine it — don't start over):
        \(existing.isEmpty ? "None yet." : existing)

        From the frames, work out what makes this reel's kept moments worth keeping — the visible action, framing, intensity, reactions, and pacing that distinguish its shots. Then return the UPDATED rubric.

        Rules for the rubric:
        - 5–12 bullet lines starting with "- ", each concrete and visually checkable in raw footage (e.g. "- a strike visibly landing with the opponent reacting", never "- exciting moments")
        - Merge with the current rubric: keep rules this reel still supports, sharpen wording, add what it newly teaches, and only drop an existing rule when this reel contradicts it
        - Describe what to LOOK FOR in unedited footage — ignore the reel's editing, captions, emojis, music, and graphics

        Also pick up to 4 of the attached frames that best EXEMPLIFY the rubric — the clearest "this is a keeper moment" images (skip title cards, transitions, and graphics-heavy frames).

        Return ONLY a JSON object, no markdown fences, of the form:
        {"rubric": "<the bullet lines joined by newlines>", "exemplar_frames": [<the chosen frames' timestamps in seconds, from their labels>]}
        """
    }

    /// Study one exemplar reel and merge what it teaches into the profile's
    /// taste rubric — the editable "what a keeper moment looks like" rules
    /// that ride into every analysis and wizard plan. Returns the updated
    /// rubric text plus the frames the model picked as the clearest visual
    /// examples of it (few-shot images for future analysis calls).
    func distillTasteRubric(video url: URL, label: String, existingRubric: String,
                            domain: String,
                            provider: String? = nil, model: String? = nil,
                            log: @escaping @Sendable (String) -> Void) async throws
        -> (rubric: String, exemplarFrames: [(time: Double, jpeg: Data)]) {
        guard FFmpeg.isAvailable else { throw FFmpegError.toolNotFound("ffmpeg") }
        let duration = await FFmpeg.duration(of: url)
        guard duration > 0 else {
            throw FFmpegError.commandFailed(tool: "ffprobe", exitCode: 1,
                                            stderr: "could not read the exemplar's duration")
        }
        // Dense enough to catch every cut of a short reel, capped for cost.
        let timestamps = Self.frameTimestamps(duration: duration,
                                              interval: max(0.5, duration / 40))
        let frames = await extractFrames(url: url, timestamps: timestamps)
        guard !frames.isEmpty else {
            throw FFmpegError.commandFailed(tool: "frame extraction", exitCode: 1,
                                            stderr: "no frames could be extracted from the exemplar")
        }
        log("Studying \(label) (\(frames.count) frames)…")
        let prompt = Self.tasteRubricPrompt(domain: domain, label: label,
                                            existingRubric: existingRubric)
        let response = try await ai.call(prompt: prompt, task: "analysis", frames: frames,
                                         model: model, provider: provider, timeout: 300, log: log)

        var rubric = ""
        var pickedTimes: [Double] = []
        if let object = AIResponseParser.jsonObject(from: response) {
            rubric = (object["rubric"] as? String ?? "")
            pickedTimes = (object["exemplar_frames"] as? [Any] ?? [])
                .compactMap { ($0 as? NSNumber)?.doubleValue }
        }
        if rubric.isEmpty {
            // Older-style plain-text answer: the whole response is the rubric.
            rubric = response.replacingOccurrences(of: "```", with: "")
        }
        rubric = rubric.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rubric.isEmpty else { throw AIError.emptyResponse("taste rubric") }

        // Resolve each picked timestamp back to the nearest extracted frame
        // (the labels are "%.1fs", so parse them for the match).
        var exemplarFrames: [(time: Double, jpeg: Data)] = []
        let labeled: [(time: Double, jpeg: Data)] = frames.compactMap { frame in
            Double(frame.label.dropLast()).map { ($0, frame.jpeg) }
        }
        for picked in pickedTimes.prefix(4) {
            guard let nearest = labeled.min(by: { abs($0.time - picked) < abs($1.time - picked) }),
                  abs(nearest.time - picked) < 3,
                  !exemplarFrames.contains(where: { $0.time == nearest.time }) else { continue }
            exemplarFrames.append(nearest)
        }
        return (rubric, exemplarFrames)
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
                       autoZoomUnframed: Bool = false,
                       breakdownTags: [String] = [],
                       centerStagePaths: Bool = false,
                       centerStageCamera: String = "balanced",
                       trimRange: (start: Double, end: Double)? = nil,
                       sampleInterval: Double? = nil,
                       force: Bool = false,
                       log: @escaping @Sendable (String) -> Void,
                       progress: @escaping @Sendable (Double, String) -> Void) async throws
        -> (runID: Int64?, newPeople: [DetectedNewPerson]) {
        guard FFmpeg.isAvailable else { throw FFmpegError.toolNotFound("ffmpeg") }
        let tags = profile.effectiveTags
        var allTags = Set(tags.values.flatMap { $0 })
        // The taste rubric adds a synthetic "highlight" tag for the moments
        // matching it — accepted alongside the profile vocabulary.
        if !profile.tasteRubric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            allTags.insert("highlight")
        }
        let domain = profile.effectiveDomain
        let duration = video.duration > 0 ? video.duration : await FFmpeg.duration(of: video.url)

        // One-shot trim: frames are sampled, the model is instructed, and
        // every returned range is clamped inside this window only.
        let window: (start: Double, end: Double)? = trimRange.flatMap { range in
            let start = max(0, range.start)
            let end = min(duration, range.end)
            return end > start ? (start, end) : nil
        }
        let clampStart = window?.start ?? 0
        let clampEnd = window?.end ?? duration
        var instructions = instructions
        if let window {
            let windowLine = String(
                format: "ANALYZE ONLY the section from %.1fs to %.1fs — frames are sampled only there. Every time range you return must fall inside this window; ignore the rest of the video entirely.",
                window.start, window.end)
            instructions = instructions.isEmpty ? windowLine : windowLine + "\n" + instructions
            log(String(format: "%@: analyzing only %.1fs–%.1fs",
                       video.filename, window.start, window.end))
        }

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
        let frames = await extractFrames(url: video.url,
                                         start: clampStart, end: clampEnd,
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
        let ignoreMarkers = personMarkers.filter(\.ignored)
        let namedMarkers: [(marker: PersonMarker, person: PersonRecord)] = detectPeople
            ? personMarkers.compactMap { marker in
                guard !marker.ignored else { return nil }
                return marker.personID.flatMap { peopleByID[$0] }.map { (marker, $0) }
            }
            : []
        // Ignore markers: the boxed people must be excluded everywhere. The
        // AI sees their portraits so it never registers or tags them; the
        // same crops feed Center Stage as negative references.
        var ignoreFrames: [AIFrame] = []
        if !ignoreMarkers.isEmpty {
            ignoreFrames = ((try? await BoundedConcurrency.map(ignoreMarkers, limit: FFmpeg.jobLimit) { _, marker in
                let at = min(max(0, marker.atTime), max(0, duration - 0.1))
                guard let data = await ThumbnailService.jpegFrame(url: video.url, at: at),
                      let portrait = Self.markerPortrait(from: data, marker: marker) else {
                    return nil as AIFrame?
                }
                return AIFrame(jpeg: portrait,
                               label: String(format: "IGNORE MARKER at %.1fs", marker.atTime))
            }) ?? []).compactMap { $0 }
            if !ignoreFrames.isEmpty {
                log("Attached \(ignoreFrames.count) ignore marker(s) — these people are excluded")
            }
        }

        // Few-shot taste examples: frames from the user's exemplar reels,
        // attached as visual definitions of the taste rubric.
        var tasteFrames: [AIFrame] = []
        if !profile.tasteRubric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for (index, path) in profile.tasteExemplarFrames.prefix(6).enumerated() {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                if let data = try? Data(contentsOf: url) {
                    tasteFrames.append(AIFrame(jpeg: data,
                                               label: "TASTE EXAMPLE \(index + 1) — a keeper moment"))
                }
            }
            if !tasteFrames.isEmpty {
                log("Attached \(tasteFrames.count) taste example frame(s)")
            }
        }

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
                                             filename: video.filename,
                                             tasteRubric: profile.tasteRubric,
                                             tasteExampleCount: tasteFrames.count,
                                             ignoreCount: ignoreFrames.count)
            tagsToRecord = Array(allTags)
            progress(0.25, "tagging (\(frames.count) frames)")
            log("Extracted \(frames.count) frames, sending for full analysis...")
        }

        let response = try await ai.call(prompt: prompt, task: "analysis",
                                         frames: referenceFrames + markerFrames + ignoreFrames
                                             + tasteFrames + frames,
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
                    let start = max(clampStart, ((range["start"] as? NSNumber)?.doubleValue ?? 0).rounded(toPlaces: 1))
                    let end = min(clampEnd, ((range["end"] as? NSNumber)?.doubleValue ?? duration).rounded(toPlaces: 1))
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
                    let start = max(clampStart, ((range["start"] as? NSNumber)?.doubleValue ?? 0).rounded(toPlaces: 1))
                    let end = min(clampEnd, ((range["end"] as? NSNumber)?.doubleValue ?? 0).rounded(toPlaces: 1))
                    if end > start { clean.append((start, end)) }
                }
                guard !clean.isEmpty else { continue }
                detectedPeople.append((key, description,
                                       suggestedName?.isEmpty == false ? suggestedName : nil,
                                       clean[0]))
                cleanTags["person:\(key)", default: []].append(contentsOf: clean)
            }
        }

        // Fight result, when the model saw one — winner/loser keys validated
        // against the people it just reported.
        var outcome: (method: String, winner: String?, loser: String?, event: String?)?
        if detectPeople, !isIncremental, let raw = object["outcome"] as? [String: Any],
           let method = (raw["method"] as? String)?.lowercased(),
           ["ko", "tko", "submission", "decision", "draw", "no-contest"].contains(method) {
            let reportedKeys = Set(detectedPeople.map(\.key)).union(knownPeople.map(\.key))
            func validKey(_ value: Any?) -> String? {
                guard let key = (value as? String)?.lowercased(), reportedKeys.contains(key) else { return nil }
                return key
            }
            let event = (raw["event"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            outcome = (method, validKey(raw["winner_key"]), validKey(raw["loser_key"]),
                       event?.isEmpty == false ? event : nil)
        }

        var cleanMoments: [(at: Double, note: String, dialog: String?)] = []
        if let rawMoments = object["moments"] as? [[String: Any]] {
            for moment in rawMoments {
                let at = ((moment["at"] as? NSNumber)?.doubleValue ?? -1).rounded(toPlaces: 1)
                guard at >= clampStart, at <= clampEnd else { continue }
                cleanMoments.append((at, moment["note"] as? String ?? "", moment["dialog"] as? String))
            }
        }

        // Optional dense second pass: scenes carrying one of the chosen
        // breakdown tags get re-examined frame-by-frame and split into their
        // individual actions (combos, exchanges). The sub-ranges replace the
        // coarse range before anything is saved, so the batch lands granular
        // scenes — with people, portrait-fit, and crop suggestions applied
        // per sub-scene like any other.
        if !breakdownTags.isEmpty {
            var windows: [(start: Double, end: Double)] = []
            var seenWindows = Set<String>()
            for (tag, ranges) in cleanTags where breakdownTags.contains(tag) {
                for range in ranges where range.end - range.start >= Self.minBreakdownDuration {
                    if seenWindows.insert("\(range.start)-\(range.end)").inserted {
                        windows.append(range)
                    }
                }
            }
            windows.sort { $0.start < $1.start }
            if !windows.isEmpty {
                log("Breaking down \(windows.count) scene(s) tagged \(breakdownTags.joined(separator: ", "))…")
            }
            for (index, window) in windows.enumerated() {
                try Task.checkCancellation()
                progress(0.88 + 0.06 * Double(index) / Double(windows.count), "breaking down scenes")
                do {
                    let sub = try await breakdownScene(url: video.url, window: window,
                                                       domain: domain, tags: tags, allTags: allTags,
                                                       provider: provider, model: model, log: log)
                    guard !sub.isEmpty else {
                        log(String(format: "No distinct actions found in %.1f–%.1fs — keeping the scene whole",
                                   window.start, window.end))
                        continue
                    }
                    // People whose ranges overlap the window ride along onto
                    // each overlapping sub-range, so sub-scenes keep their
                    // people chips (and the wizard's people filter).
                    let personTags = cleanTags.filter { $0.key.hasPrefix("person:") }
                    for (tag, ranges) in cleanTags {
                        cleanTags[tag] = ranges.filter { $0.start != window.start || $0.end != window.end }
                    }
                    var distinct = Set<String>()
                    for (tag, ranges) in sub {
                        cleanTags[tag, default: []].append(contentsOf: ranges)
                        for range in ranges {
                            distinct.insert("\(range.start)-\(range.end)")
                            for (personTag, personRanges) in personTags
                                where personRanges.contains(where: { $0.start < range.end && range.start < $0.end }) {
                                cleanTags[personTag, default: []].append((range.start, range.end))
                            }
                        }
                    }
                    log(String(format: "Split %.1f–%.1fs into %d sub-scene(s)",
                               window.start, window.end, distinct.count))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    log(String(format: "Breakdown of %.1f–%.1fs failed — keeping the scene whole",
                               window.start, window.end))
                }
            }
            cleanTags = cleanTags.filter { !$0.value.isEmpty }
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

        if let outcome {
            try? await database.saveFightOutcome(videoID: video.id, runID: runID,
                                                 method: outcome.method,
                                                 winnerKey: outcome.winner,
                                                 loserKey: outcome.loser,
                                                 event: outcome.event)
            let names = Dictionary(uniqueKeysWithValues: knownPeople.map { ($0.key, $0.displayName) })
            let winner = outcome.winner.map { names[$0] ?? $0 } ?? "?"
            let loser = outcome.loser.map { names[$0] ?? $0 } ?? "?"
            log("Fight outcome: \(winner) beat \(loser) by \(outcome.method.uppercased())"
                + (outcome.event.map { " (\($0))" } ?? ""))
        }

        // Local portrait-fit pass on wide footage: score how well each new
        // scene's people fit a 9:16 crop, so the wizard can prefer moments
        // where nobody gets cut off, and record where the crop window should
        // sit to keep those people framed — the wizard and Builder read it as
        // each scene's default crop. Pure Vision — no AI cost.
        if video.wide {
            progress(0.97, "portrait fit")
            let ranges = (try? await database.sceneRanges(runID: runID)) ?? []
            var good = 0, poor = 0, crops = 0
            for range in ranges {
                try Task.checkCancellation()
                guard let result = await Self.portraitFit(url: video.url,
                                                          start: range.start, end: range.end,
                                                          videoWidth: video.width,
                                                          videoHeight: video.height) else { continue }
                switch result.fit {
                case .fits:
                    try? await database.addSceneTag(sceneID: range.id, tag: "portrait-fit:good")
                    good += 1
                case .tooWide:
                    try? await database.addSceneTag(sceneID: range.id, tag: "portrait-fit:poor")
                    poor += 1
                case .noPeople:
                    break
                }
                // Even a too-wide scene crops best centered on its people —
                // but only when the user opted into auto-zooming unframed
                // scenes; the default leaves them letterboxed until the
                // framing pass (or the Builder) gives them a real crop.
                if autoZoomUnframed, let cropX = result.cropXFrac {
                    try? await database.setSceneCropX(range.id, fraction: cropX)
                    crops += 1
                }
            }
            if good + poor > 0 {
                log("Portrait fit: \(good) scene(s) crop-friendly for 9:16, \(poor) too spread out")
            }
            if crops > 0 {
                log("Recorded a people-centered 9:16 crop position for \(crops) scene(s)")
            }
        }

        // Optional Center Stage tracking pass (local, no AI cost): each wide
        // scene gets its virtual-camera path computed and stored, so the
        // Scenes preview can play the real moving crop and renders can skip
        // re-tracking. Scenes where people barely appear are tagged instead.
        if centerStagePaths && video.wide {
            progress(0.98, "center stage")
            let ranges = (try? await database.sceneRanges(runID: runID)) ?? []
            let centerStage = CenterStageService()
            let tuning = CenterStageService.Tuning.named(centerStageCamera)
            // User-drawn person markers make the camera identity-aware: only
            // detections matching a marked person's appearance are framed —
            // the referee stops dragging the crop.
            let focusPortraits = markerFrames.map(\.jpeg)
            let avoidPortraits = ignoreFrames.map(\.jpeg)
            if !focusPortraits.isEmpty {
                let names = Set(namedMarkers.map(\.person.displayName)).sorted()
                log("Center Stage: focusing only on \(names.joined(separator: ", "))")
            }
            if !avoidPortraits.isEmpty {
                log("Center Stage: excluding \(avoidPortraits.count) ignored person(s) from framing")
            }
            // User-framed camera hints: hard keyframes the path must pass
            // through, mapped into each scene's clip-relative time.
            let allHints = (try? await database.centerStageHints(videoID: video.id)) ?? []
            if !allHints.isEmpty {
                log("Center Stage: applying \(allHints.count) manual framing hint(s)")
            }
            var stored = 0, poor = 0
            for range in ranges {
                try Task.checkCancellation()
                let sceneHints = allHints
                    .filter { $0.atTime >= range.start - 0.25 && $0.atTime <= range.end + 0.25 }
                    .map { hint in
                        (time: min(max(0, hint.atTime - range.start), range.end - range.start),
                         crop: CGRect(x: hint.x, y: hint.y, width: hint.width, height: hint.height))
                    }
                do {
                    let result = try await centerStage.cameraPath(
                        source: video.url, start: range.start,
                        duration: range.end - range.start,
                        focusPortraits: focusPortraits,
                        avoidPortraits: avoidPortraits,
                        hints: sceneHints, tuning: tuning)
                    if result.trackedShare < 0.1 || result.keyframes.count < 2 {
                        try? await database.addSceneTag(sceneID: range.id, tag: "center-stage:poor")
                        poor += 1
                    } else {
                        let path = SceneCameraPath(camera: centerStageCamera,
                                                   keyframes: result.keyframes)
                        if let data = try? JSONEncoder().encode(path),
                           let json = String(data: data, encoding: .utf8) {
                            try? await database.setSceneCenterStagePath(range.id, json: json)
                            stored += 1
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    poor += 1
                }
            }
            if stored + poor > 0 {
                log("Center Stage: camera paths recorded for \(stored) scene(s)"
                    + (poor > 0 ? ", \(poor) scene(s) track too poorly to reframe" : ""))
            }
        }
        progress(1.0, "done")
        return (runID, newPeople)
    }

    /// The detections that matter for framing: boxes nearly as tall as the
    /// biggest one (the main subjects), capped to the four largest. Drops
    /// peripheral people — cage-side crowd, staff, a referee at distance —
    /// whose small boxes drag the union wide and pull crops off the action.
    nonisolated static func primaryPeopleBoxes(_ boxes: [CGRect]) -> [CGRect] {
        guard let tallest = boxes.map(\.height).max(), tallest > 0 else { return boxes }
        let primaries = boxes.filter { $0.height >= tallest * 0.55 }
            .sorted { $0.width * $0.height > $1.width * $1.height }
            .prefix(4)
        return primaries.isEmpty ? boxes : Array(primaries)
    }

    /// How a scene's people sit relative to a full-height 9:16 crop.
    nonisolated enum PortraitFit {
        case fits       // everyone fits within the crop width
        case tooWide    // people spread wider than the crop can hold
        case noPeople   // frames sampled fine, but nobody was detected
    }

    /// Whether the people in [start, end] sit close enough together for a
    /// full-height 9:16 crop to hold them all, plus where that crop window
    /// should sit to center them (same 0=left…1=right convention the
    /// Builder's crop slider and the renderers use). Samples three frames,
    /// unions the detected human boxes per frame, majority-votes; nil when
    /// no frame could be sampled at all (can't judge).
    nonisolated static func portraitFit(url: URL, start: Double, end: Double,
                                        videoWidth: Int, videoHeight: Int) async
        -> (fit: PortraitFit, cropXFrac: Double?)? {
        guard videoWidth > 0, videoHeight > 0 else { return nil }
        // Fraction of the frame width a full-height 9:16 crop covers.
        let cropFraction = (9.0 / 16.0) * Double(videoHeight) / Double(videoWidth)
        let duration = end - start
        var good = 0, judged = 0, sampled = 0
        var centers: [Double] = []
        for fraction in [0.25, 0.5, 0.75] {
            guard let data = await ThumbnailService.jpegFrame(url: url, at: start + duration * fraction,
                                                              maxDimension: 720) else { continue }
            sampled += 1
            let request = VNDetectHumanRectanglesRequest()
            request.upperBodyOnly = false
            try? VNImageRequestHandler(data: data).perform([request])
            let boxes = Self.primaryPeopleBoxes((request.results ?? []).map(\.boundingBox))
            guard !boxes.isEmpty else { continue }
            judged += 1
            let union = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
            centers.append(Double(union.midX))
            // 10% slack: the crop pans onto the action (auto-crop and Center
            // Stage alike), so near-fits still frame everyone.
            if Double(union.width) <= cropFraction * 1.1 { good += 1 }
        }
        guard sampled > 0 else { return nil }
        guard judged > 0 else { return (.noPeople, nil) }
        // Median people-center across the sampled frames (resists one bad
        // frame), converted from a frame-width fraction to the crop-window
        // position: offset = (center*W - cropW/2) / (W - cropW), clamped so
        // the window stays inside the frame.
        var cropXFrac: Double?
        if cropFraction < 1 {
            let center = centers.sorted()[centers.count / 2]
            cropXFrac = min(1, max(0, (center - cropFraction / 2) / (1 - cropFraction)))
        }
        return (good * 2 >= judged ? .fits : .tooWide, cropXFrac)
    }
}

nonisolated extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}

extension Analyzer {
    /// Portrait crops for a video's person markers — ground-truth images of
    /// the people to focus on, for identity-aware Center Stage tracking.
    nonisolated static func markerPortraits(url: URL, markers: [PersonMarker],
                                            duration: Double) async -> [Data] {
        ((try? await BoundedConcurrency.map(markers, limit: FFmpeg.jobLimit) { _, marker in
            let at = min(max(0, marker.atTime), max(0, duration - 0.1))
            guard let data = await ThumbnailService.jpegFrame(url: url, at: at) else {
                return nil as Data?
            }
            return Self.markerPortrait(from: data, marker: marker)
        }) ?? []).compactMap { $0 }
    }

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
