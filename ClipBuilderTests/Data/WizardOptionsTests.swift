import Foundation
import Testing
@testable import Clip_Builder

struct WizardOptionsTests {
    @Test func safeAreaStep2MergeAndLegacyDecode() throws {
        var options = WizardOptions()
        options.safeAreaOnly = true
        options.safeAreaPlatforms = [.instagram, .tiktok]
        options.renderSettings.platformSafeArea.enabled = false
        let encoded = try JSONEncoder().encode(options.step2)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["safe_area_only"] as? Bool == true)
        #expect(object["safe_area_platforms"] as? [String] == ["instagram", "tiktok"])
        let step2 = try JSONDecoder().decode(WizardStep2Options.self, from: encoded)
        let merged = WizardOptions.merge(step1: options.step1, step2: step2)
        #expect(merged.safeAreaOnly == true)
        #expect(merged.safeAreaPlatforms == [.instagram, .tiktok])
        #expect(merged.resolvedSafeArea?.platforms == [.instagram, .tiktok])
        let decoded = try JSONDecoder().decode(WizardOptions.self, from: JSONEncoder().encode(merged))
        #expect(decoded.safeAreaOnly == true && decoded.safeAreaPlatforms == merged.safeAreaPlatforms)
        let old = try JSONDecoder().decode(WizardStep2Options.self, from: Data("{}".utf8))
        #expect(old.safeAreaOnly == nil && old.safeAreaPlatforms == nil)
        options.safeAreaPlatforms = []
        options.renderSettings.platformSafeArea.platforms = [.instagram]
        #expect(options.resolvedSafeArea?.platforms == [.instagram])
        options.safeAreaOnly = false
        #expect(options.resolvedSafeArea == nil)
    }
}

extension WizardOptionsTests {
    @MainActor @Test func safeAreaPresetFieldsReachWizardDefaults() throws {
        let suite = "wizard-safe-area-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fields: [String: JSONSetting] = [
            "safe_area_only": .bool(true),
            "safe_area_platforms": .array([.string("instagram"), .string("tiktok")]),
        ]
        AISettingsPreferences.write(fields, kind: .wizard, scopes: [.options], defaults: defaults)
        #expect(defaults.bool(forKey: "wizard.safeAreaOnly"))
        #expect(defaults.string(forKey: "wizard.safeAreaPlatforms") == "instagram,tiktok")
        let read = AISettingsPreferences.wizard(defaults: defaults, profile: Fixtures.brand())
        #expect(read["safe_area_only"] == fields["safe_area_only"])
        #expect(read["safe_area_platforms"] == fields["safe_area_platforms"])
        AISettingsPreferences.write(["safe_area_platforms": .null], kind: .wizard, scopes: [.options], defaults: defaults)
        #expect(defaults.string(forKey: "wizard.safeAreaPlatforms") == "")
    }
}

extension WizardOptionsTests {
    @Test func speakerPositionsRoundTripThroughOptionsAndPresentationSteps() throws {
        let old = try JSONDecoder().decode(WizardOptions.self, from: Data("{}".utf8))
        #expect(old.speakerCaptionPositions == nil)
        #expect(try JSONDecoder().decode(WizardStep2Options.self, from: Data("{}".utf8)).speakerCaptionPositions == nil)
        var options = old
        options.speakerCaptionPositions = ["speaker1": "top", "speaker2": "custom:0.5000,0.2500"]
        let decoded = try JSONDecoder().decode(WizardOptions.self, from: JSONEncoder().encode(options))
        #expect(decoded.speakerCaptionPositions == options.speakerCaptionPositions)
        let step2 = try JSONDecoder().decode(WizardStep2Options.self, from: JSONEncoder().encode(options.step2))
        #expect(WizardOptions.merge(step1: options.step1, step2: step2).speakerCaptionPositions == options.speakerCaptionPositions)
        #expect(WizardOptions.merge(step1: options.step1, step2: WizardStep2Options(), base: options).speakerCaptionPositions == nil)
    }

    @MainActor @Test func speakerPositionsSurviveWizardPreferencesAndPresetFields() throws {
        let suite = "wizard-speaker-position-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = Fixtures.brand()
        let positions = ["speaker1": "top", "speaker2": "middle"]
        let fields = ["speakerCaptionPositions": JSONSetting.dictionaryValue(positions)]
        AISettingsPreferences.write(fields, kind: .wizard, scopes: [.options], profileName: profile.profileName, defaults: defaults)
        #expect(WizardCaptionChoices.load(profileName: profile.profileName, defaults: defaults).speakerCaptionPositions == positions)
        #expect(AISettingsPreferences.wizard(defaults: defaults, profile: profile)["speakerCaptionPositions"] == fields["speakerCaptionPositions"])
        AISettingsPreferences.write(["speakerCaptionPositions": .null], kind: .wizard, scopes: [.options], profileName: profile.profileName, defaults: defaults)
        #expect(WizardCaptionChoices.load(profileName: profile.profileName, defaults: defaults).speakerCaptionPositions == nil)
    }
}
