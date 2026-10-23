import Foundation
import Testing
@testable import Clip_Builder

struct DubPlanningTests {
    private func row(start: Double = 10, end: Double = 14, text: String = "um dois três quatro cinco") -> TranscriptRow {
        TranscriptRow(id: 1, videoID: 7, language: "pt-BR", isTranslation: true,
            startTime: start, endTime: end, text: text, originalText: nil, wordsJSON: nil, provider: nil, model: nil)
    }

    private func plan(_ clip: TimelineClip, rows: [TranscriptRow], turns: [SpeakerTurn] = []) -> [DubLine] {
        DubPlanning.lines(document: Fixtures.timelineDocument(clips: [clip]), rows: [clip.uid: rows],
            turns: [clip.uid: turns], settings: DubSettings(language: "pt-BR", voices: ["host": "host-voice", "unknown": "fallback"]))
    }

    @Test func onlyTargetTranslationsInSourceRangeAtPlaybackSpeed() throws {
        let clip = Fixtures.timelineClip(sourceStart: 10, duration: 4, startTime: 20, speed: 2)
        var original = row(); original.isTranslation = false
        var wrongLanguage = row(); wrongLanguage.language = "en-US"
        let lines = plan(clip, rows: [row(start: 12, end: 16), original, wrongLanguage,
                                     row(start: 1, end: 4), row(start: 18, end: 20)])
        let line = try #require(lines.first)
        #expect(lines.count == 1)
        #expect(line.clipUID == clip.uid)
        #expect(line.start == 21 && line.duration == 2)
        #expect(line.sourceStart == 12 && line.sourceEnd == 16)
        #expect(line.rate == 1 && line.stretch == 1 && line.audio == nil)
    }

    @Test func mutedClipsTracksCutawaysAndBumpersProduceNoLines() {
        let base = Fixtures.timelineClip(sourceStart: 10, duration: 4)
        for change in [({ $0.muted = true } as (inout TimelineClip) -> Void),
                       { $0.role = .cutaway }, { $0.bumper = true }] {
            var clip = base; change(&clip)
            #expect(plan(clip, rows: [row()]).isEmpty)
        }
        var document = Fixtures.timelineDocument(clips: [base])
        document.trackSettings[0].muted = true
        #expect(DubPlanning.lines(document: document, rows: [base.uid: [row()]], turns: [:],
                                 settings: DubSettings(language: "pt-BR")).isEmpty)
    }

    @Test func partialRowsDropBelowFortyPercentAndTrimAtBoundary() throws {
        let clip = Fixtures.timelineClip(sourceStart: 10, duration: 4)
        #expect(plan(clip, rows: [row(start: 8, end: 11)]).isEmpty)
        // Exactly 40% at either clip edge survives, with whole words only.
        let left = try #require(plan(clip, rows: [row(start: 7, end: 12)]).first)
        #expect(left.text == "quatro cinco" && left.start == 0 && left.duration == 2)
        let right = try #require(plan(clip, rows: [row(start: 12, end: 17)]).first)
        #expect(right.text == "um dois" && right.start == 2 && right.duration == 2)
        let both = try #require(plan(clip, rows: [row(start: 8, end: 16, text: "a b c d e f g h")]).first)
        #expect(both.text == "c d e f" && both.sourceStart == 10 && both.sourceEnd == 14)
    }

    @Test func wordTimesOwnEdgeTrimming() throws {
        let clip = Fixtures.timelineClip(sourceStart: 10, duration: 4)
        var translated = row(start: 9, end: 15)
        translated.wordsJSON = String(decoding: try JSONEncoder().encode([
            TranscriptWord(word: "cut", start: 9.9, end: 10.1),
            TranscriptWord(word: "Olá", start: 10.1, end: 10.5),
            TranscriptWord(word: "mundo!", start: 12, end: 14),
            TranscriptWord(word: "tail", start: 13.9, end: 14.1),
        ]), as: UTF8.self)
        #expect(plan(clip, rows: [translated]).first?.text == "Olá mundo!")
        translated.wordsJSON = "not JSON"
        #expect(plan(clip, rows: [translated]).first?.text == "dois três quatro")
    }

    @Test func attributionOverridesTurnThenMidpointThenUnknown() throws {
        let clip = Fixtures.timelineClip(sourceStart: 10, duration: 4)
        let turns = [SpeakerTurn(videoID: 7, start: 11, end: 13, cluster: 0, confidence: 1, personKey: "guest")]
        var translated = row()
        translated.speaker = .person(key: "host")
        var line = try #require(plan(clip, rows: [translated], turns: turns).first)
        #expect(line.speakerKey == "host" && line.voice == "host-voice")
        translated.speaker = .automatic
        line = try #require(plan(clip, rows: [translated], turns: turns).first)
        #expect(line.speakerKey == "guest" && line.voice == "fallback")
        translated.speaker = .unknown
        #expect(plan(clip, rows: [translated], turns: turns).first?.speakerKey == "unknown")
        translated.speaker = .automatic
        #expect(plan(clip, rows: [translated]).first?.speakerKey == "unknown")
        // Resolve against the original row midpoint even when the clip trims it.
        let trimmed = Fixtures.timelineClip(sourceStart: 12, duration: 2)
        #expect(plan(trimmed, rows: [translated], turns: turns).first?.speakerKey == "guest")
    }

    @Test func clipRowsStaySeparateAndOverlappingSpeakersAreBothTight() {
        let first = Fixtures.timelineClip(sourceStart: 10, duration: 4)
        let second = Fixtures.timelineClip(sourceStart: 10, duration: 4, startTime: 1)
        let empty = Fixtures.timelineClip(sourceStart: 10, duration: 4, startTime: 10)
        let lines = DubPlanning.lines(document: Fixtures.timelineDocument(clips: [second, first, empty]),
            rows: [first.uid: [row(text: "first")], second.uid: [row(text: "second")]], turns: [:],
            settings: DubSettings(language: "pt-BR"))
        #expect(lines.map(\.text) == ["first", "second"])
        #expect(lines.allSatisfy { $0.tight })
    }

    @Test func slotUsesOnlyFollowingSilenceCappedAtPointSix() {
        let line = sampleLine()
        var next = line
        next.start = 3.3
        #expect(abs(DubPlanning.slot(for: line, next: next) - 2.3) < 1e-9)
        next.start = 10
        #expect(DubPlanning.slot(for: line, next: next) == 2.6)
        next.start = 2
        #expect(DubPlanning.slot(for: line, next: next) == 2)
        #expect(DubPlanning.slot(for: line, next: nil) == 2)
    }

    @Test func portugueseTwentyPercentLongerFitsWithSpeechRateAlone() {
        var line = sampleLine()
        line.text = "Esta tradução em português demora um pouco mais."
        let fit = DubPlanning.fit(duration: 2.4, slot: DubPlanning.slot(for: line, next: nil))
        #expect(fit.rate == 1.2 && fit.stretch == 1 && !fit.tight)
    }

    @Test func fitUsesRateThenTempoThenMarksTightWithoutClipping() {
        let short = DubPlanning.fit(duration: 1, slot: 2)
        #expect(short.rate == 1 && short.stretch == 1 && !short.tight)
        let stretch = DubPlanning.fit(duration: 2.75, slot: 2)
        #expect(stretch.rate == 1.25 && abs(stretch.stretch - 1.1) < 1e-9 && !stretch.tight)
        let boundary = DubPlanning.fit(duration: 2 * 1.25 * 1.15, slot: 2)
        #expect(!boundary.tight)
        let tight = DubPlanning.fit(duration: 3.2, slot: 2)
        #expect(tight.rate == 1.25 && tight.stretch == 1.15 && tight.tight)
        #expect(DubPlanning.fit(duration: 1, slot: 0).tight)
    }

    @Test func duckExpressionHasRampsAndCombinesOverlapsByMaximum() {
        let line = sampleLine()
        let envelope = "max(0\\,min(1\\,min((t-0.850000)/0.150000\\,(3.150000-t)/0.150000)))"
        #expect(DubPlanning.duckExpression(lines: [line], level: 0.15, ramp: 0.15) == "1-0.850000*(\(envelope))")
        #expect(DubPlanning.duckExpression(lines: [line, line], level: 0, ramp: 0.15)
            == "1-1.000000*(max(\(envelope)\\,\(envelope)))")
        #expect(DubPlanning.duckExpression(lines: [line], level: 0, ramp: 0)
            == "1-1.000000*(between(t\\,1.000000\\,3.000000))")
        #expect(DubPlanning.duckExpression(lines: [], level: 0.15, ramp: 0.15) == "1.0")
    }

    @Test func duckExpressionNestsShallowlyForLongTranscripts() {
        // ffmpeg's expression parser rejects a few hundred nested max() calls, so a
        // 300-line dub must combine envelopes as a balanced tree, not a left fold.
        let terms = (0..<300).map { String($0) }
        let expression = DubPlanning.balancedMax(terms[...])
        var depth = 0, deepest = 0
        for character in expression {
            if character == "(" { depth += 1; deepest = max(deepest, depth) }
            if character == ")" { depth -= 1 }
        }
        #expect(deepest == 9)
        #expect(expression.components(separatedBy: "max(").count == 300)
        #expect(DubPlanning.balancedMax(["a", "b", "c"]) == "max(a\\,max(b\\,c))")
    }

    private func sampleLine() -> DubLine {
        DubLine(clipUID: UUID(), speakerKey: "unknown", voice: "voice", text: "Olá",
                sourceStart: 0, sourceEnd: 2, start: 1, duration: 2)
    }

    @Test func unnamedClustersGoToTheVIPThenTheRosterThenNumberedSpeakers() {
        func turn(_ start: Double, _ end: Double, cluster: Int, key: String? = nil) -> SpeakerTurn {
            SpeakerTurn(videoID: 7, start: start, end: end, cluster: cluster, confidence: 1, personKey: key)
        }
        func person(_ key: String, vip: Bool = false) -> VideoPersonRecord {
            VideoPersonRecord(videoID: 7, personID: Int64(key.count), key: key, name: "", descriptor: "", portraitAt: 0, vip: vip)
        }
        // Cluster 1 talks longest and belongs to the VIP; cluster 0 to the interviewer.
        let turns = [turn(0, 2, cluster: 0), turn(2, 10, cluster: 1), turn(10, 11, cluster: 0), turn(11, 12, cluster: 2)]
        let named = DubPlanning.namingTurns(turns, roster: [person("host"), person("guest", vip: true)])
        #expect(named.map(\.personKey) == ["host", "guest", "host", "speaker-3"])
        // Keyed turns are kept and their person is not handed to a cluster.
        let keyed = DubPlanning.namingTurns([turn(0, 5, cluster: 0, key: "guest"), turn(5, 6, cluster: 1)],
                                            roster: [person("host"), person("guest", vip: true)])
        #expect(keyed.map(\.personKey) == ["guest", "host"])
        #expect(DubPlanning.namingTurns([], roster: [person("host")]).isEmpty)
        #expect(DubPlanning.speakerLabel("speaker-3") == "Speaker 3")
        #expect(DubPlanning.speakerLabel("unknown") == "Unknown speaker")
        // Lines then name the speaker from the turn under the row's midpoint.
        let clip = Fixtures.timelineClip(sourceStart: 0, duration: 12)
        let lines = DubPlanning.lines(document: Fixtures.timelineDocument(clips: [clip]),
            rows: [clip.uid: [row(start: 3, end: 5, text: "olá")]], turns: [clip.uid: named],
            settings: DubSettings(language: "pt-BR"))
        #expect(lines.map(\.speakerKey) == ["guest"])
    }

    @Test func dubbedCaptionsSpanTheSpokenDurationAtClipSpeed() {
        func line(_ sourceStart: Double, duration: Double, text: String) -> DubLine {
            DubLine(clipUID: UUID(), speakerKey: "host", voice: "v", text: text,
                    sourceStart: sourceStart, sourceEnd: sourceStart + 2, start: 0, duration: duration)
        }
        // A 1.5 s spoken line at 2x source speed covers 3 source seconds; lines
        // outside the clip's range and silent lines are left out.
        let segments = DubPlanning.captionSegments(
            lines: [line(14, duration: 1, text: "dois"), line(10, duration: 1.5, text: "um"),
                    line(30, duration: 1, text: "fora"), line(12, duration: 0, text: "mudo")],
            sourceStart: 10, sourceEnd: 20, speed: 2)
        #expect(segments.map(\.text) == ["um", "dois"])
        #expect(segments.map(\.start) == [10, 14] && segments.map(\.end) == [13, 16])
        #expect(segments.allSatisfy { $0.words == nil })
        #expect(DubPlanning.captionSegments(lines: [line(10, duration: 1, text: "x")], sourceStart: 0, sourceEnd: 20, speed: 0).isEmpty)
    }
}
