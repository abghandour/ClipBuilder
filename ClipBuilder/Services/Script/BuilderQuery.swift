import Foundation

/// Each query has its own admissible fields; pagination bounds model context.
nonisolated struct BuilderQuery: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case timeline, clips, scenes, people, transcript, silences, tags, layouts, templates, capabilities, effects
    }
    var kind: Kind
    var offset = 0
    var limit = 50
    var filter: ClipFilter? = nil
    var sceneFilter: SceneFilter? = nil
    var includeHidden = false
    var video: Int64? = nil
    var range: ScriptTimeRange? = nil
    var clip: String? = nil
    var threshold = 0.3

    init(_ kind: Kind, offset: Int = 0, limit: Int = 50) {
        self.kind = kind; self.offset = offset; self.limit = limit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ScriptKey.self)
        kind = try c.decode(Kind.self, forKey: ScriptKey("kind"))
        var fields: Set<String> = ["kind", "offset", "limit"]
        switch kind {
        case .clips: fields.insert("filter")
        case .scenes: fields.insert("sceneFilter")
        case .people: fields.insert("includeHidden")
        case .transcript: fields.formUnion(["video", "range"])
        case .silences: fields.formUnion(["video", "range", "clip", "threshold"])
        default: break
        }
        let unknown = Set(c.allKeys.map(\.stringValue)).subtracting(fields)
        if !unknown.isEmpty {
            var reason = "Unknown fields for kind \(kind.rawValue): \(unknown.sorted().joined(separator: ", ")). Valid fields: \(fields.sorted().joined(separator: ", "))."
            if unknown.contains("filter") {
                reason += " filter is only valid for kind clips; use sceneFilter for scenes."
            }
            if unknown.contains("sceneFilter") {
                reason += " sceneFilter is only valid for kind scenes; use filter for clips."
            }
            throw ScriptError.invalid(reason)
        }
        offset = try c.decodeIfPresent(Int.self, forKey: ScriptKey("offset")) ?? 0
        limit = try c.decodeIfPresent(Int.self, forKey: ScriptKey("limit")) ?? 50
        filter = try c.decodeIfPresent(ClipFilter.self, forKey: ScriptKey("filter"))
        sceneFilter = try c.decodeIfPresent(SceneFilter.self, forKey: ScriptKey("sceneFilter"))
        includeHidden = try c.decodeIfPresent(Bool.self, forKey: ScriptKey("includeHidden")) ?? false
        video = try c.decodeIfPresent(Int64.self, forKey: ScriptKey("video"))
        range = try c.decodeIfPresent(ScriptTimeRange.self, forKey: ScriptKey("range"))
        clip = try c.decodeIfPresent(String.self, forKey: ScriptKey("clip"))
        threshold = try c.decodeIfPresent(Double.self, forKey: ScriptKey("threshold")) ?? 0.3
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: ScriptKey.self)
        try c.encode(kind, forKey: ScriptKey("kind"))
        try c.encode(offset, forKey: ScriptKey("offset"))
        try c.encode(limit, forKey: ScriptKey("limit"))
        switch kind {
        case .clips: try c.encodeIfPresent(filter, forKey: ScriptKey("filter"))
        case .scenes: try c.encodeIfPresent(sceneFilter, forKey: ScriptKey("sceneFilter"))
        case .people: try c.encode(includeHidden, forKey: ScriptKey("includeHidden"))
        case .transcript, .silences:
            try c.encodeIfPresent(video, forKey: ScriptKey("video"))
            try c.encodeIfPresent(range, forKey: ScriptKey("range"))
            if kind == .silences {
                try c.encodeIfPresent(clip, forKey: ScriptKey("clip"))
                try c.encode(threshold, forKey: ScriptKey("threshold"))
            }
        default: break
        }
    }
}

nonisolated struct ClipQueryRow: Codable, Sendable, Equatable {
    var id: String
    var scene: Int64?
    var track: Int
    var role: ClipRole
    var bumper: Bool
    var start: Double
    var duration: Double
    var sourceStart: Double?
    var sourceEnd: Double?
    var speed: Double
    var tags: [String]
    var people: [String]
    var score: Double?
    var unknown: [String]
    var bumperMode: BumperMode?
    var volume: Int
    var position: String?
    var cropFraction: Double?
    var muted: Bool
    var effect: ScriptValue
    var details: ScriptValue

    init(_ clip: TimelineClip, scene: SceneRecord?, library: ScriptLibrarySnapshot = .init()) {
        let inferred = scene == nil ? library.inferredScene(for: clip) : nil
        let metadataScene = scene ?? inferred
        let roster = library.rosterPeople(for: clip, scene: scene)
        id = clip.uid.uuidString; self.scene = clip.sceneID; track = clip.track
        role = clip.role; bumper = clip.bumper; start = clip.startTime; duration = clip.duration
        sourceStart = clip.sourceStart
        sourceEnd = clip.sourceStart.map { $0 + clip.sourceSpan }
        speed = clip.effectiveSpeed; tags = metadataScene?.tags.sorted() ?? []
        people = tags.filter { $0.lowercased().hasPrefix("person:") }.map { String($0.dropFirst(7)) }
        let scenePeople = Set(people.map { $0.lowercased() })
        let derived = roster.filter { !scenePeople.contains($0.key.lowercased()) }
        people = Array(Set(people + derived.map(\.key))).sorted()
        score = metadataScene?.score
        bumperMode = clip.bumper ? clip.bumperMode : nil
        volume = clip.volume; position = clip.position; cropFraction = clip.cropXFrac; muted = clip.muted
        effect = clip.effect.map { ScriptValue.stored($0) } ?? .null
        details = ScriptValue.stored(clip)
        unknown = []
        if metadataScene == nil { unknown.append("scene") }
        if inferred != nil { unknown.append("scene inferred from source overlap") }
        if !derived.isEmpty {
            unknown.append(scene == nil
                ? "people derived from the video roster; clip has no scene link"
                : "people derived from the video roster")
        }
        if score == nil { unknown.append("score") }
        if sourceStart == nil { unknown.append("source_range") }
    }
}

nonisolated struct SceneQueryRow: Codable, Sendable, Equatable {
    var id: Int64
    var video: Int64
    var start: Double
    var end: Double
    var score: Double?
    var text: String?
    var tags: [String]
    var excluded: Bool
}

nonisolated struct PersonQueryRow: Codable, Sendable, Equatable {
    var key: String
    var name: String
    var descriptor: String
    var hidden: Bool
}

nonisolated struct WordQueryRow: Codable, Sendable, Equatable {
    var word: String
    var start: Double
    var end: Double
}

nonisolated struct TranscriptQueryRow: Codable, Sendable, Equatable {
    var id: Int64
    var language: String
    var start: Double
    var end: Double
    var text: String
    var words: [WordQueryRow]?
}

nonisolated struct SilenceQueryRow: Codable, Sendable, Equatable {
    var source: ScriptTimeRange
    var timeline: ScriptTimeRange?
    var evidence: String
    var precision: TimelinePrecision = .speech
}

nonisolated struct CapabilityQueryRow: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable { case unavailable, unknown, completedEmpty, completedWithData }
    var video: Int64
    var transcript: State
    var people: State
    var analysis: State
    var unknown: [String] = []
    var transcriptOutcome: PrerequisiteOutcome? = nil
    var peopleOutcome: PrerequisiteOutcome? = nil
    var analysisOutcome: PrerequisiteOutcome? = nil
}

nonisolated struct TemplateQueryRow: Codable, Sendable, Equatable {
    var name: String
    var kind: String
    var duration: Double
}

nonisolated struct LayoutQueryRow: Codable, Sendable, Equatable {
    var id: String
    var areas: [ScriptValue]

    init(id: String, areas: [ScreenCropArea], settings: [TrackSettings] = []) {
        self.id = id
        self.areas = areas.enumerated().map { index, area in
            guard case .object(var row) = ScriptValue.stored(area) else { return .null }
            row["effect"] = settings[safe: index]?.effect.map { ScriptValue.stored($0) } ?? .null
            return .object(row)
        }
    }
}

nonisolated struct EffectQueryRow: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var group: String
    var params: [EffectCatalog.ParamSpec]
    var available: Bool
}

/// Exactly one result collection is populated. Timeline pages include compact
/// clip rows plus the other lanes and settings on the first page.
nonisolated struct BuilderQueryResult: Codable, Sendable, Equatable {
    var kind: BuilderQuery.Kind
    var total = 0
    var nextOffset: Int? = nil
    var clips: [ClipQueryRow] = []
    var scenes: [SceneQueryRow] = []
    var people: [PersonQueryRow] = []
    var transcripts: [TranscriptQueryRow] = []
    var silences: [SilenceQueryRow] = []
    var tags: [String] = []
    var layouts: [LayoutQueryRow] = []
    var effects: [EffectQueryRow] = []
    var templates: [TemplateQueryRow] = []
    var sounds: [BuilderDocumentSummary.Row] = []
    var overlays: [BuilderDocumentSummary.Row] = []
    var capabilities: [CapabilityQueryRow] = []
    var timeline: ScriptValue? = nil
    var unknown: [String] = []
}

@MainActor
extension BuilderQuery {
    func execute(model: BuilderTimelineModel, library: ScriptLibrarySnapshot,
                 resolve: (String) throws -> UUID) throws -> BuilderQueryResult {
        guard offset >= 0, offset <= 1_000_000, (1...200).contains(limit), threshold.isFinite, threshold >= 0.05,
              threshold <= 60 else { throw ScriptError.invalid("Invalid query limits or silence threshold.") }
        guard (filter == nil || kind == .clips), (sceneFilter == nil || kind == .scenes),
              (!includeHidden || kind == .people),
              (video == nil || kind == .transcript || kind == .silences),
              (range == nil || kind == .transcript || kind == .silences),
              (clip == nil || kind == .silences) else {
            throw ScriptError.invalid("Fields do not belong to this query schema.")
        }
        try range?.validate()
        try filter?.validate()
        if let track = filter?.track, track >= model.document.trackCount {
            throw ScriptError.invalid("Filter track is not visible.")
        }
        if let sceneFilter {
            guard sceneFilter.minScore.map(\.isFinite) ?? true,
                  sceneFilter.people.count + sceneFilter.tags.count <= 100 else {
                throw ScriptError.invalid("Invalid scene filter.")
            }
        }
        var result = BuilderQueryResult(kind: kind)
        @MainActor func page<T>(_ rows: [T]) -> [T] {
            result.total = rows.count
            let end = min(rows.count, offset + limit)
            result.nextOffset = end < rows.count ? end : nil
            return Array(rows.dropFirst(offset).prefix(limit))
        }
        switch kind {
        case .timeline, .clips:
            let rows = model.document.videoTrack.filter {
                kind == .timeline || (filter ?? ClipFilter()).matches($0, scene: model.scene(for: $0), library: library)
            }.sorted {
                if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
                if $0.track != $1.track { return $0.track < $1.track }
                return $0.uid.uuidString < $1.uid.uuidString
            }.map { ClipQueryRow($0, scene: model.scene(for: $0), library: library) }
            result.clips = page(rows)
            if kind == .timeline, offset == 0 {
                // Lane rows ride on the first timeline page, capped by the page
                // limit so a busy timeline never pushes the result past the
                // size ceiling; get_document_summary pages through the rest.
                let lanes = BuilderDocumentSummary.allRows(document: model.document)
                let sounds = lanes.filter { $0.lane == "sound" }
                let overlays = lanes.filter { ["text", "image", "overlay"].contains($0.lane) }
                let cap = max(1, limit)
                result.sounds = Array(sounds.prefix(cap))
                result.overlays = Array(overlays.prefix(cap))
                var document = model.document
                document.videoTrack = []
                var timeline: [String: ScriptValue] = ["lanes": ScriptValue.stored(document),
                                                       "duration": .number(model.totalDuration),
                                                       "playhead": .number(model.playhead),
                                                       "selection": model.selection.map {
                                                           .object(["kind": .string($0.kind), "id": .string($0.uid.uuidString)])
                                                       } ?? .null,
                                                       "focusedTrack": model.focusedTrack.map { .number(Double($0)) } ?? .null]
                if sounds.count > cap || overlays.count > cap {
                    timeline["laneRowsTruncated"] = .bool(true)
                    timeline["laneRowsHint"] = .string("Use get_document_summary with offset/limit for every sound and overlay row.")
                }
                result.timeline = .object(timeline)
            }
        case .scenes:
            let rows = BuilderSceneSearch.ranked(sceneFilter ?? SceneFilter(), library: library).map(\.scene).map { SceneQueryRow(id: $0.id, video: $0.videoID, start: $0.startTime, end: $0.endTime,
                                 score: $0.score, text: $0.narrative.map { String($0.prefix(1000)) },
                                 tags: $0.tags.sorted(), excluded: $0.excluded) }
            result.scenes = page(rows)
        case .people:
            result.people = page(library.people.filter { includeHidden || !$0.hidden }.sorted { $0.key < $1.key }
                .map { PersonQueryRow(key: $0.key, name: $0.name, descriptor: String($0.descriptor.prefix(1000)), hidden: $0.hidden) })
        case .tags:
            result.tags = page(Array(Set(library.tags + library.scenes.flatMap(\.tags)
                + library.people.map(\.tag) + ["b-roll", "highlight"])).sorted())
        case .templates:
            result.templates = page(library.templateRows)
        case .effects:
            result.effects = page(EffectCatalog.presets.map {
                EffectQueryRow(id: $0.id, name: $0.name, group: $0.group,
                               params: $0.params, available: EffectCatalog.isAvailable($0.id))
            })
        case .layouts:
            result.layouts = page([LayoutQueryRow(id: CropLayoutRef.fullScreenName,
                areas: [ScreenCropArea(name: CropLayoutRef.fullScreenName,
                    points: [.init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)])],
                settings: model.document.trackSettings)]
                + library.layouts.sorted { $0.name < $1.name }.map { LayoutQueryRow(id: $0.name, areas: $0.areasInTrackOrder, settings: model.document.trackSettings) })
        case .capabilities:
            result.capabilities = page(library.videos.sorted { $0.id < $1.id }.map { video in
                CapabilityQueryRow(video: video.id,
                    transcript: library.prerequisiteOutcomes[video.id]?[.transcript] == .completedEmpty ? .completedEmpty
                        : library.transcripts.contains { $0.videoID == video.id && !$0.isTranslation }
                        ? .completedWithData : video.speechSeconds == nil ? .unknown : .completedEmpty,
                    people: library.prerequisiteOutcomes[video.id]?[.people] == .completedEmpty ? .completedEmpty
                        : video.peopleDetectedAt == nil ? .unavailable
                        : library.videosWithPeople.contains(video.id)
                            ? .completedWithData : .completedEmpty,
                    analysis: library.prerequisiteOutcomes[video.id]?[.analysis] == .completedEmpty ? .completedEmpty
                        : library.scenes.contains { $0.videoID == video.id }
                        ? .completedWithData : video.visualAnalyzedAt == nil ? .unavailable : .completedEmpty,
                    unknown: library.prerequisiteOutcomes[video.id]?[.transcript] == nil && video.speechSeconds == nil
                        && !library.transcripts.contains(where: { $0.videoID == video.id && !$0.isTranslation })
                        ? ["No transcript rows or completion duration marker; legacy completed-empty cannot be distinguished."] : [],
                    transcriptOutcome: library.prerequisiteOutcomes[video.id]?[.transcript],
                    peopleOutcome: library.prerequisiteOutcomes[video.id]?[.people],
                    analysisOutcome: library.prerequisiteOutcomes[video.id]?[.analysis])
            })
        case .transcript, .silences:
            var targetClip: TimelineClip?
            if let clip {
                guard let found = model.clip(try resolve(clip)) else { throw ScriptError.invalid("Missing clip.") }
                targetClip = found
            }
            let videoID = video ?? targetClip.flatMap { target in
                library.scenes.first { $0.id == target.sceneID }?.videoID
                    ?? library.videos.first { $0.path == target.videoFile }?.id
            }
            guard let videoID, library.videos.contains(where: { $0.id == videoID }) else {
                throw ScriptError.invalid("Video is missing or outside this project.")
            }
            if let targetClip, let requested = video,
               !library.videos.contains(where: { $0.id == requested && $0.path == targetClip.videoFile }) {
                throw ScriptError.invalid("Clip does not belong to the requested video.")
            }
            let rows = library.transcripts.filter { $0.videoID == videoID && !$0.isTranslation }
                .sorted { $0.startTime == $1.startTime ? $0.id < $1.id : $0.startTime < $1.startTime }
            @MainActor func words(_ row: TranscriptRow) -> [TranscriptWord]? {
                guard let data = row.wordsJSON?.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode([TranscriptWord].self, from: data),
                      decoded.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }) else { return nil }
                return decoded.sorted { $0.start < $1.start }
            }
            if kind == .transcript {
                result.transcripts = page(rows.filter { range?.overlaps(start: $0.startTime, end: $0.endTime) ?? true }.map { row in
                    TranscriptQueryRow(id: row.id, language: row.language,
                        start: max(row.startTime, range?.start ?? row.startTime),
                        end: min(row.endTime, range?.end ?? row.endTime), text: String(row.text.prefix(4000)),
                        words: words(row).map { words in words.filter { range?.overlaps(start: $0.start, end: $0.end) ?? true }
                            .map { WordQueryRow(word: $0.word, start: max($0.start, range?.start ?? $0.start),
                                               end: min($0.end, range?.end ?? $0.end)) } })
                })
                if rows.isEmpty || rows.contains(where: { words($0) == nil }) { result.unknown = ["word_timings"] }
            } else {
                var spans: [(Double, Double, String)] = library.features.filter { $0.videoID == videoID && $0.kind == .silence }
                    .map { ($0.startTime, $0.endTime, "classified_silence") }
                let timed = rows.compactMap { words($0) }.flatMap { $0 }.sorted { $0.start < $1.start }
                if timed.isEmpty || rows.contains(where: { words($0) == nil }) { result.unknown = ["word_timings"] }
                // No leading/trailing guesses: only observed word-to-word gaps.
                var previousEnd: Double?
                for word in timed {
                    if let previousEnd, word.start - previousEnd >= threshold {
                        spans.append((previousEnd, word.start, "word_gap"))
                    }
                    previousEnd = max(previousEnd ?? word.end, word.end)
                }
                var found: [SilenceQueryRow] = []
                for (start, end, evidence) in spans {
                    // An untimed transcript row between timed rows is unknown
                    // speech, not evidence of silence across that hole.
                    if evidence == "word_gap", rows.contains(where: {
                        words($0) == nil && $0.startTime < end && start < $0.endTime
                    }) { continue }
                    var lower = max(start, range?.start ?? start)
                    var upper = min(end, range?.end ?? end)
                    if let targetClip {
                        guard let source = targetClip.sourceStart else { continue }
                        lower = max(lower, source); upper = min(upper, source + targetClip.sourceSpan)
                    }
                    guard lower.isFinite, upper.isFinite, upper - lower >= 0.05,
                          !library.proposals.contains(where: {
                              $0.videoID == videoID && $0.kind == .silence && $0.decision == .rejected
                                  && $0.startTime < upper && lower < $0.endTime
                          }) else { continue }
                    let timeline = targetClip.flatMap { clip -> ScriptTimeRange? in
                        guard let source = clip.sourceStart else { return nil }
                        return ScriptTimeRange(start: clip.startTime + (lower - source) / clip.effectiveSpeed,
                                               end: clip.startTime + (upper - source) / clip.effectiveSpeed)
                    }
                    let row = SilenceQueryRow(source: ScriptTimeRange(start: lower, end: upper),
                                              timeline: timeline, evidence: evidence)
                    if !found.contains(where: { $0.source == row.source }) { found.append(row) }
                }
                result.silences = page(found.sorted { $0.source.start == $1.source.start
                    ? $0.source.end < $1.source.end : $0.source.start < $1.source.start })
            }
        }
        return result
    }
}
