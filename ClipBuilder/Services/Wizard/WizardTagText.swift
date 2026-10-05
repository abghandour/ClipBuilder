import Foundation

extension WizardEngine {
    /// Returns only fields written by this call, for current-run attribution.
    /// Renderers load resolved text separately from the cache.
    func prepareTagText(plan: WizardPlan, options: WizardOptions, profile: BrandProfile,
                        sceneMap: [Int64: SceneRecord], database: Database, writeMissing: Bool = true,
                        emit: @escaping @Sendable (String) -> Void) async throws -> [PersonTagField] {
        guard options.usesNameTags else { return [] }
        try Task.checkCancellation()
        let people = try await database.fetchPeople().filter { !$0.hidden && !$0.name.isEmpty }
        var ranges: [Int64: [ClosedRange<Double>]] = [:]
        var keys: Set<String> = []
        for clip in plan.clips {
            let cuts = [(clip.sceneID, clip.start, clip.end)] + clip.areaClips.map { ($0.sceneID, $0.start, $0.end) }
            for (sceneID, start, end) in cuts where end > start {
                guard let scene = sceneMap[sceneID] else { continue }
                ranges[scene.videoID, default: []].append(start...end)
                keys.formUnion(people.filter { scene.tags.contains($0.tag) }.map(\.key))
            }
        }
        var turns: [Int64: [SpeakerTurn]] = [:]
        for videoID in ranges.keys.sorted() {
            turns[videoID] = try await database.fetchSpeakerTurns(videoID: videoID)
        }
        return try await prepareTagText(ranges: ranges, taggedKeys: keys, people: people, turns: turns,
            options: options, profile: profile, database: database, writeMissing: writeMissing, emit: emit)
    }

    /// Highlights batch only the kept source ranges, before either output loop.
    func prepareTagText(request: PodcastHighlightReviewRequest, candidates: [HighlightCandidate],
                        database: Database, emit: @escaping @Sendable (String) -> Void) async throws -> [PersonTagField] {
        let ranges = candidates.filter { $0.sourceEnd > $0.sourceStart }.map { $0.sourceStart...$0.sourceEnd }
        let cutScenes = request.scenes.filter { scene in
            scene.videoID == request.video.id && ranges.contains { scene.startTime < $0.upperBound && scene.endTime > $0.lowerBound }
        }
        let tags = Set(cutScenes.flatMap(\.tags))
        let keys = Set(request.people.filter { tags.contains($0.tag) }.map(\.key))
        return try await prepareTagText(ranges: [request.video.id: ranges], taggedKeys: keys,
            people: request.people, turns: [request.video.id: request.turns], options: request.options,
            profile: request.profile, database: database, emit: emit)
    }

    private func prepareTagText(ranges: [Int64: [ClosedRange<Double>]], taggedKeys: Set<String>,
                                people: [PersonRecord], turns: [Int64: [SpeakerTurn]],
                                options: WizardOptions, profile: BrandProfile, database: Database,
                                writeMissing: Bool = true,
                                emit: @escaping @Sendable (String) -> Void) async throws -> [PersonTagField] {
        guard options.usesNameTags else { return [] }
        try Task.checkCancellation()
        let field = TagTextWriter.fieldKey(profile.tagStyle(id: options.nameTagStyleID).description.field)
        var keys = taggedKeys
        var rows: [Int64: [TranscriptRow]] = [:]
        for videoID in ranges.keys.sorted() {
            try Task.checkCancellation()
            rows[videoID] = try await database.fetchTranscripts(videoID: videoID)
            for turn in turns[videoID] ?? [] where (ranges[videoID] ?? []).contains(where: { turn.start < $0.upperBound && turn.end > $0.lowerBound }) {
                if let key = turn.personKey { keys.insert(key) }
            }
        }
        let eligible = people.filter { keys.contains($0.key) && !$0.hidden && !$0.name.isEmpty }
        let cached = try await database.personTagFields().filter { $0.field == field && keys.contains($0.personKey) }
        let pending = eligible.filter { person in !cached.contains { $0.personKey == person.key } }.map { person in
            TagTextWriter.Person(key: person.key, name: person.displayName, category: person.category?.label ?? "",
                transcript: String(ranges.keys.sorted().map { id in
                    TagTextWriter.excerpt(personKey: person.key, rows: rows[id] ?? [], turns: turns[id] ?? [], ranges: ranges[id] ?? [])
                }.joined(separator: " ").prefix(600)))
        }
        var written: [PersonTagField] = []
        if writeMissing && !pending.isEmpty {
            do {
                emit("Writing name tag text — \(field), \(pending.count) people")
                // Only accepted, persisted answers contribute an output role.
                let reply = try await AIRunCapture.context.withValue(nil) {
                    try await ai.call(prompt: TagTextWriter.prompt(field: field, people: pending),
                        task: .tagText, timeout: 90, log: emit)
                }
                try Task.checkCancellation()
                emit("Name tag text: \(reply.provenance.shortLabel)")
                let answers = TagTextWriter.parse(reply.text, people: pending)
                for person in pending {
                    guard let value = answers[person.key] else { continue }
                    try Task.checkCancellation()
                    try await database.savePersonTagField(personKey: person.key, field: field, value: value, provenance: reply.provenance)
                    written.append(PersonTagField(personKey: person.key, field: field, value: value, provenance: reply.provenance))
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                emit("Name tag text failed: \(error.userMessage) — using names alone for missing descriptions")
            }
        }
        try Task.checkCancellation()
        return written
    }
}
