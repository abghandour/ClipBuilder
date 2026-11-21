import Foundation
import Testing
@testable import Clip_Builder

struct WizardOptionsTests {
    @MainActor @Test func strikeImpactFreezeRoundTripsAndTravelsThroughPreferences() throws {
        let old = try JSONDecoder().decode(WizardOptions.self, from: Data("{}".utf8))
        #expect(old.strikeImpactFreeze == nil)
        #expect(try JSONDecoder().decode(WizardStep2Options.self, from: Data("{}".utf8)).strikeImpactFreeze == nil)
        var options = old
        options.strikeImpactFreeze = 1.2
        #expect(try JSONDecoder().decode(WizardOptions.self, from: JSONEncoder().encode(options)).strikeImpactFreeze == 1.2)
        let step = try JSONDecoder().decode(WizardStep2Options.self, from: JSONEncoder().encode(options.step2))
        #expect(WizardOptions.merge(step1: options.step1, step2: step).strikeImpactFreeze == 1.2)
        #expect(WizardOptions.merge(step1: options.step1, step2: .init(), base: options).strikeImpactFreeze == nil)
        let suite = "wizard-strike-pause-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AISettingsPreferences.write(["strikeImpactFreeze": .number(1.2)], kind: .wizard, scopes: [.options], defaults: defaults)
        let fields = AISettingsPreferences.wizard(defaults: defaults, profile: Fixtures.brand())
        #expect(fields["strikeImpactFreeze"] == .number(1.2))
        #expect(WizardPresetStore.presetFields(fields)["strikeImpactFreeze"] == .number(1.2))
    }

    @Test func strikeHighlightsRoundTripAndAbsentKey() throws {
        let old = try JSONDecoder().decode(WizardOptions.self, from: Data("{}".utf8))
        #expect(old.strikeHighlights == nil)
        #expect(try JSONDecoder().decode(WizardStep2Options.self, from: Data("{}".utf8)).strikeHighlights == nil)
        let absent = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        #expect(absent["strikeHighlights"] == nil && absent["strikeStats"] == nil)
        let absentStep = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old.step2)) as? [String: Any])
        #expect(absentStep["strikeHighlights"] == nil)
        for enabled in [true, false] {
            var options = old
            options.strikeHighlights = enabled
            options.strikeStats = false
            let data = try JSONEncoder().encode(options)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["strikeHighlights"] as? Bool == enabled)
            let decoded = try JSONDecoder().decode(WizardOptions.self, from: data)
            #expect(decoded.strikeHighlights == enabled && decoded.strikeStats == false)
            let step = try JSONDecoder().decode(WizardStep2Options.self, from: JSONEncoder().encode(options.step2))
            #expect(step.strikeHighlights == enabled)
            #expect(WizardOptions.merge(step1: options.step1, step2: step).strikeHighlights == enabled)
            #expect(WizardOptions.merge(step1: options.step1, step2: WizardStep2Options(), base: options).strikeHighlights == nil)
        }
    }

    @MainActor @Test func strikeHighlightsSurvivePreferencesRememberedLookAndPresets() throws {
        let suite = "wizard-strike-highlights-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fields: [String: JSONSetting] = ["strikeHighlights": .bool(true), "strikeStats": .bool(false)]
        AISettingsPreferences.write(fields, kind: .wizard, scopes: [.options], defaults: defaults)
        #expect(defaults.bool(forKey: "wizard.strikeHighlights"))
        let profile = Fixtures.brand()
        WizardMemory.remember(profile: profile, renderSettings: nil, pacing: nil, defaults: defaults)
        let read = AISettingsPreferences.wizard(defaults: defaults, profile: profile)
        #expect(read["strikeHighlights"] == .bool(true) && read["strikeStats"] == .bool(false))
        let preset = WizardPresetStore.presetFields(read)
        #expect(preset["strikeHighlights"] == .bool(true))
        let loaded = WizardPresetStore.Loaded(name: "Fight", settings: preset)
        var changed = preset
        changed["strikeHighlights"] = .bool(false)
        #expect(WizardPresetStore.cardTitle(loaded: loaded, current: changed)
            != WizardPresetStore.cardTitle(loaded: loaded, current: preset))
        AISettingsPreferences.write(changed, kind: .wizard, scopes: [.options], defaults: defaults)
        #expect(!defaults.bool(forKey: "wizard.strikeHighlights"))
        WizardMemory.restore(profileName: profile.profileName, defaults: defaults)
        #expect(defaults.bool(forKey: "wizard.strikeHighlights"))
        defaults.set(false, forKey: "wizard.strikeHighlights")
        AISettingsPreferences.write(preset, kind: .wizard, scopes: [.options], defaults: defaults)
        #expect(defaults.bool(forKey: "wizard.strikeHighlights"))
    }

    @MainActor @Test func expressOwnsStrikeHighlightsAndTheyStayOutOfPlainRoughCuts() {
        var options = WizardOptions()
        options.strikeStats = true
        options.strikeHighlights = true
        let preview = MiniWizardSettings().previewOptions(profile: Fixtures.brand(), base: options)
        #expect(preview.strikeStats == true && preview.strikeHighlights == false)
        let rough = WizardRoughCut.options(options)
        #expect(rough.strikeStats == false && rough.strikeHighlights == false)
    }

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
