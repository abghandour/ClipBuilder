import Foundation
import Testing
@testable import Clip_Builder

struct ReviewFlagBuilderTests {
    private func flags(clips: [TimelineClip] = [Fixtures.timelineClip()],
                       scenes: [SceneRecord] = [Fixtures.scene()],
                       turns: [SpeakerTurn] = [],
                       quality: ReelQualityReport? = nil,
                       fallbacks: [RenderFramingFallback] = []) -> [ReviewFlag] {
        ReviewFlagBuilder.flags(document: Fixtures.timelineDocument(clips: clips),
                                scenes: Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0) }),
                                turns: turns, quality: quality, renderFallbacks: fallbacks)
    }

    @Test func unnamedTurnMapsToOutputTimeWithSpeed() throws {
        // Source 2...10 at 2x plays on the timeline from 10 to 14.
        let clip = Fixtures.timelineClip(sourceStart: 2, duration: 4, startTime: 10, speed: 2)
        let result = flags(clips: [clip], turns: [Fixtures.speakerTurn(start: 6, end: 8, personKey: nil)])
        let flag = try #require(result.first)
        #expect(result.count == 1)
        #expect(flag.kind == .unnamedSpeaker)
        #expect(flag.severity == .warning)
        #expect(abs(flag.time - 12) < 0.0001)
        #expect(abs((flag.endTime ?? 0) - 13) < 0.0001)
        #expect(flag.clipOriginKey == clip.originKey)
    }

    @Test func turnStartingBeforeTheClipClampsToItsStart() throws {
        let clip = Fixtures.timelineClip(sourceStart: 2, duration: 4, startTime: 5)
        let flag = try #require(flags(clips: [clip], turns: [Fixtures.speakerTurn(start: 0, end: 3, personKey: nil)]).first)
        #expect(abs(flag.time - 5) < 0.0001)
        #expect(abs((flag.endTime ?? 0) - 6) < 0.0001)
    }

    @Test func lowConfidenceUsesTheBetterOfVoiceAndPicture() {
        let low = flags(turns: [Fixtures.speakerTurn(confidence: 0.3, pictureConfidence: 0.4)])
        #expect(low.map(\.kind) == [.lowConfidenceSpeaker])
        #expect(low.first?.severity == .info)
        let pictureSure = flags(turns: [Fixtures.speakerTurn(confidence: 0.3, pictureConfidence: 0.8)])
        #expect(pictureSure.isEmpty)
    }

    @Test func turnsOutsideTheClipOrOnAnotherVideoAreIgnored() {
        let result = flags(turns: [Fixtures.speakerTurn(start: 7, end: 9, personKey: nil),
                                   Fixtures.speakerTurn(videoID: 2, start: 3, end: 4, personKey: nil)])
        #expect(result.isEmpty)
    }

    @Test func widePoorFitSceneWithoutPathIsFlagged() throws {
        var scene = Fixtures.scene(wide: true)
        scene.tags.append("portrait-fit:poor")
        let clip = Fixtures.timelineClip(startTime: 3)
        let flag = try #require(flags(clips: [clip], scenes: [scene]).first)
        #expect(flag.kind == .noTrackingPath)
        #expect(flag.time == 3)

        scene.centerStagePathJSON = "[{\"t\":0}]"
        #expect(flags(clips: [clip], scenes: [scene]).isEmpty)
        var narrow = Fixtures.scene(wide: false)
        narrow.tags.append("portrait-fit:poor")
        #expect(flags(clips: [clip], scenes: [narrow]).isEmpty)
    }

    @Test func renderFallbackLandsAtItsClipStart() throws {
        let first = Fixtures.timelineClip(startTime: 0)
        let second = Fixtures.timelineClip(sourceStart: 8, startTime: 4)
        let byOrigin = flags(clips: [first, second], fallbacks: [
            RenderFramingFallback(clipOriginKey: second.originKey, startTime: 0, reason: "tracking lost the subject")])
        let flag = try #require(byOrigin.first)
        #expect(flag.kind == .framingFallback)
        #expect(flag.time == 4)
        #expect(flag.clipOriginKey == second.originKey)

        let byTime = flags(clips: [first, second], fallbacks: [
            RenderFramingFallback(clipOriginKey: "unknown", startTime: 5, reason: "")])
        #expect(byTime.first?.time == 4)
        #expect(byTime.first?.clipOriginKey == second.originKey)
    }

    @Test func fallbackInALaterSplitPieceLandsOnThatPiece() throws {
        // One clip split by a cleanup cut: both pieces keep its origin key.
        let head = Fixtures.timelineClip(sourceStart: 2, duration: 3, startTime: 0)
        var tail = Fixtures.timelineClip(sourceStart: 7, duration: 4, startTime: 3)
        tail.originKey = head.originKey
        let bySource = flags(clips: [head, tail], fallbacks: [
            RenderFramingFallback(clipOriginKey: head.originKey, startTime: 3, reason: "x",
                                  sourcePath: "/tmp/fixture.mp4", sourceStart: 7)])
        let flag = try #require(bySource.first)
        #expect(flag.time == 3)
        #expect(flag.endTime == 7)
        #expect(flag.clipOriginKey == head.originKey)

        // Without a source start the timeline time picks the piece.
        let byTime = flags(clips: [head, tail], fallbacks: [
            RenderFramingFallback(clipOriginKey: head.originKey, startTime: 4, reason: "x")])
        #expect(byTime.first?.time == 3)
    }

    @Test func fallbackFromACutReanchorsOnTheFullDocument() {
        let clip = Fixtures.timelineClip(sourceStart: 8, startTime: 12)
        let document = Fixtures.timelineDocument(clips: [Fixtures.timelineClip(), clip])
        let anchored = ReviewFlagBuilder.anchored([
            RenderFramingFallback(clipOriginKey: "cut-local", startTime: 0, reason: "x",
                                  sourcePath: "/tmp/fixture.mp4", sourceStart: 8)], in: document)
        #expect(anchored.first?.clipOriginKey == clip.originKey)
        #expect(anchored.first?.startTime == 12)
    }

    @Test func qualityFailureIsAWarningAtTimeZero() throws {
        let report = ReelQualityReport(score: 40, verdict: .blocked, checks: [],
                                       warnings: ["Weak hook"], failures: ["Rendered file is missing"])
        let result = flags(quality: report)
        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.kind == .qualityWarning && $0.time == 0 })
        let failure = try #require(result.first { $0.message == "Rendered file is missing" })
        #expect(failure.severity == .warning)
        #expect(result.first { $0.message == "Weak hook" }?.severity == .info)
        // Warnings sort first at the same time.
        #expect(result.first?.severity == .warning)
    }

    @Test func duplicatesCollapseById() {
        let report = ReelQualityReport(score: 60, verdict: .reviewRequired, checks: [],
                                       warnings: ["Weak hook", "Weak hook"], failures: [])
        let clip = Fixtures.timelineClip()
        let fallback = RenderFramingFallback(clipOriginKey: clip.originKey, startTime: 0, reason: "a")
        let result = flags(clips: [clip], quality: report, fallbacks: [fallback, fallback])
        #expect(result.count == 2)
        #expect(Set(result.map(\.id)).count == result.count)
    }

    @Test func adjacentTurnsOfOneSpeakerMerge() {
        let clip = Fixtures.timelineClip(sourceStart: 0, duration: 10)
        let result = flags(clips: [clip], turns: [
            Fixtures.speakerTurn(start: 1, end: 2, personKey: nil),
            Fixtures.speakerTurn(start: 2.5, end: 4, personKey: nil),
            Fixtures.speakerTurn(start: 4, end: 5, cluster: 1, personKey: nil)])
        #expect(result.count == 2)
        #expect(result.first?.endTime == 4)
    }

    @Test func flagsAreSortedByTime() {
        var scene = Fixtures.scene()
        scene.tags.append("portrait-fit:poor")
        let first = Fixtures.timelineClip(startTime: 0)
        let second = Fixtures.timelineClip(sourceStart: 2, startTime: 4)
        let report = ReelQualityReport(score: 70, verdict: .reviewRequired, checks: [], warnings: ["Late"], failures: [])
        let result = flags(clips: [second, first], scenes: [scene],
                           turns: [Fixtures.speakerTurn(start: 3, end: 4, personKey: nil)], quality: report)
        #expect(!result.isEmpty)
        #expect(result.map(\.time) == result.map(\.time).sorted())
        #expect(result.map(\.time) == [0, 0, 1, 4, 5])
    }

    @Test func jsonRoundTripsAndToleratesMissingFields() throws {
        let flag = ReviewFlag(id: "a", kind: .framingFallback, time: 2, endTime: 3,
                              clipOriginKey: "o", severity: .warning, message: "m")
        let json = try #require(ReviewFlagBuilder.encode([flag]))
        #expect(ReviewFlagBuilder.decode(json) == [flag])
        let partial = ReviewFlagBuilder.decode(#"[{"kind":"somethingNew","time":1.5}]"#)
        #expect(partial.count == 1)
        #expect(partial.first?.kind == .qualityWarning)
        #expect(partial.first?.time == 1.5)
        #expect(partial.first?.id.isEmpty == false)
        #expect(ReviewFlagBuilder.decode(nil).isEmpty)
        #expect(ReviewFlagBuilder.encode([]) == nil)
    }
}
