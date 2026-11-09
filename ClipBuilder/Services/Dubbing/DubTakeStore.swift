import Foundation

/// Serializes each paid row across concurrent jobs. Waiting remains cancellable;
/// the owning request belongs to its job, so Stop never leaves a request running.
actor DubTakeStore {
    static let shared = DubTakeStore()
    private var waiters: [String: [(UUID, CheckedContinuation<Void, Error>)]] = [:]
    private let settings: @Sendable () -> ElevenLabsSettings
    private let client: @Sendable () throws -> ElevenLabsClient
    private let download: @Sendable (String, URL, Database) async throws -> Void

    init(settings: @escaping @Sendable () -> ElevenLabsSettings = {
        SettingsStore.loadSettings().ai.elevenLabs ?? ElevenLabsSettings()
    }, client: @escaping @Sendable () throws -> ElevenLabsClient = {
        guard let key = try ElevenLabsKeychain().read(), !key.isEmpty else { throw ElevenLabsError.invalidKey }
        return ElevenLabsClient(apiKey: key)
    }, download: @escaping @Sendable (String, URL, Database) async throws -> Void = {
        try await DubTakeDrive.shared.download(id: $0, to: $1, database: $2)
    }) {
        self.settings = settings
        self.client = client
        self.download = download
    }

    /// A changed fragment is an exact-span override, never a replacement of
    /// the whole row. This same identity is used by synthesis and estimates.
    nonisolated static func requestSource(_ line: DubLine) -> DubTakeSource? {
        guard var source = line.takeSource,
              [source.rowStart, source.rowEnd, line.sourceStart, line.sourceEnd].allSatisfy(\.isFinite),
              source.rowEnd > source.rowStart, line.sourceEnd > line.sourceStart,
              !DubTakeCutter.normalized(line.text).isEmpty else { return nil }
        let expected = DubTakeCutter.text(source.text, rowStart: source.rowStart, rowEnd: source.rowEnd,
                                         start: line.sourceStart, end: line.sourceEnd, words: source.words)
        if line.takeIsOverride == true || DubTakeCutter.normalized(expected) != DubTakeCutter.normalized(line.text) {
            source.rowStart = line.sourceStart
            source.rowEnd = line.sourceEnd
            source.text = line.text
            source.wordsJSON = nil
        }
        source.text = DubTakeCutter.normalized(source.text)
        return source
    }

    nonisolated static func matches(_ take: DubTake, source: DubTakeSource, voice: String,
                                    settings: ElevenLabsSettings) -> Bool {
        take.source.videoID == source.videoID && take.source.transcriptionKey == source.transcriptionKey
            && take.source.rowStart == source.rowStart && take.source.rowEnd == source.rowEnd
            && take.source.language == source.language && take.voice == voice && take.model == settings.model
            && take.settingsHash == DubTake.settingsHash(settings)
            && DubTakeCutter.normalized(take.text) == DubTakeCutter.normalized(source.text)
    }

    nonisolated static func fullSpan(_ line: DubLine, source: DubTakeSource) -> Bool {
        line.sourceStart <= source.rowStart && line.sourceEnd >= source.rowEnd
    }

    /// Returns nil only for legacy lines or a partial row with no usable alignment.
    func audio(for line: DubLine, database: Database, directory: URL = DubSynthesizer.cacheDirectory,
               reuseOnly: Bool = false)
        async throws -> (line: DubLine, url: URL)? {
        guard ElevenLabsVoices.isElevenLabs(line.voice), let source = Self.requestSource(line),
              let voiceID = ElevenLabsVoices.voiceID(line.voice) else { return nil }
        let settings = settings()
        let hash = try await database.dubVideoHash(source.videoID)
        let id = DubTake.key(videoHash: hash, source: source, voice: line.voice, settings: settings)
        let folder = await database.dubTakesDirectory
        let lock = folder.path + "/" + id
        try await acquire(lock)
        defer { release(lock) }
        try Task.checkCancellation()
        let existing = try await database.fetchDubTakes(videoID: source.videoID).first {
            Self.matches($0, source: source, voice: line.voice, settings: settings)
        }
        if let existing, !Self.hasAudio(folder.appendingPathComponent(existing.audioFile)),
           let driveID = existing.driveFileID, !driveID.isEmpty {
            // Download to a staging file: a failed transfer cannot replace good
            // local audio, and removal during the request must not resurrect it.
            let temporary = folder.appendingPathComponent(UUID().uuidString + ".caf")
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await download(driveID, temporary, database)
                try Task.checkCancellation()
                guard Self.hasAudio(temporary) else { throw ScriptError.invalid("The shared dub take contains no audio.") }
                guard try await database.fetchDubTakes(videoID: source.videoID).contains(existing) else {
                    throw ScriptError.invalid("The shared dub take changed during download.")
                }
                _ = try await database.dubVideoHash(source.videoID)
                try Data(contentsOf: temporary).write(to: folder.appendingPathComponent(existing.audioFile), options: .atomic)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                ErrorLog.record("Dub", "Could not download take; using synthesis: \(error.localizedDescription)")
            }
        }
        let plainName = try DubSynthesizer.cacheName(language: "elevenlabs",
            voice: DubTake.cacheVoice(line.voice, settings: settings), rate: 1, text: line.text)
        let plain = directory.appendingPathComponent(plainName)
        var take: DubTake
        let hit: Bool
        if let existing, Self.hasAudio(folder.appendingPathComponent(existing.audioFile)) {
            take = existing
            hit = true
        } else if line.draft != true, Self.hasAudio(plain) {
            guard !reuseOnly else { return nil }
            // Existing exact fragments remain free; full spans can be promoted
            // into durable takes even though the legacy response had no alignment.
            guard Self.fullSpan(line, source: source) else { return nil }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            take = DubTake(id: id, source: source, speakerKey: line.speakerKey, text: source.text,
                voice: line.voice, model: settings.model, settingsHash: DubTake.settingsHash(settings),
                audioFile: id + ".caf", alignment: nil, edited: false)
            let destination = folder.appendingPathComponent(take.audioFile)
            try Data(contentsOf: plain).write(to: destination, options: .atomic)
            do { try await database.upsertDubTake(take) }
            catch { try? FileManager.default.removeItem(at: destination); throw error }
            hit = true
        } else {
            guard !reuseOnly else { return nil }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let client = try client()
            ElevenLabsDubUsage.current?.request(characters: source.text.count)
            let response = try await client.speakWithTimestamps(text: source.text, voiceID: voiceID,
                                                               model: settings.model, settings: settings)
            guard let audio = response.audio, !audio.isEmpty else {
                throw ScriptError.invalid("ElevenLabs returned no take audio.")
            }
            try Task.checkCancellation()
            let temporary = folder.appendingPathComponent(UUID().uuidString + ".mp3")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try audio.write(to: temporary)
            guard Self.hasAudio(temporary) else { throw ScriptError.invalid("ElevenLabs returned an empty take.") }
            // Keep the original alignment when it describes the submitted text.
            // Normalized alignment can change words (e.g. numbers); unsafe cuts fall back.
            let alignment = [response.alignment, response.normalized_alignment].compactMap { $0 }.first {
                $0.isValid && DubTakeCutter.normalized($0.characters.joined()) == source.text
            }
            take = DubTake(id: id, source: source, speakerKey: line.speakerKey, text: source.text,
                voice: line.voice, model: settings.model, settingsHash: DubTake.settingsHash(settings),
                audioFile: id + ".caf", alignment: alignment, edited: false)
            let converted = folder.appendingPathComponent(UUID().uuidString + ".caf")
            defer { try? FileManager.default.removeItem(at: converted) }
            try await FFmpeg.run(SiriDubSynthesizer.conversionArguments(input: temporary, output: converted, rate: 1),
                                 timeout: SiriDubSynthesizer.timeout, purpose: "Save dub take")
            try Task.checkCancellation()
            guard Self.hasAudio(converted) else { throw ScriptError.invalid("ElevenLabs returned an empty take.") }
            // Re-check removal after the network/ffmpeg awaits, before publishing anything.
            _ = try await database.dubVideoHash(source.videoID)
            try Data(contentsOf: converted).write(to: folder.appendingPathComponent(take.audioFile), options: .atomic)
            do { try await database.upsertDubTake(take) }
            catch {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(take.audioFile))
                throw error
            }
            hit = false
        }
        // Scheduling never waits for Drive; uploads keep their captured profile
        // context even if the user switches profiles while they run.
        await DubTakeDrive.shared.enqueue(take, database: database)
        let full = Self.fullSpan(line, source: source)
        let range = DubTakeCutter.timeRange(text: take.text, alignment: take.alignment,
            rowStart: source.rowStart, rowEnd: source.rowEnd, start: line.sourceStart, end: line.sourceEnd, words: source.words)
        guard full || range != nil else { return nil }
        if hit { ElevenLabsDubUsage.current?.reuse(characters: line.text.count) }
        let name = DubTake.digest([take.id, take.text, take.driveFileID ?? "", String(line.sourceStart), String(line.sourceEnd),
            full ? "full" : range.map { "\($0.lowerBound):\($0.upperBound)" } ?? ""]) + ".caf"
        let output = directory.appendingPathComponent(name)
        if !Self.hasAudio(output) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = directory.appendingPathComponent(UUID().uuidString + ".caf")
            defer { try? FileManager.default.removeItem(at: temporary) }
            var args = ["-y", "-nostdin", "-i", folder.appendingPathComponent(take.audioFile).path]
            if !full, let range {
                args += ["-af", "atrim=start=\(DubPlanning.number(range.lowerBound)):end=\(DubPlanning.number(range.upperBound)),asetpts=PTS-STARTPTS"]
            }
            args += ["-ar", "48000", "-ac", "1", "-c:a", "pcm_f32le", temporary.path]
            try await FFmpeg.run(args, timeout: SiriDubSynthesizer.timeout, purpose: "Cut dub take")
            try Task.checkCancellation()
            guard Self.hasAudio(temporary) else { throw ScriptError.invalid("The take cut contains no audio.") }
            try Data(contentsOf: temporary).write(to: output, options: .atomic)
        }
        var result = line
        result.takeID = take.id
        result.takeIsOverride = source.rowStart != line.takeSource?.rowStart || source.rowEnd != line.takeSource?.rowEnd
        return (result, output)
    }

    nonisolated static func hasAudio(_ url: URL) -> Bool {
        (try? DubSynthesizer.fileDuration(of: url)) ?? 0 > 0
    }

    @concurrent
    nonisolated static func fitted(_ input: URL, rate: Double, directory: URL = DubSynthesizer.cacheDirectory) async throws -> URL {
        let output = directory.appendingPathComponent(DubTake.digest([input.lastPathComponent, String(rate)]) + ".caf")
        if hasAudio(output) { return output }
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await FFmpeg.run(SiriDubSynthesizer.conversionArguments(input: input, output: temporary, rate: rate),
                             timeout: SiriDubSynthesizer.timeout, purpose: "Fit dub take")
        try Task.checkCancellation()
        guard hasAudio(temporary) else { throw ScriptError.invalid("The fitted take contains no audio.") }
        if !hasAudio(output) {
            try Data(contentsOf: temporary).write(to: output, options: .atomic)
        }
        return output
    }

    @concurrent
    nonisolated static func applyingReviews(_ lines: [DubLine], database: Database) async throws -> [DubLine] {
        var result = lines
        var byVideo: [Int64: [DubTake]] = [:]
        for index in result.indices {
            guard var source = result[index].takeSource else { continue }
            if byVideo[source.videoID] == nil { byVideo[source.videoID] = try await database.fetchDubTakes(videoID: source.videoID) }
            let line = result[index]
            let edited = (byVideo[source.videoID] ?? []).filter {
                $0.edited && $0.source.transcriptionKey == source.transcriptionKey && $0.source.language == source.language
            }
            // Exact-span corrections win over the whole row's wording.
            let take = edited.first { $0.source.rowStart == line.sourceStart && $0.source.rowEnd == line.sourceEnd }
                ?? edited.first { $0.source.rowStart == source.rowStart && $0.source.rowEnd == source.rowEnd }
            if let take {
                if take.source.rowStart == source.rowStart && take.source.rowEnd == source.rowEnd {
                    if DubTakeCutter.normalized(source.text) != DubTakeCutter.normalized(take.text) { source.wordsJSON = nil }
                    source.text = take.text
                    result[index].takeSource = source
                    result[index].text = DubTakeCutter.text(take.text, rowStart: source.rowStart, rowEnd: source.rowEnd,
                                                           start: line.sourceStart, end: line.sourceEnd, words: source.words)
                } else {
                    result[index].text = take.text
                    result[index].takeIsOverride = true
                }
                result[index].speakerKey = take.speakerKey
                result[index].reviewedEarlier = true
            }
            if let speaker = try await database.dubSpeakerOverride(source) {
                result[index].speakerKey = speaker
                result[index].reviewedEarlier = true
            }
            result[index].plannedText = result[index].text
            result[index].plannedSpeaker = result[index].speakerKey
        }
        return result.filter { !DubTakeCutter.normalized($0.text).isEmpty }
    }

    private func acquire(_ key: String) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if waiters[key] == nil { waiters[key] = []; return }
            try await withCheckedThrowingContinuation { continuation in
                waiters[key, default: []].append((id, continuation))
            }
        } onCancel: { Task { await self.cancelWaiter(id, key: key) } }
    }

    private func release(_ key: String) {
        guard var queued = waiters[key], !queued.isEmpty else { waiters[key] = nil; return }
        let next = queued.removeFirst()
        waiters[key] = queued
        next.1.resume()
    }

    private func cancelWaiter(_ id: UUID, key: String) {
        guard let index = waiters[key]?.firstIndex(where: { $0.0 == id }),
              let waiter = waiters[key]?.remove(at: index) else { return }
        waiter.1.resume(throwing: CancellationError())
    }
}
