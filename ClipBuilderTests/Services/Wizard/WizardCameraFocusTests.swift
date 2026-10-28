import Foundation
import Testing
@testable import Clip_Builder

@Suite("Wizard camera focus")
struct WizardCameraFocusTests {
    @Test func legacySelectionMapping() {
        for stored in ["", "talker", "talker_and_previous"] {
            #expect(WizardCameraFocus.migratedSelection(cameraFocus: stored, legacyPodcastFraming: "split_zoom") == "grid")
            #expect(WizardCameraFocus.migratedSelection(cameraFocus: stored, legacyPodcastFraming: "original") == "original")
            #expect(WizardCameraFocus.migratedSelection(cameraFocus: stored, legacyPodcastFraming: "follow_speaker") == stored)
            #expect(WizardCameraFocus.migratedSelection(cameraFocus: stored, legacyPodcastFraming: nil) == stored)
        }
    }

    @Test func migrationRunsOnce() throws {
        let suite = "CameraFocusMigration-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("split_zoom", forKey: "wizard.podcastFraming")
        WizardDefaults.migrateLegacy(defaults: defaults)
        #expect(Framing.split(defaults.string(forKey: WizardExpressExtras.framingKey))?.subject == .layout)
        #expect(Framing.split(defaults.string(forKey: WizardExpressExtras.framingKey))?.layout == "Split")
        defaults.set("talker_and_rotation", forKey: "wizard.highlightFraming")
        WizardDefaults.migrateLegacy(defaults: defaults)
        #expect(defaults.string(forKey: "wizard.highlightFraming") == "talker_and_rotation")
    }

    @Test func podcastOptionsSurviveAndFightOptionsClear() throws {
        for kind in CropRecipe.Kind.allCases {
            var options = WizardOptions()
            options.highlightFraming = kind
            options.podcastFraming = .original
            let podcast = options.neutralized(for: .podcast)
            #expect(podcast.highlightFraming == kind && podcast.podcastFraming == .original)
            let fight = options.neutralized(for: .mmaFinish)
            #expect(fight.highlightFraming == nil && fight.podcastFraming == .followSpeaker)
            let restored = try JSONDecoder().decode(WizardOptions.self, from: JSONEncoder().encode(podcast))
            #expect(restored.framing?.subject == .original)
        }
    }

    @Test func oldOptionsDecode() throws {
        func decode(_ json: String) throws -> WizardOptions {
            try JSONDecoder().decode(WizardOptions.self, from: Data(json.utf8))
        }
        let empty = try decode("{}")
        #expect(empty.highlightFraming == nil && empty.podcastFraming == .followSpeaker)
        let split = try decode(#"{"podcastFraming":"split_zoom"}"#)
        #expect(split.highlightFraming == .grid && split.podcastFraming == .followSpeaker)
        let original = try decode(#"{"podcastFraming":"original"}"#)
        #expect(original.podcastFraming == .original)
        let follow = try decode(#"{"podcastFraming":"follow_speaker","highlightFraming":"talker_and_rest"}"#)
        #expect(follow.highlightFraming == .talkerAndRest)
    }

    @MainActor @Test func copyPasteAndPipelineKeepCameraFocus() throws {
        let suite = "CameraFocusSettings-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for kind in CropRecipe.Kind.allCases {
            for original in [false, true] {
                var options = WizardOptions()
                options.formatPreset = "podcast"
                options.highlightFraming = kind
                options.podcastFraming = original ? .original : .followSpeaker
                AISettingsPreferences.write(JSONSetting.dictionary(options), kind: .wizard, defaults: defaults)
                let exported = AISettingsPreferences.wizard(defaults: defaults, profile: Fixtures.brand())
                let restored = try JSONDecoder().decode(WizardOptions.self, from: JSONEncoder().encode(exported))
                let pipeline = AppStore.wizardOptionsFromForm(transcriptsAvailable: true, defaults: defaults)
                #expect(restored.framing == options.requestedFraming && pipeline.framing == options.requestedFraming)
                #expect(restored.requestedFraming.subject == options.requestedFraming.subject)
            }
        }
        AISettingsPreferences.write(["podcastFraming": .string("split_zoom")], kind: .wizard, defaults: defaults)
        #expect(Framing.split(defaults.string(forKey: WizardExpressExtras.framingKey))?.subject == .layout)
        #expect(Framing.split(defaults.string(forKey: WizardExpressExtras.framingKey))?.layout == "Split")
    }

    @Test func planFramingValidation() async throws {
        let engine = WizardEngine(ai: AIService(config: AppSettings().ai), render: RenderEngine())
        var options = WizardOptions()
        options.formatPreset = "podcast"
        for value in CropRecipe.Kind.allCases.map(\.rawValue) + ["unknown", "", "original"] {
            let raw: [String: Any] = ["clips": [["scene_id": 1, "start": 2, "end": 6]], "framing": value]
            let plan = try #require(await engine.validatePlan(raw, scenes: [1: Fixtures.scene()], musicNames: [], options: options))
            #expect(plan.framing == (Framing.Subject(rawValue: value) ?? .speakerFocus))
        }
        for nullValue in [false, true] {
            let raw: [String: Any] = ["clips": [["scene_id": 1, "start": 2, "end": 6]],
                                      "framing": nullValue ? NSNull() : 42]
            let plan = try #require(await engine.validatePlan(raw, scenes: [1: Fixtures.scene()], musicNames: [], options: options))
            #expect(plan.framing == .speakerFocus)
        }
        let raw: [String: Any] = ["clips": [["scene_id": 1, "start": 2, "end": 6]]]
        let absent = try #require(await engine.validatePlan(raw, scenes: [1: Fixtures.scene()], musicNames: [], options: options))
        #expect(absent.framing == .speakerFocus)
        options.formatPreset = "mma-finish"
        let fightRaw: [String: Any] = ["clips": [["scene_id": 1, "start": 2, "end": 6]], "framing": "grid"]
        let fight = try #require(await engine.validatePlan(fightRaw, scenes: [1: Fixtures.scene()], musicNames: [], options: options))
        #expect(fight.framing == nil)
    }

    @Test func podcastPromptDescribesFraming() async {
        let engine = WizardEngine(ai: AIService(config: AppSettings().ai), render: RenderEngine())
        var options = WizardOptions()
        options.formatPreset = "podcast"
        let prompt = await engine.legacyPlanPrompt(profile: Fixtures.brand(), research: [:],
            scenes: [Fixtures.scene()], musicNames: [], signals: .init(), people: [], outcomes: [], options: options)
        #expect(prompt.contains("optional top-level \"framing\""))
        for subject in FramingMenu.allowed(type: .podcast) where subject != .auto {
            #expect(prompt.contains(subject.rawValue))
        }
    }
}
