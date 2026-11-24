import Foundation
import Testing
@testable import Clip_Builder

@Suite("Filler cuts")
struct FillerCutRulesTests {
    private func row(_ words: [TranscriptWord], translated: Bool = false) throws -> TranscriptRow {
        TranscriptRow(id: 1, videoID: 7, language: "en", isTranslation: translated,
            startTime: 0, endTime: 10, text: words.map(\.word).joined(separator: " "),
            wordsJSON: String(decoding: try JSONEncoder().encode(words), as: UTF8.self))
    }

    @Test("Cuts preserve kept words and only use original filler and repeat proposals")
    func proposedSpans() throws {
        let words: [TranscriptWord] = [
            .init(word: "We", start: 0.5, end: 1), .init(word: "um", start: 2, end: 2.3),
            .init(word: "can", start: 3, end: 3.3),
            .init(word: "go", start: 4, end: 4.3), .init(word: "go", start: 4.4, end: 4.7),
            .init(word: "home", start: 5, end: 5.4)]
        let source = try row(words)
        let spans = FillerCutRules.spans(rows: [source])
        #expect(spans.count == 2)
        #expect(FillerCutRules.spans(rows: [try row(words, translated: true)]).isEmpty)
        let result = FillerCutRules.split(Fixtures.plan(clips: [.init(sceneID: 1, start: 0, end: 6)]),
            spans: [7: spans], sceneVideo: [1: 7])
        #expect(result.cutsApplied == 2)
        for piece in result.plan.clips {
            #expect(spans.allSatisfy { piece.end <= $0.lowerBound || piece.start >= $0.upperBound })
        }
        for word in [words[0], words[2], words[4], words[5]] {
            #expect(result.plan.clips.contains { $0.start <= word.start && $0.end >= word.end })
        }
        let retake = try row([
            .init(word: "we", start: 0, end: 0.2), .init(word: "go", start: 0.3, end: 0.5),
            .init(word: "home.", start: 0.6, end: 0.8), .init(word: "we", start: 2, end: 2.2),
            .init(word: "go", start: 2.3, end: 2.5), .init(word: "home.", start: 2.6, end: 2.8)])
        #expect(FillerCutRules.spans(rows: [retake]).isEmpty)
        let falseStart = try row([.init(word: "I", start: 0, end: 0.2),
            .init(word: "I", start: 1, end: 1.2), .init(word: "think", start: 1.3, end: 1.5)])
        #expect(FillerCutRules.spans(rows: [falseStart]).isEmpty)
    }

    @Test("Edges trim, small remnants and whole-clip cuts stay, and touching spans coalesce")
    func boundaries() {
        let plan = Fixtures.plan(clips: [Fixtures.planClip(start: 0, end: 10)])
        let result = FillerCutRules.split(plan, spans: [7: [-1...1, 9...12]], sceneVideo: [1: 7])
        #expect(result.plan.clips.map(\.start) == [1])
        #expect(result.plan.clips.map(\.end) == [9])
        #expect(result.cutsApplied == 2 && result.secondsRemoved == 2)
        for span in [0.2...1, 8...9.8, -1...12, 0...9.6] {
            let skipped = FillerCutRules.split(plan, spans: [7: [span]], sceneVideo: [1: 7])
            #expect(skipped.cutsApplied == 0 && skipped.plan.appliedFillerSpans == nil)
            #expect(skipped.plan.clips.first?.start == 0 && skipped.plan.clips.first?.end == 10)
        }
        let merged = FillerCutRules.split(plan, spans: [7: [2...3, 3...4, 2.5...3.5]], sceneVideo: [1: 7])
        #expect(merged.cutsApplied == 1 && merged.secondsRemoved == 2)
        let exact = FillerCutRules.split(plan, spans: [7: [0.5...9.5]], sceneVideo: [1: 7])
        #expect(exact.plan.clips.count == 2 && exact.cutsApplied == 1)
    }

    @Test("Speed, replay, layout and companion areas are ineligible", arguments: [0, 1, 2, 3])
    func eligibility(kind: Int) throws {
        var clip = Fixtures.planClip(start: 0, end: 6)
        switch kind {
        case 0: clip.speed = 0.5
        case 1: clip.replay = true
        case 2: clip.layout = "Two up"
        default: clip.areaClips = [.init(area: "Right", sceneID: 2, start: 0, end: 6)]
        }
        let plan = Fixtures.plan(clips: [clip])
        let result = FillerCutRules.split(plan, spans: [7: [2...3]], sceneVideo: [1: 7])
        #expect(result.cutsApplied == 0 && result.secondsRemoved == 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(result.plan) == encoder.encode(plan))
    }

    @Test("Only first pieces introduce; B-roll, identity, names and crop follow source ranges")
    func presentation() throws {
        var clip = Fixtures.planClip(start: 10, end: 20)
        clip.textOverlay = "Title"
        clip.overlayKicker = "Context"
        clip.miniPickID = 42
        clip.screenCrop = "Interview/Left"
        clip.leftSpeakerName = "Ana"
        clip.rightSpeakerName = "Bob"
        var intro = TextOverlayItem()
        intro.startTime = 0.5
        intro.endTime = 3
        var late = intro
        late.startTime = 7
        late.endTime = 9
        clip.speakerIntroductions = [intro, late]
        clip.brollCuts = [
            .init(start: 10.5, end: 11.5, sceneID: 2, sceneOffset: 0, reason: "first", origin: .user),
            .init(start: 15, end: 17, sceneID: 2, sceneOffset: 1, reason: "last", origin: .user),
            .init(start: 11, end: 16, sceneID: 2, sceneOffset: 2, reason: "crossing", origin: .user)]
        let result = FillerCutRules.split(Fixtures.plan(clips: [clip]), spans: [7: [12...14]], sceneVideo: [1: 7])
        let first = try #require(result.plan.clips.first), last = try #require(result.plan.clips.last)
        #expect(first.textOverlay == "Title" && first.overlayKicker == "Context")
        #expect(first.speakerIntroductions.count == 1 && first.speakerIntroductions.first?.endTime == 2)
        #expect(last.textOverlay == nil && last.overlayKicker == nil && last.speakerIntroductions.isEmpty)
        #expect(first.continuesPrevious == nil && last.continuesPrevious == true)
        // The cutaway crossing the cut (11...16, offset 2) stays over both sides with its own footage.
        #expect(first.brollCuts?.map(\.start) == [10.5, 11] && first.brollCuts?.map(\.end) == [11.5, 12])
        #expect(last.brollCuts?.map(\.start) == [14, 15] && last.brollCuts?.map(\.end) == [16, 17])
        #expect(first.brollCuts?.last?.sceneOffset == 2 && last.brollCuts?.first?.sceneOffset == 5)
        #expect(result.plan.clips.allSatisfy { $0.miniPickID == 42 && $0.screenCrop == clip.screenCrop
            && $0.leftSpeakerName == "Ana" && $0.rightSpeakerName == "Bob" })
        var options = WizardOptions()
        options.nameTags = true
        #expect(WizardNameTags.shows(on: first, options: options))
        #expect(!WizardNameTags.shows(on: last, options: options))
    }

    @Test("New joins are cuts, original joins survive, and splitting twice is identical")
    func joinsAndIdempotence() throws {
        let plan = Fixtures.plan(clips: [Fixtures.planClip(start: 0, end: 8),
            Fixtures.planClip(sceneID: 2, start: 20, end: 28), Fixtures.planClip(sceneID: 3, start: 0, end: 8)],
            transitions: ["fade", "wipeleft"])
        let spans: [Int64: [ClosedRange<Double>]] = [7: [2...3, 5...6, 22...23]]
        let result = FillerCutRules.split(plan, spans: spans, sceneVideo: [1: 7, 2: 7, 3: 8])
        #expect(result.plan.transitions == ["cut", "cut", "fade", "cut", "wipeleft"])
        #expect(result.expandingTransitions(["dissolve", "fade"]) == ["cut", "cut", "dissolve", "cut", "fade"])
        #expect(result.cutsApplied == 3 && result.secondsRemoved == 3)
        let again = FillerCutRules.split(result.plan, spans: spans, sceneVideo: [1: 7, 2: 7, 3: 8])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(again.plan) == encoder.encode(result.plan))
        #expect(again.cutsApplied == 0 && again.secondsRemoved == 0)
        // Rendered again with the option off: regenerated transitions still cut at the joins.
        #expect(FillerCutRules.cutJoins(["fade", "fade", "fade", "fade", "fade"], clips: result.plan.clips)
            == ["cut", "cut", "fade", "cut", "fade"])
        #expect(FillerCutRules.cutJoins(["fade"], clips: result.plan.clips) == ["cut"])
    }

    @Test("A caption page spanning a removed word keeps both sides and their timings")
    func captionJoin() throws {
        let words: [TranscriptWord] = [.init(word: "We", start: 0, end: 1),
            .init(word: "um", start: 2, end: 2.5), .init(word: "agree", start: 3, end: 4, emphasis: "primary")]
        let segments = [TranscriptSegment(start: 0, end: 4, text: "We um agree", words: words)]
        let clean = FillerCutRules.captions(segments, removing: [1.5...2.75])
        #expect(clean.first?.text == "We agree")
        #expect(clean.first?.words == [words[0], words[2]])
        var style = CaptionStyle()
        style.wordsPerPage = 6
        let renderers = CaptionRendererSet(base: CaptionRenderer(videoWidth: 1080, videoHeight: 1920,
            style: style, safeArea: nil), speakerStyles: [:])
        for range in [0.0...1.5, 2.75...4.0] {
            let pages = CaptionOverlayPlan.pages(segments: clean, renderers: renderers,
                sourceStart: range.lowerBound, speed: 1, duration: range.upperBound - range.lowerBound,
                position: "auto", language: "en")
            #expect(!pages.isEmpty)
            #expect(pages.allSatisfy { $0.caption.text == "We agree" })
        }
        #expect(FillerCutRules.captions(segments, removing: [0...4]).isEmpty)
        #expect(FillerCutRules.captions(segments, removing: []).first?.text == "We um agree")
    }

    @Test("Markers sit where a join skips exactly an applied span")
    func markers() {
        let pieces: [FillerCutRules.ShownPiece] = [
            .init(videoID: 7, sourceStart: 0, sourceEnd: 5.9, output: 0),
            .init(videoID: 7, sourceStart: 6.8, sourceEnd: 13.6, output: 5.9),
            // The same clip split again by a reframe: contiguous, no join.
            .init(videoID: 7, sourceStart: 13.6, sourceEnd: 15, output: 12.7),
            // Another pick of the recording; the filler at 16...17 was never in the reel.
            .init(videoID: 7, sourceStart: 20, sourceEnd: 24, output: 14.1),
            .init(videoID: 8, sourceStart: 26, sourceEnd: 30, output: 18.1)]
        let spans: [Int64: [ClosedRange<Double>]] = [7: [5.9...6.8, 16...17], 8: [24...26]]
        let found = FillerCutRules.markers(pieces: pieces, spans: spans)
        #expect(found.map(\.time) == [5.9])
        #expect(abs((found.first?.removed ?? 0) - 0.9) < 1e-9)
        #expect(FillerCutRules.markers(pieces: pieces, spans: [:]).isEmpty)
        #expect(FillerCutRules.summary(found) == "1 filler cut (−0.9 s)")
        #expect(FillerCutRules.summary(found + found) == "2 fillers cut (−1.8 s)")
        #expect(FillerCutRules.summary([]) == nil)
    }

    @Test("A filler under another speaker's word is not cut")
    func overlappingSpeech() throws {
        func make(_ id: Int64, _ words: [TranscriptWord]) throws -> TranscriptRow {
            TranscriptRow(id: id, videoID: 7, language: "en", isTranslation: false,
                startTime: words.first?.start ?? 0, endTime: words.last?.end ?? 0,
                text: words.map(\.word).joined(separator: " "),
                wordsJSON: String(decoding: try JSONEncoder().encode(words), as: UTF8.self))
        }
        let host = try make(1, [.init(word: "so", start: 0, end: 0.4), .init(word: "um", start: 2, end: 2.3),
                                .init(word: "next", start: 3, end: 3.4)])
        #expect(FillerCutRules.spans(rows: [host]).count == 1)
        let guest = try make(2, [.init(word: "important", start: 1.8, end: 2.6)])
        #expect(FillerCutRules.spans(rows: [host, guest]).isEmpty)
    }

    @Test("Captions keep a span's words on a clip that plays through it")
    func skippedSpans() {
        let spans = [2.0...3.0, 9.0...10.0]
        #expect(FillerCutRules.skipped(spans, playing: 0...2) == spans)
        #expect(FillerCutRules.skipped(spans, playing: 3...9) == spans)
        #expect(FillerCutRules.skipped(spans, playing: 0...8) == [9.0...10.0])
    }
}
