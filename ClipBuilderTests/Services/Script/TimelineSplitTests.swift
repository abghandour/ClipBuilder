import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Script split and precision", .serialized)
struct TimelineSplitTests {
    @Test("Split keeps speed-adjusted source continuity, identities and outer boundaries", arguments: [ClipRole.main, .cutaway])
    func sourceMath(role: ClipRole) throws {
        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 2, duration: 4, startTime: 3, speed: 0.5)
        clip.role = role
        clip.fadeIn = 0.2; clip.fadeOut = 0.3
        clip.transIn = "fade"; clip.transOut = "fade"
        clip.screenCrop = "50-50 Horizontal/Top"
        clip.cutawayAudio = .mixed
        let pieces = try #require(TimelineSplit.pieces(clip, at: 4.123))
        #expect(pieces.head.uid == clip.uid && pieces.tail.uid != clip.uid)
        #expect(pieces.head.originKey == clip.originKey && pieces.tail.originKey == clip.originKey)
        #expect(abs((pieces.head.sourceEnd ?? 0) - 2.5615) < 1e-9)
        #expect(pieces.head.sourceEnd == pieces.tail.sourceStart)
        #expect(pieces.tail.sourceEnd == 4)
        #expect(abs(pieces.head.duration + pieces.tail.duration - clip.duration) < 1e-9)
        #expect(pieces.head.transIn == "fade" && pieces.head.transOut == nil)
        #expect(pieces.tail.transIn == nil && pieces.tail.transOut == "fade")
        #expect(pieces.head.fadeIn == 0.2 && pieces.head.fadeOut == 0)
        #expect(pieces.tail.fadeIn == 0 && pieces.tail.fadeOut == 0.3)
        #expect(pieces.tail.role == role && pieces.tail.cutawayAudio == .mixed)
        #expect(pieces.tail.screenCrop == clip.screenCrop)
        #expect(pieces.tail.startTime == 4.123)
    }

    @Test("Endpoints, slivers, nonfinite times, unresolved bounds and bumpers reject")
    func rejection() {
        var clip = Fixtures.timelineClip(sceneID: nil, duration: 4)
        for at in [0.0, 4, -1, 0.049, 3.951, .infinity, .nan] {
            #expect(TimelineSplit.pieces(clip, at: at) == nil)
        }
        #expect(TimelineSplit.pieces(clip, at: 0.05) != nil)
        clip.sourceEnd = nil
        #expect(TimelineSplit.pieces(clip, at: 2) == nil)
        clip.sourceEnd = 6
        clip.bumper = true
        #expect(TimelineSplit.pieces(clip, at: 2) == nil)
    }

    @Test("Speech split and source edits survive subsequent packing in milliseconds")
    func speechPacking() throws {
        let clip = Fixtures.timelineClip()
        let model = ScriptFixtures.model(clips: [clip, Fixtures.timelineClip(startTime: 10)])
        model.setClipSourceRange(clip.uid, start: 2.1234, end: 4.5674, precision: .speech)
        #expect(model.clip(clip.uid)?.sourceStart == 2.123)
        #expect(abs((model.clip(clip.uid)?.duration ?? 0) - 2.444) < 1e-9)
        let split = try model.splitClip(clip.uid, at: 0.1234, precision: .speech).get()
        model.resolveLayout(track: 0)
        #expect(model.clip(split.tail)?.startTime == 0.123)
        #expect(abs((model.clip(split.tail)?.sourceStart ?? 0) - 2.246) < 1e-9)
        #expect(abs((model.document.mainClips(inTrack: 0).last?.startTime ?? 0) - 2.444) < 1e-9)
        model.trimClip(split.tail, duration: 0.0574, precision: .speech)
        #expect(abs((model.clip(split.tail)?.duration ?? 0) - 0.057) < 1e-9)
    }

    @Test("Ordinary trim/placement/split still snap and source-range duration rounds to tenths")
    func ordinaryPolicy() throws {
        let clip = Fixtures.timelineClip()
        let model = ScriptFixtures.model(clips: [clip])
        model.setTrackSequential(false, track: 0)
        model.placeClip(clip.uid, startTime: 1.26, track: 0)
        #expect(model.clip(clip.uid)?.startTime == 1.5)
        model.trimClip(clip.uid, duration: 2.26)
        #expect(model.clip(clip.uid)?.duration == 2.5)
        model.setClipSourceRange(clip.uid, start: 2.123, end: 4.567)
        #expect(model.clip(clip.uid)?.duration == 2.4)
        #expect((try? model.splitClip(clip.uid, at: 1.6).get()) == nil)
        let split = try model.splitClip(clip.uid, at: 2.26).get()
        #expect(split.at == 2.5)
    }

    @Test("Speech minimum is screen time through speed; rounded bounds are validated")
    func speedAndBounds() {
        let clip = Fixtures.timelineClip(speed: 2)
        let model = ScriptFixtures.model(clips: [clip])
        let before = model.document
        model.setClipSourceRange(clip.uid, start: 2, end: 2.099, precision: .speech)
        #expect(TimelineDiff(before: before, after: model.document).isEmpty)
        model.setClipSourceRange(clip.uid, start: 9.95, end: 10.0006, precision: .speech)
        #expect(TimelineDiff(before: before, after: model.document).isEmpty)
        model.setClipSourceRange(clip.uid, start: 2, end: 2.1, precision: .speech)
        #expect(abs((model.clip(clip.uid)?.duration ?? 0) - 0.05) < 1e-9)
    }

    @Test("Document primitive changes only the split clip and opens no gap")
    func documentPrimitive() throws {
        let first = Fixtures.timelineClip(sceneID: nil)
        let second = Fixtures.timelineClip(sceneID: nil, startTime: 4)
        var document = Fixtures.timelineDocument(clips: [first, second])
        let original = document
        #expect(TimelineSplit.split(in: &document, uid: first.uid, at: 0) == nil)
        #expect(TimelineDiff(before: original, after: document).isEmpty)
        let split = try #require(TimelineSplit.split(in: &document, uid: first.uid, at: 0.123, precision: .speech))
        #expect(document.videoTrack.count == 3)
        #expect(document.videoTrack.last == second)
        #expect(document.videoTrack[1].uid == split.tail && document.videoTrack[1].startTime == 0.123)
        #expect(document.videoTrack[0].precision == .speech && document.videoTrack[1].precision == .speech)
        #expect(document.cropBlocks.isEmpty, "The primitive does not normalize the document")
    }

    @Test("Speech policy excludes bumpers")
    func bumperPrecision() {
        var clip = Fixtures.timelineClip(sceneID: nil)
        clip.bumper = true
        let model = ScriptFixtures.model(clips: [clip])
        let before = model.document
        model.trimClip(clip.uid, duration: 0.123, precision: .speech)
        model.setClipSourceRange(clip.uid, start: 2, end: 3, precision: .speech)
        #expect((try? model.splitClip(clip.uid, at: 1, precision: .speech).get()) == nil)
        #expect(TimelineDiff(before: before, after: model.document).isEmpty)
    }

    @Test("Pause packing uses the primitive across lanes without moving cutaways")
    func pausePacking() throws {
        let first = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 6)
        let second = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 6, track: 1)
        var cutaway = Fixtures.timelineClip(sceneID: nil, duration: 1, startTime: 8)
        cutaway.role = .cutaway
        var pause = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 1, startTime: 2)
        pause.bumper = true; pause.bumperMode = .pause
        let model = ScriptFixtures.model(clips: [first, second, cutaway, pause])
        model.resolveLayout(track: 0); model.resolveLayout(track: 1)
        for track in 0...1 {
            let pieces = model.document.mainClips(inTrack: track)
            #expect(pieces.map(\.startTime) == [0, 3])
            #expect(pieces.map(\.duration) == [2, 4])
            #expect(pieces[0].sourceEnd == pieces[1].sourceStart)
            #expect(pieces[0].originKey == pieces[1].originKey)
        }
        #expect(model.clip(cutaway.uid)?.startTime == 8)
    }
    @Test("Precision persists, participates in equality and is inherited by copies and pieces")
    func precisionRoundTrip() throws {
        var clip = Fixtures.timelineClip(sceneID: nil, duration: 0.2)
        let ordinary = clip
        clip.precision = .speech
        #expect(clip != ordinary)
        let encoded = try JSONEncoder().encode(clip)
        let json = try JSONDecoder().decode(ScriptValue.self, from: encoded)
        if case .object(let fields) = json { #expect(fields["precision"] == .string("speech")) }
        else { Issue.record("Expected clip object") }
        let decoded = try JSONDecoder().decode(TimelineClip.self, from: encoded)
        #expect(decoded.precision == .speech && decoded.duration == clip.duration)
        let old = try JSONDecoder().decode(TimelineClip.self, from: JSONEncoder().encode(ordinary))
        #expect(old.precision == .ordinary)
        let pieces = try #require(TimelineSplit.pieces(decoded, at: 0.1))
        #expect(pieces.head.precision == .speech && pieces.tail.precision == .speech)
        let model = ScriptFixtures.model(clips: [decoded])
        model.duplicateClip(decoded.uid)
        #expect(model.document.videoTrack.count == 2)
        #expect(model.document.videoTrack.allSatisfy { $0.precision == .speech })
        #expect(Set(model.document.videoTrack.map(\.originKey)).count == 2)
    }

    @Test("Reloaded speech clips split around a pause with a sub-half-second head")
    func reloadedSpeechPacking() throws {
        var clip = Fixtures.timelineClip(sceneID: nil, duration: 0.2)
        clip.precision = .speech
        var pause = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 1, startTime: 0.1)
        pause.bumper = true; pause.bumperMode = .pause
        let document = Fixtures.timelineDocument(clips: [clip, pause])
        let reloaded = try JSONDecoder().decode(TimelineDocument.self, from: JSONEncoder().encode(document))
        let model = ScriptFixtures.model(clips: reloaded.videoTrack)
        model.resolveLayout(track: 0)
        let pieces = model.document.mainClips(inTrack: 0)
        #expect(pieces.count == 2, "Speech precision must survive JSON and seed")
        #expect(pieces.map(\.startTime) == [0, 1.1])
        #expect(pieces.allSatisfy { abs($0.duration - 0.1) < 1e-9 && $0.precision == .speech })
        #expect(pieces.first?.sourceEnd == pieces.last?.sourceStart)
    }

    @Test("An explicit ceiling resolves missing ends without changing the input trim")
    func explicitCeiling() throws {
        var clip = Fixtures.timelineClip()
        clip.sourceEnd = nil
        #expect(TimelineSplit.pieces(clip, at: 2) == nil)
        let pieces = try #require(TimelineSplit.pieces(clip, at: 2, minimum: 0.5, ceiling: 10))
        #expect(clip.sourceEnd == nil)
        #expect(pieces.head.sourceEnd == 4 && pieces.tail.sourceEnd == 6)
        let model = ScriptFixtures.model(clips: [clip])
        let before = model.document
        #expect((try? model.splitClip(clip.uid, at: 0).get()) == nil)
        #expect(TimelineDiff(before: before, after: model.document).isEmpty)
        let result = try model.splitClip(clip.uid, at: 2).get()
        #expect(result.sourceStart == 2 && result.sourceCut == 4 && result.sourceEnd == 6)
    }

    @Test("Speech store validation returns typed failures without mutations")
    func typedFailures() throws {
        let clip = Fixtures.timelineClip(speed: 2)
        var bumper = Fixtures.timelineClip(sceneID: nil)
        bumper.bumper = true
        let model = ScriptFixtures.model(clips: [clip, bumper])
        let before = model.document
        let cases: [(Result<Void, ClipEditFailure>, ClipEditFailure)] = [
            (model.trimClip(UUID(), duration: 1, precision: .speech), .notFound),
            (model.trimClip(bumper.uid, duration: 1, precision: .speech), .bumper),
            (model.trimClip(clip.uid, duration: .nan, precision: .speech), .outOfBounds),
            (model.trimClip(clip.uid, duration: 0.049, precision: .speech), .tooShort),
            (model.setClipSourceRange(clip.uid, start: 2, end: 2.099, precision: .speech), .tooShort),
            (model.setClipSourceRange(clip.uid, start: 9.95, end: 10.0006, precision: .speech), .outOfBounds)
        ]
        for (result, expected) in cases {
            if case .failure(let failure) = result { #expect(failure == expected) }
            else { Issue.record("Expected \(expected.rawValue)") }
        }
        #expect(TimelineDiff(before: before, after: model.document).isEmpty)
        try model.setClipSourceRange(clip.uid, start: 2, end: 2.1, precision: .speech).get()
        #expect(model.clip(clip.uid)?.precision == .speech)
        let sameRange = Fixtures.timelineClip()
        let unchangedModel = ScriptFixtures.model(clips: [sameRange])
        try unchangedModel.setClipSourceRange(sameRange.uid, start: 2, end: 6, precision: .speech).get()
        #expect(unchangedModel.clip(sameRange.uid)?.precision == .speech,
                "Selecting speech precision is an edit even when the bounds already match")
    }

}
