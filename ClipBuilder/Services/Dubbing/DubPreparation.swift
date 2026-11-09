import Foundation
import Synchronization

/// The same strict translation, voice and measured-fit pipeline for every entry point.
nonisolated enum DubPreparation {
    struct Speech: Sendable {
        var voices: @Sendable (String) async -> [DubSynthesizer.Voice]
        var synthesize: @Sendable (String, String, Double) async throws -> URL
        var duration: @Sendable (URL) async throws -> Double
        var synthesizeDraft: @Sendable (String, String, Double) async throws -> URL = {
            try await ElevenLabsDubSynthesizer.shared.synthesize(text: $0, voice: $1, rate: $2,
                directory: DubSynthesizer.cacheDirectory, model: "eleven_flash_v2_5")
        }

        static let mac = Speech(voices: { DubSynthesizer.installedVoices(language: $0) },
            synthesize: { try await DubSynthesizer.shared.synthesize(text: $0, voice: $1, rate: $2) },
            duration: { try await DubSynthesizer.shared.duration(of: $0) })

        /// Siri voices that are downloaded and have their shortcut. Synthesis
        /// goes through the shared synthesizer, which routes Siri identifiers
        /// to the shortcut and keeps one cache folder for the mixer.
        static let siri = Speech(voices: { await SiriDubVoices.readyVoices(language: $0) },
            synthesize: mac.synthesize, duration: mac.duration)

        static let elevenLabs = Speech(voices: {
            await DubLanguageChoices.voices(engine: .elevenLabs, language: $0)
        }, synthesize: mac.synthesize, duration: mac.duration)

        static func forEngine(_ engine: DubVoiceEngine?) -> Speech {
            switch engine ?? .mac {
            case .mac: mac
            case .siri: siri
            case .elevenLabs: elevenLabs
            }
        }
    }

    struct Prepared: Equatable, Sendable {
        var document: TimelineDocument
        var settings: DubSettings
        var lines: [DubLine]
        /// Keep the planned slots: measured speech duration must never become the next slot.
        var slots: [UUID: Double]
        var overlaps: Set<UUID>
        var speakerNames: [String: String] = [:]
        /// People seen in the dubbed videos, for correcting who says a line.
        var speakerChoices: [String] = []
        /// Speaker key → gender from the person's descriptor; voices must match it.
        var speakerGenders: [String: DubVoiceGender] = [:]
    }

    static func resolvedDocument(_ document: TimelineDocument, scenes: [SceneRecord]) -> TimelineDocument {
        var result = document
        let scenesByID = Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0) })
        for index in result.videoTrack.indices {
            let clip = result.videoTrack[index]
            let start: Double
            let duration: Double
            let path: String
            if let sceneID = clip.sceneID, let scene = scenesByID[sceneID] {
                start = clip.sourceStart ?? scene.startTime
                duration = clip.duration > 0 ? clip.duration : (scene.duration * 10).rounded() / 10
                path = scene.videoPath
            } else if let file = clip.videoFile, let sourceStart = clip.sourceStart {
                start = sourceStart
                duration = clip.duration > 0 ? clip.duration : max(0, (clip.sourceEnd ?? start) - start)
                path = file
            } else { continue }
            // Match the renderer's source pass, before it splits clips at crop blocks.
            // A crop-boundary piece must never replace the original speech range.
            result.videoTrack[index].sourceStart = start
            result.videoTrack[index].sourceEnd = start + duration * clip.effectiveSpeed
            result.videoTrack[index].duration = duration
            result.videoTrack[index].videoFile = path
            result.videoTrack[index].speed = clip.effectiveSpeed
            result.videoTrack[index].track = min(max(0, clip.track), TimelineDocument.maxTracks - 1)
        }
        return result
    }

    @concurrent
    static func prepare(document: TimelineDocument, scenes: [SceneRecord], settings: DubSettings,
                        database: Database, ai: AIService, speech: Speech = .mac,
                        onDevice: TranscriptTranslator.InstalledTranslation = TranscriptTranslator.translateInstalled,
                        log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Prepared {
        let document = resolvedDocument(document, scenes: scenes)
        let videos = try await database.fetchVideos()
        var clipsByVideo: [Int64: [TimelineClip]] = [:]
        for clip in document.videoTrack where !clip.muted && !clip.bumper && !clip.isCutaway {
            guard !(document.trackSettings[safe: clip.track]?.muted ?? false), clip.duration > 0 else { continue }
            let scene = scenes.first { $0.id == clip.sceneID }
            guard let videoID = scene?.videoID ?? videos.first(where: { $0.path == clip.videoFile })?.id,
                  clip.sourceStart != nil else {
                throw DubTranslationGate.failure(language: settings.language,
                    file: clip.videoFile.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "clip")
            }
            clipsByVideo[videoID, default: []].append(clip)
        }
        var rows: [UUID: [TranscriptRow]] = [:]
        var turns: [UUID: [SpeakerTurn]] = [:]
        var choices: [String] = []
        for videoID in clipsByVideo.keys.sorted() {
            try Task.checkCancellation()
            let clips = clipsByVideo[videoID] ?? []
            let file = videos.first { $0.id == videoID }?.filename
                ?? scenes.first { $0.videoID == videoID }?.videoFilename ?? "clip"
            log("Translating \(file)…")
            let translated = try await DubTranslationGate.ensure(videoID: videoID, file: file,
                ranges: clips.compactMap { clip in
                    guard let start = clip.sourceStart, let end = clip.sourceEnd, end > start else { return nil }
                    return start..<end
                }, language: settings.language, ai: ai, database: database, onDevice: onDevice, log: { log($0) })
            let roster = try await database.fetchVideoPeople(videoID: videoID)
            for person in roster where !person.key.isEmpty && !choices.contains(person.key) { choices.append(person.key) }
            let speakers = DubPlanning.namingTurns(try await database.fetchSpeakerTurns(videoID: videoID), roster: roster)
            for clip in clips { rows[clip.uid] = translated; turns[clip.uid] = speakers }
        }
        let people = try await database.fetchPeople()
        let genders = Dictionary(uniqueKeysWithValues: people.map { ($0.key, DubVoiceGender.inferred(from: $0.descriptor)) })
        var prepared = try await synthesize(document: document, rows: rows, turns: turns,
                                             settings: settings, speech: speech, genders: genders, database: database,
                                             preview: settings.engine == .elevenLabs, log: log)
        prepared.speakerNames = Dictionary(uniqueKeysWithValues: people.map { ($0.key, $0.displayName) })
        prepared.speakerChoices = choices
        prepared.speakerGenders = genders
        return prepared
    }

    /// An empty ElevenLabs list means no key, a failed voice fetch, or no
    /// voice for the language. The Mac "install voices" advice fits none of them.
    static func elevenLabsSetupMessage(language: String) -> String {
        let name = Locale.current.localizedString(forIdentifier: language) ?? language
        return "No ElevenLabs voices for \(name). Add your ElevenLabs key in Settings > AI, "
            + "or set Voices to Mac voices in the Audio settings."
    }

    /// Best installed voices go out first (they arrive ranked), one per
    /// speaker, round-robin within the speaker's gender: a male speaker never
    /// gets a female voice or the reverse, even a remembered one, as long as a
    /// voice of his or her gender is installed. Unknown genders use any voice.
    static func assigningVoices(lines: [DubLine], settings: DubSettings,
                               installed: [DubSynthesizer.Voice],
                               genders: [String: DubVoiceGender] = [:]) throws -> DubSettings {
        guard !installed.isEmpty else {
            throw ScriptError.invalid("Install voices in System Settings › Accessibility › Spoken Content")
        }
        var result = settings
        var next: [DubVoiceGender: Int] = [:]
        var assigned: Set<String> = []
        for key in lines.map(\.speakerKey) where assigned.insert(key).inserted {
            let gender = genders[key] ?? .unknown
            var pool = installed.filter { gender == .unknown || $0.gender == gender }
            if pool.isEmpty { pool = installed }
            if !pool.contains(where: { $0.identifier == result.voices[key] }) {
                let index = next[gender, default: 0]
                result.voices[key] = pool[index % pool.count].identifier
                next[gender] = index + 1
            }
        }
        return result
    }

    /// A teammate's clone may be absent from this account's voice list, but its
    /// paid take is still playable. Keep that remembered voice when all of its
    /// lines can be reused; missing speech still needs an available voice.
    @concurrent
    static func includingReusableVoices(_ installed: [DubSynthesizer.Voice], lines: [DubLine], settings: DubSettings,
                                        genders: [String: DubVoiceGender] = [:], database: Database?,
                                        elevenLabs: ElevenLabsSettings? = nil) async throws -> [DubSynthesizer.Voice] {
        guard settings.engine == .elevenLabs, let database else { return installed }
        var result = installed
        for (speaker, voice) in settings.voices where ElevenLabsVoices.isElevenLabs(voice)
            && !result.contains(where: { $0.identifier == voice }) {
            let lines = lines.filter { $0.speakerKey == speaker }
            guard !lines.isEmpty else { continue }
            let estimate = try await ElevenLabsDubUsage.estimate(lines: lines, voices: [speaker: voice],
                database: database, settings: elevenLabs)
            guard estimate.characters == 0 else { continue }
            result.append(.init(identifier: voice, language: settings.language, name: "Shared voice",
                                gender: genders[speaker] ?? .unknown))
        }
        return result
    }

    @concurrent
    static func synthesize(document: TimelineDocument, rows: [UUID: [TranscriptRow]],
                           turns: [UUID: [SpeakerTurn]], settings: DubSettings, speech: Speech = .mac,
                           genders: [String: DubVoiceGender] = [:], database: Database? = nil,
                           preview: Bool = false,
                           log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Prepared {
        var lines = DubPlanning.lines(document: document, rows: rows, turns: turns, settings: settings)
        if let database {
            lines = try await DubTakeStore.applyingReviews(lines, database: database)
        }
        guard !lines.isEmpty else { throw ScriptError.invalid("No translated speech in this timeline's audible clips.") }
        let installed = try await includingReusableVoices(await speech.voices(settings.language), lines: lines,
            settings: settings, genders: genders, database: database)
        if settings.engine == .siri, installed.isEmpty {
            throw ScriptError.invalid(SiriDubVoices.setupMessage(language: settings.language))
        }
        if settings.engine == .elevenLabs, installed.isEmpty {
            throw ScriptError.invalid(elevenLabsSetupMessage(language: settings.language))
        }
        let settings = try assigningVoices(lines: lines, settings: settings, installed: installed, genders: genders)
        let slots = Dictionary(uniqueKeysWithValues: lines.indices.map { index in
            (lines[index].id, DubPlanning.slot(for: lines[index], next: lines[safe: index + 1]))
        })
        let overlaps = Set(lines.filter(\.tight).map(\.id))
        if settings.engine == .elevenLabs {
            let estimate = try await ElevenLabsDubUsage.estimate(lines: lines, voices: settings.voices, database: database)
            log(estimate.caption)
        }
        let planned = lines
        lines = try await ElevenLabsDubUsage.withLogging(enabled: settings.engine == .elevenLabs, log: log) {
            let limit = settings.engine == .elevenLabs
                ? (SettingsStore.loadSettings().ai.elevenLabs ?? ElevenLabsSettings()).concurrency : 1
            return try await fitLines(planned, settings: settings, slots: slots, overlaps: overlaps,
                                      speech: speech, limit: limit, database: database, preview: preview, log: log)
        }
        return Prepared(document: document, settings: settings, lines: lines, slots: slots, overlaps: overlaps)
    }

    /// BoundedConcurrency preserves input order; progress counts completions,
    /// since remote requests can finish in a different order from the lines.
    @concurrent
    static func fitLines(_ lines: [DubLine], settings: DubSettings, slots: [UUID: Double], overlaps: Set<UUID>,
                         speech: Speech, limit: Int, database: Database? = nil,
                         preview: Bool = false,
                         log: @escaping @Sendable (String) -> Void) async throws -> [DubLine] {
        let completed = Mutex(0)
        return try await BoundedConcurrency.map(lines, limit: limit) { index, line in
            try Task.checkCancellation()
            log("Dub line \(index + 1) of \(lines.count)")
            var line = line
            line.voice = settings.voices[line.speakerKey] ?? ""
            let fitted = try await fit(line, slot: slots[line.id] ?? 0,
                                       overlapping: overlaps.contains(line.id), speech: speech, database: database, preview: preview)
            completed.withLock { count in
                count += 1
                log("PROGRESS: \(Double(count) / Double(lines.count))")
            }
            return fitted
        }
    }

    @concurrent
    static func fit(_ line: DubLine, slot: Double, overlapping: Bool, speech: Speech = .mac,
                    database: Database? = nil, preview: Bool = false,
                    takeStore: DubTakeStore = .shared,
                    directory: URL = DubSynthesizer.cacheDirectory) async throws -> DubLine {
        var result = line
        result.rate = 1
        result.takeID = nil
        result.draft = nil
        let take: (line: DubLine, url: URL)?
        if let database, ElevenLabsVoices.isElevenLabs(line.voice) {
            take = try await takeStore.audio(for: line, database: database, directory: directory, reuseOnly: preview)
        } else { take = nil }
        if let take { result = take.line; result.rate = 1; result.draft = nil }
        let isDraft = preview && ElevenLabsVoices.isElevenLabs(line.voice) && take == nil
        let synthesize = isDraft ? speech.synthesizeDraft : speech.synthesize
        result.draft = isDraft ? true : nil
        var url: URL
        if let take { url = take.url }
        else { url = try await synthesize(line.text, line.voice, 1) }
        var duration = try await speech.duration(url)
        guard duration.isFinite, duration > 0 else { throw ScriptError.invalid("The Mac voice returned an empty dub line.") }
        let fit = DubPlanning.fit(duration: duration, slot: slot)
        if fit.rate > 1 {
            try Task.checkCancellation()
            result.rate = fit.rate
            if let take { url = try await DubTakeStore.fitted(take.url, rate: fit.rate, directory: directory) }
            else { url = try await synthesize(line.text, line.voice, fit.rate) }
            duration = try await speech.duration(url)
        }
        try Task.checkCancellation()
        guard duration.isFinite, duration > 0 else { throw ScriptError.invalid("The Mac voice returned an empty dub line.") }
        result.stretch = min(1.15, max(1, duration / max(0.001, slot)))
        result.duration = duration / result.stretch
        result.tight = overlapping || result.duration > slot + 1e-9
        result.audio = url.lastPathComponent
        return result
    }

    /// Final takes remain untouched. Drafts resolve takes again in case another
    /// job or teammate completed the same row while this review was open.
    @concurrent
    static func finalize(_ prepared: Prepared, database: Database?, speech: Speech? = nil,
                         takeStore: DubTakeStore = .shared,
                         log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Prepared {
        var result = prepared
        let speech = speech ?? .forEngine(prepared.settings.engine)
        let drafts = prepared.lines.filter { $0.draft == true }
        for (index, line) in drafts.enumerated() {
            try Task.checkCancellation()
            log("Final dub line \(index + 1) of \(drafts.count)")
            let final = try await fit(line, slot: prepared.slots[line.id] ?? 0,
                overlapping: prepared.overlaps.contains(line.id), speech: speech, database: database, takeStore: takeStore)
            if let position = result.lines.firstIndex(where: { $0.id == line.id }) { result.lines[position] = final }
            log("PROGRESS: \(Double(index + 1) / Double(drafts.count))")
        }
        return result
    }

    @concurrent
    static func reopening(document: TimelineDocument, scenes: [SceneRecord], settings: DubSettings,
                          lines: [DubLine], speakerNames: [String: String],
                          speakerChoices: [String] = [], database: Database? = nil) async -> Prepared {
        let document = resolvedDocument(document, scenes: scenes)
        // Legacy timelines predate row metadata. Resolve it before accepting
        // review corrections, without changing the saved wording or timing.
        var lines = lines
        if let database {
            do { lines = try await attachingSources(lines, document: document, settings: settings, database: database) }
            catch { ErrorLog.record("Dub", "Could not resolve earlier dub rows: \(error.localizedDescription)") }
        }
        // Reconstruct planned spans from source times, never from synthesized durations.
        let planned = lines.sorted { $0.start < $1.start }.map { line in
            var planned = line
            let speed = playbackClip(for: line, document: document)?.effectiveSpeed ?? 1
            planned.duration = (line.sourceEnd - line.sourceStart) / speed
            return planned
        }
        let slots = Dictionary(uniqueKeysWithValues: planned.indices.map {
            (planned[$0].id, DubPlanning.slot(for: planned[$0], next: planned[safe: $0 + 1]))
        })
        let overlaps = Set(planned.filter { line in
            planned.contains { $0.id != line.id && $0.start < line.start + line.duration && line.start < $0.start + $0.duration }
        }.map(\.id))
        return Prepared(document: document, settings: settings, lines: lines, slots: slots,
                        overlaps: overlaps, speakerNames: speakerNames, speakerChoices: speakerChoices)
    }

    @concurrent
    static func attachingSources(_ lines: [DubLine], document: TimelineDocument, settings: DubSettings,
                                 database: Database) async throws -> [DubLine] {
        guard lines.contains(where: { $0.takeSource == nil }) else { return lines }
        let videos = try await database.fetchVideos()
        var rows: [Int64: [TranscriptRow]] = [:]
        var result = lines
        for index in result.indices where result[index].takeSource == nil {
            let line = result[index]
            guard let clip = playbackClip(for: line, document: document),
                  let videoID = videos.first(where: { $0.path == clip.videoFile })?.id else { continue }
            if rows[videoID] == nil { rows[videoID] = try await database.fetchTranscripts(videoID: videoID) }
            guard let row = rows[videoID]?.first(where: {
                $0.isTranslation && $0.language == settings.language
                    && $0.startTime <= line.sourceStart && $0.endTime >= line.sourceEnd
            }) else { continue }
            result[index].takeSource = DubTakeSource(videoID: videoID, transcriptionKey: row.transcriptionKey ?? "",
                rowStart: row.startTime, rowEnd: row.endTime, language: row.language, text: row.text, wordsJSON: row.wordsJSON)
            result[index].plannedText = line.text
            result[index].plannedSpeaker = line.speakerKey
        }
        return result
    }

    /// UIDs are session-local. A reopened document finds the audible source at the line's absolute time.
    static func playbackClip(for line: DubLine, document: TimelineDocument) -> TimelineClip? {
        let clips = document.videoTrack.filter {
            !$0.muted && !$0.bumper && !$0.isCutaway && $0.startTime <= line.start
                && line.start < $0.startTime + $0.duration
                && !(document.trackSettings[safe: $0.track]?.muted ?? false)
        }
        return clips.first { clip in
            guard let start = clip.sourceStart else { return false }
            return abs(start + (line.start - clip.startTime) * clip.effectiveSpeed - line.sourceStart) < 0.05
        } ?? clips.min { $0.track < $1.track }
    }
}
