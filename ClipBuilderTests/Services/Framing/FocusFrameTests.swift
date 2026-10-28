import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

@Suite("Focus frame planning and coordinates")
struct FocusFrameTests {
    private let right = FreeCropRect(xFrac: 0.5, wFrac: 0.5)

    private func context() -> FramingContext {
        var video = Fixtures.video()
        video.podcastLayout = PodcastLayout.splitHorizontal.rawValue
        let roster = [
            VideoPersonRecord(videoID: video.id, personID: 1, key: "left", name: "Left", descriptor: "",
                portraitAt: 0, portraitBox: .init(x: 0.15, y: 0.2, w: 0.1, h: 0.2), vip: false),
            VideoPersonRecord(videoID: video.id, personID: 2, key: "right", name: "Right", descriptor: "",
                portraitAt: 0, portraitBox: .init(x: 0.7, y: 0.2, w: 0.1, h: 0.2), vip: true),
        ]
        let turns = [SpeakerTurn(videoID: video.id, start: 2, end: 5, cluster: 0, confidence: 1, personKey: "left", tile: 0),
            SpeakerTurn(videoID: video.id, start: 5, end: 9, cluster: 1, confidence: 1, personKey: "right", tile: 1)]
        return FramingContext(video: video, range: 2...9, canvasAspect: 9.0 / 16, type: .podcast,
            roster: roster, turns: turns, layouts: ScreenCropStore.builtIn)
    }

    @Test func resolvesUncroppedAndPostBarStripCoordinates() {
        #expect(FocusFrame.resolved(right) == right)
        let frame = FreeCropRect(xFrac: 0.5, yFrac: 0.25, wFrac: 0.25, hFrac: 0.5)
        let content = RenderEngine.ContentBox(x: 0.25, y: 0.25, w: 0.5, h: 0.5, aspect: 16.0 / 9)
        #expect(FocusFrame.resolved(frame, contentBox: content) == right)
        #expect(FocusFrame.sourceWindow(frame, contentBox: content) == frame)
        let outside = FreeCropRect(xFrac: 0, yFrac: 0, wFrac: 0.1, hFrac: 0.1)
        #expect(FocusFrame.resolved(outside, contentBox: content) == FreeCropRect())
        #expect(FocusFrame.sourceWindow(outside, contentBox: content) ==
            FreeCropRect(xFrac: 0.25, yFrac: 0.25, wFrac: 0.5, hFrac: 0.5))
        #expect(FocusFrame.resolved(FreeCropRect(xFrac: .nan)) == FreeCropRect())
        let clipped = FocusFrame.resolved(FreeCropRect(xFrac: 0.8, wFrac: 0.5))
        #expect(abs(clipped.wFrac - 0.2) < 1e-9 && clipped.xFrac == 0.8)
    }

    @Test func initialOriginalWindowLocksToCanvasAndTrackingStartsAtFullSource() {
        let source = CGSize(width: 1920, height: 1080)
        let original = FocusFrame.initial(framing: Framing(subject: .original), sourceSize: source, canvasAspect: 9.0 / 16)
        #expect(abs(original.wFrac * source.width / (original.hFrac * source.height) - 9.0 / 16) < 1e-9)
        #expect(abs(original.xFrac + original.wFrac / 2 - 0.5) < 1e-9)
        for subject: Framing.Subject in [.centerStage, .speakerFocus, .vipFocus] {
            #expect(FocusFrame.initial(framing: Framing(subject: subject), sourceSize: source, canvasAspect: 9.0 / 16) == FreeCropRect())
        }
    }

    @Test(arguments: Framing.Subject.allCases)
    func freeHandleRequiresOriginalBlurredFillAndExplicitUnlock(_ subject: Framing.Subject) {
        let source = CGSize(width: 1920, height: 1080)
        for fit: Framing.Fit in [.fill, .blurredFill] {
            for locked: Bool? in [nil, true, false] {
                let framing = Framing(subject: subject, fit: fit, lockAspect: locked)
                let expected = subject == .original && (fit == .fill || locked != false)
                #expect(FocusFrame.handleAspectLocked(framing: framing) == expected)
                let initial = FocusFrame.initial(framing: framing, sourceSize: source, canvasAspect: 9.0 / 16)
                if expected {
                    #expect(abs(initial.wFrac * source.width / (initial.hFrac * source.height) - 9.0 / 16) < 1e-9)
                } else {
                    #expect(initial == FreeCropRect())
                }
            }
        }
    }

    @Test(arguments: [Framing.Subject.original, .centerStage, .vipFocus, .speakerFocus, .layout])
    func installsSubjectSpecificGeometry(_ subject: Framing.Subject) throws {
        let plan = FramingPlanner.resolve(framing: Framing(subject: subject, focusFrame: right), context: context())
        var clip = Fixtures.timelineClip()
        if subject != .layout {
            clip.cameraPath = [.init(t: 0, x: 0, y: 0, w: 0.3, h: 1), .init(t: 3, x: 0, y: 0, w: 0.3, h: 1)]
        }
        FocusFrame.apply(plan, to: &clip)
        switch subject {
        case .original:
            #expect(plan.isStatic && plan.sourceWindow == right)
            #expect(clip.freeCrops == [FreeCrop(src: right, dst: FreeCropRect())])
            #expect(clip.areaRegion == nil && clip.areaWindow == nil && clip.cameraPath == nil && !clip.centerStage)
        case .layout:
            #expect(plan.sourceWindow == nil && clip.areaRegion == nil && clip.freeCrops == nil)
        default:
            #expect(!plan.isStatic && plan.sourceWindow == right)
            #expect(clip.areaRegion == right && clip.areaWindow == nil && clip.cameraPath == nil && clip.centerStage)
            if let composition = try FramingPlanner.composition(plan: plan, context: context()) {
                #expect(!composition.slots.isEmpty)
                for slot in composition.slots {
                    let region = try #require(slot.region)
                    #expect(FocusFrame.rect(right).contains(FocusFrame.rect(region)))
                    #expect(slot.window == nil)
                    for key in slot.path ?? [] {
                        #expect(key.x >= right.xFrac - 1e-9 && key.x + key.w <= 1 + 1e-9)
                        #expect(key.y >= 0 && key.y + key.h <= 1 + 1e-9)
                    }
                }
            }
        }
    }

    @Test func filtersPortraitsFeedsAndSpeechBeforePlanning() {
        let filtered = FocusFrame.filtered(context(), frame: right)
        #expect(filtered.roster.map(\.key) == ["right"])
        #expect(filtered.feeds.map(\.index) == [1])
        #expect(filtered.turns.map(\.personKey) == ["right"])
        #expect(filtered.storedPath == nil)
    }

    @Test(arguments: [Framing.Subject.centerStage, .vipFocus, .speakerFocus])
    func nobodyInsideFallsBackToTheExactStaticWindow(_ subject: Framing.Subject) {
        let window = FreeCropRect(xFrac: 0, yFrac: 0.8, wFrac: 0.1, hFrac: 0.1)
        let request = Framing(subject: subject, focusFrame: window)
        let plan = FramingPlanner.resolve(framing: request, context: context())
        #expect(plan.isStatic && plan.sourceWindow == window)
        #expect(FramingPlanner.warning(framing: request, context: context()) == FocusFrame.nobodyInside)
        var clip = Fixtures.timelineClip()
        FocusFrame.apply(plan, to: &clip)
        #expect(clip.freeCrops?.first?.src == window && clip.areaRegion == nil)
        var options = WizardOptions()
        options.framing = request
        let evidence = context()
        let preview = WizardPreviewFraming.resolve(options: options, record: Fixtures.scene(), video: evidence.video,
            face: nil, turns: evidence.turns, roster: evidence.roster, people: [], layouts: evidence.layouts)
        #expect(preview.framing == .original && preview.warning == FocusFrame.nobodyInside)
    }

    @Test func freshRecipePathsRetainTheirTimingInsideTheFrame() {
        let plan = FramingPlanner.resolve(framing: Framing(subject: .speakerFocus, focusFrame: right), context: context())
        var clip = Fixtures.timelineClip()
        clip.framingPlan = plan
        clip.cameraPath = [0.0, 1.5, 3.0].map { time in
            let shot = FocusFrame.fitting(FreeCropRect(xFrac: 0.4, yFrac: 0.1, wFrac: 0.4, hFrac: 0.8), inside: right)
            return CameraPathKeyframe(t: time, x: shot.xFrac, y: shot.yFrac, w: shot.wFrac, h: shot.hFrac)
        }
        FocusFrame.apply(plan, to: &clip, replanned: true)
        #expect(FocusFrame.hasReplannedPath(clip))
        FocusFrame.apply(plan, to: &clip)
        #expect(clip.cameraPath?.map(\.t) == [0, 1.5, 3])
        clip.framingPlan = FramingPlanner.resolve(framing: Framing(subject: .speakerFocus,
            focusFrame: FreeCropRect(xFrac: 0.6, wFrac: 0.4)), context: context())
        if let changed = clip.framingPlan { FocusFrame.apply(changed, to: &clip) }
        #expect(clip.cameraPath == nil)
    }

    @Test func focusedTrackingDiscardsSceneAndExplicitPathsWithoutChangingTiming() throws {
        var scene = Fixtures.scene(start: 2, end: 8)
        let path = SceneCameraPath(camera: "balanced", keyframes: [
            .init(t: 0, x: 0, y: 0, w: 0.3, h: 1), .init(t: 6, x: 0, y: 0, w: 0.3, h: 1)])
        scene.centerStagePathJSON = String(decoding: try JSONEncoder().encode(path), as: UTF8.self)
        var clip = Fixtures.timelineClip(sceneID: scene.id, sourceStart: 3, duration: 2, speed: 1.5)
        clip.wide = true; clip.centerStage = true; clip.cameraPath = path.keyframes
        clip.framingPlan = FramingPlanner.resolve(framing: Framing(subject: .centerStage, focusFrame: right), context: context())
        let resolved = try #require(MultitrackRenderer.resolveClips(document: Fixtures.timelineDocument(clips: [clip]), scenes: [scene]).first)
        #expect(resolved.areaRegion == right && resolved.cameraPath == nil)
        #expect(resolved.sourceStart == 3 && resolved.duration == 2 && resolved.speed == 1.5)
        #expect(MultitrackRenderer.effectiveCameraPath(for: clip, scenes: [scene]).isEmpty)
    }
}
