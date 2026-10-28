import Foundation
import Testing
@testable import Clip_Builder

@Suite("Framing planner")
struct FramingPlannerTests {
    private func context(vip: Bool = true, broll: Bool = false, type: VideoType = .podcast) -> FramingContext {
        var video = Fixtures.video()
        video.videoType = type.rawValue
        video.podcastLayout = PodcastLayout.singleCamera.rawValue
        let roster = [VideoPersonRecord(videoID: video.id, personID: 1, key: "guest", name: "Guest",
            descriptor: "", portraitAt: 0, portraitBox: .init(x: 0.3, y: 0.2, w: 0.1, h: 0.2), vip: vip)]
        return FramingContext(video: video, range: 2...9, canvasAspect: 9.0 / 16,
            roster: roster, turns: [SpeakerTurn(videoID: video.id, start: 2, end: 9, cluster: 0,
                confidence: 1, personKey: "guest", tile: 0)], layouts: ScreenCropStore.builtIn, hasBRoll: broll)
    }

    @Test func originalKeepsAStaticWindowAndCenterStageUsesBalancedTracking() throws {
        let window = FreeCropRect(xFrac: 0.1, wFrac: 0.8)
        let original = Framing(subject: .original, fit: .blurredFill, focusFrame: window, lockAspect: false)
        let plan = FramingPlanner.resolve(framing: original, context: context())
        #expect(plan ==
            .static(window: window, fit: .blurredFill, feather: 0.08, blur: 0.5))
        var clip = Fixtures.timelineClip()
        WizardOrdinaryTimeline.apply(plan, scene: Fixtures.scene(), to: &clip)
        #expect(clip.framingPlan?.sourceWindow == window)
        #expect(clip.freeCrops?.first?.src == window)
        let tracked = FramingPlanner.resolve(framing: Framing(subject: .centerStage), context: context())
        let recipe = try #require(tracked.recipe)
        #expect(recipe.centerStage == true && recipe.tracking)
        #expect(tracked.camera == "balanced")
        #expect(try FramingPlanner.composition(plan: tracked, context: context()) == nil)
    }

    @Test(arguments: [false, true])
    func centerStageKeepsOnlyVIPsWhenOneIsTagged(vip: Bool) throws {
        let plan = FramingPlanner.resolve(framing: Framing(subject: .centerStage, people: .vips), context: context(vip: vip))
        let recipe = try #require(plan.recipe)
        #expect(recipe.centerStage == true)
        #expect(recipe.centerStageVIPs == (vip ? true : nil))
        #expect(FramingPlanner.resolve(framing: Framing(subject: .centerStage), context: context()).recipe?.centerStageVIPs == nil)
    }

    @Test func runVIPChoiceOverridesPeopleTags() throws {
        // Nobody tagged, but the run names the guest: Center stage keeps only them.
        let chosen = Framing(subject: .centerStage, people: .vips, vips: ["guest"])
        let recipe = try #require(FramingPlanner.resolve(framing: chosen, context: context(vip: false)).recipe)
        #expect(recipe.centerStageVIPs == true && recipe.centerStageVIPKeys == ["guest"])
        // Tagged, but the run drops everyone: back to everyone in the picture.
        let dropped = Framing(subject: .centerStage, people: .vips, vips: [])
        #expect(FramingPlanner.resolve(framing: dropped, context: context(vip: true)).recipe?.centerStageVIPs == nil)
        // The VIPs grid follows the run's choice too.
        let grid = FramingPlanner.resolve(framing: Framing(subject: .layout, vips: ["host", "third"], layout: FramingMenu.vipsLayout),
                                          context: feeds(vips: 1))
        guard case .composed(let layout, let areas, _) = grid else { Issue.record("not composed"); return }
        #expect(layout.areas.count == 2)
        #expect(Set(areas.compactMap { $0.region?.xFrac }) == [0.5, 0])
        #expect(Set(areas.compactMap { $0.region?.yFrac }) == [0, 0.5])
    }

    private func feeds(vips: Int) -> FramingContext {
        var context = context(vip: vips >= 1)
        context.roster.append(VideoPersonRecord(videoID: context.video.id, personID: 2, key: "host", name: "Host",
            descriptor: "", portraitAt: 0, portraitBox: .init(x: 0.7, y: 0.2, w: 0.1, h: 0.2), vip: vips >= 2))
        context.roster.append(VideoPersonRecord(videoID: context.video.id, personID: 3, key: "third", name: "Third",
            descriptor: "", portraitAt: 0, portraitBox: .init(x: 0.5, y: 0.6, w: 0.1, h: 0.2), vip: vips >= 3))
        context.feeds = [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 0.5, personKey: "guest"),
                         PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 0.5, personKey: "host"),
                         PodcastTile(index: 2, x: 0, y: 0.5, w: 1, h: 0.5, personKey: "third")]
        return context
    }

    @Test func everyoneLayoutIsAGridByHeadCount() throws {
        let plan = FramingPlanner.resolve(framing: Framing(subject: .layout, layout: FramingMenu.everyoneLayout), context: feeds(vips: 1))
        guard case .composed(let layout, let areas, _) = plan else { Issue.record("not composed"); return }
        #expect(layout.name == FramingMenu.everyoneLayout && layout.areas.count == 3)
        #expect(Set(areas.compactMap { $0.region?.xFrac }) == [0, 0.5])
        #expect(Set(areas.map(\.areaID)) == Set(layout.areas.map(\.id)))
        #expect(FramingPlanner.warning(framing: Framing(subject: .layout, layout: FramingMenu.everyoneLayout), context: feeds(vips: 1)) == nil)
        #expect(try FramingPlanner.composition(plan: plan, context: feeds(vips: 1))?.slots.count == 3)
    }

    @Test func vipsLayoutShowsOnlyTaggedVIPsAndFallsBackToEveryone() throws {
        let request = Framing(subject: .layout, layout: FramingMenu.vipsLayout)
        let two = FramingPlanner.resolve(framing: request, context: feeds(vips: 2))
        guard case .composed(let layout, let areas, _) = two else { Issue.record("not composed"); return }
        #expect(layout.name == FramingMenu.vipsLayout && layout.areas.count == 2)
        #expect(areas.allSatisfy { $0.region?.yFrac == 0 })
        #expect(Set(areas.compactMap { $0.region?.xFrac }) == [0, 0.5])
        let none = FramingPlanner.resolve(framing: request, context: feeds(vips: 0))
        guard case .composed(let fallback, _, _) = none else { Issue.record("not composed"); return }
        #expect(fallback.areas.count == 3)
        #expect(FramingPlanner.warning(framing: request, context: feeds(vips: 0))?.contains("showing everyone") == true)
        #expect(FramingPlanner.warning(framing: request, context: feeds(vips: 2)) == nil)
    }

    @Test(arguments: [false, true])
    func vipUsesAvailableBRoll(broll: Bool) throws {
        let resolved = FramingPlanner.resolve(framing: Framing(subject: .vipFocus), context: context(broll: broll))
        let recipe = try #require(resolved.recipe)
        #expect(recipe.kind == (broll ? .vipBRoll : .vip))
        #expect(recipe.tracking && recipe.minimumHold == FramingHolds.recipeHold)
        #expect(VIPRotation.minimumHold == FramingHolds.vipHold)
    }

    @Test(arguments: [false, true])
    func speakerKeepsShotAndTransitionParameters(vip: Bool) throws {
        let request = Framing(subject: .speakerFocus, pullBack: 0.6, moves: .cuts)
        let recipe = try #require(FramingPlanner.resolve(framing: request, context: context(vip: vip)).recipe)
        var expected = CropRecipe(kind: vip ? .interview : .talker)
        expected.interviewZoom = 0.6
        expected.interviewCuts = true
        expected.interviewPunchIn = .talker
        #expect(recipe == expected)
        #expect(!recipe.interviewZoomMoves && recipe.tracking)
    }

    @Test func layoutUsesRoleCompositionAndCarriesItsSnapshot() throws {
        let resolved = FramingPlanner.resolve(framing: Framing(subject: .layout, layout: "Split"), context: context())
        guard case .composed(let layout, let areas, _) = resolved else { Issue.record("Expected composition"); return }
        #expect(layout.name == "Split" && layout.areas.map(\.role) == [.vip, .others])
        #expect(!areas.isEmpty)
    }

    @Test(arguments: VideoType.allCases)
    func automaticNeverLeaksAnUnresolvedSubject(type: VideoType) {
        var evidence = context(type: type)
        let allowed = FramingMenu.allowed(type: type).filter { $0 != .auto }
        for choice in Framing.Subject.allCases {
            evidence.chosenSubject = choice
            let subject = FramingPlanner.subject(framing: Framing(), context: evidence)
            #expect(subject != .auto && allowed.contains(subject))
            if allowed.contains(choice) { #expect(subject == choice) }
        }
        evidence.chosenSubject = nil
        let expected = FramingMenu.default(type: type).subject
        #expect(FramingPlanner.subject(framing: Framing(), context: evidence) == (expected == .auto ? .speakerFocus : expected))
    }

    @Test(arguments: CropRecipe.Kind.allCases)
    func legacyAndMigratedOptionsResolveIdentically(kind: CropRecipe.Kind) {
        var old = WizardOptions()
        old.highlightFraming = kind
        old.interviewZoom = 0.6
        old.interviewCuts = true
        let before = FramingPlanner.resolve(framing: old.requestedFraming, context: context())
        old.framing = Framing.legacy(from: old)
        old.highlightFraming = nil
        old.interviewZoom = nil
        old.interviewCuts = nil
        #expect(FramingPlanner.resolve(framing: old.requestedFraming, context: context()) == before)
    }

    @Test func legacyWritesAreReplacedByOneFramingRequest() throws {
        let data = Data(#"{"highlightFraming":"interview_focus","interviewZoom":0.4,"interviewCuts":true,"interviewPunchIn":"interviewer","interviewZoomMoves":true,"framingCamera":"fast"}"#.utf8)
        let old = try JSONDecoder().decode(WizardOptions.self, from: data)
        let encoded = try JSONEncoder().encode(old)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["highlightFraming", "podcastFraming", "interviewZoom", "interviewCuts", "interviewPunchIn", "interviewZoomMoves", "framingCamera"] {
            #expect(object[key] == nil)
        }
        let restored = try JSONDecoder().decode(WizardOptions.self, from: encoded)
        #expect(restored.framing == Framing(subject: .speakerFocus, pullBack: 0.4, moves: .cuts))
        let oldTake = Data(#""talker_and_previous""#.utf8)
        #expect(try JSONDecoder().decode(Framing.Subject.self, from: oldTake) == .speakerFocus)
    }
}
