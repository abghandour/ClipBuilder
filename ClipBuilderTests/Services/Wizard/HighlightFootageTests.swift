import Foundation
import Testing
@testable import Clip_Builder

@Suite("Highlight footage")
struct HighlightFootageTests {
    private func scene(_ id: Int64, video: Int64 = 1, start: Double, end: Double) -> SceneRecord {
        var scene = Fixtures.scene(id: id, start: start, end: end)
        scene.videoID = video
        return scene
    }

    private func video(_ id: Int64, hash: String) -> VideoRecord {
        var video = Fixtures.video(id: id)
        video.hash = hash
        return video
    }

    @Test func snapshotRecordsEveryReferencedSceneByHashAndRange() {
        var clip = Fixtures.planClip(sceneID: 1, start: 2, end: 6)
        clip.areaClips = [WizardPlanAreaClip(area: "top", sceneID: 2, start: 11, end: 14)]
        clip.brollCuts = [BRollCut(start: 3, end: 4, sceneID: 3, sceneOffset: 0, reason: "", origin: .user)]
        let plan = Fixtures.plan(clips: [clip])
        let refs = HighlightFootage.snapshot(plan: plan,
            scenes: [scene(1, start: 0, end: 8), scene(2, start: 10, end: 18), scene(3, video: 2, start: 0, end: 5)],
            videos: [video(1, hash: "A"), video(2, hash: "B")])
        #expect(refs == [HighlightFootageRef(sceneID: 1, videoHash: "A", start: 0, end: 8),
                         HighlightFootageRef(sceneID: 2, videoHash: "A", start: 10, end: 18),
                         HighlightFootageRef(sceneID: 3, videoHash: "B", start: 0, end: 5)])
        #expect(HighlightFootage.videoHashes(refs) == ["A", "B"])
        // A scene whose video is unknown is left out.
        #expect(HighlightFootage.snapshot(plan: plan, scenes: [scene(1, start: 0, end: 8)], videos: []).isEmpty)
    }

    @Test func resolveMatchesByHashThenRangeWithinTolerance() {
        // The teammate's ids (1, 2) differ from this Mac's (40, 41) and its video id.
        let refs = [HighlightFootageRef(sceneID: 1, videoHash: "A", start: 0, end: 8),
                    HighlightFootageRef(sceneID: 2, videoHash: "A", start: 10, end: 18)]
        let local = [video(7, hash: "A")]
        let scenes = [scene(40, video: 7, start: 0, end: 8.04), scene(41, video: 7, start: 10.06, end: 18),
                      scene(42, video: 9, start: 10, end: 18)]
        let resolved = HighlightFootage.resolve(refs: refs, localVideos: local, scenes: scenes)
        // Within tolerance and containing the whole recorded range: reused.
        #expect(resolved[1] == HighlightFootage.ResolvedScene(videoID: 7, start: 0, end: 8.04, sceneID: 40))
        // 0.06 s off is outside the tolerance and another video's scene never counts: create one.
        #expect(resolved[2] == HighlightFootage.ResolvedScene(videoID: 7, start: 10, end: 18, sceneID: nil))
    }

    /// A scene inside the tolerance that does not contain the recorded range
    /// (0.04…7.97 for 0…8) would make `resolvedPlan` reject a clip at the
    /// recorded edges, so the exact recorded range is created instead and the
    /// clip's source times still fit it.
    @Test func resolveNeverReusesASceneThatCutsTheRecordedRange() throws {
        let ref = HighlightFootageRef(sceneID: 1, videoHash: "A", start: 0, end: 8)
        let local = [video(7, hash: "A")]
        let short = [scene(40, video: 7, start: 0.04, end: 7.97), scene(41, video: 7, start: 0, end: 7.98),
                     scene(42, video: 7, start: 0.03, end: 8)]
        let resolved = try #require(HighlightFootage.resolve(ref, localVideos: local, scenes: short))
        #expect(resolved == HighlightFootage.ResolvedScene(videoID: 7, start: 0, end: 8, sceneID: nil))
        // Edges within the 0.001 containment tolerance still count.
        let close = [scene(43, video: 7, start: 0.0005, end: 7.9995)]
        #expect(HighlightFootage.resolve(ref, localVideos: local, scenes: close)?.sceneID == 43)

        // The created range holds a clip at the recorded edges; the cut one would not.
        var clip = Fixtures.planClip(sceneID: 40, start: 0, end: 8)
        clip.brollCuts = [BRollCut(start: 2, end: 3, sceneID: 40, sceneOffset: 0, reason: "", origin: .user)]
        let plan = Fixtures.plan(clips: [clip])
        #expect(WizardSelectionRules.resolvedPlan(plan, scenes: [scene(40, video: 7, start: 0.04, end: 7.97)]) == nil)
        let created = scene(50, video: 7, start: resolved.start, end: resolved.end)
        let remapped = try #require(HighlightFootage.remap(plan, sceneIDs: [40: 50]))
        let kept = try #require(WizardSelectionRules.resolvedPlan(remapped, scenes: [created]))
        #expect(kept.clips.first?.start == 0 && kept.clips.first?.end == 8)
        #expect(kept.clips.first?.brollCuts?.first?.start == 2)
    }

    @Test func resolvePrefersTheClosestScene() {
        let ref = HighlightFootageRef(sceneID: 1, videoHash: "A", start: 0, end: 8)
        let scenes = [scene(5, start: 0.03, end: 8), scene(6, start: 0, end: 8.01)]
        #expect(HighlightFootage.resolve(ref, localVideos: [video(1, hash: "A")], scenes: scenes)?.sceneID == 6)
    }

    @Test func missingVideoIsReportedAndNotResolved() {
        let refs = [HighlightFootageRef(sceneID: 1, videoHash: "A", start: 0, end: 8),
                    HighlightFootageRef(sceneID: 2, videoHash: "Z", start: 0, end: 8)]
        let local = [video(1, hash: "A")]
        #expect(HighlightFootage.missingVideoHashes(refs, localVideos: local) == ["Z"])
        let resolved = HighlightFootage.resolve(refs: refs, localVideos: local, scenes: [])
        #expect(resolved[1]?.sceneID == nil && resolved[1]?.videoID == 1)
        #expect(resolved[2] == nil)
    }

    @Test func remapReplacesEverySceneIDAndDropsLocalPicks() throws {
        var clip = Fixtures.planClip(sceneID: 1)
        clip.areaClips = [WizardPlanAreaClip(area: "top", sceneID: 2, start: 2, end: 4)]
        clip.brollCuts = [BRollCut(start: 3, end: 4, sceneID: 3, sceneOffset: 0, reason: "", origin: .user)]
        clip.miniPickID = 12
        var plan = Fixtures.plan(clips: [clip])
        plan.footage = [WizardFootageReference(sceneID: 1)]
        let remapped = try #require(HighlightFootage.remap(plan, sceneIDs: [1: 10, 2: 20, 3: 30]))
        #expect(remapped.clips[0].sceneID == 10 && remapped.clips[0].areaClips[0].sceneID == 20)
        #expect(remapped.clips[0].brollCuts?.first?.sceneID == 30)
        #expect(remapped.clips[0].miniPickID == nil && remapped.footage == nil)
        #expect(HighlightFootage.remap(plan, sceneIDs: [1: 10, 2: 20]) == nil, "an unmapped B-roll scene fails")
    }

    @Test func planFromPlanClipsJSON() throws {
        let json = #"[{"clip_index":0,"scene_id":5,"start":1.5,"end":4,"speed":0.5,"reason":"why"}]"#
        let plan = try #require(HighlightFootage.plan(fromPlanClipsJSON: json, rationale: "r", targetDuration: 6))
        #expect(plan.clips.count == 1 && plan.clips[0].sceneID == 5 && plan.clips[0].speed == 0.5)
        #expect(plan.clips[0].reason == "why" && plan.rationale == "r")
        #expect(HighlightFootage.plan(fromPlanClipsJSON: nil, rationale: nil, targetDuration: 0) == nil)
    }
}
