import Foundation

/// The same strict translation, voice and measured-fit pipeline for every entry point.
nonisolated enum DubPreparation {
    struct Speech: Sendable {
        var voices: @Sendable (String) async -> [DubSynthesizer.Voice]
        var synthesize: @Sendable (String, String, Double) async throws -> URL
        var duration: @Sendable (URL) async throws -> Double

        static let mac = Speech(voices: { DubSynthesizer.installedVoices(language: $0) },
            synthesize: { try await DubSynthesizer.shared.synthesize(text: $0, voice: $1, rate: $2) },
            duration: { try await DubSynthesizer.shared.duration(of: $0) })
    }

    struct Prepared: Equatable, Sendable {
        var document: TimelineDocument
        var settings: DubSettings
        var lines: [DubLine]
        /// Keep the planned slots: measured speech duration must never become the next slot.
        var slots: [UUID: Double]
        var overlaps: Set<UUID>
        var speakerNames: [String: String] = [:]
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
            let speakers = try await database.fetchSpeakerTurns(videoID: videoID)
            for clip in clips { rows[clip.uid] = translated; turns[clip.uid] = speakers }
        }
        var prepared = try await synthesize(document: document, rows: rows, turns: turns,
                                             settings: settings, speech: speech, log: log)
        prepared.speakerNames = Dictionary(uniqueKeysWithValues: try await database.fetchPeople().map { ($0.key, $0.name) })
        return prepared
    }

    static func assigningVoices(lines: [DubLine], settings: DubSettings,
                               installed: [DubSynthesizer.Voice]) throws -> DubSettings {
        guard !installed.isEmpty else {
            throw ScriptError.invalid("Install voices in System Settings › Accessibility › Spoken Content")
        }
        var result = settings
        var next = 0
        var assigned: Set<String> = []
        for key in lines.map(\.speakerKey) where assigned.insert(key).inserted {
            if !installed.contains(where: { $0.identifier == result.voices[key] }) {
                result.voices[key] = installed[next % installed.count].identifier
                next += 1
            }
        }
        return result
    }

    @concurrent
    static func synthesize(document: TimelineDocument, rows: [UUID: [TranscriptRow]],
                           turns: [UUID: [SpeakerTurn]], settings: DubSettings, speech: Speech = .mac,
                           log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Prepared {
        var lines = DubPlanning.lines(document: document, rows: rows, turns: turns, settings: settings)
        guard !lines.isEmpty else { throw ScriptError.invalid("No translated speech in this timeline's audible clips.") }
        let settings = try assigningVoices(lines: lines, settings: settings, installed: await speech.voices(settings.language))
        let slots = Dictionary(uniqueKeysWithValues: lines.indices.map { index in
            (lines[index].id, DubPlanning.slot(for: lines[index], next: lines[safe: index + 1]))
        })
        let overlaps = Set(lines.filter(\.tight).map(\.id))
        for index in lines.indices {
            try Task.checkCancellation()
            log("Dub line \(index + 1) of \(lines.count)")
            lines[index].voice = settings.voices[lines[index].speakerKey] ?? ""
            lines[index] = try await fit(lines[index], slot: slots[lines[index].id] ?? 0,
                                         overlapping: overlaps.contains(lines[index].id), speech: speech)
            log("PROGRESS: \(Double(index + 1) / Double(lines.count))")
        }
        return Prepared(document: document, settings: settings, lines: lines, slots: slots, overlaps: overlaps)
    }

    @concurrent
    static func fit(_ line: DubLine, slot: Double, overlapping: Bool, speech: Speech = .mac) async throws -> DubLine {
        var result = line
        result.rate = 1
        var url = try await speech.synthesize(line.text, line.voice, 1)
        var duration = try await speech.duration(url)
        guard duration.isFinite, duration > 0 else { throw ScriptError.invalid("The Mac voice returned an empty dub line.") }
        let fit = DubPlanning.fit(duration: duration, slot: slot)
        if fit.rate > 1 {
            try Task.checkCancellation()
            result.rate = fit.rate
            url = try await speech.synthesize(line.text, line.voice, fit.rate)
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

    @concurrent
    static func reopening(document: TimelineDocument, scenes: [SceneRecord], settings: DubSettings,
                          lines: [DubLine], speakerNames: [String: String]) async -> Prepared {
        let document = resolvedDocument(document, scenes: scenes)
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
                        overlaps: overlaps, speakerNames: speakerNames)
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
