import Foundation
import Testing
@testable import Clip_Builder

struct MiniBRollTimelineTests {
    @Test func exactWordTimeIsFullFrameMutedWithPodcastAudioUnderneath() throws {
        var source = Fixtures.scene(id: 1, start: 100, end: 120)
        source.tags = ["podcast"]
        let scene = Fixtures.scene(id: 2, start: 50, end: 60)
        var clip = Fixtures.planClip(sceneID: 1, start: 100, end: 120)
        clip.brollCuts = [.init(start: 101.25, end: 104.75, sceneID: 2, sceneOffset: 1.5, reason: "word", origin: .user)]
        let plan = Fixtures.plan(clips: [clip])
        let original = WizardEngine.timelineDocument(from: plan, sceneMap: [1: source])
        let rendered = MiniBRollTimeline.adding(to: original, clip: clip, scenes: [scene], enabled: true)
        let cut = try #require(rendered.videoTrack.first { $0.isCutaway })
        #expect(cut.startTime == 1.25 && cut.duration == 3.5)
        #expect(cut.sourceStart == 51.5 && cut.sourceEnd == 55)
        #expect(cut.coverAllAreas && cut.muted && cut.cutawayAudio == .muted)
        #expect(cut.screenCrop == nil && cut.captions == "none" && cut.precision == .speech)
        #expect(rendered.videoTrack.filter { !$0.isCutaway } == original.videoTrack)
        #expect(rendered.textOverlays == original.textOverlays)
        #expect(SceneReferences.ids(in: plan) == [1, 2])
        let shifted = BRollCutMapping.timelineClips(clip.brollCuts ?? [], sourceRange: 100...120,
            scenes: [scene], reelStart: 9)
        #expect(shifted.first?.startTime == 10.25)
    }

    @Test func disabledOrEmptyManualCutsNeverAddAutomaticFill() {
        var clip = Fixtures.planClip(start: 100, end: 120)
        clip.brollCuts = [.init(start: 101, end: 104, sceneID: 2, sceneOffset: 0, reason: "word", origin: .user)]
        let source = Fixtures.scene(start: 100, end: 120)
        let document = WizardEngine.timelineDocument(from: Fixtures.plan(clips: [clip]), sceneMap: [1: source])
        let scene = Fixtures.scene(id: 2, start: 50, end: 60)
        #expect(MiniBRollTimeline.adding(to: document, clip: clip, scenes: [scene], enabled: false).videoTrack == document.videoTrack)
        clip.brollCuts = []
        #expect(MiniBRollTimeline.adding(to: document, clip: clip, scenes: [scene], enabled: true).videoTrack == document.videoTrack)
        clip.brollCuts = nil
        #expect(MiniBRollTimeline.adding(to: document, clip: clip, scenes: [scene], enabled: true).videoTrack == document.videoTrack)
    }

    @Test func multiplePiecesRetainWordTimesUnderSplitLayoutsAndBumpers() throws {
        let scene = Fixtures.scene(id: 2, start: 50, end: 60)
        var first = Fixtures.planClip(sceneID: 1, start: 100, end: 110)
        var second = Fixtures.planClip(sceneID: 1, start: 200, end: 210)
        first.brollCuts = [.init(start: 101, end: 104, sceneID: 2, sceneOffset: 0, reason: "first", origin: .user)]
        second.brollCuts = [.init(start: 202, end: 205, sceneID: 2, sceneOffset: 0, reason: "second", origin: .user)]
        var split = TimelineDocument()
        split.videoTrack = [Fixtures.timelineClip(sourceStart: 100, duration: 10)]
        var other = split.videoTrack[0]
        other.track = 1
        other.muted = true
        split.videoTrack.append(other)
        let result = MiniBRollTimeline.adding(to: split, clip: first, scenes: [scene], enabled: true)
        #expect(result.videoTrack.last?.coverAllAreas == true)
        #expect(result.videoTrack.prefix(2).allSatisfy { !$0.isCutaway })
        let next = BRollCutMapping.timelineClips(second.brollCuts ?? [], sourceRange: 200...210, scenes: [scene], reelStart: 13)
        #expect(next.first?.startTime == 15) // 3-second bumper + 10-second kept piece + word at +2.
    }
}
