import Foundation
import Testing
@testable import Clip_Builder

@Suite("Framing models and migration")
struct FramingTests {
    @Test(arguments: CropRecipe.Kind.allCases)
    func convertsEveryLegacyRecipe(_ kind: CropRecipe.Kind) {
        var old = WizardOptions()
        old.highlightFraming = kind
        old.interviewZoom = 0.65
        old.interviewCuts = true
        let expected: Framing
        switch kind {
        case .vip, .vipBRoll: expected = Framing(subject: .vipFocus)
        case .grid: expected = Framing(subject: .layout, layout: "Split")
        case .talker, .interview, .talkerAndRest, .talkerAndPrevious, .talkerAndRotation:
            expected = Framing(subject: .speakerFocus, pullBack: 0.65, moves: .cuts)
        }
        #expect(Framing.legacy(from: old) == expected)
        old.interviewCuts = nil
        old.interviewZoom = nil
        let defaults = Framing.legacy(from: old)
        #expect(defaults.moves == .smooth && defaults.pullBack == 0)
    }

    @Test func originalWinsAndRemovedControlsDoNotInventAChoice() {
        var old = WizardOptions()
        #expect(Framing.legacy(from: old) == Framing())
        old.interviewPunchIn = "interviewer"
        old.interviewZoomMoves = true
        old.framingCamera = "fastAction"
        #expect(Framing.legacy(from: old) == Framing())
        old.highlightFraming = .vip
        old.podcastFraming = .original
        #expect(Framing.legacy(from: old) == Framing(subject: .original, fit: .fill))
        old.framing = Framing(subject: .centerStage, fit: .blurredFill)
        #expect(Framing.legacy(from: old) == old.framing)
        old.framing = Framing()
        #expect(Framing.legacy(from: old) == Framing())
    }

    @Test(arguments: VideoType.allCases)
    func menuMatchesTheTable(_ type: VideoType) {
        let subjects: [Framing.Subject]
        switch type {
        case .fight: subjects = [.original, .vipFocus]
        case .training: subjects = [.original, .centerStage]
        case .podcast: subjects = [.auto, .speakerFocus, .centerStage, .layout, .original]
        case .interview: subjects = [.speakerFocus, .centerStage, .layout, .auto, .original]
        case .screen: subjects = [.layout, .original]
        case .recap, .other: subjects = [.speakerFocus, .layout, .original]
        }
        #expect(FramingMenu.allowed(type: type) == subjects)
        #expect(FramingMenu.default(type: type).subject == subjects.first)
        #expect(FramingMenu.default(type: type).fit == (type == .fight || type == .training || type == .screen ? .blurredFill : .fill))
    }

    @Test func jsonDefaultsAndSnakeCaseRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        #expect(try decoder.decode(Framing.self, from: Data("{}".utf8)) == Framing())
        #expect(try encoder.encode(Framing()) == Data("{}".utf8))
        let nulls = #"{"subject":null,"pull_back":null,"moves":null,"fit":null,"feather":null,"blur":null,"focus_frame":null,"lock_aspect":null,"layout":null}"#
        #expect(try decoder.decode(Framing.self, from: Data(nulls.utf8)) == Framing())
        let framing = Framing(subject: .layout, pullBack: 0.7, moves: .cuts, fit: .blurredFill,
                              feather: 0.15, blur: 0.9, focusFrame: FreeCropRect(wFrac: 0.5), layout: "Split")
        let data = try encoder.encode(framing)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["pull_back"] as? Double == 0.7 && json["focus_frame"] != nil)
        #expect(try decoder.decode(Framing.self, from: data) == framing)
        #expect(Framing.split(framing.joined) == framing)
    }

    @Test(arguments: [false, true])
    func aspectLockRoundTripsThroughJSONAndExpressMemory(_ locked: Bool) throws {
        let framing = Framing(subject: .original, fit: .blurredFill,
            focusFrame: FreeCropRect(xFrac: 0.1, wFrac: 0.8), lockAspect: locked)
        let data = try JSONEncoder().encode(framing)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["lock_aspect"] as? Bool == locked)
        #expect(json["lockAspect"] == nil)
        #expect(try JSONDecoder().decode(Framing.self, from: data) == framing)
        #expect(Framing.split(framing.joined) == framing)
        var legacy = framing
        legacy.lockAspect = nil
        #expect(legacy != framing)
        #expect(Set([legacy, framing]).count == 2)
    }

    @Test func peopleRoundTripsAndDefaultsToEveryone() throws {
        #expect(try JSONDecoder().decode(Framing.self, from: Data(#"{"subject":"centerStage"}"#.utf8)).people == nil)
        let framing = Framing(subject: .centerStage, people: .vips)
        let json = try #require(JSONSerialization.jsonObject(with: try JSONEncoder().encode(framing)) as? [String: Any])
        #expect(json["people"] as? String == "vips")
        #expect(Framing.split(framing.joined) == framing)
        #expect(!Framing(subject: .centerStage).joined.contains("people"))
        let chosen = Framing(subject: .centerStage, people: .vips, vips: ["a", "b"])
        #expect(Framing.split(chosen.joined) == chosen)
        #expect(chosen.joined.contains(#""vips":["a","b"]"#))
        for type in VideoType.allCases {
            for subject in FramingMenu.allowed(type: type) { #expect(!subject.summary(type: type).isEmpty) }
        }
        #expect(FramingMenu.virtualLayouts.allSatisfy { FramingMenu.virtualLayoutSummary($0) != nil })
    }

    @Test func missingAspectLockKeepsLegacyFramingLocked() throws {
        let data = Data(#"{"subject":"original","fit":"blurredFill"}"#.utf8)
        let framing = try JSONDecoder().decode(Framing.self, from: data)
        #expect(framing.lockAspect == nil)
        #expect(FocusFrame.handleAspectLocked(framing: framing))
        #expect(!framing.joined.contains("lock_aspect"))
        #expect(Framing.split(framing.joined) == framing)
    }

    @Test func freeWindowSurvivesWizardAndPresetSettingsBridges() throws {
        let profile = Fixtures.brand()
        var mini = MiniWizardSettings()
        mini.framing = Framing(subject: .original, fit: .blurredFill,
            focusFrame: FreeCropRect(xFrac: 0.25, yFrac: 0.25, wFrac: 0.5, hFrac: 0.5), lockAspect: false)
        #expect(try JSONDecoder().decode(MiniWizardSettings.self, from: JSONEncoder().encode(mini)).framing == mini.framing)
        var options = mini.previewOptions(profile: profile)
        #expect(options.requestedFraming == mini.framing)
        #expect(try JSONDecoder().decode(WizardOptions.self, from: JSONEncoder().encode(options)).framing == mini.framing)
        let step = try JSONDecoder().decode(WizardStep2Options.self, from: JSONEncoder().encode(options.step2))
        #expect(WizardOptions.merge(step1: options.step1, step2: step).framing == mini.framing)
        #expect(WizardPresetBridge.miniSettings(from: WizardPresetBridge.wizardFields(from: mini)).framing == mini.framing)
        let suite = "FramingTests.freeWindow.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        mini.remember(profileName: profile.profileName, defaults: defaults)
        #expect(MiniWizardSettings.remembered(profile: profile, defaults: defaults).framing == mini.framing)
        WizardExpressExtras.apply(to: &options, defaults: defaults)
        var restored = WizardOptions()
        WizardExpressExtras.apply(to: &restored, defaults: defaults)
        #expect(restored.requestedFraming == mini.framing)
    }

    private var plans: [FramingPlan] {
        let window = FreeCropRect(xFrac: 0.2, wFrac: 0.6)
        var recipe = CropRecipe(kind: .interview)
        recipe.slots = [.vip, .recent(1)]
        recipe.interviewZoom = 0.4
        recipe.interviewCuts = true
        let layout = ScreenCropLayout(name: "Split", areas: [ScreenCropArea(name: "Top", points: [
            ScreenCropPoint(x: 0, y: 0), ScreenCropPoint(x: 1, y: 0),
            ScreenCropPoint(x: 1, y: 0.5), ScreenCropPoint(x: 0, y: 0.5),
        ])])
        return [
            .static(window: window, fit: .blurredFill, feather: 0.12, blur: 0.9),
            .tracked(recipe, region: window, fit: .fill, feather: 0.08, blur: 0.5),
            .composed(layout: layout, areas: [
                AreaSegment(areaID: "Top", sourceID: 12, sourcePath: "/main.mov", start: 3, duration: 8,
                            role: .vip, framing: .recipe(recipe), audio: .program),
                AreaSegment(areaID: "Bottom", sourceID: nil, sourcePath: "/broll.mov", start: 15, duration: 2,
                            role: .broll, framing: .static(window: window), audio: .muted),
            ], fit: .blurredFill),
        ]
    }

    @Test func everyPlanRoundTripsWithItsDiscriminatorAndSnapshot() throws {
        for (plan, kind) in zip(plans, ["static", "tracked", "composed"]) {
            let data = try JSONEncoder().encode(plan)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["kind"] as? String == kind)
            #expect(try JSONDecoder().decode(FramingPlan.self, from: data) == plan)
        }
    }

    @Test func timelineRoundTripAndEqualityIncludeThePlan() throws {
        for plan in plans {
            var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 2, duration: 4)
            clip.videoFile = "/main.mov"
            clip.framingPlan = plan
            let data = try JSONEncoder().encode(clip)
            #expect(String(decoding: data, as: UTF8.self).contains("framing_plan"))
            var back = try JSONDecoder().decode(TimelineClip.self, from: data)
            back.uid = clip.uid // UI-only identity is regenerated when loading.
            #expect(back == clip)
            back.framingPlan = nil
            #expect(back != clip)
        }
        #expect(try JSONDecoder().decode(TimelineClip.self, from: Data(#"{"id":1}"#.utf8)).framingPlan == nil)
    }

    @Test func wizardOptionsMigrateAtFinalizationAndSurviveStepMerging() throws {
        let old = try JSONDecoder().decode(WizardOptions.self, from: Data(#"{"highlightFraming":"interview_focus","interviewZoom":0.4,"interviewCuts":true}"#.utf8))
        #expect(old.framing == nil)
        let finalized = old.neutralized(for: .custom)
        #expect(finalized.framing == Framing(subject: .speakerFocus, pullBack: 0.4, moves: .cuts))
        #expect(finalized.neutralized(for: .custom).framing == finalized.framing)
        let step2 = try JSONDecoder().decode(WizardStep2Options.self, from: JSONEncoder().encode(finalized.step2))
        let merged = WizardOptions.merge(step1: finalized.step1, step2: step2, base: WizardOptions())
        #expect(merged.framing == finalized.framing)
        #expect(try JSONDecoder().decode(WizardOptions.self, from: JSONEncoder().encode(merged)).framing == finalized.framing)
        var mini = MiniWizardSettings()
        mini.framing = Framing(subject: .centerStage, fit: .blurredFill)
        #expect(mini.previewOptions(profile: Fixtures.brand()).framing == mini.framing)
    }

    @Test func expressDecodesOldChoicesButHonorsAnExplicitDefault() throws {
        for (json, expected) in [
            (#"{}"#, Framing()),
            (#"{"cameraFocus":"original"}"#, Framing(subject: .original)),
            (#"{"cameraFocus":"interview_focus","interviewZoom":0.6,"interviewCuts":true}"#, Framing(subject: .speakerFocus, pullBack: 0.6, moves: .cuts)),
            (#"{"highlightFraming":"vip_broll"}"#, Framing(subject: .vipFocus)),
            (#"{"podcastFraming":"original"}"#, Framing(subject: .original)),
            (#"{"cameraFocus":"grid"}"#, Framing(subject: .layout, layout: "Split")),
            (#"{"cameraFocus":"grid","framing":{}}"#, Framing()),
        ] {
            let settings = try JSONDecoder().decode(MiniWizardSettings.self, from: Data(json.utf8))
            #expect(settings.framing == expected)
            #expect(try JSONDecoder().decode(MiniWizardSettings.self, from: JSONEncoder().encode(settings)).framing == expected)
        }
    }

    @Test func sharedHoldPoliciesKeepTheirExistingValues() {
        #expect(VIPRotation.every == 6 && VIPRotation.minimumHold == 4 && VIPRotation.tail == 2.5)
        #expect(CropRecipe(kind: .talker).minimumHold == 1.5)
        #expect(InterviewFocusPlanning.moveSeconds == 0.8)
    }

    @Test func framingInvalidatesThePreviewRequest() {
        var options = WizardOptions()
        func key() -> PreviewKey {
            PreviewKey(options: options, scene: Fixtures.scene(), profile: Fixtures.brand(), contentRevision: 0, overlayTexts: [])
        }
        let original = key()
        options.framing = Framing(subject: .original, fit: .blurredFill)
        #expect(key() != original)
        let blurred = key()
        options.framing?.blur = 0.9
        #expect(key() != blurred)
    }
}
