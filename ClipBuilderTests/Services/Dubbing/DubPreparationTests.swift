import Foundation
import Testing
@testable import Clip_Builder

struct DubPreparationTests {
    private let voices = [
        DubSynthesizer.Voice(identifier: "one", language: "pt-BR", name: "One"),
        DubSynthesizer.Voice(identifier: "two", language: "pt-BR", name: "Two"),
    ]

    private func line(speaker: String = "unknown", start: Double = 0, duration: Double = 2) -> DubLine {
        DubLine(clipUID: UUID(), speakerKey: speaker, voice: "one", text: "Olá",
                sourceStart: start, sourceEnd: start + duration, start: start, duration: duration)
    }

    private actor SpeechStub {
        var rates: [Double] = []
        let normal: Double
        let accelerated: Double
        init(normal: Double, accelerated: Double) { self.normal = normal; self.accelerated = accelerated }
        func synthesize(_ text: String, _ voice: String, _ rate: Double) -> URL {
            rates.append(rate)
            return URL(fileURLWithPath: rate == 1 ? "/tmp/normal.caf" : "/tmp/fast.caf")
        }
        func duration(_ url: URL) -> Double { url.lastPathComponent == "normal.caf" ? normal : accelerated }
        nonisolated var speech: DubPreparation.Speech {
            .init(voices: { _ in [.init(identifier: "one", language: "pt-BR", name: "One")] },
                  synthesize: { await self.synthesize($0, $1, $2) }, duration: { await self.duration($0) })
        }
    }

    @Test func rememberedVoicesWinOthersAlternateAndUnknownSharesOne() throws {
        let lines = [line(speaker: "host"), line(speaker: "guest"), line(), line(), line(speaker: "third")]
        let automatic = try DubPreparation.assigningVoices(lines: lines, settings: .init(language: "pt-BR"), installed: voices)
        #expect(automatic.voices == ["host": "one", "guest": "two", "unknown": "one", "third": "two"])
        let remembered = try DubPreparation.assigningVoices(lines: lines,
            settings: .init(language: "pt-BR", voices: ["host": "two", "guest": "uninstalled"]), installed: voices)
        #expect(remembered.voices["host"] == "two")
        #expect(remembered.voices["guest"] == "one")
        #expect(remembered.voices["unknown"] == "two")
    }

    @Test func voicesNeverCrossGenderWhenOneOfTheSpeakersGenderIsInstalled() throws {
        typealias Voice = DubSynthesizer.Voice
        let installed = [Voice(identifier: "siri-f", language: "pt-BR", name: "Voice 2", quality: 3, gender: .female),
                         Voice(identifier: "felipe", language: "pt-BR", name: "Felipe", quality: 2, gender: .male),
                         Voice(identifier: "luciana", language: "pt-BR", name: "Luciana", quality: 2, gender: .female),
                         Voice(identifier: "eddy", language: "pt-BR", name: "Eddy", quality: 0, gender: .male)]
        let lines = [line(speaker: "host"), line(speaker: "guest"), line(speaker: "coach"), line(speaker: "fan")]
        let genders: [String: DubVoiceGender] = ["host": .male, "guest": .male, "coach": .male, "fan": .female]
        // Remembered female voice for a man is replaced; men round-robin the male pool, best first.
        let result = try DubPreparation.assigningVoices(lines: lines,
            settings: .init(language: "pt-BR", voices: ["host": "luciana"]), installed: installed, genders: genders)
        #expect(result.voices == ["host": "felipe", "guest": "eddy", "coach": "felipe", "fan": "siri-f"])
        // No voice of the gender installed: any voice rather than none.
        let onlyWomen = Array(installed.filter { $0.gender == .female })
        #expect(try DubPreparation.assigningVoices(lines: [line(speaker: "host")], settings: .init(language: "pt-BR"),
            installed: onlyWomen, genders: genders).voices["host"] == "siri-f")
        #expect(DubVoiceGender.inferred(from: "Tall muscular male fighter with dark blonde hair") == .male)
        #expect(DubVoiceGender.inferred(from: "Woman in a red jacket, short hair") == .female)
        #expect(DubVoiceGender.inferred(from: "Official, black UFC polo shirt") == .unknown)
        #expect(DubVoiceGender.inferred(voiceName: "Grandma") == .female && DubVoiceGender.inferred(voiceName: "Rocko") == .male)
    }

    @Test func fitRemeasuresCappedSpeechInsteadOfAssumingLinearRate() async throws {
        let stub = SpeechStub(normal: 3, accelerated: 2.8)
        let result = try await DubPreparation.fit(line(), slot: 2, overlapping: false, speech: stub.speech)
        #expect(await stub.rates == [1, 1.25])
        #expect(result.rate == 1.25 && result.stretch == 1.15 && result.tight)
        #expect(abs(result.duration - 2.8 / 1.15) < 1e-9)
        #expect(result.audio == "fast.caf")
    }

    @Test func slotIsCapturedBeforeSynthesizedDurationsReplacePlannedSpans() async throws {
        let clip = Fixtures.timelineClip(sourceStart: 0, duration: 7)
        let rows = [TranscriptRow(id: 1, videoID: 1, language: "pt-BR", isTranslation: true,
            startTime: 0, endTime: 2, text: "Olá", originalText: nil, wordsJSON: nil, provider: nil, model: nil),
            TranscriptRow(id: 2, videoID: 1, language: "pt-BR", isTranslation: true,
            startTime: 5, endTime: 7, text: "Adeus", originalText: nil, wordsJSON: nil, provider: nil, model: nil)]
        let stub = SpeechStub(normal: 3.12, accelerated: 2.5)
        let result = try await DubPreparation.synthesize(document: Fixtures.timelineDocument(clips: [clip]),
            rows: [clip.uid: rows], turns: [:], settings: .init(language: "pt-BR"), speech: stub.speech)
        let first = try #require(result.lines.first)
        #expect(result.slots[first.id] == 2.6)
        #expect(abs(first.rate - 1.2) < 1e-9)
        #expect(first.duration == 2.5 && first.stretch == 1 && !first.tight)
        let second = try #require(result.lines.last)
        #expect(result.slots[second.id] == 2)
        #expect(second.tight && second.stretch == 1.15)
    }

    @Test func shortSpeechNeedsOnlyOneSynthesisAndOverlapStaysTight() async throws {
        let stub = SpeechStub(normal: 1, accelerated: 0.5)
        let result = try await DubPreparation.fit(line(), slot: 2, overlapping: true, speech: stub.speech)
        #expect(await stub.rates == [1])
        #expect(result.rate == 1 && result.stretch == 1 && result.tight)
    }

    @Test func sceneOnlySourceRangesAndPlaybackAfterUIDRegeneration() throws {
        var clip = Fixtures.timelineClip(sourceStart: 10, duration: 3, startTime: 4, speed: 2)
        clip.sourceStart = nil; clip.sourceEnd = nil; clip.videoFile = nil
        let document = DubPreparation.resolvedDocument(Fixtures.timelineDocument(clips: [clip]),
                                                       scenes: [Fixtures.scene(start: 10, end: 20)])
        let resolved = try #require(document.videoTrack.first)
        #expect(resolved.sourceStart == 10 && resolved.sourceEnd == 16)
        var speech = line(start: 5, duration: 1)
        speech.sourceStart = 12
        speech.clipUID = UUID()
        // A scene clip saves no source range (TimelineClip encodes it only for
        // file clips), so a reloaded timeline is resolved against its scenes
        // again before playback, as DubPreview does with the prepared document.
        let reloaded = DubPreparation.resolvedDocument(
            try JSONDecoder().decode(TimelineDocument.self, from: JSONEncoder().encode(document)),
            scenes: [Fixtures.scene(start: 10, end: 20)])
        #expect(DubPreparation.playbackClip(for: speech, document: reloaded)?.sourceStart == 10)
        #expect(reloaded.videoTrack.first?.uid != resolved.uid)
    }

    @Test func gateRunsForEachSourceAndKeysRowsByClip() async throws {
        let temp = try await TempDatabase()
        let videoID = try await temp.seedVideo()
        let scenes = try await temp.database.fetchScenes(includeExcluded: true)
        var clip = TimelineClip(); clip.sceneID = try #require(scenes.first).id; clip.duration = 2
        let stub = SpeechStub(normal: 1, accelerated: 1)
        try await temp.database.replaceTranscripts(videoID: videoID, transcriptionKey: "dub", language: "en",
            isTranslation: false, segments: [.init(start: 0, end: 2, text: "Hello", words: nil)], provider: "fixture", model: nil)
        let prepared = try await DubPreparation.prepare(document: Fixtures.timelineDocument(clips: [clip]), scenes: scenes,
            settings: .init(language: "pt-BR"), database: temp.database, ai: CaptionTranslationStub().service(),
            speech: stub.speech, onDevice: { rows, _ in Dictionary(uniqueKeysWithValues: rows.map { ($0.id, "Olá") }) })
        #expect(prepared.lines.count == 1 && prepared.lines.first?.clipUID == clip.uid)
        #expect(prepared.lines.first?.text == "Olá")
    }
}

extension DubPreparationTests {
    @Test func cropBoundariesDoNotShortenSpeechSourceRange() {
        let clip = Fixtures.timelineClip(sourceStart: 10, duration: 4)
        var document = Fixtures.timelineDocument(clips: [clip])
        document.cropBlocks = [.init(layout: .fullScreen, startTime: 0, duration: 2),
                               .init(layout: .fullScreen, startTime: 2, duration: 2)]
        let resolved = DubPreparation.resolvedDocument(document, scenes: [Fixtures.scene(start: 10, end: 14)])
        #expect(resolved.videoTrack.count == 1)
        #expect(resolved.videoTrack[0].sourceStart == 10 && resolved.videoTrack[0].sourceEnd == 14)
        #expect(resolved.videoTrack[0].startTime == 0 && resolved.videoTrack[0].duration == 4)
    }

    @Test func voicesRankSiriPremiumEnhancedCompactThenEloquenceAndDropNovelty() {
        typealias Voice = DubSynthesizer.Voice
        #expect(Voice.rank(identifier: "com.apple.siri.natural.Aaron", quality: .enhanced) == 3)
        #expect(Voice.rank(identifier: "com.apple.voice.premium.pt-BR.Luciana", quality: .premium) == 3)
        #expect(Voice.rank(identifier: "com.apple.voice.enhanced.pt-BR.Felipe", quality: .enhanced) == 2)
        #expect(Voice.rank(identifier: "com.apple.voice.compact.pt-BR.Luciana", quality: .default) == 1)
        #expect(Voice.rank(identifier: "com.apple.eloquence.pt-BR.Eddy", quality: .default) == 0)
        #expect(Voice.isNovelty("com.apple.speech.synthesis.voice.Zarvox") && !Voice.isNovelty("com.apple.eloquence.pt-BR.Eddy"))
        let ranked = DubSynthesizer.ranked([
            Voice(identifier: "eddy", language: "pt-BR", name: "Eddy", quality: 0),
            Voice(identifier: "luciana", language: "pt-BR", name: "Luciana", quality: 1),
            Voice(identifier: "felipe", language: "pt-BR", name: "Felipe", quality: 2),
            Voice(identifier: "siri", language: "pt-BR", name: "Voice 1", quality: 3)])
        #expect(ranked.map(\.identifier) == ["siri", "felipe", "luciana", "eddy"])
        #expect(ranked.map(\.qualityLabel) == ["Premium", "Enhanced", nil, "Eloquence"])
    }
}
