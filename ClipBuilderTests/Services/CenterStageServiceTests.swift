import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

struct CenterStageServiceTests {
    @Test func conversationFourHzMatchesTenHz() async throws {
        let service = CenterStageService()
        var tenHz = CenterStageService.Tuning.conversation
        tenHz.analysisInterval = 0.1
        let fourHz = CenterStageService.Tuning.conversation
        #expect(fourHz.analysisInterval == 0.25 && fourHz.keyframeInterval == 0.3)
        func fixture(interval: Double) -> [FeedPathSample] {
            stride(from: 0.0, through: 12, by: interval).map { time in
                FeedPathSample(time: time, faces: [CGRect(x: 0.42 + 0.08 * sin(time / 4),
                    y: 0.2, width: 0.12, height: 0.2)], expression: nil)
            }
        }
        let a = await service.pathForDetectionFixture(fixture(interval: fourHz.analysisInterval),
            size: CGSize(width: 1280, height: 720), duration: 12, tuning: fourHz, aspect: 9.0 / 16)
        let b = await service.pathForDetectionFixture(fixture(interval: tenHz.analysisInterval),
            size: CGSize(width: 1280, height: 720), duration: 12, tuning: tenHz, aspect: 9.0 / 16)
        #expect(a.count >= 2 && b.count >= 2)
        #expect(a.contains { abs($0.t - 0.3) < 1e-9 })
        for time in Set((a + b).map(\.t)) {
            let left = try #require(CenterStageService.interpolated(a, at: time))
            let right = try #require(CenterStageService.interpolated(b, at: time))
            #expect(abs(left.x - right.x) < 0.02)
            #expect(abs(left.x + left.w - right.x - right.w) < 0.02)
        }
    }

    @Test func conversationCadenceIsExplicitRatherThanSmoothingMagicNumber() async throws {
        var tuning = CenterStageService.Tuning.conversation
        tuning.smoothing = 0.2
        #expect(tuning.timeBasedSmoothing)
        var balanced = CenterStageService.Tuning.balanced
        balanced.smoothing = 0.12
        #expect(!balanced.timeBasedSmoothing)
        let samples = stride(from: 0.0, through: 2, by: 0.25).map {
            FeedPathSample(time: $0, faces: [CGRect(x: 0.4, y: 0.2, width: 0.1, height: 0.15)], expression: nil)
        }
        let path = await CenterStageService().pathForDetectionFixture(samples,
            size: CGSize(width: 1280, height: 720), duration: 2, tuning: tuning, aspect: 9.0 / 16)
        #expect(path.contains { abs($0.t - 0.3) < 1e-9 })
    }

    @Test func fullFrameTrackingSelectsEachCellsFocusedFace() async throws {
        let samples = stride(from: 0.0, through: 2, by: 0.25).map {
            FeedPathSample(time: $0, faces: [CGRect(x: 0.15, y: 0.2, width: 0.1, height: 0.15),
                                           CGRect(x: 0.75, y: 0.2, width: 0.1, height: 0.15)], expression: nil)
        }
        let service = CenterStageService()
        let left = await service.pathForDetectionFixture(samples, size: CGSize(width: 1280, height: 720),
            duration: 2, tuning: .conversation, aspect: 1.125, focus: AreaFocus(x: 0.2, y: 0.3))
        let right = await service.pathForDetectionFixture(samples, size: CGSize(width: 1280, height: 720),
            duration: 2, tuning: .conversation, aspect: 1.125, focus: AreaFocus(x: 0.8, y: 0.3))
        #expect(!left.isEmpty && left.count == right.count)
        for (a, b) in zip(left, right) { #expect(a.x + 0.1 < b.x) }
    }

    @Test func slicingAtEqualTimeCutKeepsTheNewCrop() throws {
        let path = [CameraPathKeyframe(t: 0, x: 0.1, y: 0, w: 0.3, h: 1),
                    CameraPathKeyframe(t: 0, x: 0.5, y: 0.1, w: 0.24, h: 0.8),
                    CameraPathKeyframe(t: 5, x: 0.5, y: 0.1, w: 0.24, h: 0.8)]
        let sliced = CenterStageService.slice(path, from: 0, duration: 2)
        #expect(sliced.count == 2)
        let start = try #require(sliced.first)
        #expect(start.x == 0.5 && start.w == 0.24 && start.h == 0.8)
        #expect(CenterStageService.interpolated(sliced, at: 1)?.x == 0.5)
    }

    @Test func savedPathChecksEveryKeyframeAgainstTargetAspect() {
        let portrait = CameraPathKeyframe(t: 0, x: 0.2, y: 0, w: 0.31640625, h: 1)
        var end = portrait; end.t = 2
        #expect(CenterStageService.pathMatchesCanvas([portrait, end], canvasAspect: 9.0 / 16))
        #expect(!CenterStageService.pathMatchesCanvas([portrait, end], canvasAspect: 4.0 / 5))
        end.w = 0.45
        #expect(!CenterStageService.pathMatchesCanvas([portrait, end], canvasAspect: 9.0 / 16))
    }

    @Test func savedFeedPathRequiresMatchingCameraAndFullFrame() throws {
        var scene = Fixtures.scene(start: 0, end: 3)
        let saved = SceneCameraPath(camera: "smooth", keyframes: [
            .init(t: 0, x: 0.2, y: 0, w: 0.31640625, h: 1),
            .init(t: 3, x: 0.3, y: 0, w: 0.31640625, h: 1)])
        scene.centerStagePathJSON = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
        var clip = Fixtures.timelineClip(sourceStart: 0, duration: 3)
        clip.wide = true; clip.centerStage = true
        clip.areaRegion = FreeCropRect(xFrac: 0, yFrac: 0, wFrac: 0.5, hFrac: 1)
        func resolved(_ camera: String) -> MultitrackRenderer.ResolvedClip? {
            MultitrackRenderer.resolveClips(document: Fixtures.timelineDocument(clips: [clip]),
                scenes: [scene], centerStageCamera: camera).first
        }
        #expect(resolved("smooth")?.cameraPath == nil)
        clip.areaRegion = FreeCropRect(xFrac: 0, yFrac: 0, wFrac: 1, hFrac: 1)
        #expect(resolved("balanced")?.cameraPath == nil)
        #expect(resolved("smooth")?.cameraPath == saved.keyframes)
        clip.areaFocus = AreaFocus(x: 0.8, y: 0.4)
        #expect(resolved("smooth")?.cameraPath == nil)
    }

    @Test func desiredBodyCropKeepsEdgeFaceAfterGuard() {
        let size = CGSize(width: 1920, height: 1080)
        let face = CGRect(x: 0.9, y: 0.2, width: 0.09, height: 0.2)
        let body = CenterStageService.bodyEstimate(fromFace: face)
        let crop = CenterStageService.desiredCrop(forUnion: body, size: size, tuning: .conversation)
        let pixels = CGRect(x: face.minX * size.width, y: face.minY * size.height,
                            width: face.width * size.width, height: face.height * size.height)
        let guarded = FaceGuard.contain(crop, faces: [pixels], bounds: CGRect(origin: .zero, size: size))
        #expect(guarded.contains(pixels))
        #expect(CGRect(origin: .zero, size: size).contains(guarded))
    }

    @Test func plannerUsesPortraitHeadroomForWideCells() {
        let face = CGRect(x: 0.4, y: 0.3, width: 0.1, height: 0.15)
        let crop = CropRecipePlanner.crop(tile: PodcastTile(index: 0, x: 0, y: 0, w: 1, h: 1),
            aspect: 2, sourceAspect: 1, center: (face.midX, face.midY), face: face)
        #expect(abs(crop.yFrac - (face.minY - crop.hFrac * FaceGuard.headroom)) < 0.001)
    }
}
