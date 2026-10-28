import Foundation
import Testing
@testable import Clip_Builder

@Suite("Layout role filler")
struct LayoutRoleFillerTests {
    private func context(vip: Bool = true) -> FramingContext {
        var video = Fixtures.video()
        video.duration = 24
        video.videoType = VideoType.podcast.rawValue
        var context = FramingContext(video: video, range: 2...22, canvasAspect: 9.0 / 16,
            roster: [
                .init(videoID: video.id, personID: 1, key: "a", name: "A", descriptor: "", portraitAt: 0,
                    portraitBox: .init(x: 0.1, y: 0.2, w: 0.1, h: 0.2), vip: vip),
                .init(videoID: video.id, personID: 2, key: "b", name: "B", descriptor: "", portraitAt: 0,
                    portraitBox: .init(x: 0.7, y: 0.2, w: 0.1, h: 0.2))],
            turns: [
                .init(videoID: video.id, start: 2, end: 7, cluster: 0, confidence: 1, personKey: "a", tile: 0),
                .init(videoID: video.id, start: 7, end: 12, cluster: 1, confidence: 1, personKey: "b", tile: 1),
                .init(videoID: video.id, start: 15, end: 22, cluster: 0, confidence: 1, personKey: "a", tile: 0)],
            layouts: ScreenCropStore.builtIn)
        context.feeds = [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1, personKey: "a"),
                         PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1, personKey: "b")]
        return context
    }

    private func layout(_ name: String) throws -> ScreenCropLayout {
        try #require(ScreenCropStore.builtIn.first { $0.name == name })
    }

    @Test func vipOthersAndBRollUseTheirOwnSourceClocks() throws {
        var context = context()
        var scene = Fixtures.scene()
        scene.id = 99
        scene.videoPath = "/tmp/broll.mp4"
        context.scenes = [scene]
        context.brollCuts = [.init(source: .scene(99), sourceStart: 30, start: 6, duration: 4, reason: "Example")]
        let result = LayoutRoleFiller.resolve(layout: try layout("Three stack"), context: context)
        #expect(result.areas.filter { $0.role == .vip }.allSatisfy { $0.region?.xFrac == 0 })
        #expect(result.areas.filter { $0.role == .others }.allSatisfy { $0.region?.xFrac == 0.5 })
        let broll = try #require(result.areas.first { $0.role == .broll && $0.sourcePath == scene.videoURL.path })
        #expect(broll.start == 30 && broll.duration == 4 && broll.timelineStart == 6)
        #expect(result.areas.allSatisfy { $0.audio == .program })
        #expect(result.areas.filter { $0.role != .broll }.allSatisfy { $0.duration >= FramingHolds.recipeHold })
    }

    @Test func noVIPUsesCurrentAndPreviousAndHoldsBetweenTurns() throws {
        let result = LayoutRoleFiller.resolve(layout: try layout("Split"), context: context(vip: false))
        #expect(result.notes.contains { $0.contains("No VIP") })
        #expect(result.areas.first { $0.role == .vip }?.region?.xFrac == 0)
        #expect(result.areas.first { $0.role == .others }?.region?.xFrac == 0.5)
        let middle = try #require(result.areas.first { $0.role == .vip && $0.timelineStart == 5 })
        #expect(middle.region?.xFrac == 0.5 && middle.duration == 8)
    }

    @Test func singlePersonSilenceAndMissingBRollHaveVisibleFallbacks() throws {
        var context = context(vip: false)
        context.feeds = [context.feeds[0]]
        context.roster = [context.roster[0]]
        context.turns = [context.turns[0]]
        context.turns[0].start = 5
        let result = LayoutRoleFiller.resolve(layout: try layout("Three stack"), context: context)
        #expect(result.areas.count == 3)
        #expect(result.areas.allSatisfy { $0.region?.xFrac == 0 && $0.timelineStart == 0 })
        for note in ["Only one person", "Silence", "No B-roll"] {
            #expect(result.notes.contains { $0.contains(note) })
        }
    }

    @Test func duplicateRolesChooseNextCandidateAndVIPRotationKeepsItsHolds() throws {
        var context = context()
        context.roster[1].vip = true
        var layout = try layout("Split")
        layout.areas[1].role = .vip
        let result = LayoutRoleFiller.resolve(layout: layout, context: context)
        let first = result.areas.first { $0.areaID == layout.areas[0].id }
        let second = result.areas.first { $0.areaID == layout.areas[1].id }
        #expect(first?.region != second?.region)
        #expect(result.areas.allSatisfy { $0.duration >= FramingHolds.vipHold })
        #expect(result.notes.contains { $0.contains("Repeated roles") })
    }

    @Test func explicitSourcesAndMissingPresenter() throws {
        var context = context()
        context.sourceRoles = ["screen": "/tmp/screen.mov"]
        let result = LayoutRoleFiller.resolve(layout: try layout("Screen + presenter"), context: context)
        #expect(result.areas[0].sourcePath == "/tmp/screen.mov")
        #expect(result.areas[1].sourcePath == context.sourcePath)
        #expect(result.notes.contains { $0.contains("Missing Presenter") })
        #expect(result.areas.allSatisfy { $0.audio == .program })
    }

    @MainActor @Test func snapshotsSurviveDeletionAndComposeSourcesWithProgramAudio() throws {
        var context = context()
        var screen = Fixtures.video(id: 2)
        screen.path = "/tmp/screen.mov"
        context.sources = [screen]
        var deleted = try layout("Screen + presenter")
        deleted.name = "Deleted layout"
        context.layouts = [deleted]
        let request = Framing(subject: .layout, layout: deleted.name, sourceRoles: ["screen": screen.url.path])
        let resolved = FramingPlanner.resolve(framing: request, context: context)
        let stored = try JSONDecoder().decode(FramingPlan.self, from: JSONEncoder().encode(resolved))
        context.layouts = []
        let plan = try #require(try FramingPlanner.composition(plan: stored, context: context))
        let builder = BuilderTimelineModel(mode: .transient)
        builder.document.trackCount = 2
        builder.compose(plan, source: .video(context.video))
        #expect(builder.document.videoTrack.map(\.videoFile) == [screen.url.path, context.sourcePath])
        #expect(builder.document.videoTrack.allSatisfy { $0.sourceStart == 2 && $0.duration == 20 })
        #expect(builder.document.videoTrack[0].framingProgramAudio == .init(path: context.sourcePath, start: 2, visualStart: 2))
        #expect(builder.document.videoTrack[1].muted)
        #expect(stored.area(forTrack: 0)?.role == .screen)
        let decoded = try JSONDecoder().decode(TimelineDocument.self, from: JSONEncoder().encode(builder.document))
        #expect(decoded.videoTrack[0].framingProgramAudio == builder.document.videoTrack[0].framingProgramAudio)
        #expect(decoded.videoTrack[0].framingPlan == stored)
        #expect(Framing.split(request.joined)?.sourceRoles == request.sourceRoles)
    }

    @MainActor @Test func everyTrackingSlotExpandsItsOwnSpans() throws {
        let video = Fixtures.video()
        let spans = [CropRecipePlanner.TrackingSpan(start: 0, end: 4, region: FreeCropRect(wFrac: 0.5)),
                     CropRecipePlanner.TrackingSpan(start: 4, end: 10, region: FreeCropRect(xFrac: 0.5, wFrac: 0.5))]
        let slot = CropRecipePlanner.Slot(subject: .vip, trackingSpans: spans)
        let plan = CropRecipePlanner.Plan(layout: CropLayoutRef(name: "Split"), slots: [slot, slot])
        let builder = BuilderTimelineModel(mode: .transient)
        builder.compose(plan, source: .video(video))
        for track in 0...1 {
            let clips = builder.document.videoTrack.filter { $0.track == track }.sorted { $0.startTime < $1.startTime }
            #expect(clips.map(\.duration) == [4, 6])
            #expect(clips.map(\.sourceStart) == [0, 4])
            #expect(clips.map(\.areaRegion) == spans.map { Optional($0.region) })
        }
    }

}
