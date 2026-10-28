import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

@Suite("Fighter tracking adapter")
struct FighterTrackingAdapterTests {
    private func signature(_ index: Int) throws -> AppearanceSignature {
        var value = try #require(AppearanceSignature(cgImage: FitTestImage.source()))
        value.histogram = (0..<64).map { $0 == index ? 1 : 0 }
        return value
    }

    @Test func portraitIdentitySurvivesCrossingAndDetectionOrderChanges() throws {
        let red = try signature(0), blue = try signature(63)
        var tracker = FighterTrackingAdapter.Tracker(portraits: [red], hasVIP: true)
        for (index, x) in [0.15, 0.35, 0.55, 0.75].enumerated() {
            let vip = CGRect(x: x, y: 0.2, width: 0.15, height: 0.65)
            let other = CGRect(x: 0.9 - x, y: 0.2, width: 0.15, height: 0.65)
            var bodies = [FighterTrackingAdapter.Body(box: vip, appearance: red),
                          FighterTrackingAdapter.Body(box: other, appearance: blue)]
            if index.isMultiple(of: 2) { bodies.reverse() }
            let selected = tracker.select(bodies, at: Double(index))
            #expect(selected.matchedVIP && selected.box == vip)
        }
    }

    @Test func withoutVIPCameraTargetContainsBothLargestBodies() {
        var tracker = FighterTrackingAdapter.Tracker(portraits: [], hasVIP: false)
        for (index, x) in [0.15, 0.35, 0.55, 0.75].enumerated() {
            let a = CGRect(x: x, y: 0.2, width: 0.15, height: 0.65)
            let b = CGRect(x: 0.9 - x, y: 0.2, width: 0.15, height: 0.65)
            let spectator = CGRect(x: 0, y: 0, width: 0.02, height: 0.03)
            let result = tracker.select([.init(box: a, appearance: nil), .init(box: spectator, appearance: nil),
                                         .init(box: b, appearance: nil)], at: Double(index))
            #expect(result.box.contains(a) && result.box.contains(b))
            #expect(result.box == a.union(b))
            let window = FighterTrackingAdapter.containing(camera: CGRect(x: 0.4, y: 0, width: 0.3, height: 1), subjects: [result.box])
            #expect(window.contains(a) && window.contains(b))
        }
    }

    @Test func lostVIPWidensForTwoSecondsThenReacquiresFromPortrait() throws {
        let red = try signature(0), blue = try signature(63)
        let a = FighterTrackingAdapter.Body(box: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.6), appearance: red)
        let b = FighterTrackingAdapter.Body(box: CGRect(x: 0.6, y: 0.2, width: 0.2, height: 0.6), appearance: blue)
        var tracker = FighterTrackingAdapter.Tracker(portraits: [red], hasVIP: true)
        #expect(tracker.select([a, b], at: 0).matchedVIP)
        #expect(!tracker.select([b], at: 1).matchedVIP)
        #expect(!tracker.select([a, b], at: 2.99).matchedVIP)
        #expect(tracker.select([b, a], at: 3).box == a.box)
    }

    @Test func fightPlanBypassesPodcastRecipeAndUsesFastAction() throws {
        var video = Fixtures.video()
        video.videoType = VideoType.fight.rawValue
        let context = FramingContext(video: video, range: 0...10, canvasAspect: 9.0 / 16)
        let plan = FramingPlanner.resolve(framing: Framing(subject: .vipFocus), context: context)
        #expect(plan.recipe?.fighterFocus == true)
        #expect(plan.camera == "fast")
        #expect(try FramingPlanner.composition(plan: plan, context: context) == nil)
        #expect(FramingPlanner.unavailableReason(.vipFocus, type: .fight, hasTurns: false, hasVIP: false) == nil)
    }

    @Test func wideActionReplayFitsBeforeLosingTheSecondFighter() {
        var recipe = CropRecipe(kind: .vip)
        recipe.fighterFocus = true
        let plan = FramingPlan.tracked(recipe, region: nil, fit: .blurredFill, feather: 0.08, blur: 0.5)
        let area = ScreenCropArea(name: "Full", points: [.init(x: 0, y: 0), .init(x: 1, y: 0),
            .init(x: 1, y: 1), .init(x: 0, y: 1)])
        let graph = AreaFramer.pathFilter(keyframes: [.init(t: 0, x: 0, y: 0, w: 1, h: 1),
            .init(t: 4, x: 0.1, y: 0, w: 0.8, h: 1)], source: CGSize(width: 1920, height: 1080),
            area: area, namespace: "fight", framingPlan: plan)
        #expect(graph.contains("force_original_aspect_ratio=decrease"))
        #expect(graph.contains("boxblur=") && graph.contains("geq=") && graph.contains("overlay=(W-w)/2:(H-h)/2"))
    }

}
