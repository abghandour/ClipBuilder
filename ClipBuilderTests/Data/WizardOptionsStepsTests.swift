import Foundation
import Testing
@testable import Clip_Builder

@Suite("Wizard options steps")
struct WizardOptionsStepsTests {
    @Test func splitRoundTripKeepsEveryPersistedOption() throws {
        var options = WizardOptions()
        options.sourceSceneSelection = true
        options.sourcesRestricted = true
        options.sourceSceneIDs = [7, 9]
        options.sourceVideoPaths = ["/tmp/source.mp4"]
        options.selectedRunIDs = [4]
        options.sourcePeople = ["guest"]
        options.projectID = 12
        options.formatPreset = "interview"
        options.targetDurationSeconds = 24
        options.highlightMaxSeconds = 42
        options.highlightMaxCount = 5
        options.aiInstructions = "Start with the answer"
        options.pinnedOverlayText = "Keep these words"
        options.pinnedOverlayTemplate = "Custom look"
        options.templateJSON = "{}"
        options.templateLabel = "Reference"
        options.tastePreset = "none"
        options.modelOverride = "fixture"
        options.screenCropLayouts = ["Two up"]
        options.musicFolder = "Quiet"
        options.musicTrack = "Quiet/Track"
        options.overlayStyle = "minimal"
        options.overlayAnimation = "fade"
        options.overlayPlacement = "bottom"
        options.captionLanguage = "pt"
        options.nameTags = true
        options.nameTagContent = "nameAndRole"
        options.nameTagStyle = "Guest look"
        options.nameTagPosition = "topTrailing"
        options.allowedTransitions = ["fade"]
        options.highlightFraming = .grid
        options.pacing = EditPacing(cadence: .threeSeconds, curve: .accelerate)
        options.brollInstructions = "Show the venue"
        options.localHashtags = true
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let step1 = try JSONDecoder().decode(WizardStep1Options.self, from: encoder.encode(options.step1))
        let step2 = try JSONDecoder().decode(WizardStep2Options.self, from: encoder.encode(options.step2))
        let merged = WizardOptions.merge(step1: step1, step2: step2)
        #expect(merged.sourceSceneIDs == options.sourceSceneIDs)
        #expect(merged.sourceVideoPaths == options.sourceVideoPaths)
        #expect(merged.selectedRunIDs == options.selectedRunIDs)
        var originalJSON = try #require(JSONSerialization.jsonObject(with: encoder.encode(options)) as? [String: Any])
        var mergedJSON = try #require(JSONSerialization.jsonObject(with: encoder.encode(merged)) as? [String: Any])
        // Set iteration order is intentionally unspecified by Codable.
        for key in ["sourceSceneIDs", "sourceVideoPaths", "selectedRunIDs"] {
            originalJSON.removeValue(forKey: key)
            mergedJSON.removeValue(forKey: key)
        }
        #expect(NSDictionary(dictionary: mergedJSON).isEqual(to: originalJSON))
        #expect(merged.localHashtags)
        let first = try #require(JSONSerialization.jsonObject(with: encoder.encode(step1)) as? [String: Any])
        let second = try #require(JSONSerialization.jsonObject(with: encoder.encode(step2)) as? [String: Any])
        #expect(Set(first.keys).isDisjoint(with: Set(second.keys)))
        #expect(first["pacing"] == nil && first["musicTrack"] == nil)
        #expect(second["sourceSceneIDs"] == nil && second["pinnedOverlayText"] == nil)
    }

    @Test func emptySubsetsAndOldRunSettingsDecode() throws {
        let decoder = JSONDecoder()
        let step1 = try decoder.decode(WizardStep1Options.self, from: Data("{}".utf8))
        let step2 = try decoder.decode(WizardStep2Options.self, from: Data("{}".utf8))
        let merged = WizardOptions.merge(step1: step1, step2: step2)
        #expect(merged.useMusic && merged.useBRoll && merged.critiqueLoop)
        #expect(step2.nameTags == nil && step2.nameTagContent == nil && step2.nameTagStyle == nil && step2.nameTagPosition == nil)
        let legacy = try decoder.decode(WizardOptions.self, from: Data("{}".utf8))
        #expect(legacy.nameTags == nil && legacy.nameTagContent == nil && legacy.nameTagStyle == nil && legacy.nameTagPosition == nil)
        #expect(merged.pacing == EditPacing())
        var original = WizardRunSettings(options: WizardOptions())
        original.options.musicTrack = "New track"
        original.options.overlayStyle = "minimal"
        original.options.overlayAnimation = "fade"
        original.options.overlayPlacement = "bottom"
        let data = try JSONEncoder().encode(original)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var options = try #require(json["options"] as? [String: Any])
        for key in ["musicTrack", "overlayStyle", "overlayAnimation", "overlayPlacement"] {
            options.removeValue(forKey: key)
        }
        json["options"] = options
        let decoded = try decoder.decode(WizardRunSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.options.musicTrack == nil && decoded.options.overlayStyle == nil)
        #expect(decoded.options.critiqueMaxVersions == original.options.critiqueMaxVersions)
    }

    @Test func changingLookKeepsSelectionAndClearsOptionalChoices() {
        var original = WizardOptions()
        original.sourceSceneIDs = [1, 2]
        original.aiInstructions = "Keep the finish"
        original.musicTrack = "Old track"
        var look = original.step2
        look.musicTrack = nil
        look.addCaptions = true
        look.pacing = EditPacing(cadence: .twoSeconds)
        let changed = WizardOptions.merge(step1: original.step1, step2: look, base: original)
        #expect(changed.sourceSceneIDs == [1, 2])
        #expect(changed.aiInstructions == original.aiInstructions)
        #expect(changed.addCaptions && changed.musicTrack == nil)
        #expect(changed.pacing.cadence == .twoSeconds)
    }

    @Test func profileMusicDefaultIsAdditive() throws {
        let decoder = JSONDecoder()
        var profile = try decoder.decode(BrandProfile.self, from: Data(#"{"profile_name":"Legacy"}"#.utf8))
        #expect(profile.defaultMusicVolume == nil)
        profile.defaultMusicVolume = 2
        let data = try JSONEncoder().encode(profile)
        #expect(try decoder.decode(BrandProfile.self, from: data).defaultMusicVolume == 2)
    }

}
