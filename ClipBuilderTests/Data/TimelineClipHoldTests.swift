import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Timeline hold clips")
struct TimelineClipHoldTests {
    private func hold(sceneID: Int64? = nil) -> TimelineClip {
        var clip = Fixtures.timelineClip(sceneID: sceneID, sourceStart: 3, duration: 0.8)
        clip.hold = true
        clip.sourceEnd = clip.sourceStart
        clip.speed = nil
        return clip
    }

    @Test("A hold round trips its frame and explicit screen duration", arguments: [false, true])
    func roundTrip(sceneOnly: Bool) throws {
        var clip = hold(sceneID: sceneOnly ? 42 : nil)
        if sceneOnly { clip.videoFile = nil }
        let data = try JSONEncoder().encode(clip)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["hold"] as? Bool == true)
        #expect(object["duration"] as? Double == 0.8)
        let restored = try JSONDecoder().decode(TimelineClip.self, from: data)
        #expect(restored.hold == true)
        #expect(restored.duration == 0.8)
        #expect(restored.sourceStart == 3 && restored.sourceEnd == 3)
        #expect(restored.speed == nil && restored.sourceSpan == 0)
        var ordinary = clip
        ordinary.hold = nil
        #expect(ordinary != clip)
    }

    @Test("Ordinary clips omit hold; older documents decode it as nil")
    func ordinary() throws {
        var clip = Fixtures.timelineClip(sceneID: nil, duration: 2)
        for flag in [nil, false] as [Bool?] {
            clip.hold = flag
            let data = try JSONEncoder().encode(clip)
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["hold"] == nil)
            #expect(try JSONDecoder().decode(TimelineClip.self, from: data).hold == nil)
        }
        let old = Data(#"{"start":2,"end":4}"#.utf8)
        let restored = try JSONDecoder().decode(TimelineClip.self, from: old)
        #expect(restored.hold == nil && restored.duration == 2)
        let missingDuration = Data(#"{"hold":true,"start":2,"end":4,"speed":2}"#.utf8)
        let frozen = try JSONDecoder().decode(TimelineClip.self, from: missingDuration)
        #expect(frozen.duration == 0 && frozen.sourceEnd == 2 && frozen.speed == nil)
    }

    @Test("Trimming, windowing, source mapping and crop boundaries keep the held frame")
    func editAndSlice() throws {
        let clip = hold()
        let model = ScriptFixtures.model(clips: [clip])
        try model.trimClip(clip.uid, duration: 20).get()
        #expect(model.clip(clip.uid)?.duration == 5)
        try model.trimClip(clip.uid, duration: 0.01, precision: .speech).get()
        #expect(model.clip(clip.uid)?.duration == 0.05)
        try model.trimClip(clip.uid, duration: 0.01).get()
        #expect(model.clip(clip.uid)?.duration == 0.5)
        let edited = try #require(model.clip(clip.uid))
        #expect(edited.sourceStart == 3 && edited.sourceEnd == 3)
        #expect(model.sourceTime(for: edited, atTimeline: 0.4) == 3)
        #expect(TimelineSplit.pieces(clip, at: 0.4, minimum: 0.05) == nil)
        if case .failure(.outOfBounds) = model.splitClip(clip.uid, at: 0.25, precision: .speech) {} else {
            Issue.record("A hold must refuse splitting")
        }
        let steps = ScriptRunner().run([.init(.setClipSpeed(clip: clip.uid.uuidString, speed: 1))],
                                      model: model, library: ScriptFixtures.library())
        if case .refused? = steps.first {} else { Issue.record("A hold must refuse even a 1× speed command") }

        var document = Fixtures.timelineDocument(clips: [clip])
        let window = MultitrackRenderer.windowed(document, from: 0.2, to: 0.6)
        let sliced = try #require(window.videoTrack.first)
        #expect(sliced.sourceStart == 3 && sliced.sourceEnd == 3)
        #expect(abs(sliced.duration - 0.4) < 1e-9)
        document.cropBlocks = [CropBlockItem(layout: .fullScreen, startTime: 0, duration: 0.4),
                               CropBlockItem(layout: .fullScreen, startTime: 0.4, duration: 0.4)]
        let resolved = MultitrackRenderer.resolveClips(document: document, scenes: [])
        #expect(resolved.count == 2)
        #expect(resolved.allSatisfy { $0.hold && $0.sourceStart == 3 && $0.sourceSpan == 0
            && $0.speed == 1 && $0.muted && $0.captionsPosition == nil })
        if let first = resolved.first {
            var moving = first
            moving.hold = false
            #expect(try RenderSegmentCache.key(first) != RenderSegmentCache.key(moving))
        }
    }

    @Test("A zero-duration strike window samples exactly the held picture")
    func highlightPicture() {
        let highlight = StrikeHighlightRules.Highlight(
            limb: [CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.4, y: 0.5)],
            target: CGPoint(x: 0.6, y: 0.5), radius: 0.1, cost: 0.1,
            limbSide: .left, usesArm: true, attackerOnLeft: true)
        let track = StrikeHighlightRules.Track(keyframes: [.init(time: 1, highlight: highlight),
                                                           .init(time: 2, highlight: highlight)],
                                               contact: 1.5, aspect: 16.0 / 9)
        #expect(StrikeHighlightBurn.tracks([track], start: 1.5, duration: 0).count == 1)
        #expect(StrikeHighlightBurn.frameTimes(track, start: 1.5, duration: 0) == [1.5])
        #expect(StrikeHighlightBurn.frameTimes(track, start: 3, duration: 0).isEmpty)
    }

    @Test("A frozen camera path samples one position and lasts for the screen duration")
    func cameraPath() {
        let path = [CameraPathKeyframe(t: 0, x: 0, y: 0, w: 0.3, h: 1),
                    CameraPathKeyframe(t: 2, x: 0.6, y: 0, w: 0.3, h: 1)]
        let frozen = HoldClipRules.cameraPath(path, at: 1, duration: 0.8)
        #expect(frozen.count == 2)
        #expect(frozen.first?.x == 0.3 && frozen.last?.x == 0.3)
        #expect(frozen.first?.t == 0 && frozen.last?.t == 0.8)
        #expect(HoldClipRules.duration(0.8, precision: .ordinary) == 0.8)
    }
}
