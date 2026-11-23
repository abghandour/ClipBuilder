import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

@Suite("Staying figure review regressions")
struct TelestrationReviewFixTests {
    private func document() -> TimelineDocument {
        var hold = Fixtures.timelineClip(sceneID: nil, sourceStart: 1, duration: 1)
        hold.startTime = 0
        hold.hold = true
        hold.wide = true
        hold.telestration = Telestration(figures: [.init(linger: 1)])
        var tail = hold
        tail.uid = UUID()
        tail.startTime = 1
        tail.hold = nil
        tail.telestration = nil
        return Fixtures.timelineDocument(clips: [hold, tail])
    }

    @Test func freeCropScaleAgreement() throws {
        var hold = try #require(MultitrackRenderer.resolveClips(document: document(), scenes: []).first)
        for (width, supported) in [(0.5, true), (0.504, true), (0.52, false)] {
            hold.freeCrops = [.init(src: .init(wFrac: width), dst: .init())]
            let frame = TelestrationScreenStay.frame(for: hold,
                source: CGSize(width: 1600, height: 800), canvas: CGSize(width: 800, height: 800))
            #expect((frame != nil) == supported)
        }
    }

    @Test func visibleHoldWinsEvenWithoutStay() throws {
        var doc = document()
        var top = doc.videoTrack[0]
        top.uid = UUID()
        top.originKey = "z"
        doc.videoTrack[0].originKey = "a"
        // Document order deliberately disagrees with persisted identity.
        doc.videoTrack.insert(top, at: 0)
        var tail = try #require(MultitrackRenderer.resolveClips(document: doc, scenes: []).last)
        #expect(tail.lingeringHold?.first?.originKey == "z")
        doc.videoTrack[0].telestration = nil
        tail = try #require(MultitrackRenderer.resolveClips(document: doc, scenes: []).last)
        #expect(tail.lingering == nil)
    }

    @Test func landscapePreviewKeepsScenePath() throws {
        var doc = document()
        doc.renderSettings = RenderSettings(preset: .custom, customWidth: 640, customHeight: 360)
        for i in doc.videoTrack.indices {
            doc.videoTrack[i].sceneID = 1
            doc.videoTrack[i].centerStage = true
        }
        var scene = Fixtures.scene(start: 0, end: 6)
        scene.videoWidth = 1280
        scene.videoHeight = 720
        let path = SceneCameraPath(camera: "balanced", keyframes: [
            .init(t: 0, x: 0.1, y: 0.1, w: 0.5, h: 0.5),
            .init(t: 6, x: 0.3, y: 0.2, w: 0.5, h: 0.5)])
        scene.centerStagePathJSON = String(decoding: try JSONEncoder().encode(path), as: UTF8.self)
        let preview = MultitrackRenderer.windowed(doc, scenes: [scene], from: 1.1, to: 1.8)
        let hold = try #require(preview.lingerHolds.values.first)
        #expect(hold.cameraPath?.count == 2)
        let exported = RenderContext.$settings.withValue(doc.renderSettings) {
            MultitrackRenderer.resolveClips(document: doc, scenes: [scene])
        }
        #expect(hold.cameraPath == exported.first?.cameraPath)
    }

    @Test func noStayKeyOmitsAllStayFields() throws {
        var doc = document()
        doc.videoTrack[0].telestration = nil
        let clips = MultitrackRenderer.resolveClips(document: doc, scenes: [])
        let key = RenderSegmentKey(start: 0, duration: 2, clips: clips,
            captions: [], overlays: [], masks: [:], fontFingerprints: [],
            captionStyle: CaptionStyle(), settings: doc.renderSettings, encoder: [],
            lingering: TelestrationLingerResolution.cacheEvidence(clips),
            screenStays: TelestrationLingerResolution.screenEvidence(clips))
        let json = String(decoding: try JSONEncoder().encode(key), as: UTF8.self)
        for field in ["lingering", "screenStays", "screenStay", "lingeringHold", "stayHoldID", "stayTransitions", "fixedStayFlash"] {
            #expect(!json.contains("\"\(field)\""))
        }
    }
}
