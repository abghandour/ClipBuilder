import Foundation
import Testing
@testable import Clip_Builder

@Suite("Wizard rough cut")
struct WizardRoughCutTests {
    @Test("every presentation layer is off and the canvas is a third of the size, aspect kept")
    func optionsKeepFramingOnly() {
        var options = WizardOptions()
        options.renderSettings.preset = .portrait1080
        options.renderSettings.quality = .archival
        options.renderSettings.speechPolish = SpeechPolishSettings()
        options.addCaptions = true
        options.enableTextOverlays = true
        options.nameTags = true
        options.useMusic = true
        options.musicTrack = "Beat"
        options.muteSource = true
        options.dubLanguage = "pt"
        options.includeWatermark = true
        options.includeIntroBumper = true
        options.introBumperPath = "/tmp/intro.mp4"
        options.watermarkOverlayTemplate = "Mark"
        options.fixedOverlayTemplate = "Lower Third"
        options.strikeStats = true
        options.lookPreset = "vintage"
        options.useBRoll = true
        options.transitionChoice = "fadeblack"
        options.framing = Framing(subject: .speakerFocus)
        options.interviewZoom = 0.4
        options.interviewCuts = true

        let rough = WizardRoughCut.options(options)
        #expect(rough.renderSettings.width == 360 && rough.renderSettings.height == 640)
        #expect(rough.renderSettings.quality == .compact && rough.renderSettings.speechPolish == nil)
        #expect(!rough.addCaptions && !rough.enableTextOverlays && rough.nameTags == false && !rough.usesNameTags)
        #expect(!rough.useMusic && rough.musicTrack == nil && !rough.muteSource && rough.dubLanguage == nil)
        #expect(!rough.includeWatermark && !rough.includeIntroBumper && rough.introBumperPath == nil)
        #expect(rough.watermarkOverlayTemplate == nil && rough.fixedOverlayTemplate == nil)
        #expect(rough.strikeStats == false && rough.lookPreset == nil && !rough.useBRoll)
        #expect(rough.transitionChoice == nil && rough.allowedTransitions == ["cut"])
        // Framing is the point of a rough cut.
        #expect(rough.framing?.subject == .speakerFocus && rough.interviewZoom == 0.4 && rough.interviewCuts == true)
    }

    @Test("a chosen effect and transition survive the strip; none is the default")
    func extrasKeepEffectAndTransition() {
        var options = WizardOptions()
        options.lookPreset = "vintage"
        options.lookIntensity = 0.6
        options.transitionChoice = "fadeblack"
        options.allowedTransitions = ["fade", "fadeblack"]
        #expect(RoughCutExtras() == RoughCutExtras(look: nil, transition: nil), "both none by default")
        let plain = WizardRoughCut.options(options)
        #expect(plain.lookPreset == nil && plain.lookIntensity == nil && plain.transitionChoice == nil)
        let named = WizardRoughCut.options(options, extras: RoughCutExtras(look: "noir", transition: "fade"))
        #expect(named.lookPreset == "noir" && named.lookIntensity == 0.6)
        #expect(named.transitionChoice == "fade" && named.allowedTransitions == ["fade"])
        let random = WizardRoughCut.options(options, extras: RoughCutExtras(transition: WizardPlanRules.randomTransitionChoice))
        #expect(random.allowedTransitions == ["fade", "fadeblack"], "random draws from the page's set")

        var document = TimelineDocument()
        var main = TimelineClip()
        main.effect = EffectSpec(preset: "noir")
        main.transIn = "fade"
        main.transOut = "fade"
        document.videoTrack = [main]
        let kept = WizardRoughCut.strip(document, extras: RoughCutExtras(look: "noir", transition: "fade"))
        #expect(kept.videoTrack[0].effect?.preset == "noir" && kept.videoTrack[0].transIn == "fade")
        let onlyLook = WizardRoughCut.strip(document, extras: RoughCutExtras(look: "noir"))
        #expect(onlyLook.videoTrack[0].effect?.preset == "noir" && onlyLook.videoTrack[0].transIn == nil)
    }

    @Test("Express's Overlays tab puts captions, name tags, safe area, watermark and the overlay back; the rest stays off")
    func overlaysFromExpressSurviveTheStrip() {
        var options = WizardOptions()
        options.renderSettings.preset = .portrait1080
        options.useMusic = true
        options.dubLanguage = "pt"
        options.includeIntroBumper = true
        options.includeHeadline = true
        var settings = MiniWizardSettings()
        settings.captions = true
        settings.captionPosition = "top"
        settings.captionStyleID = "bold"
        settings.englishCaptions = true
        settings.nameTags = true
        settings.nameTagPosition = "custom:0.5,0.2"
        settings.safeAreaOnly = true
        settings.safeAreaPlatforms = [SocialPlatform.instagram.rawValue]
        settings.watermark = true
        settings.watermarkOverlay = "Mark"
        settings.watermarkOpacity = 0.3
        settings.overlay = true
        settings.overlayTemplate = "Lower third"
        settings.overlayStart = 2
        settings.overlayTexts = ["Hook"]
        let rough = WizardRoughCut.options(options, extras: RoughCutExtras(overlays: RoughCutOverlays(settings: settings)))
        #expect(rough.addCaptions && rough.captionPosition == "top" && rough.captionStyleID == "bold" && rough.captionLanguage == "en")
        #expect(rough.usesNameTags && rough.nameTagPosition == "custom:0.5,0.2")
        #expect(rough.safeAreaOnly == true && rough.safeAreaPlatforms == [.instagram])
        #expect(rough.includeWatermark && rough.watermarkOverlayTemplate == "Mark" && rough.watermarkOpacity == 0.3)
        #expect(rough.fixedOverlayTemplate == "Lower third" && rough.fixedOverlayStart == 2 && rough.fixedOverlayTexts == ["Hook"])
        // Still a rough cut: small, no sound, dub, bumpers or cards.
        #expect(rough.renderSettings.width == 360 && rough.renderSettings.height == 640 && rough.renderSettings.quality == .compact)
        #expect(!rough.useMusic && rough.dubLanguage == nil && !rough.includeIntroBumper && !rough.includeHeadline)
        #expect(rough.transitionChoice == nil && rough.allowedTransitions == ["cut"])
        // The same choices as Generate maps them.
        var generate = WizardStep2Options()
        settings.applyOverlayOptions(to: &generate)
        #expect(generate.addCaptions == true && generate.nameTags == true && generate.fixedOverlayTemplate == "Lower third")
        #expect(settings.step2Options(base: WizardStep2Options()).fixedOverlayTexts == generate.fixedOverlayTexts)

        // A dubbed page captions the rough cut in the dub language, dub itself stays off.
        var dubbed = settings
        dubbed.dub = true
        dubbed.dubLanguage = "pt"
        let dubbedCut = WizardRoughCut.options(options, extras: RoughCutExtras(overlays: RoughCutOverlays(settings: dubbed)))
        #expect(dubbedCut.captionLanguage == "pt" && dubbedCut.dubLanguage == nil)

        // Off in the tab stays off in the cut.
        var plain = settings
        plain.captions = false
        plain.nameTags = false
        plain.watermark = false
        plain.overlay = false
        let off = WizardRoughCut.options(options, extras: RoughCutExtras(overlays: RoughCutOverlays(settings: plain)))
        #expect(!off.addCaptions && !off.usesNameTags && !off.includeWatermark && off.fixedOverlayTemplate == nil)
        #expect(off.watermarkOverlayTemplate == nil && off.watermarkOpacity == nil)

        // The built document keeps what the options asked for; sound, dub, cards and cutaways still go.
        var document = TimelineDocument()
        var card = TimelineClip()
        card.videoFile = "/tmp/cards/intro_card.mp4"
        card.duration = 2
        var main = TimelineClip()
        main.sceneID = 7
        main.startTime = 2
        main.captions = "top"
        var cutaway = TimelineClip()
        cutaway.role = .cutaway
        cutaway.track = 1
        document.videoTrack = [card, main, cutaway]
        document.textOverlays = [TextOverlayItem()]
        document.overlayBlocks = [OverlayBlockItem()]
        document.brandLayers = [BrandLayerItem(path: "/tmp/w.png", kind: BrandLayerItem.watermark)]
        document.soundTrack = [SoundItem()]
        document.dub = DubSettings(language: "pt")
        let kept = WizardRoughCut.strip(document, extras: RoughCutExtras(overlays: RoughCutOverlays(settings: settings)))
        #expect(kept.videoTrack.count == 1 && kept.videoTrack[0].captions == "top" && kept.videoTrack[0].startTime == 0)
        #expect(kept.textOverlays.count == 1 && kept.overlayBlocks.count == 1 && kept.brandLayers?.count == 1)
        #expect(kept.soundTrack.isEmpty && kept.dub == nil)
        #expect(WizardRoughCut.leftOut(overlays: true).hasPrefix("cards") && WizardRoughCut.leftOut(overlays: false) == WizardRoughCut.leftOut)
    }

    @Test("takes become preview clips in output order, titled by selection")
    func previewClipsFromTakes() {
        let scene = Fixtures.scene(id: 7, start: 0, end: 60)
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: 7, start: 2, end: 8),
                                         Fixtures.planClip(sceneID: 7, start: 20, end: 25),
                                         Fixtures.planClip(sceneID: 99, start: 0, end: 1)])
        let take = WizardSelectionTake(id: 11, selectionID: 5, ordinal: 2, note: nil, plan: plan, sceneIDs: [7],
                                       proxyPath: nil, criticScore: nil, criticNotes: nil, provenance: nil, createdAt: nil)
        let clips = WizardPreviewClips.takes([take], names: [5: "Opening"], scenes: [scene])
        #expect(clips.map(\.title) == ["Opening · 1", "Opening · 2"], "the clip without a scene is skipped")
        #expect(clips.map(\.start) == [2, 20] && clips[0].scene.id == 7)
        let unnamed = WizardPreviewClips.takes([take], names: [:], scenes: [scene])
        #expect(unnamed[0].title == "Take 2 · 1")
    }

    @Test("an unrendered cut has a stable id, its planned length, and marks the review unrendered")
    func unrenderedCuts() {
        let scene = Fixtures.scene(id: 7, start: 0, end: 60)
        let clips = [WizardPreviewClip(id: "take-11-0", title: "A", scene: scene, start: 2, end: 8, outputStart: 0, outputDuration: 6),
                     WizardPreviewClip(id: "take-11-1", title: "B", scene: scene, start: 20, end: 25, outputStart: 5.5, outputDuration: 5)]
        #expect(RoughCut.plannedDuration(of: clips) == 10.5, "the end of the last clip after the overlap")
        #expect(RoughCut.plannedDuration(of: []) == 0)
        let pending = RoughCut(url: nil, name: "Rough cut", duration: 10.5, takeID: 11)
        let rendered = RoughCut(url: URL(fileURLWithPath: "/tmp/rough-1.mp4"), name: "Rough cut", duration: 10.5, takeID: 11)
        #expect(!pending.isRendered && rendered.isRendered)
        #expect(pending.id == "unrendered-11" && pending.id != rendered.id)
        let review = RoughCutReview(projectID: 1, cuts: [pending], namespace: "express", requestID: UUID(),
                                    framing: Framing(), sourceType: .other, videoIDs: [], canvasAspect: 9 / 16)
        #expect(!review.isRendered)
        var done = review
        done.cuts = [rendered]
        #expect(done.isRendered)
    }

    @Test("a cut's playhead maps to the kept footage moment, clip by clip")
    func momentAtPlayhead() {
        let scene = Fixtures.scene(id: 7, start: 0, end: 60)
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: 7, start: 2, end: 8),
                                         Fixtures.planClip(sceneID: 7, start: 20, end: 25)])
        let take = WizardSelectionTake(id: 11, selectionID: 5, ordinal: 1, note: nil, plan: plan, sceneIDs: [7],
                                       proxyPath: nil, criticScore: nil, criticNotes: nil, provenance: nil, createdAt: nil)
        let other = WizardSelectionTake(id: 12, selectionID: 5, ordinal: 2, note: nil, plan: plan, sceneIDs: [7],
                                        proxyPath: nil, criticScore: nil, criticNotes: nil, provenance: nil, createdAt: nil)
        let all = WizardPreviewClips.takes([take, other], names: [:], scenes: [scene])
        let clips = WizardPreviewClips.clips(all, ofTake: 11)
        #expect(clips.map(\.id) == ["take-11-0", "take-11-1"], "only this take's clips, in order")
        #expect(WizardPreviewClips.moment(in: clips, at: 1.5) == WizardPreviewMoment(clipID: "take-11-0", time: 3.5))
        #expect(WizardPreviewClips.moment(in: clips, at: 6) == WizardPreviewMoment(clipID: "take-11-1", time: 20),
                "the second clip starts where the first one's six seconds end")
        #expect(WizardPreviewClips.moment(in: clips, at: 30) == WizardPreviewMoment(clipID: "take-11-1", time: 25),
                "past the end stays on the last moment")
        #expect(WizardPreviewClips.moment(in: clips, at: -1)?.time == 2)
        #expect(WizardPreviewClips.moment(in: [], at: 0) == nil)
    }

    @Test("rendered preview follows screen time at slow and fast speeds", arguments: [0.5, 2.0])
    func renderedSpeed(speed: Double) throws {
        let scene = Fixtures.scene(id: 7, start: 0, end: 60)
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: 7, start: 10, end: 18)])
        let take = WizardSelectionTake(id: 11, selectionID: 5, ordinal: 1, note: nil, plan: plan, sceneIDs: [7],
                                       proxyPath: nil, criticScore: nil, criticNotes: nil, provenance: nil, createdAt: nil)
        let duration = 8 / speed
        let document = Fixtures.timelineDocument(clips: [Fixtures.timelineClip(sceneID: 7, sourceStart: 10,
            duration: duration, speed: speed)])
        let clips = WizardPreviewClips.rendered(document, take: take, name: "Opening", scenes: [scene], xfadeDuration: 0.4)
        let moment = try #require(WizardPreviewClips.moment(in: clips, at: duration / 4))
        #expect(moment.clipID == "take-11-0")
        #expect(abs(moment.time - 12) < 0.0001)
        let end = try #require(WizardPreviewClips.moment(in: clips, at: duration + 10))
        #expect(abs(end.time - 18) < 0.0001)
    }

    @Test("rendered preview uses pacing trims and the incoming clip during an overlap")
    func renderedRangesAndOverlap() throws {
        let scene = Fixtures.scene(id: 7, start: 0, end: 60)
        var plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: 7, start: 2, end: 12),
                                       Fixtures.planClip(sceneID: 7, start: 20, end: 30)])
        plan.framing = .original
        let take = WizardSelectionTake(id: 11, selectionID: 5, ordinal: 1, note: nil, plan: plan, sceneIDs: [7],
                                       proxyPath: nil, criticScore: nil, criticNotes: nil, provenance: nil, createdAt: nil)
        // The renderer's document has already trimmed both ends for pacing.
        let first = Fixtures.timelineClip(sceneID: 7, sourceStart: 4, duration: 3)
        var second = Fixtures.timelineClip(sceneID: 7, sourceStart: 23, duration: 2, startTime: 3)
        second.transIn = "fade"
        let document = WizardRoughCut.strip(Fixtures.timelineDocument(clips: [first, second]),
                                           extras: RoughCutExtras(transition: "fade"))
        let clips = WizardPreviewClips.rendered(document, take: take, name: "Opening", scenes: [scene], xfadeDuration: 0.4)
        #expect(clips.map(\.id) == ["take-11-0", "take-11-1"])
        #expect(clips.map(\.start) == [4, 23] && clips.map(\.end) == [7, 25])
        #expect(clips.allSatisfy { $0.chosenSubject == .original })
        #expect(abs(try #require(clips[1].outputStart) - 2.6) < 0.0001)
        for (time, id, source) in [(0.0, "take-11-0", 4.0), (2.5, "take-11-0", 6.5),
                                    (2.6, "take-11-1", 23.0), (2.8, "take-11-1", 23.2),
                                    (3.4, "take-11-1", 23.8), (4.6, "take-11-1", 25.0)] {
            let moment = try #require(WizardPreviewClips.moment(in: clips, at: time))
            #expect(moment.clipID == id)
            #expect(abs(moment.time - source) < 0.0001)
        }
        second.transIn = nil
        let hardCut = WizardPreviewClips.rendered(Fixtures.timelineDocument(clips: [first, second]),
            take: take, name: "Opening", scenes: [scene], xfadeDuration: 0.4)
        #expect(WizardPreviewClips.moment(in: hardCut, at: 2.8)?.clipID == "take-11-0")
    }

    @Test("autoplay finds the requested take after failures, or nothing when that take failed")
    func requestedTakeSurvivesPartialFailure() {
        let first = RoughCut(url: URL(fileURLWithPath: "/tmp/first.mp4"), name: "First", duration: 3, takeID: 11)
        let second = RoughCut(url: URL(fileURLWithPath: "/tmp/second.mp4"), name: "Second", duration: 3, takeID: 12)
        var review = RoughCutReview(projectID: 1, cuts: [first, second], namespace: "full", requestID: UUID(),
                                    framing: Framing(), sourceType: .other, videoIDs: [1], canvasAspect: 9.0 / 16)
        #expect(review.cut(forTake: 12) == second)
        review.cuts = [second]
        #expect(review.cut(forTake: 12) == second)
        #expect(review.cut(forTake: 11) == nil)
        review.cuts = []
        #expect(review.cut(forTake: 12) == nil)
    }

    @Test("a small canvas keeps its aspect: one factor for both sides, floor on the short side")
    func smallCanvasFloor() {
        var options = WizardOptions()
        options.renderSettings.preset = .custom
        options.renderSettings.customWidth = 500
        options.renderSettings.customHeight = 250
        let rough = WizardRoughCut.options(options)
        #expect(rough.renderSettings.width == 480 && rough.renderSettings.height == 240)
        options.renderSettings.customWidth = 300
        options.renderSettings.customHeight = 240
        let tiny = WizardRoughCut.options(options)
        #expect(tiny.renderSettings.width == 300 && tiny.renderSettings.height == 240, "never upscaled")
    }

    @Test("the built document loses overlays, sound, dub, effects, cutaways and captions")
    func stripDocument() {
        var document = TimelineDocument()
        var card = TimelineClip()
        card.videoFile = "/tmp/cards/intro_card.mp4"
        card.duration = 2
        var main = TimelineClip()
        main.sceneID = 7
        main.startTime = 2
        main.duration = 5
        main.captions = "bottom"
        main.effect = EffectSpec(preset: "vintage")
        main.transIn = "fade"
        main.transOut = "fadeblack"
        var cutaway = TimelineClip()
        cutaway.role = .cutaway
        cutaway.track = 1
        document.videoTrack = [card, main, cutaway]
        document.textOverlays = [TextOverlayItem()]
        document.overlayBlocks = [OverlayBlockItem()]
        document.soundTrack = [SoundItem()]
        document.dub = DubSettings(language: "pt")
        document.renderSettings.speechPolish = SpeechPolishSettings()

        let rough = WizardRoughCut.strip(document)
        #expect(rough.videoTrack.count == 1 && rough.videoTrack[0].sceneID == 7, "card and cutaway gone")
        #expect(rough.videoTrack[0].startTime == 0, "the card's gap closes")
        #expect(rough.videoTrack[0].captions == "none" && rough.videoTrack[0].effect == nil)
        #expect(rough.videoTrack[0].transIn == nil && rough.videoTrack[0].transOut == nil)
        #expect(rough.textOverlays.isEmpty && rough.overlayBlocks.isEmpty && rough.soundTrack.isEmpty)
        #expect(rough.dub == nil && rough.renderSettings.speechPolish == nil)
    }
}
