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
