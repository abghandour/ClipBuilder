import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

struct InterviewFocusRecipeTests {
    private func roster() -> [VideoPersonRecord] {
        [VideoPersonRecord(videoID: 1, personID: 1, key: "guest", name: "Guest", descriptor: "", portraitAt: 0,
            portraitBox: .init(x: 0.34, y: 0.2, w: 0.04, h: 0.1), vip: true),
         VideoPersonRecord(videoID: 1, personID: 2, key: "host", name: "Host", descriptor: "", portraitAt: 0,
            portraitBox: .init(x: 0.52, y: 0.2, w: 0.04, h: 0.1), vip: false)]
    }

    private func video() -> VideoRecord {
        var video = Fixtures.video()
        video.width = 1920; video.height = 1080; video.duration = 40
        video.podcastLayout = PodcastLayout.singleCamera.rawValue
        return video
    }

    private func turns() -> [SpeakerTurn] {
        [SpeakerTurn(videoID: 1, start: 0, end: 15, cluster: 0, confidence: 1, personKey: "guest", tile: 0),
         SpeakerTurn(videoID: 1, start: 15, end: 22, cluster: 1, confidence: 1, personKey: "host", tile: 1),
         SpeakerTurn(videoID: 1, start: 22, end: 40, cluster: 0, confidence: 1, personKey: "guest", tile: 0)]
    }

    @Test func unplacedVIPGoesToTheFeedThatSpeaksLongest() throws {
        // Portraits from an analysis before face snapping cover the whole frame.
        let saturated = VideoPersonRecord.PortraitBox(x: 1, y: 1, w: 1, h: 1)
        var roster = roster()
        roster[0].portraitBox = saturated
        roster[1].portraitBox = saturated
        var video = video()
        let tiles = [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1, faceX: 0.36, faceY: 0.29),
                     PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1, faceX: 0.57, faceY: 0.21)]
        video.podcastTilesJSON = String(decoding: try JSONEncoder().encode(tiles), as: UTF8.self)
        // Turns carry a tile but no person key; the guest answers for 30 of 40 s on tile 1.
        let turns = [SpeakerTurn(videoID: 1, start: 0, end: 30, cluster: 1, confidence: 1, personKey: nil, tile: 1),
                     SpeakerTurn(videoID: 1, start: 30, end: 36, cluster: 0, confidence: 1, personKey: nil, tile: 0),
                     SpeakerTurn(videoID: 1, start: 36, end: 40, cluster: 1, confidence: 1, personKey: nil, tile: 1)]
        let placed = VIPRecipePlanning.placingUnplacedVIP(tiles, roster: roster, turns: turns)
        #expect(placed.tiles.first { $0.index == 1 }?.personKey == "guest")
        #expect(placed.tiles.first { $0.index == 0 }?.personKey == nil)
        #expect(placed.note?.contains("Guest") == true)
        #expect(InterviewFaceSampling.feedTiles(video: video, roster: roster, turns: turns).first { $0.index == 1 }?.personKey == "guest")
        // A VIP already on a feed, or two VIPs, are left alone.
        #expect(VIPRecipePlanning.placingUnplacedVIP(tiles, roster: self.roster(), turns: turns).note == nil)
        var twoVIPs = roster
        twoVIPs[1].vip = true
        #expect(VIPRecipePlanning.placingUnplacedVIP(tiles, roster: twoVIPs, turns: turns).note == nil)

        var recipe = CropRecipe(kind: .interview)
        let tight = try CropRecipePlanner.plan(recipe, video: video, range: 0...40, turns: turns, roster: roster,
            layouts: ScreenCropStore.builtIn, canvasAspect: 9.0 / 16)
        recipe.interviewZoom = 1
        let wide = try CropRecipePlanner.plan(recipe, video: video, range: 0...40, turns: turns, roster: roster,
            layouts: ScreenCropStore.builtIn, canvasAspect: 9.0 / 16)
        #expect(tight.notes.contains { $0.contains("speaks longest") })
        #expect(tight.tiles.first { $0.index == 1 }?.personKey == "guest", "name tags read the placed feed identity")
        #expect(tight.tiles.first { $0.index == 0 }?.personKey == "host", "the one feed left is the interviewer's")
        // Name tags: the guest's shots and the host's cutaways tile the clip,
        // and concurrent tags never sit on top of each other.
        let people = [NameTagPlanner.Person(key: "guest", name: "Guest"), NameTagPlanner.Person(key: "host", name: "Host")]
        let areas = NameTagPlanner.areas(plan: tight, tiles: tight.tiles, roster: roster, layouts: ScreenCropStore.builtIn,
            canvas: CGSize(width: 1080, height: 1920), duration: 40, sourceAspect: 16.0 / 9)
        let tags = NameTagPlanner.plan(areas: areas, people: people, settings: .init())
        let guest = tags.filter { $0.personKey == "guest" }.sorted { $0.start < $1.start }
        #expect(guest.first?.start == 0 && guest.last?.end == 40)
        let host = tags.filter { $0.personKey == "host" }
        #expect(!host.isEmpty)
        for (shot, next) in zip(guest, guest.dropFirst()) where next.start - shot.end > 0.001 {
            #expect(host.contains { abs($0.start - shot.end) < 0.001 && abs($0.end - next.start) < 0.001 },
                    "the gap \(shot.end)–\(next.start) is a cutaway to the host")
        }
        for h in host {
            for g in guest where g.start < h.end && g.end > h.start {
                #expect(!g.rect.intersects(h.rect))
            }
        }
        let tightFirst = try #require(tight.slots.first?.path?.first)
        let wideFirst = try #require(wide.slots.first?.path?.first)
        #expect(tightFirst.x + tightFirst.w / 2 > 0.5, "the tight shot centres on the guest's feed")
        #expect(wideFirst.h > tightFirst.h && abs(wideFirst.h - 1) < 0.001)
    }

    @Test func kindAndDefaultsMatchSpecification() throws {
        #expect(CropRecipe.Kind.interview.rawValue == "interview_focus")
        #expect(CropRecipe.Kind.interview.name == "VIP focus" && CropRecipe.Kind.vip.name == "VIP on screen")
        #expect(CropRecipe.Kind.interview.summary == "Full screen on whoever talks; a question returns to the VIP after 2 s, and a long answer cuts away to the asker for 2 s every 8 s.")
        #expect(CropRecipePlanner.hold(for: CropRecipe(kind: .interview)) == 2)
        #expect(WizardCameraFocus.summary("interview_focus") == CropRecipe.Kind.interview.summary)
        #expect(CropRecipe.builtIn.contains { $0.kind == .interview })
        #expect(try JSONDecoder().decode(CropRecipe.Kind.self, from: JSONEncoder().encode(CropRecipe.Kind.interview)) == .interview)
        // One person at a time whatever the feed count (November 2, 2026).
        for feeds in [1, 2, 3, 4] {
            #expect(CropRecipePlanner.layoutName(kind: .interview, people: feeds) == CropLayoutRef.fullScreenName)
        }
        let recipe = CropRecipe(kind: .interview)
        #expect(CropRecipePlanner.defaultSlots(recipe, areas: 1, tiles: []) == [.talker])
    }

    @Test func singleCameraUsesPlainFullScreenPathOnRelativeClock() throws {
        for tracking in [false, true] {
            var recipe = CropRecipe(kind: .interview)
            recipe.tracking = tracking
            let plan = try CropRecipePlanner.plan(recipe, video: video(), range: 10...30,
                turns: turns(), roster: roster(), layouts: [], canvasAspect: 9.0 / 16)
            #expect(plan.layout.isFullScreen && plan.slots.count == 1)
            let slot = try #require(plan.slots.first)
            #expect(slot.subject == .vip && slot.region == nil && slot.trackingSpans == nil && slot.window == nil && slot.focus == nil)
            let path = try #require(slot.path)
            // Guest 10–15, the host asks 15–22 (shown 2 s), back to the guest at 17.
            #expect(path.map(\.t) == [0, 5, 5.8, 7, 7.8, 20])
            #expect(abs(path[0].x + path[0].w / 2 - 0.36) < 0.001 && abs(path[2].x + path[2].w / 2 - 0.54) < 0.001)
            #expect(path[4].x == path[0].x && path[4].h == path[0].h)
            #expect(CenterStageService.pathMatchesCanvas(path, sourceSize: CGSize(width: 1920, height: 1080), canvasAspect: 9.0 / 16))
        }
    }

    @Test func storedPersonColumnsStillUseSingleCameraPathAndFaceCenterFallback() throws {
        var video = video()
        let tiles = [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1, personKey: "guest", faceX: 0.36, faceY: 0.25),
                     PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1, personKey: "host", faceX: 0.54, faceY: 0.25)]
        video.podcastTilesJSON = String(decoding: try JSONEncoder().encode(tiles), as: UTF8.self)
        var roster = roster()
        roster[0].portraitBox = .init(x: 1, y: 1, w: 1, h: 1)
        roster[1].portraitBox = nil
        let plan = try CropRecipePlanner.plan(CropRecipe(kind: .interview), video: video,
            turns: turns(), roster: roster, layouts: [], canvasAspect: 9.0 / 16)
        #expect(plan.layout.isFullScreen)
        let path = try #require(plan.slots.first?.path)
        #expect(abs(path[0].x + path[0].w / 2 - 0.36) < 0.0001)
        #expect(path[0].h == 0.6)
    }

    @Test func separateFeedsShowOnePersonAtATimeStartingOnTheVIP() throws {
        for layout in [PodcastLayout.splitHorizontal, .grid] {
            var video = video()
            video.podcastLayout = layout.rawValue
            let tiles = [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1, personKey: "guest"),
                         PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1, personKey: "host")]
            video.podcastTilesJSON = String(decoding: try JSONEncoder().encode(tiles), as: UTF8.self)
            // The host asks first and the guest answers: the opening is on the
            // VIP all the same, then the picture cuts to whoever talks.
            let turns = [SpeakerTurn(videoID: 1, start: 3, end: 10, cluster: 1, confidence: 1, personKey: "host", tile: 1),
                         SpeakerTurn(videoID: 1, start: 10, end: 40, cluster: 0, confidence: 1, personKey: "guest", tile: 0)]
            var recipe = CropRecipe(kind: .interview)
            recipe.interviewCuts = true
            let plan = try CropRecipePlanner.plan(recipe, video: video,
                turns: turns, roster: roster(), layouts: ScreenCropStore.builtIn, canvasAspect: 9.0 / 16)
            #expect(plan.layout.isFullScreen && plan.slots.map(\.subject) == [.talker])
            let path = try #require(plan.slots[0].path)
            func centre(at time: Double) -> Double? {
                path.last(where: { $0.t <= time }).map { $0.x + $0.w / 2 }
            }
            #expect(try #require(centre(at: 0)) < 0.5, "opens on the guest's feed before anyone talks")
            #expect(try #require(centre(at: 4)) > 0.5, "the host's feed while the host asks")
            #expect(try #require(centre(at: 6)) < 0.5, "back to the guest 2 s into the question")
            #expect(try #require(centre(at: 20)) < 0.5, "on the guest while they answer")
            #expect(try #require(centre(at: 19)) > 0.5, "a 2 s cutaway to the host 8 s into the answer")
            #expect(path.allSatisfy { $0.w <= 0.5 + 0.0001 }, "never wider than one feed")
            #expect(plan.slots[0].talking == [3...5, 10...18, 20...28, 30...40])
        }
    }

    @Test func steadyCameraTracksEachFeedInsteadOfHoldingAFixedCrop() throws {
        var video = video()
        video.podcastLayout = PodcastLayout.splitHorizontal.rawValue
        let tiles = [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1, personKey: "guest"),
                     PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1, personKey: "host")]
        video.podcastTilesJSON = String(decoding: try JSONEncoder().encode(tiles), as: UTF8.self)
        let turns = [SpeakerTurn(videoID: 1, start: 3, end: 10, cluster: 1, confidence: 1, personKey: "host", tile: 1),
                     SpeakerTurn(videoID: 1, start: 10, end: 40, cluster: 0, confidence: 1, personKey: "guest", tile: 0)]
        var recipe = CropRecipe(kind: .interview)
        recipe.interviewCuts = true
        recipe.steady = true
        let plan = try CropRecipePlanner.plan(recipe, video: video,
            turns: turns, roster: roster(), layouts: ScreenCropStore.builtIn, canvasAspect: 9.0 / 16)
        let spans = try #require(plan.slots[0].trackingSpans)
        // Guest's feed, the host's feed while they ask, the guest's feed from
        // 2 s into the question, cutaways to the host at 18 and 28: the camera
        // tracks the person inside each feed, so the recording camera's moves are absorbed.
        #expect(spans.map(\.start) == [0, 3, 5, 18, 20, 28, 30] && spans.last?.end == 40)
        #expect(spans.map { $0.region.xFrac } == [0, 0.5, 0, 0.5, 0, 0.5, 0] && spans.allSatisfy { $0.region.wFrac == 0.5 })
        #expect(spans.allSatisfy { $0.focus != nil }, "each span seeds the camera on the person's face")
        // Off: the same recording keeps its fixed crops.
        recipe.steady = nil
        let fixed = try CropRecipePlanner.plan(recipe, video: video,
            turns: turns, roster: roster(), layouts: ScreenCropStore.builtIn, canvasAspect: 9.0 / 16)
        #expect(fixed.slots[0].trackingSpans == nil && fixed.slots[0].path != nil)
    }

    @Test func severalVIPsTakeTurnsInTheReturnsWithGlides() throws {
        var roster = roster()
        roster.append(VideoPersonRecord(videoID: 1, personID: 3, key: "guest2", name: "Guest 2", descriptor: "", portraitAt: 0,
            portraitBox: .init(x: 0.75, y: 0.2, w: 0.04, h: 0.1), vip: true))
        let turns = [SpeakerTurn(videoID: 1, start: 0, end: 20, cluster: 1, confidence: 1, personKey: "host", tile: 1)]
        let plan = try CropRecipePlanner.plan(CropRecipe(kind: .interview), video: video(), range: 0...20,
            turns: turns, roster: roster, layouts: [], canvasAspect: 9.0 / 16)
        let path = try #require(plan.slots.first?.path)
        // The host asks the whole clip: host, guest at 2, host again at 10, guest 2 at 12.
        #expect(path.map(\.t) == [0, 2, 2.8, 10, 10.8, 12, 12.8, 20])
        #expect(abs(path[0].x + path[0].w / 2 - 0.54) < 0.001 && path[4].x == path[0].x)
        #expect(abs(path[2].x + path[2].w / 2 - 0.36) < 0.001 && abs(path[6].x + path[6].w / 2 - 0.77) < 0.001)
        #expect(plan.slots[0].trackingSpans == nil && plan.slots[0].region == nil)
    }

    @Test func closeFacesStayStillAndPullBackOpensEveryShot() throws {
        var roster = roster()
        roster[1].portraitBox = .init(x: 0.38, y: 0.2, w: 0.04, h: 0.1)
        let still = try CropRecipePlanner.plan(CropRecipe(kind: .interview), video: video(),
            turns: turns(), roster: roster, layouts: [], canvasAspect: 9.0 / 16)
        // Faces this close share one face-tight frame: a move would be a twitch.
        #expect(still.slots[0].path?.map(\.t) == [0, 40])
        #expect(still.notes.isEmpty)
        #expect(still.slots[0].region == nil)
        roster[1].portraitBox = .init(x: 0.85, y: 0.2, w: 0.04, h: 0.1)
        let distant = try CropRecipePlanner.plan(CropRecipe(kind: .interview), video: video(),
            turns: turns(), roster: roster, layouts: [], canvasAspect: 9.0 / 16)
        #expect(distant.notes.isEmpty, "no two-shot, so nothing to explain")
        // Every shot follows Pull back: the face-tight height at 0, full height at 1.
        let source = Double(video().width) / Double(video().height)
        let close = InterviewFocusPlanning.tightHeight(
            vipFace: CGRect(x: 0.85 * source, y: 0.2, width: 0.04 * source, height: 0.1), canvasAspect: 9.0 / 16, maxHeight: 1)
        #expect(distant.slots[0].path?.contains { abs($0.h - close) < 0.001 } == true, "the host's shot is face-tight")
        #expect(distant.slots[0].path?.contains { abs($0.x + $0.w / 2 - 0.87) < 0.001 } == true, "and centred on the host")
        #expect(distant.slots[0].path?.allSatisfy { $0.h < 1 } == true, "nothing opens to the full height at 0 %")
        var pulledBack = CropRecipe(kind: .interview)
        pulledBack.interviewZoom = 1
        let wide = try CropRecipePlanner.plan(pulledBack, video: video(),
            turns: turns(), roster: roster, layouts: [], canvasAspect: 9.0 / 16)
        #expect(wide.slots[0].path?.allSatisfy { $0.h == 1 } == true)
    }

    @MainActor @Test func builderAndPodcastTimelineInstallCameraPath() throws {
        var expected = CropRecipe(kind: .interview)
        expected.interviewPunchIn = .talker
        let plan = try CropRecipePlanner.plan(expected, video: video(), range: 10...30,
            turns: turns(), roster: roster(), layouts: [], canvasAspect: 9.0 / 16)
        let builder = BuilderTimelineModel(mode: .transient)
        var source = video(); source.duration = 20
        builder.compose(plan, source: .video(source), highlightTalker: false)
        let composed = try #require(builder.document.videoTrack.first)
        #expect(composed.centerStage && composed.cameraPath == plan.slots[0].path)
        #expect(composed.cameraPathSource == "recipe" && composed.areaRegion == nil)
        let scene = Fixtures.scene(id: 42, start: 10, end: 30)
        let document = PodcastRecipeTimeline.build(subject: .speakerFocus, video: video(), range: 10...30,
            sourceScene: scene, turns: turns(), roster: roster(), layouts: [], settings: RenderSettings(), tagText: [:])
        let clip = try #require(document.videoTrack.first)
        #expect(document.videoTrack.count == 1)
        #expect(clip.centerStage && clip.cameraPath == plan.slots[0].path)
        #expect(clip.sourceStart == 10 && clip.sourceEnd == 30 && clip.duration == 20)
        #expect(clip.sceneID == scene.id && clip.areaRegion == nil)
    }

    @MainActor @Test func wizardCutDocumentsPreserveInterviewPath() throws {
        var scene = Fixtures.scene(id: 42, start: 10, end: 30)
        scene.tags = ["podcast", "podcast-exchange"]
        var plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: scene.id, start: 10, end: 30)])
        plan.framing = .speakerFocus
        var options = WizardOptions()
        options.formatPreset = "podcast"
        let cuts = WizardPodcastTimeline.cutDocuments(plan: plan, sceneMap: [scene.id: scene], options: options,
            videos: [video()], turns: [1: turns()], rosters: [1: roster()], layouts: [])
        let document = try #require(cuts[0])
        let clip = try #require(document.videoTrack.first)
        let path = try #require(clip.cameraPath)
        #expect(document.videoTrack.count == 1 && clip.centerStage && clip.areaRegion == nil)
        #expect(path.map(\.t) == [0, 5, 5.8, 7, 7.8, 20])
        #expect(clip.sourceStart == 10 && clip.sourceEnd == 30 && clip.duration == 20)
        #expect(CenterStageService.pathMatchesCanvas(path, sourceSize: CGSize(width: 1920, height: 1080)))
    }
}

extension InterviewFocusRecipeTests {
    @MainActor @Test func interviewerCutsReachTheRecipeAndPodcastTimeline() throws {
        var recipe = CropRecipe(kind: .interview)
        recipe.interviewPunchIn = .talker
        recipe.interviewCuts = true
        let plan = try CropRecipePlanner.plan(recipe, video: video(), range: 10...30,
            turns: turns(), roster: roster(), layouts: [], canvasAspect: 9.0 / 16)
        let path = try #require(plan.slots.first?.path)
        #expect(path.map(\.t) == [0, 4.99, 5, 6.99, 7, 20])
        #expect(abs(path[2].x + path[2].w / 2 - 0.54) < 0.001)
        #expect(path[2] != path[0] && path[4].x == path[0].x)
        #expect(CameraKeyframes.isCut(path, at: 2) && CameraKeyframes.isCut(path, at: 4))
        var options = WizardOptions()
        options.framing = Framing(subject: .speakerFocus)
        options.framing?.moves = .cuts
        let document = PodcastRecipeTimeline.build(subject: .speakerFocus, video: video(), range: 10...30,
            sourceScene: nil, turns: turns(), roster: roster(), layouts: [], settings: RenderSettings(),
            options: options, tagText: [:])
        #expect(document.videoTrack.first?.cameraPath == path)
    }

    @Test func rotatedVIPsAlsoUseCutPaths() throws {
        var people = roster()
        people.append(VideoPersonRecord(videoID: 1, personID: 3, key: "guest2", name: "Guest 2", descriptor: "", portraitAt: 0,
            portraitBox: .init(x: 0.75, y: 0.2, w: 0.04, h: 0.1), vip: true))
        var recipe = CropRecipe(kind: .interview)
        recipe.interviewPunchIn = .interviewer
        recipe.interviewCuts = true
        let plan = try CropRecipePlanner.plan(recipe, video: video(), range: 0...30,
            turns: turns(), roster: people, layouts: [], canvasAspect: 9.0 / 16)
        let path = try #require(plan.slots.first?.path)
        let changes = path.indices.dropFirst().filter { !CameraKeyframes.sameRect(path[$0 - 1], path[$0]) }
        #expect(!changes.isEmpty)
        #expect(changes.allSatisfy { CameraKeyframes.isCut(path, at: $0) })
        // The guest's 15 s answer earns a cutaway at 8 (nobody asked yet: the
        // next person in turn, the host), the host's question is shown at 15,
        // the guest is back at 17 and answers from 22.
        func centre(_ time: Double) throws -> Double {
            let shot = try #require(CenterStageService.interpolated(path, at: time))
            return shot.x + shot.w / 2
        }
        let centres = try [9.0, 11, 16, 20].map(centre)
        #expect(zip(centres, [0.54, 0.36, 0.54, 0.36]).allSatisfy { abs($0 - $1) < 0.001 }, "\(centres)")
    }

    /// The talker cell holds the previous talker while the VIP cell is on the
    /// talker's feed, and swaps the moment the VIP cell moves.
    @Test func talkerCellNeverRepeatsTheVIPCellsFeed() {
        let segments = [
            CropRecipePlanner.Segment(start: 0, end: 10, talker: 0, recent: [2, 1]),
            CropRecipePlanner.Segment(start: 10, end: 15, talker: 1, recent: [0, 2]),
            CropRecipePlanner.Segment(start: 15, end: 20, talker: 0, recent: [1, 2]),
        ]
        let plain = CropRecipePlanner.talkerEvents(segments: segments, avoiding: [], order: [0, 1, 2])
        #expect(plain.map(\.time) == [0, 10, 15] && plain.map(\.tile) == [0, 1, 0])
        let vipCell: [(time: Double, tile: Int?)] = [(0, 0), (6, 2), (12, 0)]
        let events = CropRecipePlanner.talkerEvents(segments: segments, avoiding: vipCell, order: [0, 1, 2])
        #expect(events.map(\.time) == [0, 6, 10, 12, 15])
        // 0–6 the VIP cell shows the talker: previous talker 2. 6–10 it moved
        // to 2, so the talker returns. 10–15 the host talks while the VIP cell
        // is on 2 then 0: the host both times. From 15 the VIP cell is on the
        // talker again: the previous talker, the host.
        #expect(events.map(\.tile) == [2, 0, 1, 1, 1])
        // Nobody spoke before and the VIP cell is on the talker: the first other feed.
        let opening = CropRecipePlanner.talkerEvents(
            segments: [CropRecipePlanner.Segment(start: 0, end: 5, talker: 0, recent: [])], avoiding: [(0, 0)], order: [0, 1, 2])
        #expect(opening.map(\.tile) == [1])
    }

    @Test func gridWithTwoVIPsStillShowsOnePersonAtATime() throws {
        var video = video()
        video.podcastLayout = PodcastLayout.grid.rawValue
        let tiles = [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 0.5, personKey: "guest"),
                     PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 0.5, personKey: "host"),
                     PodcastTile(index: 2, x: 0, y: 0.5, w: 0.5, h: 0.5, personKey: "guest2")]
        video.podcastTilesJSON = String(decoding: try JSONEncoder().encode(tiles), as: UTF8.self)
        var roster = roster()
        roster.append(VideoPersonRecord(videoID: 1, personID: 3, key: "guest2", name: "Guest 2", descriptor: "", portraitAt: 0,
            portraitBox: .init(x: 0.2, y: 0.7, w: 0.04, h: 0.1), vip: true))
        let turns = [SpeakerTurn(videoID: 1, start: 0, end: 10, cluster: 0, confidence: 1, personKey: "guest", tile: 0),
                     SpeakerTurn(videoID: 1, start: 10, end: 15, cluster: 1, confidence: 1, personKey: "host", tile: 1),
                     SpeakerTurn(videoID: 1, start: 15, end: 20, cluster: 0, confidence: 1, personKey: "guest", tile: 0)]
        let plan = try CropRecipePlanner.plan(CropRecipe(kind: .interview), video: video, range: 0...20,
            turns: turns, roster: roster, layouts: ScreenCropStore.builtIn, canvasAspect: 9.0 / 16)
        // Two VIPs on a grid: still one person at a time, whoever talks.
        #expect(plan.layout.isFullScreen && plan.slots.map(\.subject) == [.talker])
        func tile(containing rect: FreeCropRect) -> Int? {
            let cx = rect.xFrac + rect.wFrac / 2, cy = rect.yFrac + rect.hFrac / 2
            return tiles.first { cx >= $0.x && cx < $0.x + $0.w && cy >= $0.y && cy < $0.y + $0.h }?.index
        }
        let path = try #require(plan.slots[0].path)
        // Guest 0–10, the host asks 10–15 (shown 2 s), the guest from 12.
        let expected: [(time: Double, tile: Int)] = [(0, 0), (10, 1), (12, 0)]
        var samples = 0
        for t in stride(from: 0.25, to: 20, by: 0.5) {
            let shot = try #require(CenterStageService.interpolated(path, at: t))
            let shown = tile(containing: FreeCropRect(xFrac: shot.x, yFrac: shot.y, wFrac: shot.w, hFrac: shot.h))
            #expect(shown == expected.last { $0.time <= t }?.tile, "t=\(t)")
            #expect(shot.w <= 0.5 + 0.0001 && shot.h <= 0.5 + 0.0001, "never wider than one feed at t=\(t)")
            samples += 1
        }
        #expect(samples == 40)
    }
}
