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

    /// Run an analysis-task AI call, halving the sampled frame grid and
    /// retrying whenever the provider rejects the request as too long — a
    /// thinner analysis beats a dead one. Auxiliary frames (markers, notes,
    /// taste examples) always ride along untouched.
    private func callThinningFrames(prompt: String, auxiliary: [AIFrame], sampled: [AIFrame],
                                    video: URL? = nil,
                                    model: String?, provider: String?,
                                    log: @escaping @Sendable (String) -> Void) async throws -> AIResponse {
        var frames = sampled
        while true {
            do {
                return try await ai.call(prompt: prompt, task: "analysis",
                                         frames: auxiliary + frames, video: video,
                                         model: model, provider: provider,
                                         timeout: 300, log: log)
            } catch let error as AIError {
                guard case .promptTooLong = error, frames.count > 8 else { throw error }
                frames = frames.enumerated()
                    .filter { $0.offset.isMultiple(of: 2) }
                    .map(\.element)
                log("Prompt too long for the model — retrying with \(frames.count) frames")
            }
        }
    }

    private func extractFrames(url: URL, timestamps: [Double]) async -> [AIFrame] {
        let jpegFrames = await ThumbnailService.jpegFrames(url: url, at: timestamps)
        return zip(timestamps, jpegFrames).compactMap { timestamp, jpeg in
            jpeg.map { AIFrame(jpeg: $0, label: String(format: "%.1fs", timestamp)) }
        }
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

    /// The profile's taste knowledge — a general rubric plus per-video-type
    /// rubrics distilled from exemplar reels. Matching moments get the
    /// "highlight" tag; type matches also get "highlight:<category>".
    /// `exampleCount` = attached "TASTE EXAMPLE" frames riding along.
    private static func tasteBlock(_ rubric: String, categories: [TasteCategory],
                                   exampleCount: Int) -> String {
        let trimmed = rubric.trimmingCharacters(in: .whitespacesAndNewlines)
        let active = categories.filter {
            !$0.rubric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !trimmed.isEmpty || !active.isEmpty else { return "" }
        var block = "\n## TASTE RUBRIC (what a keeper moment looks like for this user)\n"
        if !trimmed.isEmpty { block += trimmed + "\n" }
        if !active.isEmpty {
            block += "\nVIDEO-TYPE RUBRICS — a range matching one of these ALSO gets that type's own tag:\n"
            for category in active {
                block += "- tag \"highlight:\(category.key)\" (\(category.label)):\n"
                    + category.rubric.split(separator: "\n")
                        .map { "  \($0)" }.joined(separator: "\n") + "\n"
            }
        }
        if exampleCount > 0 {
            block += "\n\(exampleCount) image(s) labeled \"TASTE EXAMPLE …\" ride along with the frames — actual moments from the user's exemplar reels. Treat them as visual definitions of these rubrics.\n"
        }
        block += "\nIn ADDITION to the tag vocabulary below, tag every time range matching the rules above with \"highlight\" (plus the matching \"highlight:<type>\" tag when a video-type rubric matched). Be selective — highlights mark the genuinely strong moments, not everything that vaguely qualifies.\n"
        return block
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
        The video's filename is "\(filename)". Real names come from TWO sources — read both:
        - ON-SCREEN TEXT (strongest evidence): broadcast graphics such as chyrons/lower-thirds (e.g. "DU PLESSIS ⋯ STRICKLAND" beside the fight clock), corner name banners, tale-of-the-tape cards, scoreboards, walkout captions, commentary name straps. Match each name to the person it labels — a lower-third lists the fighters in their on-screen corner order, and the name usually sits nearest its fighter.
        - FILENAME: filenames often carry the real names of the people in the footage.
        Use these names three ways:
        - If a name matches a KNOWN person's name above, that is strong evidence to reuse their key.
        - Set "suggested_name" whenever you are confident of a person's real name from these sources: on every NEW key, AND on a reused KNOWN key whose entry above has no user name yet. Copy names as written (normalize ALL-CAPS to standard capitalization); null when unsure — never invent or guess a name.
        - If a KNOWN person's registered name above is MISSPELLED — the on-screen graphics or the person's standard, well-documented spelling shows the correct form — set "corrected_name" on their entry to the fixed spelling (accents and capitalization included). Fix ONLY the spelling of the SAME name: never substitute a different person's name or swap in a nickname; null when the registered name is already right or you are unsure.
        In your JSON response, ALSO include a top-level "people" array:
        "people": [{"key": "<known key, or a new kebab-case slug you invent>", "description": "<concise visual description: build, hair, clothing, distinguishing marks>", "suggested_name": "<name from on-screen graphics or the filename, or null>", "corrected_name": "<fixed spelling of a known person's misspelled registered name, or null>", "ranges": [{"start": 0.0, "end": 5.2}]}]
        Rules: reuse a known key ONLY when confident it is the same person; invent a new key otherwise; one entry per person; ranges cover where that person is clearly visible.
        Every time range you return in "tags" that shows a person MUST be covered by that person's ranges here — footage with people but no person attribution is an error. (Footage with nobody in it may still be tagged normally.)
        AND include a top-level "outcome" object IF this video shows a fight/match RESULT — signals: the referee stopping the action, a fighter unconscious or tapping, the hand raise, a victory celebration, broadcast result graphics:
        "outcome": {"method": "<ko|tko|submission|decision|draw|no-contest>", "winner_key": "<person key of the winner, or null if unsure>", "loser_key": "<person key, or null>", "event": "<event name from broadcast graphics/filename (e.g. \"UFC 330\" or a title-fight strap like \"UFC MIDDLEWEIGHT CHAMPIONSHIP\"), or null>", "round": <round number when the fight clock's round indicator is readable (e.g. "R5" → 5), or null>}
        Use "outcome": null when the video shows no result (training, interview, preview). Never guess the winner — null beats wrong.

        """
    }

    /// Once-per-analysis filename proposal: auto-generated names (screen
    /// recordings, camera defaults, hex dumps) get a descriptive replacement
    /// built from what the model actually saw; a descriptive name that
    /// misspells a person or event gets its spelling fixed.
    private static func filenameBlock(_ filename: String) -> String {
        """

        ## FILENAME SUGGESTION
        The file is currently named "\(filename)". Include a top-level "suggested_filename" in TWO cases:
        - The name looks auto-generated or says nothing about the content — screen-recording/camera defaults ("ScreenRecording_…", "IMG_1234", "DSC…"), bare dates/timestamps, hex or UUID strings: build a short human-readable name from what the footage actually shows: the people (named via on-screen graphics or known people), event, round, and content type. Example: "Du Plessis vs Strickland - UFC Middleweight Championship R5".
        - The name describes the content but MISSPELLS a person's or event's name: return the same name with ONLY the spelling fixed (use the person's standard, well-documented spelling).
        Plain text only — no file extension, no slashes, colons, or quotes, at most 60 characters. If the current name already describes the content and is spelled correctly, return "suggested_filename": null.

        """
    }

    /// A model-proposed filename made safe for disk: path/quote characters
    /// stripped, whitespace collapsed, length capped — nil when nothing
    /// usable remains or it just matches the current name anyway.
    static func sanitizedFilenameSuggestion(_ raw: String, currentFilename: String) -> String? {
        let cleaned = raw
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\"\n\r"))
            .joined(separator: " ")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            .joined(separator: " ")
        let currentBase = (currentFilename as NSString).deletingPathExtension
        guard !cleaned.isEmpty,
              cleaned.caseInsensitiveCompare(currentBase) != .orderedSame else { return nil }
        return String(cleaned.prefix(80))
    }

    /// True when `candidate` is plausibly the same name as `current` with
    /// only its spelling fixed — accents, capitalization, a few letters —
    /// measured as a small edit distance between the case/diacritic-folded
    /// strings. The gate that keeps a model "correction" from ever replacing
    /// a person's name with a different person's.
    static func isSpellingFix(of current: String, candidate: String) -> Bool {
        func folded(_ name: String) -> [Character] {
            Array(name.folding(options: [.diacriticInsensitive, .caseInsensitive],
                               locale: nil))
        }
        let a = folded(current), b = folded(candidate)
        guard !a.isEmpty, !b.isEmpty else { return false }
        // Levenshtein, single-row.
        var row = Array(0...b.count)
        for (i, charA) in a.enumerated() {
            var previous = row[0]
            row[0] = i + 1
            for (j, charB) in b.enumerated() {
                let cost = charA == charB ? previous : min(previous, row[j], row[j + 1]) + 1
                previous = row[j + 1]
                row[j + 1] = cost
            }
        }
        // A third of the name, at least one edit — "Sean" → "Juan" (2 edits
        // on 4 letters) must fail while "Blanchowics" → "Blachowicz" passes.
        return row[b.count] <= max(1, min(a.count, b.count) / 3)
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
                                           tasteCategories: [TasteCategory] = [],
                                           tasteExampleCount: Int = 0,
                                           ignoreCount: Int = 0) -> String {
        """
        You are analyzing frames from a \(domain) video.
        Video duration: \(String(format: "%.1f", duration))s. Frames are shown at their timestamps.
        \(instructionsBlock(instructions))\(tasteBlock(tasteRubric, categories: tasteCategories, exampleCount: tasteExampleCount))\(notesBlock(notes, withReferenceFrames: notesHaveReferenceFrames))\(peopleBlock(knownPeople, filename: filename))\(filenameBlock(filename))\(markerBlock(markers))\(ignoreBlock(ignoreCount))
        Your job: produce a TAG-CENTRIC analysis. For each tag that applies to this
        video, provide the TIME RANGES where that tag is present. Also note any
        important moments (dialog, key events).

        AVAILABLE TAGS (only use tags from this list):
        \(tagList(tags))
        Return a JSON object with this exact structure:
        {
          "video_type": "<fight|training|interview|recap|other>",
          "tags": {
            "tag_name": [{"start": 0.0, "end": 5.2}, {"start": 12.0, "end": 18.5}],
            "another_tag": [{"start": 0.0, "end": 30.0}]
          },
          "sequences": [
            {"start": 12.0, "end": 18.5, "narrative": "A pressures B against the cage, lands a 3-punch combination; B changes levels, A sprawls and finishes with two knees — B drops to seated.", "score": 8.7, "reason": "escalating exchange with a clear payoff"}
          ],
          "moments": [
            {"at": 3.5, "note": "clean right hook lands", "dialog": null},
            {"at": 15.0, "note": "coach gives instructions", "dialog": "Mao na cara dele [EN: Hand on his face]"}
          ]
        }

        SEQUENCES — the part that makes highlights good:
        - For every action time range you tag, add a matching "sequences" entry with the SAME start/end: a beat-by-beat story (1-3 sentences) of what happens, who does what to whom.
        - "score" is 0-10 for ENTERTAINMENT, not action count. Score the shape of the sequence: pressure → exchange → escalation → visible payoff (a landed shot, a reaction, a takedown, a reversal) scores high; isolated strikes with no consequence score low. A knockdown/finish/near-finish is 9+; a clean escalating exchange 7-9; routine action 4-6; filler under 4.
        - Pad each sequence's range to include its lead-in and its payoff/reaction — a highlight cut without the reaction feels amputated.
        - Non-action ranges (arena, backstage, interviews) don't need sequence entries.

        RULES:
        - "video_type" classifies the WHOLE video: "fight" = an actual competitive bout (a result at stake, referee/cage/ring context), "training" = gym/practice/sparring/pad-work footage, "interview" = talking-head, press, or podcast-style content, "recap" = an edited recap/highlight package about a fight, "other" = anything else. Pick the single best fit for what dominates the video.
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
        - ALSO return a "sequences" entry per action range: same start/end, "narrative" (a 1-2 sentence beat-by-beat story of the action) and "score" (0-10 ENTERTAINMENT: escalation with a visible payoff scores high, isolated action low)
        - Return ONLY a JSON object of the form {"tags": {"tag-name": [{"start": 12.0, "end": 15.5}]}, "sequences": [{"start": 12.0, "end": 15.5, "narrative": "...", "score": 7.5}]} — no markdown fences, no explanation
        - If nothing distinct happens, return: {"tags": {}, "sequences": []}
        """, domain, start, end, tagList(tags), start, end)
    }

    /// One dense look at a single scene's window: up to 120 frames at ≥0.25s
    /// spacing, returning validated tag ranges (absolute timestamps) for the
    /// individual actions inside it.
    private func breakdownScene(url: URL, window: (start: Double, end: Double),
                                domain: String, tags: [String: [String]], allTags: Set<String>,
                                provider: String?, model: String?,
                                log: @escaping @Sendable (String) -> Void) async throws
        -> (tags: [String: [(start: Double, end: Double)]],
            sequences: [(start: Double, end: Double, narrative: String, score: Double)]) {
        let span = window.end - window.start
        let interval = max(0.25, span / Double(Self.maxCustomFrames))
        var timestamps: [Double] = []
        var t = window.start + 0.1
        while t < window.end - 0.1 && timestamps.count < Self.maxCustomFrames {
            timestamps.append(t.rounded(toPlaces: 1))
            t += interval
        }
        let frames = await extractFrames(url: url, timestamps: timestamps)
        guard !frames.isEmpty else { return ([:], []) }
        log(String(format: "Re-examining %.1f–%.1fs with %d dense frames…",
                   window.start, window.end, frames.count))
        let prompt = Self.breakdownPrompt(domain: domain, start: window.start, end: window.end,
                                          tags: tags)
        let response = try await callThinningFrames(prompt: prompt, auxiliary: [], sampled: frames,
                                                    model: model, provider: provider, log: log)
        guard let object = AIResponseParser.jsonObject(from: response.text),
              let rawTags = object["tags"] as? [String: Any] else { return ([:], []) }
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
        var sequences: [(start: Double, end: Double, narrative: String, score: Double)] = []
        for entry in object["sequences"] as? [[String: Any]] ?? [] {
            let start = max(window.start, ((entry["start"] as? NSNumber)?.doubleValue ?? 0).rounded(toPlaces: 1))
            let end = min(window.end, ((entry["end"] as? NSNumber)?.doubleValue ?? 0).rounded(toPlaces: 1))
            let narrative = (entry["narrative"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard end > start, !narrative.isEmpty else { continue }
            let score = min(10, max(0, (entry["score"] as? NSNumber)?.doubleValue ?? 5))
            sequences.append((start, end, narrative, score))
        }
        return (cleanTags, sequences)
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
        The video's filename is "\(filename)". Real names come from two sources: ON-SCREEN TEXT — broadcast graphics like chyrons/lower-thirds, corner name banners, tale-of-the-tape cards, scoreboards, captions (match each name to the person it labels) — and the FILENAME, which often carries the subjects' real names. If a name matches a KNOWN person, that supports reusing their key; set "suggested_name" for a NEW person, or for a reused KNOWN key whose entry above has no user name, whenever you are confident (normalize ALL-CAPS; null when unsure — never guess).
        If a KNOWN person's registered name above is MISSPELLED — the on-screen graphics or the person's standard, well-documented spelling shows the correct form — set "corrected_name" on their entry to the fixed spelling (accents and capitalization included). Fix ONLY the spelling of the SAME name: never substitute a different person's name or swap in a nickname; null when the registered name is already right or you are unsure.
        \(filenameBlock(filename))
        Return ONLY a JSON object, no markdown fences:
        {"people": [{"key": "<known key, or a new kebab-case slug>", "description": "<concise visual description: build, hair, clothing, marks>", "suggested_name": "<name from on-screen graphics or the filename, or null>", "corrected_name": "<fixed spelling of a known person's misspelled registered name, or null>", "ranges": [{"start": 0.0, "end": 5.2}], "portrait": {"at": <timestamp of a frame where this person is clearly and fully visible>, "x": 0.1, "y": 0.2, "w": 0.25, "h": 0.6}}], "suggested_filename": "<per the FILENAME SUGGESTION section, or null>"}
        "portrait" is a normalized top-left box tightly around that person at that frame — it becomes their avatar, so prefer a moment where they are unobstructed and facing the camera.
        """
    }

    /// People-only pass: identify everyone in the video (reusing known
    /// identities, honoring person and ignore markers), upsert the registry,
    /// and record the roster on the video with portrait boxes for avatars.
    /// No tagging happens. Misspelled registered names the model can correct
    /// from on-screen graphics are fixed in place; a filename proposal
    /// (auto-generated or misspelled current name) rides along for review.
    /// Returns the fresh roster plus that proposal.
    func detectPeopleOnly(video: VideoRecord, profile: BrandProfile, database: Database,
                          provider: String? = nil, model: String? = nil,
                          log: @escaping @Sendable (String) -> Void) async throws
        -> (roster: [VideoPersonRecord], suggestedFilename: String?) {
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
        let response = try await callThinningFrames(prompt: prompt,
                                                    auxiliary: markerFrames + ignoreFrames,
                                                    sampled: frames,
                                                    model: model, provider: provider, log: log)
        guard let object = AIResponseParser.jsonObject(from: response.text),
              let rawPeople = object["people"] as? [[String: Any]] else {
            throw AIError.emptyResponse("people detection (unparseable JSON)")
        }

        var entries: [(key: String, descriptor: String, portraitAt: Double,
                       portraitJSON: String?, rangesJSON: String?)] = []
        var seenKeys = Set<String>()
        // Spelling fixes for known, already-named people (unnamed people are
        // named through the review flows instead).
        let knownByKey = Dictionary(uniqueKeysWithValues: knownPeople.map { ($0.key, $0) })
        var corrections: [(person: PersonRecord, name: String)] = []
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
            if let corrected = (raw["corrected_name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !corrected.isEmpty,
               let existing = knownByKey[key], !existing.name.isEmpty,
               corrected != existing.name,
               Self.isSpellingFix(of: existing.name, candidate: corrected) {
                corrections.append((existing, corrected))
            }
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
        for (person, corrected) in corrections {
            try await database.renamePerson(id: person.id, name: corrected)
            log("Fixed spelling: \"\(person.name)\" → \"\(corrected)\"")
        }
        let idsByKey = Dictionary(uniqueKeysWithValues:
            ((try? await database.fetchPeople()) ?? []).map { ($0.key, $0.id) })
        try await database.replaceVideoPeople(videoID: video.id, entries: entries.compactMap { entry in
            idsByKey[entry.key].map { ($0, entry.portraitAt, entry.portraitJSON, entry.rangesJSON) }
        }, provenance: response.provenance)
        log("People: \(entries.count) found in \(video.filename)")
        let suggestedFilename = (object["suggested_filename"] as? String)
            .flatMap { Self.sanitizedFilenameSuggestion($0, currentFilename: video.filename) }
        return ((try? await database.fetchVideoPeople(videoID: video.id)) ?? [], suggestedFilename)
    }

    // MARK: - Trim suggestion

    /// Skim ~24 sparse frames across the whole video and propose the section
    /// worth analyzing — screen-recording chrome, menus, replays, and dead
    /// air trimmed off before the expensive dense pass spends tokens on them.
    func suggestTrim(video: VideoRecord, provider: String? = nil, model: String? = nil,
                     log: @escaping @Sendable (String) -> Void) async throws
        -> (start: Double, end: Double, reason: String, provenance: AIProvenance) {
        guard FFmpeg.isAvailable else { throw FFmpegError.toolNotFound("ffmpeg") }
        let duration = video.duration > 0 ? video.duration : await FFmpeg.duration(of: video.url)
        let frames = await extractFrames(url: video.url, start: 0, end: duration,
                                         interval: max(2, duration / 24), log: log)
        guard !frames.isEmpty else {
            throw FFmpegError.commandFailed(tool: "frame extraction", exitCode: 1,
                                            stderr: "no frames could be extracted from \(video.filename)")
        }
        let prompt = """
        You are deciding which SECTION of a \(String(format: "%.0f", duration))s video ("\(video.filename)") is worth a detailed AI analysis. The frames below are sparse samples labeled with their timestamps.

        Find the window holding the actual content — the footage itself. EXCLUDE from the window: app/menu chrome at the start or end of a screen recording, title cards, long static shots of nothing happening, end screens, and trailing dead air. Broadcast replays inside the content still count as content.

        Return ONLY a JSON object:
        {"start": <seconds>, "end": <seconds>, "reason": "<at most 15 words on what was cut off>"}
        When the whole video is content, return the full range with reason "all content".
        """
        let response = try await ai.call(prompt: prompt, task: "trim", frames: frames,
                                         model: model, provider: provider,
                                         timeout: 180, log: log)
        guard let object = AIResponseParser.jsonObject(from: response.text),
              let rawStart = (object["start"] as? NSNumber)?.doubleValue,
              let rawEnd = (object["end"] as? NSNumber)?.doubleValue else {
            throw AIError.unusableResponse("The trim suggestion couldn't be read from the model's reply.")
        }
        let start = min(max(0, rawStart), duration)
        let end = min(max(start, rawEnd), duration)
        guard end - start >= 3 else {
            throw AIError.unusableResponse("The model proposed a window under 3 seconds — ignored.")
        }
        let reason = (object["reason"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (start, end, reason, response.provenance)
    }

    /// Portrait AIFrames for a list of markers, labeled by index.
    private func withPortraits(url: URL, duration: Double, markers: [PersonMarker],
                               label: (Int) -> String) async -> [AIFrame] {
        let timestamps = markers.map { min(max(0, $0.atTime), max(0, duration - 0.1)) }
        let jpegFrames = await ThumbnailService.jpegFrames(url: url, at: timestamps)
        return zip(markers.indices, zip(markers, jpegFrames)).compactMap { index, pair in
            guard let data = pair.1,
                  let portrait = Self.markerPortrait(from: data, marker: pair.0) else { return nil }
            return AIFrame(jpeg: portrait, label: label(index))
        }
    }

    // MARK: - Fight scoring pass

    private static func fightScorePrompt(domain: String, windowStart: Double, windowEnd: Double,
                                         roster: [VideoPersonRecord], hasReferences: Bool) -> String {
        let fighters = roster.isEmpty
            ? "  (nobody identified yet — use \"unknown\" for every event)"
            : roster.map { person in
                "  - key \"\(person.key)\": \(person.displayName) — \(person.descriptor)"
            }.joined(separator: "\n")
        let actions = FightScoring.actionPoints
            .map { "  - \"\($0.action)\" — \($0.label)" }
            .joined(separator: "\n")
        let referenceNote = hasReferences
            ? "\nA cropped REFERENCE image of each fighter is attached first (labeled \"FIGHTER REFERENCE — <name> (key ...)\"). Study each fighter's kit — shorts color/pattern, waistband text, gloves, tattoos, hair, build — and use it to tell them apart in the action frames. Fighters move around the cage and switch sides between frames; identify them by their KIT and body, never by which side of the frame they are on.\n"
            : ""
        return """
        You are scoring the FIGHT ACTION in a \(domain) video and attributing every action to the correct fighter. Frames are sampled roughly every second across \(String(format: "%.1f", windowStart))s–\(String(format: "%.1f", windowEnd))s and labeled with their timestamps.
        \(referenceNote)
        FIGHTERS — attribute every event to one of these keys:
        \(fighters)

        Log every clearly visible scoring action as one event. Action types:
        \(actions)

        ATTRIBUTION (this is the most important part — get the fighter right):
        - "fighter" is the key of the fighter who PERFORMS/LANDS the action — the one throwing the strike, completing the takedown, or attempting the submission. The OTHER fighter is the one receiving it; never credit the action to the fighter getting hit.
        - Identify the performer by their kit and body (see the references), tracing which fighter's arm/leg/hips initiate the action across the surrounding frames. Read jab/cross/kick origin, who is on top in grappling, who has back control.
        - For a "knockdown" or "hurt", the fighter is the one who LANDED the blow, not the one who fell or is hurt.
        - A "takedown" or "reversal" is credited to the fighter who completes it (ends up in control), not the one taken down.
        - When you genuinely cannot tell which of the two threw it, use "unknown" — but prefer a confident attribution using the kit references. Do not default to "unknown" out of laziness, and do not guess randomly between the two.

        OTHER RULES:
        - Only log actions you can actually SEE happen in the frames. When consecutive frames show one exchange, log it conservatively — one event per landed action, never one per frame.
        - Skip officials, coaches, and crowd shots. Skip broadcast replays of an action you already logged.
        - "t" is the timestamp in seconds, within the window above.
        - An empty list is a valid answer for a lull with no scoring action.

        Return ONLY a JSON object, no markdown fences:
        {"events": [{"t": <seconds>, "fighter": "<key or \"unknown\">", "action": "<one of the action types above>"}]}
        """
    }

    /// Dedicated fight-scoring pass: dense (~1s) frame sampling over the
    /// fight scenes only, the model logs point events per fighter, code
    /// assigns the weights and replaces the video's event list. The pace
    /// graph and per-fighter score lines render from these events. Returns
    /// the number of events saved.
    func scoreFightAction(video: VideoRecord, scenes: [SceneRecord], profile: BrandProfile,
                          database: Database, provider: String? = nil, model: String? = nil,
                          log: @escaping @Sendable (String) -> Void) async throws -> Int {
        guard FFmpeg.isAvailable else { throw FFmpegError.toolNotFound("ffmpeg") }
        // Only footage typed fight/recap gets the pass — anything else
        // (including untyped) shouldn't burn a dense AI pass, and the UI
        // only shows the graph for fight footage. Read the row fresh: the
        // caller's record predates this run's inference.
        let currentType = ((try? await database.video(id: video.id)) ?? nil)?.type
        guard currentType?.supportsFightFeatures == true else {
            log("\(video.filename): \(currentType?.label ?? "untyped") video — skipping the fight scoring pass (set the Type to Fight to score it)")
            return 0
        }
        let fightTags: Set<String> = ["striking", "punching", "kicking", "grappling",
                                      "takedown", "submission", "clinch", "sparring",
                                      "knockdown", "ground-and-pound", "high-energy"]
        let targets = scenes
            .filter { $0.videoID == video.id && $0.tags.contains(where: fightTags.contains) }
            .sorted { $0.startTime < $1.startTime }
        guard !targets.isEmpty else {
            log("\(video.filename): no fight-action scenes — skipping the fight scoring pass")
            return 0
        }
        // Merge overlapping/adjacent scene ranges, then split into ≤45s
        // scoring windows so each call stays within the frame budget at 1s.
        var windows: [(start: Double, end: Double)] = []
        for scene in targets {
            if let last = windows.last, scene.startTime - last.end <= 2 {
                windows[windows.count - 1].end = max(last.end, scene.endTime)
            } else {
                windows.append((scene.startTime, scene.endTime))
            }
        }
        windows = windows.flatMap { window -> [(start: Double, end: Double)] in
            guard window.end - window.start > 45 else { return [window] }
            var chunks: [(start: Double, end: Double)] = []
            var cursor = window.start
            while cursor < window.end {
                chunks.append((cursor, min(cursor + 45, window.end)))
                cursor += 45
            }
            return chunks
        }
        // The video's roster carries the portrait boxes needed for the
        // visual attribution references.
        let roster = (try? await database.fetchVideoPeople(videoID: video.id)) ?? []
        let validKeys = Set(roster.map(\.key))
        // Resolve either the key or the fighter's display name (the model
        // sometimes answers with the name) to a canonical key.
        var keyByName: [String: String] = [:]
        for person in roster where !person.name.isEmpty {
            keyByName[person.name.lowercased()] = person.key
        }
        let validActions = Set(FightScoring.actionKeys)
        // One cropped reference image per fighter, so the model can tell
        // them apart by kit/build instead of guessing from a text descriptor.
        let referenceFrames = await fighterReferenceFrames(url: video.url, roster: roster)
        if roster.isEmpty {
            log("\(video.filename): no identified fighters — scoring action but leaving it unattributed. Detect and name the fighters (People) for per-fighter momentum.")
        } else {
            log("Attributing action to \(roster.count) fighter(s): \(roster.map(\.displayName).joined(separator: ", "))"
                + (referenceFrames.count == roster.count ? " (with visual references)"
                   : " (\(referenceFrames.count) visual reference(s))"))
        }

        var events: [(time: Double, fighterKey: String, action: String, points: Double)] = []
        // The model that answered the (last) scoring window — stamped on
        // every event row.
        var scoringProvenance: AIProvenance?
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            log(String(format: "Scoring fight action %d/%d [%.1fs–%.1fs]…",
                       index + 1, windows.count, window.start, window.end))
            let frames = await extractFrames(url: video.url, start: window.start,
                                             end: window.end, interval: 1.0, log: log)
            guard !frames.isEmpty else { continue }
            let prompt = Self.fightScorePrompt(domain: profile.effectiveDomain,
                                               windowStart: window.start, windowEnd: window.end,
                                               roster: roster, hasReferences: !referenceFrames.isEmpty)
            do {
                let response = try await callThinningFrames(prompt: prompt,
                                                            auxiliary: referenceFrames,
                                                            sampled: frames, model: model,
                                                            provider: provider, log: log)
                scoringProvenance = response.provenance
                guard let object = AIResponseParser.jsonObject(from: response.text),
                      let raw = object["events"] as? [[String: Any]] else {
                    log("Scoring window returned no usable events JSON — continuing")
                    continue
                }
                for entry in raw {
                    guard let action = entry["action"] as? String, validActions.contains(action),
                          let time = (entry["t"] as? NSNumber)?.doubleValue else { continue }
                    let raw = (entry["fighter"] as? String ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let resolved = validKeys.contains(raw) ? raw : (keyByName[raw] ?? "")
                    events.append((time: min(max(window.start, time), window.end),
                                   fighterKey: resolved,
                                   action: action,
                                   points: FightScoring.points(for: action)))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log("Fight scoring window failed (\(error)) — continuing")
            }
        }
        events.sort { $0.time < $1.time }
        try await database.replaceFightEvents(videoID: video.id, events: events,
                                              provenance: scoringProvenance)
        let attributed = events.count { !$0.fighterKey.isEmpty }
        let share = events.isEmpty ? 0 : Int(Double(attributed) / Double(events.count) * 100)
        log("\(video.filename): fight action scored — \(events.count) event(s), "
            + "\(attributed) attributed to a fighter (\(share)%)")
        if !events.isEmpty, share < 60, !roster.isEmpty {
            log("Low attribution rate — the fighters may look too similar at this sampling; naming them and adding clearer person markers helps.")
        }
        return events.count
    }

    /// One cropped reference image per identified fighter (from their stored
    /// portrait box), attached to every scoring call so the model attributes
    /// action by kit/build rather than a text description alone.
    private func fighterReferenceFrames(url: URL,
                                        roster: [VideoPersonRecord]) async -> [AIFrame] {
        let references = roster.compactMap { person in
            person.portraitBox.map { (person: person, box: $0) }
        }
        let jpegFrames = await ThumbnailService.jpegFrames(
            url: url, at: references.map { max(0, $0.person.portraitAt) })
        return zip(references, jpegFrames).compactMap { reference, jpeg in
            guard let jpeg,
                  let crop = Self.boxPortrait(from: jpeg, box: reference.box) else { return nil }
            return AIFrame(jpeg: crop,
                           label: "FIGHTER REFERENCE — \(reference.person.displayName) (key \"\(reference.person.key)\")")
        }
    }

    // MARK: - Taste rubric distillation

    private static func tasteRubricPrompt(domain: String, label: String,
                                          existingRubric: String,
                                          categories: [TasteCategory],
                                          performance: String) -> String {
        let existing = existingRubric.trimmingCharacters(in: .whitespacesAndNewlines)
        let categoryList = categories.isEmpty ? "None yet — this reel founds the first category." :
            categories.map { category in
                "- key \"\(category.key)\" (\(category.label)), studied \(category.studiedCount) reel(s):\n"
                    + (category.rubric.isEmpty ? "  (no rubric yet)" :
                        category.rubric.split(separator: "\n").map { "  \($0)" }.joined(separator: "\n"))
            }.joined(separator: "\n")
        return """
        You are studying a reference reel ("\(label)")\(domain.isEmpty ? "" : " from the \(domain) domain"). The user hand-picked it because its moments are exactly what they want detected in their own raw footage.
        \(performance.isEmpty ? "" : "\nPERFORMANCE: \(performance) — weight the patterns of well-performing reels more heavily.\n")
        FIRST, classify this reel into a VIDEO TYPE category. Existing categories with their current rubrics:
        \(categoryList)

        STRONGLY prefer an existing category — create a new one ONLY when this reel is clearly a different kind of video (e.g. an interview when only fight-highlight exists). A new category needs a kebab-case key and a short Title Case label.

        THEN, from the frames, work out what makes this reel's kept moments worth keeping — the visible action, framing, intensity, reactions, and pacing that distinguish its shots. Return the UPDATED rubric FOR THE CHOSEN CATEGORY (merge with that category's current rubric above).
        \(existing.isEmpty ? "" : "\nThe user's general rubric (context only — do not return it):\n\(existing)\n")
        Rules for the rubric:
        - 5–12 bullet lines starting with "- ", each concrete and visually checkable in raw footage (e.g. "- a strike visibly landing with the opponent reacting", never "- exciting moments")
        - Merge with the chosen category's current rubric: keep rules this reel still supports, sharpen wording, add what it newly teaches, and only drop an existing rule when this reel contradicts it
        - Describe what to LOOK FOR in unedited footage — ignore the reel's editing, captions, emojis, music, and graphics

        Also pick up to 4 of the attached frames that best EXEMPLIFY the rubric — the clearest "this is a keeper moment" images (skip title cards, transitions, and graphics-heavy frames).

        Return ONLY a JSON object, no markdown fences, of the form:
        {"category": "<existing key, or a new kebab-case key>", "category_label": "<short Title Case label>", "rubric": "<the bullet lines joined by newlines>", "exemplar_frames": [<the chosen frames' timestamps in seconds, from their labels>]}
        """
    }

    /// Study one exemplar reel and merge what it teaches into the profile's
    /// taste rubric — the editable "what a keeper moment looks like" rules
    /// that ride into every analysis and wizard plan. Returns the updated
    /// rubric text plus the frames the model picked as the clearest visual
    /// examples of it (few-shot images for future analysis calls).
    func distillTasteRubric(video url: URL, label: String, existingRubric: String,
                            categories: [TasteCategory] = [],
                            performance: String = "",
                            domain: String,
                            provider: String? = nil, model: String? = nil,
                            log: @escaping @Sendable (String) -> Void) async throws
        -> (categoryKey: String, categoryLabel: String, rubric: String,
            exemplarFrames: [(time: Double, jpeg: Data)]) {
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
                                            existingRubric: existingRubric,
                                            categories: categories,
                                            performance: performance)
        let response = try await callThinningFrames(prompt: prompt, auxiliary: [], sampled: frames,
                                                    model: model, provider: provider, log: log)

        var rubric = ""
        var pickedTimes: [Double] = []
        var categoryKey = "general"
        var categoryLabel = "General"
        if let object = AIResponseParser.jsonObject(from: response.text) {
            rubric = (object["rubric"] as? String ?? "")
            pickedTimes = (object["exemplar_frames"] as? [Any] ?? [])
                .compactMap { ($0 as? NSNumber)?.doubleValue }
            if let raw = (object["category"] as? String)?.lowercased() {
                let key = raw.map { $0.isLetter || $0.isNumber ? $0 : "-" }
                    .reduce(into: "") { result, character in
                        if character != "-" || result.last != "-" { result.append(character) }
                    }
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                if !key.isEmpty { categoryKey = key }
            }
            // A near-match to an existing key snaps onto it — the model
            // occasionally pluralizes or re-words its own category names.
            if let existing = categories.first(where: {
                $0.key == categoryKey || $0.key.hasPrefix(categoryKey) || categoryKey.hasPrefix($0.key)
            }) {
                categoryKey = existing.key
                categoryLabel = existing.label
            } else if let label = (object["category_label"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
                categoryLabel = label
            } else {
                categoryLabel = categoryKey.split(separator: "-")
                    .map { $0.capitalized }.joined(separator: " ")
            }
        }
        if rubric.isEmpty {
            // Older-style plain-text answer: the whole response is the rubric.
            rubric = response.text.replacingOccurrences(of: "```", with: "")
        }
        rubric = rubric.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rubric.isEmpty else { throw AIError.emptyResponse("taste rubric") }
        log("Classified as \(categoryLabel) (\(categoryKey))")

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
        return (categoryKey, categoryLabel, rubric, exemplarFrames)
    }

    // MARK: - Analysis

    /// Full visual analysis of one video. If the video was analyzed before
    /// and only new tags were added to the schema, runs the cheaper
    /// incremental pass instead. Returns the id of the analyze batch the
    /// results were stored under (nil when the pass was skipped) plus the
    /// people first detected in this pass, for the end-of-run review sheet,
    /// and a proposed replacement filename when the current one looks
    /// auto-generated (nil otherwise).
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
        -> (runID: Int64?, newPeople: [DetectedNewPerson], suggestedFilename: String?) {
        guard FFmpeg.isAvailable else { throw FFmpegError.toolNotFound("ffmpeg") }
        let tags = profile.effectiveTags
        var allTags = Set(tags.values.flatMap { $0 })
        // The taste system adds synthetic highlight tags for matching
        // moments — generic plus one per learned video type.
        if !profile.tasteRubric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            allTags.insert("highlight")
        }
        for category in profile.tasteCategories
        where !category.rubric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            allTags.insert("highlight")
            allTags.insert("highlight:\(category.key)")
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
            return (nil, [], nil)
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
            let timestamps = notes.map { min(max(0, $0.atTime), max(0, duration - 0.1)) }
            let jpegFrames = await ThumbnailService.jpegFrames(url: video.url, at: timestamps)
            referenceFrames = zip(notes, jpegFrames).compactMap { note, jpeg in
                jpeg.map { AIFrame(jpeg: $0, label: String(format: "REFERENCE for note at %.1fs", note.atTime)) }
            }
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
            let timestamps = ignoreMarkers.map { min(max(0, $0.atTime), max(0, duration - 0.1)) }
            let jpegFrames = await ThumbnailService.jpegFrames(url: video.url, at: timestamps)
            ignoreFrames = zip(ignoreMarkers, jpegFrames).compactMap { marker, jpeg in
                guard let jpeg,
                      let portrait = Self.markerPortrait(from: jpeg, marker: marker) else { return nil }
                return AIFrame(jpeg: portrait,
                               label: String(format: "IGNORE MARKER at %.1fs", marker.atTime))
            }
            if !ignoreFrames.isEmpty {
                log("Attached \(ignoreFrames.count) ignore marker(s) — these people are excluded")
            }
        }

        // Few-shot taste examples: frames from the user's exemplar reels —
        // the general library plus a couple per learned video type.
        var tasteFrames: [AIFrame] = []
        let hasTaste = !profile.tasteRubric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || profile.tasteCategories.contains {
                !$0.rubric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        if hasTaste {
            var entries: [(path: String, label: String)] = profile.tasteExemplarFrames
                .prefix(4).map { ($0, "TASTE EXAMPLE") }
            for category in profile.tasteCategories {
                entries += category.exemplarFrames.suffix(2)
                    .map { ($0, "TASTE EXAMPLE (\(category.label))") }
            }
            for (index, entry) in entries.prefix(8).enumerated() {
                let url = URL(fileURLWithPath: (entry.path as NSString).expandingTildeInPath)
                if let data = try? Data(contentsOf: url) {
                    tasteFrames.append(AIFrame(jpeg: data,
                                               label: "\(entry.label) \(index + 1) — a keeper moment"))
                }
            }
            if !tasteFrames.isEmpty {
                log("Attached \(tasteFrames.count) taste example frame(s)")
            }
        }

        var markerFrames: [AIFrame] = []
        if !namedMarkers.isEmpty {
            let timestamps = namedMarkers.map { min(max(0, $0.marker.atTime), max(0, duration - 0.1)) }
            let jpegFrames = await ThumbnailService.jpegFrames(url: video.url, at: timestamps)
            markerFrames = zip(namedMarkers, jpegFrames).compactMap { entry, jpeg in
                guard let jpeg,
                      let portrait = Self.markerPortrait(from: jpeg, marker: entry.marker) else { return nil }
                return AIFrame(jpeg: portrait,
                               label: String(format: "PERSON MARKER: %@ at %.1fs",
                                             entry.person.displayName, entry.marker.atTime))
            }
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
                                             tasteCategories: profile.tasteCategories,
                                             tasteExampleCount: tasteFrames.count,
                                             ignoreCount: ignoreFrames.count)
            tagsToRecord = Array(allTags)
            progress(0.25, "tagging (\(frames.count) frames)")
            log("Extracted \(frames.count) frames, sending for full analysis...")
        }

        // Video-native input: when Gemini is the resolved provider and the
        // whole file is a reasonable upload, it watches the actual video —
        // motion, impacts, and audio — instead of sampled stills. Trimmed
        // runs stay frames-only so timestamps remain unambiguous, and any
        // fallback provider still gets the frames.
        var nativeVideo: URL?
        let resolved = await ai.resolveProviderModel(task: "analysis",
                                                     provider: provider, model: model)
        if resolved.provider == "gemini", window == nil {
            let size = ((try? FileManager.default.attributesOfItem(atPath: video.url.path))?[.size]
                as? NSNumber)?.int64Value ?? .max
            if size <= 300 * 1024 * 1024 {
                nativeVideo = video.url
                log("Attaching the video natively — Gemini reads motion and audio directly")
            }
        }

        let response = try await callThinningFrames(
            prompt: prompt,
            auxiliary: referenceFrames + markerFrames + ignoreFrames + tasteFrames,
            sampled: frames,
            video: nativeVideo,
            model: model, provider: provider, log: log)
        guard let object = AIResponseParser.jsonObject(from: response.text) else {
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
                              suggestedName: String?, correctedName: String?,
                              firstSeen: (start: Double, end: Double))] = []
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
                let correctedName = (entry["corrected_name"] as? String)?
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
                                       correctedName?.isEmpty == false ? correctedName : nil,
                                       clean[0]))
                cleanTags["person:\(key)", default: []].append(contentsOf: clean)
            }
        }

        // Fight result, when the model saw one — winner/loser keys validated
        // against the people it just reported.
        var outcome: (method: String, winner: String?, loser: String?, event: String?, round: Int?)?
        if detectPeople, !isIncremental, let raw = object["outcome"] as? [String: Any],
           let method = (raw["method"] as? String)?.lowercased(),
           ["ko", "tko", "submission", "decision", "draw", "no-contest"].contains(method) {
            let reportedKeys = Set(detectedPeople.map(\.key)).union(knownPeople.map(\.key))
            func validKey(_ value: Any?) -> String? {
                guard let key = (value as? String)?.lowercased(), reportedKeys.contains(key) else { return nil }
                return key
            }
            let event = (raw["event"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let round = (raw["round"] as? NSNumber)?.intValue
            outcome = (method, validKey(raw["winner_key"]), validKey(raw["loser_key"]),
                       event?.isEmpty == false ? event : nil,
                       round.flatMap { (1...12).contains($0) ? $0 : nil })
        }

        // Filename proposal: offered for auto-generated-looking names and
        // for descriptive names with a misspelled person/event (the prompt
        // gates it), sanitized here so it is always usable as a file name.
        // One per analysis — the full pass only.
        var suggestedFilename: String?
        if !isIncremental, let raw = object["suggested_filename"] as? String {
            suggestedFilename = Self.sanitizedFilenameSuggestion(raw, currentFilename: video.filename)
        }

        // Whole-video classification — steers fight-only features and the
        // wizard. Saved further down, and only when the row has no type yet.
        let inferredType = isIncremental ? nil
            : (object["video_type"] as? String).flatMap { VideoType(rawValue: $0.lowercased()) }

        var cleanMoments: [(at: Double, note: String, dialog: String?)] = []
        if let rawMoments = object["moments"] as? [[String: Any]] {
            for moment in rawMoments {
                let at = ((moment["at"] as? NSNumber)?.doubleValue ?? -1).rounded(toPlaces: 1)
                guard at >= clampStart, at <= clampEnd else { continue }
                cleanMoments.append((at, moment["note"] as? String ?? "", moment["dialog"] as? String))
            }
        }

        // Sequence understanding: the beat-by-beat story + entertainment
        // score per range, attached to the matching scenes after saving.
        var sequences: [(start: Double, end: Double, narrative: String, score: Double)] = []
        for entry in object["sequences"] as? [[String: Any]] ?? [] {
            let start = max(clampStart, ((entry["start"] as? NSNumber)?.doubleValue ?? 0).rounded(toPlaces: 1))
            let end = min(clampEnd, ((entry["end"] as? NSNumber)?.doubleValue ?? 0).rounded(toPlaces: 1))
            let narrative = (entry["narrative"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard end > start, !narrative.isEmpty else { continue }
            let score = min(10, max(0, (entry["score"] as? NSNumber)?.doubleValue ?? 5))
            sequences.append((start, end, narrative, score))
        }
        // Windows the breakdown split — their scenes become parents of the
        // action scenes cut from inside them.
        var brokenWindows: [(start: Double, end: Double)] = []

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
                    guard !sub.tags.isEmpty else {
                        log(String(format: "No distinct actions found in %.1f–%.1fs — keeping the scene whole",
                                   window.start, window.end))
                        continue
                    }
                    // Hierarchical: the sequence scene is KEPT, its actions
                    // land inside it and get linked as children after saving
                    // — the planner can pick the whole story or its beats.
                    brokenWindows.append(window)
                    // People whose ranges overlap the window ride along onto
                    // each overlapping sub-range, so sub-scenes keep their
                    // people chips (and the wizard's people filter).
                    let personTags = cleanTags.filter { $0.key.hasPrefix("person:") }
                    var distinct = Set<String>()
                    for (tag, ranges) in sub.tags {
                        cleanTags[tag, default: []].append(contentsOf: ranges)
                        for range in ranges {
                            distinct.insert("\(range.start)-\(range.end)")
                            for (personTag, personRanges) in personTags
                                where personRanges.contains(where: { $0.start < range.end && range.start < $0.end }) {
                                cleanTags[personTag, default: []].append((range.start, range.end))
                            }
                        }
                    }
                    sequences.append(contentsOf: sub.sequences)
                    log(String(format: "Sequence %.1f–%.1fs kept, %d action scene(s) added inside it",
                               window.start, window.end, distinct.count))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    log(String(format: "Breakdown of %.1f–%.1fs failed — keeping the scene whole",
                               window.start, window.end))
                }
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
            // Spelling fixes for known, already-named people: the model
            // flagged a registered name it can see is misspelled (broadcast
            // graphics, the fighter's standard spelling). Only near-identical
            // names are accepted, so a "correction" can never swap in a
            // different person; unnamed people go through the review sheet
            // via suggested_name instead.
            let knownByKey = Dictionary(uniqueKeysWithValues: knownPeople.map { ($0.key, $0) })
            for person in detectedPeople {
                guard let correction = person.correctedName,
                      let existing = knownByKey[person.key],
                      !existing.name.isEmpty,
                      correction != existing.name,
                      Self.isSpellingFix(of: existing.name, candidate: correction) else { continue }
                try await database.renamePerson(id: existing.id, name: correction)
                log("Fixed spelling: \"\(existing.name)\" → \"\(correction)\"")
            }
            // Known-but-unnamed people whose name the model lifted from
            // on-screen graphics/filename join the review too, so "Unnamed
            // person N" finally gets its chyron name confirmed.
            let unnamedKnown = Set(knownPeople.filter { $0.name.isEmpty }.map(\.key))
            let reviewable = detectedPeople.filter { person in
                !known.contains(person.key)
                    || (unnamedKnown.contains(person.key) && person.suggestedName != nil)
            }
            newPeople = reviewable.map { person in
                DetectedNewPerson(key: person.key, descriptor: person.description,
                                  suggestedName: person.suggestedName,
                                  videoURL: video.url, videoFilename: video.filename,
                                  sampleTime: (person.firstSeen.start + person.firstSeen.end) / 2)
            }
        }
        // The provider that actually answered (after any failover) is the
        // batch's provenance.
        let attribution = (provider: response.provider, model: response.model)
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

        // A type already on the row wins — it's either the user's manual
        // pick or an earlier inference; re-analysis never flips it.
        if let inferredType {
            if let current = try? await database.video(id: video.id), current.videoType == nil {
                try? await database.setVideoType(id: video.id, type: inferredType.rawValue)
                log("\(video.filename): video type — \(inferredType.label)")
            }
        }

        if let outcome {
            try? await database.saveFightOutcome(videoID: video.id, runID: runID,
                                                 method: outcome.method,
                                                 winnerKey: outcome.winner,
                                                 loserKey: outcome.loser,
                                                 event: outcome.event,
                                                 round: outcome.round)
            let names = Dictionary(uniqueKeysWithValues: knownPeople.map { ($0.key, $0.displayName) })
            let winner = outcome.winner.map { names[$0] ?? $0 } ?? "?"
            let loser = outcome.loser.map { names[$0] ?? $0 } ?? "?"
            log("Fight outcome: \(winner) beat \(loser) by \(outcome.method.uppercased())"
                + (outcome.round.map { " in round \($0)" } ?? "")
                + (outcome.event.map { " (\($0))" } ?? ""))
        }

        if let suggestedFilename {
            log("Filename looks auto-generated — suggesting \"\(suggestedFilename)\"")
        }

        // Sequence stories + entertainment scores land on their scenes;
        // breakdown actions link to their parent sequence; then crowd
        // loudness spikes boost the scores of the scenes they land in.
        let savedRanges = (try? await database.sceneRanges(runID: runID)) ?? []
        func savedSceneID(start: Double, end: Double, tolerance: Double = 0.3) -> Int64? {
            savedRanges.first { abs($0.start - start) <= tolerance && abs($0.end - end) <= tolerance }?.id
        }
        var scored: [Int64: Double] = [:]
        for sequence in sequences {
            guard let id = savedSceneID(start: sequence.start, end: sequence.end) else { continue }
            try? await database.setSceneNarrative(id, narrative: sequence.narrative,
                                                  score: sequence.score)
            scored[id] = sequence.score
        }
        if !sequences.isEmpty {
            log("Sequence stories: \(scored.count) scene(s) scored for entertainment")
        }
        for window in brokenWindows {
            guard let parentID = savedSceneID(start: window.start, end: window.end) else { continue }
            for range in savedRanges
                where range.id != parentID
                    && range.start >= window.start - 0.05 && range.end <= window.end + 0.05
                    && (range.end - range.start) < (window.end - window.start) - 0.05 {
                try? await database.setSceneParent(range.id, parentID: parentID)
            }
        }

        // Audio excitement: crowd/commentator loudness spikes lift the
        // scores of the scenes they land in — a knockdown that erupts the
        // arena outranks a quiet one. Pure ffmpeg RMS; no AI cost.
        if !scored.isEmpty, await FFmpeg.hasAudioStream(video.url) {
            progress(0.96, "audio excitement")
            let curve = await Self.loudnessCurve(url: video.url)
            if curve.count > 4 {
                let median = curve.sorted()[curve.count / 2]
                var boosted = 0
                for (id, score) in scored {
                    guard let range = savedRanges.first(where: { $0.id == id }) else { continue }
                    let lower = max(0, Int(range.start))
                    let upper = min(curve.count - 1, Int(range.end) + 2)
                    guard upper >= lower, let peak = curve[lower...upper].max() else { continue }
                    let excitement = min(1, max(0, (peak - median) / 12))
                    guard excitement > 0.1 else { continue }
                    try? await database.setSceneScore(id, score: min(10, score + 1.5 * excitement),
                                                      excitement: excitement)
                    boosted += 1
                }
                if boosted > 0 {
                    log("Audio excitement boosted \(boosted) scene score(s)")
                }
            }
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
        return (runID, newPeople, suggestedFilename)
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

    /// Per-second RMS loudness (dB) of the source audio — crowd and
    /// commentator spikes mark the exciting moments. Pure ffmpeg; empty on
    /// failure or silence.
    @concurrent
    nonisolated static func loudnessCurve(url: URL) async -> [Double] {
        guard let output = try? await FFmpeg.run([
            "-i", url.path, "-map", "a:0", "-vn",
            "-af", "aresample=8000,asetnsamples=8000,astats=metadata=1:reset=1,"
                + "ametadata=mode=print:key=lavfi.astats.Overall.RMS_level:file=-",
            "-f", "null", "-",
        ], timeout: 300) else { return [] }
        return output.split(separator: "\n").compactMap { line -> Double? in
            guard let range = line.range(of: "RMS_level=") else { return nil }
            let value = Double(line[range.upperBound...].trimmingCharacters(in: .whitespaces))
            guard let value else { return -70 }
            return value.isFinite ? value : -70
        }
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
        let fractions = [0.25, 0.5, 0.75]
        let frames = await ThumbnailService.jpegFrames(
            url: url, at: fractions.map { start + duration * $0 }, maxDimension: 720)
        for data in frames {
            guard let data else { continue }
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
    @concurrent
    nonisolated static func markerPortraits(url: URL, markers: [PersonMarker],
                                            duration: Double) async -> [Data] {
        let timestamps = markers.map { min(max(0, $0.atTime), max(0, duration - 0.1)) }
        let jpegFrames = await ThumbnailService.jpegFrames(url: url, at: timestamps)
        return zip(markers, jpegFrames).compactMap { marker, jpeg in
            jpeg.flatMap { Self.markerPortrait(from: $0, marker: marker) }
        }
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

    /// Crop a person's portrait box (normalized top-left) out of a frame —
    /// the fight-scoring pass shows one per fighter as a visual attribution
    /// reference. Padded so the whole fighter (kit, build) is legible.
    nonisolated static func boxPortrait(from data: Data,
                                        box: VideoPersonRecord.PortraitBox) -> Data? {
        guard let image = NSImage(data: data),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        let pad = 0.15
        let rect = CGRect(x: (box.x - box.w * pad) * width,
                          y: (box.y - box.h * pad) * height,
                          width: box.w * (1 + 2 * pad) * width,
                          height: box.h * (1 + 2 * pad) * height)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !rect.isEmpty, let cropped = cg.cropping(to: rect) else { return nil }
        return NSBitmapImageRep(cgImage: cropped)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
