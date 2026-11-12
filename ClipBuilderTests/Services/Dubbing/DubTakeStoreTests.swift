import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

struct DubTakeStoreTests {
    private func line(videoID: Int64, start: Double = 0, end: Double = 4) -> DubLine {
        let text = "one two three four"
        return DubLine(clipUID: UUID(), speakerKey: "host", voice: "elevenlabs:fixture", text:
            DubTakeCutter.text(text, rowStart: 0, rowEnd: 4, start: start, end: end),
            sourceStart: start, sourceEnd: end, start: 0, duration: end - start,
            takeSource: DubTakeSource(videoID: videoID, transcriptionKey: "transcript", rowStart: 0,
                rowEnd: 4, language: "en", text: text), plannedText: text, plannedSpeaker: "host")
    }

    private func response(directory: URL, alignment: Bool = true, text: String = "one two three four") async throws -> Data {
        let audio = directory.appendingPathComponent(UUID().uuidString + ".mp3")
        defer { try? FileManager.default.removeItem(at: audio) }
        try await FFmpeg.run(["-y", "-nostdin", "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
                              "-c:a", "libmp3lame", audio.path])
        var json: [String: Any] = ["audio_base64": try Data(contentsOf: audio).base64EncodedString()]
        if alignment {
            json["alignment"] = ["characters": text.map(String.init),
                "character_start_times_seconds": text.indices.enumerated().map { Double($0.offset) * 0.2 },
                "character_end_times_seconds": text.indices.enumerated().map { Double($0.offset + 1) * 0.2 }]
        }
        return try JSONSerialization.data(withJSONObject: json)
    }

    @Test(.enabled(if: FFmpeg.isAvailable))
    func differentTrimsAndConcurrentJobsPayOnceAndSurviveCacheClearing() async throws {
        let temp = try await TempDatabase()
        let id = try await temp.seedVideo()
        let payload = try await response(directory: temp.directory.url)
        let stub = ElevenLabsTransportStub([(200, payload)])
        let store = DubTakeStore(settings: { ElevenLabsSettings() }, client: { stub.client() })
        let cache = temp.directory.url.appendingPathComponent("derived")
        let first = line(videoID: id, start: 0, end: 2)
        let second = line(videoID: id, start: 1, end: 4)
        async let a = store.audio(for: first, database: temp.database, directory: cache)
        async let b = store.audio(for: second, database: temp.database, directory: cache)
        let results = try await (a, b)
        #expect(results.0 != nil && results.1 != nil)
        #expect(await stub.requests.count == 1)
        #expect(try await temp.database.fetchDubTakes(videoID: id).count == 1)
        let request = try #require(await stub.requests.first)
        #expect(request.url?.path.hasSuffix("/with-timestamps") == true)
        let httpBody = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        #expect(body["text"] as? String == "one two three four")
        let estimate = try await ElevenLabsDubUsage.estimate(lines: [first, second], voices: [:],
            database: temp.database, settings: ElevenLabsSettings(), directory: cache)
        #expect(estimate.characters == 0 && estimate.reusedLines == 2)
        try FileManager.default.removeItem(at: cache)
        let messages = Mutex<[String]>([])
        _ = try await ElevenLabsDubUsage.withLogging(enabled: true, log: { message in messages.withLock { $0.append(message) } }) {
            try await store.audio(for: second, database: temp.database, directory: cache)
        }
        #expect(await stub.requests.count == 1)
        #expect(messages.withLock { $0.last } == "ElevenLabs: 14 characters reused · 0 characters requested")
    }

    @Test(.enabled(if: FFmpeg.isAvailable))
    func missingAlignmentReusesWholeRowsButFallsBackForFragments() async throws {
        let temp = try await TempDatabase()
        let id = try await temp.seedVideo()
        let payload = try await response(directory: temp.directory.url, alignment: false)
        let stub = ElevenLabsTransportStub([(200, payload)])
        let store = DubTakeStore(settings: { ElevenLabsSettings() }, client: { stub.client() })
        let cache = temp.directory.url.appendingPathComponent("derived")
        #expect(try await store.audio(for: line(videoID: id), database: temp.database, directory: cache) != nil)
        let partial = line(videoID: id, start: 1, end: 4)
        #expect(try await store.audio(for: partial, database: temp.database, directory: cache) == nil)
        #expect(await stub.requests.count == 1)
        let estimate = try await ElevenLabsDubUsage.estimate(lines: [partial], voices: [:], database: temp.database,
            settings: ElevenLabsSettings(), directory: cache)
        #expect(estimate.characters == partial.text.count)
        #expect(estimate.reusedLines == 0)
    }

    @Test func estimatesDeduplicateWholeRowMisses() async throws {
        let temp = try await TempDatabase()
        let id = try await temp.seedVideo()
        let estimate = try await ElevenLabsDubUsage.estimate(lines: [line(videoID: id, start: 0, end: 2),
            line(videoID: id, start: 1, end: 4)], voices: [:], database: temp.database,
            settings: ElevenLabsSettings(), directory: temp.directory.url)
        #expect(estimate.characters == "one two three four".count)
        #expect(estimate.reusedLines == 1)
    }

    @Test func editedSubspanHasItsOwnIdentity() throws {
        var edited = line(videoID: 1, start: 1, end: 3)
        edited.text = "a correction"
        let source = try #require(DubTakeStore.requestSource(edited))
        #expect(source.rowStart == 1 && source.rowEnd == 3 && source.text == "a correction")
        let original = try #require(DubTakeStore.requestSource(line(videoID: 1, start: 1, end: 3)))
        #expect(original.rowStart == 0 && original.rowEnd == 4)
        // Reverting a previously reviewed fragment must replace that override,
        // rather than leaving the old correction to return in the next timeline.
        edited.takeIsOverride = true
        edited.text = "two three"
        let reverted = try #require(DubTakeStore.requestSource(edited))
        #expect(reverted.rowStart == 1 && reverted.rowEnd == 3 && reverted.text == "two three")
    }

    @Test func reviewedTextAndSpeakersCarryOverButPartialTextStaysInItsSpan() async throws {
        let temp = try await TempDatabase()
        let id = try await temp.seedVideo()
        var edited = line(videoID: id, start: 1, end: 3)
        edited.plannedText = edited.text
        edited.text = "corrected phrase"
        edited.speakerKey = "guest"
        let source = try #require(DubTakeStore.requestSource(edited))
        let key = DubTake.key(videoHash: try await temp.database.dubVideoHash(id), source: source,
                              voice: edited.voice, settings: ElevenLabsSettings())
        let take = DubTake(id: key, source: source, speakerKey: "guest", text: edited.text, voice: edited.voice,
            model: ElevenLabsSettings().model, settingsHash: DubTake.settingsHash(ElevenLabsSettings()),
            audioFile: key + ".caf", alignment: nil, edited: false)
        try await temp.database.upsertDubTake(take)
        edited.takeID = key
        try await temp.database.rememberDubReview([edited])
        let restored = try await DubTakeStore.applyingReviews([line(videoID: id, start: 1, end: 3),
            line(videoID: id)], database: temp.database)
        #expect(restored[0].text == "corrected phrase" && restored[0].reviewedEarlier == true)
        #expect(restored[1].text == "one two three four")
        #expect(restored.allSatisfy { $0.speakerKey == "guest" })
        #expect(try await temp.database.fetchDubTakes(videoID: id).first?.edited == true)
    }

    @Test func deletionCascadesAndRetirementRemovesPaidFiles() async throws {
        let temp = try await TempDatabase()
        for retire in [false, true] {
            let id = try await temp.seedVideo()
            let source = try #require(line(videoID: id).takeSource)
            let key = DubTake.key(videoHash: try await temp.database.dubVideoHash(id), source: source,
                voice: "elevenlabs:fixture", settings: ElevenLabsSettings())
            let take = DubTake(id: key, source: source, speakerKey: "host", text: source.text, voice: "elevenlabs:fixture",
                model: ElevenLabsSettings().model, settingsHash: DubTake.settingsHash(ElevenLabsSettings()),
                audioFile: key + ".caf", alignment: nil, edited: false)
            try await temp.database.upsertDubTake(take)
            let folder = await temp.database.dubTakesDirectory
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let audio = folder.appendingPathComponent(take.audioFile)
            try Data("fixture".utf8).write(to: audio)
            if retire {
                let files = try await temp.database.retireVideos([id])
                try await temp.database.deleteDubTakeAudioFiles(files)
            } else { try await temp.database.deleteVideos([id]) }
            #expect(try await temp.database.fetchDubTakes(videoID: id).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: audio.path))
        }
    }

    @Test(.enabled(if: FFmpeg.isAvailable))
    func wholeRowCorrectionIsAlreadyVoicedForANewTimelineAndTrim() async throws {
        let temp = try await TempDatabase()
        let id = try await temp.seedVideo()
        let initial = try await response(directory: temp.directory.url)
        let corrected = try await response(directory: temp.directory.url, text: "new two three four")
        let stub = ElevenLabsTransportStub([(200, initial), (200, corrected)])
        let store = DubTakeStore(settings: { ElevenLabsSettings() }, client: { stub.client() })
        let cache = temp.directory.url.appendingPathComponent("derived")
        let first = try #require(try await store.audio(for: line(videoID: id), database: temp.database, directory: cache))
        var edit = first.line
        edit.text = "new two three four"
        let voiced = try #require(try await store.audio(for: edit, database: temp.database, directory: cache))
        try await temp.database.rememberDubReview([voiced.line])
        let later = try await DubTakeStore.applyingReviews([line(videoID: id), line(videoID: id, start: 0, end: 2)],
                                                          database: temp.database)
        #expect(later.map(\.text) == ["new two three four", "new two"])
        #expect(later.allSatisfy { $0.reviewedEarlier == true })
        for line in later {
            #expect(try await store.audio(for: line, database: temp.database, directory: cache) != nil)
        }
        #expect(await stub.requests.count == 2)
        let estimate = try await ElevenLabsDubUsage.estimate(lines: later, voices: [:], database: temp.database,
            settings: ElevenLabsSettings(), directory: cache)
        #expect(estimate.characters == 0 && estimate.reusedLines == 2)
    }

    @Test func existingVersion47LibraryGetsTakeTablesWithoutLosingVideos() async throws {
        let temp = try await TempDatabase()
        let id = try await temp.seedVideo()
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.execute("DROP TABLE dub_takes")
        try raw.execute("DROP TABLE dub_speaker_overrides")
        try raw.execute("PRAGMA user_version = 47")
        let path = temp.path
        let upgraded = try await Task.detached { try Database(path: path) }.value
        #expect(try await upgraded.fetchVideos().contains { $0.id == id })
        #expect(try await upgraded.fetchDubTakes(videoID: id).isEmpty)
        #expect(try raw.query("PRAGMA user_version").first?.values.first?.intValue == 52)
    }

    @Test func oldTimelineLinesDecodeWithoutTakeMetadata() throws {
        let original = line(videoID: 1)
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        for key in ["takeSource", "takeID", "takeIsOverride", "plannedText", "plannedSpeaker", "reviewedEarlier"] { json[key] = nil }
        let decoded = try JSONDecoder().decode(DubLine.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.takeSource == nil && decoded.reviewedEarlier == nil)
    }
}

extension DubTakeStoreTests {
    @Test func previewMissNeverCreatesATake() async throws {
        let temp = try await TempDatabase()
        let id = try await temp.seedVideo()
        let stub = ElevenLabsTransportStub([])
        let takes = DubTakeStore(settings: { ElevenLabsSettings() }, client: { stub.client() })
        let requests = Mutex<[String]>([])
        let speech = DubPreparation.Speech(voices: { _ in [] }, synthesize: { _, _, _ in
            Issue.record("Preview must not use final synthesis")
            return URL(fileURLWithPath: "/tmp/final.caf")
        }, duration: { _ in 1 }, synthesizeDraft: { text, voice, _ in
            requests.withLock { $0.append(voice + ":" + text) }
            return URL(fileURLWithPath: "/tmp/draft.caf")
        })
        let original = line(videoID: id)
        let draft = try await DubPreparation.fit(original, slot: 4, overlapping: false, speech: speech,
            database: temp.database, preview: true, takeStore: takes, directory: temp.directory.url)
        #expect(draft.draft == true && draft.takeID == nil && draft.audio == "draft.caf")
        #expect(requests.withLock { $0 } == [original.voice + ":" + original.text])
        #expect(try await temp.database.fetchDubTakes(videoID: id).isEmpty)
        #expect(await stub.requests.isEmpty)
    }

    @Test(.enabled(if: FFmpeg.isAvailable))
    func previewReusesFinalTakeWithoutDrafting() async throws {
        let temp = try await TempDatabase()
        let id = try await temp.seedVideo()
        let stub = ElevenLabsTransportStub([(200, try await response(directory: temp.directory.url))])
        let takes = DubTakeStore(settings: { ElevenLabsSettings() }, client: { stub.client() })
        let cache = temp.directory.url.appendingPathComponent("derived")
        let original = line(videoID: id)
        _ = try await takes.audio(for: original, database: temp.database, directory: cache)
        let speech = DubPreparation.Speech(voices: { _ in [] }, synthesize: { _, _, _ in
            throw ScriptError.invalid("Unexpected synthesis")
        }, duration: { _ in 1 }, synthesizeDraft: { _, _, _ in
            throw ScriptError.invalid("A final take must skip Flash")
        })
        let reused = try await DubPreparation.fit(original, slot: 4, overlapping: false, speech: speech,
            database: temp.database, preview: true, takeStore: takes, directory: temp.directory.url)
        #expect(reused.draft != true && reused.takeID != nil)
        #expect(await stub.requests.count == 1)
    }

    @Test func finalizationOnlyVoicesDraftsAndRefitsTheirOriginalSlots() async throws {
        var draft = line(videoID: 1)
        draft.draft = true
        draft.audio = "draft.caf"
        var final = line(videoID: 1)
        final.audio = "reused.caf"
        final.takeID = "existing-take"
        let requests = Mutex<[String]>([])
        let speech = DubPreparation.Speech(voices: { _ in [] }, synthesize: { text, _, rate in
            requests.withLock { $0.append(text + ":" + String(rate)) }
            return URL(fileURLWithPath: "/tmp/final-\(rate).caf")
        }, duration: { $0.lastPathComponent == "final-1.0.caf" ? 3 : 2.4 }, synthesizeDraft: { _, _, _ in
            throw ScriptError.invalid("Apply must not draft")
        })
        let prepared = DubPreparation.Prepared(document: TimelineDocument(),
            settings: .init(language: "en", engine: .elevenLabs), lines: [draft, final],
            slots: [draft.id: 2, final.id: 4], overlaps: [])
        let result = try await DubPreparation.finalize(prepared, database: nil, speech: speech)
        #expect(result.lines[1] == final)
        #expect(result.lines[0].draft != true && result.lines[0].audio == "final-1.25.caf")
        #expect(result.lines[0].rate == 1.25 && result.lines[0].stretch == 1.15)
        #expect(result.slots == prepared.slots)
        #expect(requests.withLock { $0 } == [draft.text + ":1.0", draft.text + ":1.25"])
    }

    @Test(.enabled(if: FFmpeg.isAvailable))
    func sharedTakeDownloadsBeforeSynthesisAndEstimatesAsReused() async throws {
        let temp = try await TempDatabase()
        let id = try await temp.seedVideo()
        let stub = ElevenLabsTransportStub([(200, try await response(directory: temp.directory.url))])
        let takes = DubTakeStore(settings: { ElevenLabsSettings() }, client: { stub.client() })
        let cache = temp.directory.url.appendingPathComponent("derived")
        let original = line(videoID: id)
        _ = try await takes.audio(for: original, database: temp.database, directory: cache)
        var take = try #require(try await temp.database.fetchDubTakes(videoID: id).first)
        take.driveFileID = "shared-audio"
        try await temp.database.upsertDubTake(take)
        let folder = await temp.database.dubTakesDirectory
        let audio = folder.appendingPathComponent(take.audioFile)
        let bytes = try Data(contentsOf: audio)
        try FileManager.default.removeItem(at: audio)
        try FileManager.default.removeItem(at: cache)
        let estimate = try await ElevenLabsDubUsage.estimate(lines: [original], voices: [:], database: temp.database,
            settings: ElevenLabsSettings(), directory: cache)
        #expect(estimate.characters == 0 && estimate.reusedLines == 1)
        let voices = try await DubPreparation.includingReusableVoices([], lines: [original],
            settings: .init(language: "en", voices: [original.speakerKey: original.voice], engine: .elevenLabs),
            database: temp.database, elevenLabs: ElevenLabsSettings())
        #expect(voices.map(\.identifier) == [original.voice])
        let downloads = Mutex<[String]>([])
        let receiving = DubTakeStore(settings: { ElevenLabsSettings() }, client: {
            throw ScriptError.invalid("A shared take must not require an ElevenLabs key")
        }, download: { fileID, destination, _ in
            downloads.withLock { $0.append(fileID) }
            try bytes.write(to: destination)
        })
        let result = try await receiving.audio(for: original, database: temp.database, directory: cache, reuseOnly: true)
        #expect(result?.line.takeID == take.id)
        #expect(downloads.withLock { $0 } == ["shared-audio"])
        #expect(DubTakeStore.hasAudio(audio))
    }

    @Test(.enabled(if: FFmpeg.isAvailable))
    func failedDownloadFallsBackToSynthesis() async throws {
        let temp = try await TempDatabase()
        let id = try await temp.seedVideo()
        let original = line(videoID: id)
        let source = try #require(original.takeSource)
        let settings = ElevenLabsSettings()
        let key = DubTake.key(videoHash: try await temp.database.dubVideoHash(id), source: source,
            voice: original.voice, settings: settings)
        let take = DubTake(id: key, source: source, speakerKey: original.speakerKey, text: source.text,
            voice: original.voice, model: settings.model, settingsHash: DubTake.settingsHash(settings),
            audioFile: key + ".caf", alignment: nil, edited: false, driveFileID: "unavailable")
        try await temp.database.upsertDubTake(take)
        let stub = ElevenLabsTransportStub([(200, try await response(directory: temp.directory.url))])
        let takes = DubTakeStore(settings: { settings }, client: { stub.client() }, download: { _, _, _ in
            throw URLError(.notConnectedToInternet)
        })
        let result = try await takes.audio(for: original, database: temp.database, directory: temp.directory.url)
        #expect(result != nil)
        #expect(await stub.requests.count == 1)
        #expect(try await temp.database.fetchDubTakes(videoID: id).first?.driveFileID == nil)
    }

    @Test func draftAudioDoesNotMakeTheApplyEstimateFree() async throws {
        let temp = try await TempDatabase()
        var draft = line(videoID: try await temp.seedVideo())
        draft.draft = true
        draft.audio = "draft.caf"
        let estimate = try await ElevenLabsDubUsage.estimate(lines: [draft], cachedLines: [draft], voices: [:],
            database: temp.database, settings: ElevenLabsSettings(), directory: temp.directory.url)
        #expect(estimate.characters == draft.text.count && estimate.reusedLines == 0)
        #expect(ElevenLabsDubUsage.pendingCharacters(lines: [draft], cachedLines: [draft], voices: [:]) == draft.text.count)
    }
}

extension DubTakeStoreTests {
    @Test(.enabled(if: FFmpeg.isAvailable))
    func flashAsFinalModelStillCreatesATimestampedTakeInsteadOfPromotingDraftAudio() async throws {
        let temp = try await TempDatabase()
        let id = try await temp.seedVideo()
        var draft = line(videoID: id)
        draft.draft = true
        var configured = ElevenLabsSettings()
        configured.model = "eleven_flash_v2_5"
        let settings = configured
        let name = try DubSynthesizer.cacheName(language: "elevenlabs",
            voice: DubTake.cacheVoice(draft.voice, settings: settings), rate: 1, text: draft.text)
        let cachedDraft = temp.directory.url.appendingPathComponent(name)
        try await FFmpeg.run(["-y", "-nostdin", "-f", "lavfi", "-i", "sine=frequency=220:duration=4",
            "-ar", "48000", "-ac", "1", "-c:a", "pcm_f32le", cachedDraft.path])
        draft.audio = name
        let estimate = try await ElevenLabsDubUsage.estimate(lines: [draft], cachedLines: [draft], voices: [:],
            database: temp.database, settings: settings, directory: temp.directory.url)
        #expect(estimate.characters == draft.text.count)
        #expect(estimate.credits == Int(ceil(Double(draft.text.count) * 0.5)))
        let stub = ElevenLabsTransportStub([(200, try await response(directory: temp.directory.url))])
        let takes = DubTakeStore(settings: { settings }, client: { stub.client() })
        let final = try await DubPreparation.fit(draft, slot: 4, overlapping: false,
            speech: .init(voices: { _ in [] }, synthesize: { _, _, _ in
                throw ScriptError.invalid("Expected a final timestamped take")
            }, duration: { _ in 4 }), database: temp.database, takeStore: takes, directory: temp.directory.url)
        #expect(final.draft != true && final.takeID != nil && final.audio != draft.audio)
        #expect(await stub.requests.count == 1)
        let take = try #require(try await temp.database.fetchDubTakes(videoID: id).first)
        #expect(take.model == settings.model && take.alignment != nil)
    }

    @Test func completedUploadCannotResurrectRemovedTakeOrOverwriteANewerEdit() async throws {
        let temp = try await TempDatabase()
        let id = try await temp.seedVideo()
        let original = line(videoID: id)
        let source = try #require(original.takeSource)
        let settings = ElevenLabsSettings()
        let key = DubTake.key(videoHash: try await temp.database.dubVideoHash(id), source: source,
            voice: original.voice, settings: settings)
        let take = DubTake(id: key, source: source, speakerKey: original.speakerKey, text: source.text,
            voice: original.voice, model: settings.model, settingsHash: DubTake.settingsHash(settings),
            audioFile: key + ".caf", alignment: nil, edited: false)
        try await temp.database.upsertDubTake(take)
        var newer = take
        newer.text = "new wording"
        try await temp.database.upsertDubTake(newer)
        try await temp.database.setDubTakeDriveFile("stale-upload", for: take)
        #expect(try await temp.database.fetchDubTakes(videoID: id).first?.driveFileID == nil)
        try await temp.database.setDubTakeDriveFile("current-upload", for: newer)
        #expect(try await temp.database.fetchDubTakes(videoID: id).first?.driveFileID == "current-upload")
        try await temp.database.deleteVideos([id])
        try await temp.database.setDubTakeDriveFile("late-upload", for: newer)
        #expect(try await temp.database.fetchDubTakes(videoID: id).isEmpty)
    }
}
