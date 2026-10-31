import Foundation
import Testing
@testable import Clip_Builder

@Suite("Builder framing request")
struct BuilderFramingRulesTests {
    private func clip() -> TimelineClip {
        var clip = TimelineClip()
        clip.wide = true
        clip.cropXFrac = 0.3
        clip.centerStage = true
        clip.sourceStart = 4
        clip.duration = 2
        return clip
    }

    @Test func staticPlanClearsWideAndSetsTheWindow() {
        var clip = clip()
        let window = FreeCropRect(xFrac: 0.1, yFrac: 0.2, wFrac: 0.5, hFrac: 0.6)
        BuilderFraming.apply(.static(window: window, fit: .blurredFill, feather: 0.1, blur: 0.4),
                             wide: true, cropXFrac: 0.3, storedPath: nil, sceneStart: 2, to: &clip)
        #expect(clip.wide == false)
        #expect(clip.cropXFrac == nil)
        #expect(clip.centerStage == false)
        #expect(clip.cameraPath == nil)
        #expect(clip.freeCrops?.first?.src == window)
        #expect(clip.framingPlan?.isStatic == true)
    }

    @Test func centerStagePlanSetsTheRegionAndSlicesTheStoredPath() {
        var clip = clip()
        var recipe = CropRecipe(kind: .talker)
        recipe.centerStage = true
        let keys = [CameraPathKeyframe(t: 0, x: 0, y: 0, w: 0.5, h: 1), CameraPathKeyframe(t: 8, x: 0.5, y: 0, w: 0.5, h: 1)]
        let stored = SceneCameraPath(camera: "conversation", keyframes: keys)
        BuilderFraming.apply(.tracked(recipe, region: nil, fit: .fill, feather: 0.08, blur: 0.5),
                             wide: true, cropXFrac: nil, storedPath: stored, sceneStart: 2, to: &clip)
        #expect(clip.centerStage)
        #expect(clip.areaRegion == FreeCropRect())
        #expect(clip.freeCrops == nil)
        #expect((clip.cameraPath?.count ?? 0) >= 2)
        #expect(clip.cameraPath?.first?.t == 0)
    }

    @Test func noPlanRestoresTheSceneCrop() {
        var clip = clip()
        clip.freeCrops = [FreeCrop(src: FreeCropRect(), dst: FreeCropRect())]
        BuilderFraming.apply(nil, wide: true, cropXFrac: nil, storedPath: nil, sceneStart: 0, to: &clip)
        #expect(clip.wide)
        #expect(clip.cropXFrac == 0.5)
        #expect(clip.freeCrops == nil)
        #expect(clip.framingPlan == nil)
    }

    @Test func draggedWindowFlowsBackIntoTheRequest() {
        var before = TimelineClip()
        before.framingRequest = Framing(subject: .original)
        before.framingPlan = .static(window: FreeCropRect(), fit: .fill, feather: 0.08, blur: 0.5)
        before.freeCrops = [FreeCrop(src: FreeCropRect(), dst: FreeCropRect())]
        var after = before
        let moved = FreeCropRect(xFrac: 0.2, yFrac: 0.1, wFrac: 0.4, hFrac: 0.7)
        after.freeCrops = [FreeCrop(src: moved, dst: moved)]
        BuilderFraming.mirrorFocusFrame(before: before, after: &after)
        #expect(after.framingRequest?.focusFrame == moved)
        #expect(after.framingPlan?.sourceWindow == moved)
        // Without a request nothing is mirrored.
        var plain = after
        plain.framingRequest = nil
        var plainMoved = plain
        plainMoved.freeCrops = [FreeCrop(src: FreeCropRect(), dst: FreeCropRect())]
        BuilderFraming.mirrorFocusFrame(before: plain, after: &plainMoved)
        #expect(plainMoved.framingRequest == nil)
    }
}

@MainActor
@Suite("Builder framing request on the model", .serialized)
struct BuilderFramingModelTests {
    @Test func setAndClearRoundTrip() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        model.load(profileName: "Framing")
        let scene = Fixtures.scene(start: 2, end: 10)
        model.updateScenes([scene])
        model.addScene(scene)
        let uid = try #require(model.document.videoTrack.first?.uid)

        var request = Framing(subject: .original)
        request.focusFrame = FreeCropRect(xFrac: 0.25, yFrac: 0, wFrac: 0.5, hFrac: 1)
        model.setFramingRequest(uid, request, type: .podcast)
        var clip = try #require(model.clip(uid))
        #expect(clip.framingRequest == request)
        #expect(clip.framingPlan?.isStatic == true)
        #expect(clip.wide == false)
        #expect(clip.freeCrops?.first?.src == FocusFrame.resolved(request.focusFrame!))

        model.setFramingRequest(uid, Framing(subject: .centerStage), type: .podcast)
        clip = try #require(model.clip(uid))
        #expect(clip.centerStage)
        #expect(clip.framingPlan?.recipe?.centerStage == true)
        #expect(clip.freeCrops == nil)

        model.clearFramingRequest(uid)
        clip = try #require(model.clip(uid))
        #expect(clip.framingRequest == nil)
        #expect(clip.framingPlan == nil)
        #expect(clip.centerStage == false)
        #expect(clip.wide == scene.wide)
    }

    @Test func requestSurvivesTheDocumentRoundTrip() throws {
        var clip = TimelineClip()
        clip.framingRequest = Framing(subject: .speakerFocus, pullBack: 0.4)
        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(TimelineClip.self, from: data)
        #expect(decoded.framingRequest == clip.framingRequest)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"framing_request\""))
    }
}
