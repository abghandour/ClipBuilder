import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Builder bumpers", .serialized)
struct BumperBuilderTests {
    @Test("insert at playhead ripples all lanes, moves freely, and enforces framing")
    func insertionAndMovement() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        model.loadDocument(Fixtures.timelineDocument(clips: [Fixtures.timelineClip(duration: 10)]))
        model.playhead = 4
        model.addBumper(BumperAsset(path: "/bumper.mp4", displayName: "CTA", duration: 2))
        let clip = try #require(model.document.videoTrack.first(where: { $0.bumper }))
        #expect(clip.track == 0 && clip.startTime == 4 && clip.duration == 2)
        #expect(model.document.videoTrack.filter { !$0.bumper }.map(\.startTime).sorted() == [0, 6])
        model.placeClip(clip.uid, startTime: 1, track: 0)
        #expect(model.clip(clip.uid)?.startTime == 1)
        model.updateClip(clip.uid) {
            $0.wide = true
            $0.centerStage = true
            $0.captions = "top"
            $0.cropXFrac = 0.2
        }
        let edited = try #require(model.clip(clip.uid))
        #expect(!edited.wide && !edited.centerStage && edited.captions == "none" && edited.cropXFrac == nil)
    }

    @Test("fast preview chooses bumper above other tracks and maps speed")
    func fastPreview() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        var bumper = try #require(BumperAsset(path: "/bumper.mp4", displayName: "CTA", duration: 2).clip(at: 4))
        bumper.speed = 0.5
        bumper.duration = 4
        model.loadDocument(Fixtures.timelineDocument(clips: [bumper,
            Fixtures.timelineClip(duration: 10, track: 1)]))
        let plan = model.previewPlan()
        let middle = try #require(plan.segments.first(where: { $0.bumper }))
        #expect(middle.url.path == "/bumper.mp4" && middle.timelineStart == 4)
        #expect(middle.duration == 4 && middle.speed == 0.5 && middle.sourceStart == 0)
    }
}
