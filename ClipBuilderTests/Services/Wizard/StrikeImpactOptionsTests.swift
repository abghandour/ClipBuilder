import Foundation
import Testing
@testable import Clip_Builder

@Suite("Strike impact settings")
struct StrikeImpactOptionsTests {
    @MainActor @Test func optionsStepsPreferencesAndPresets() throws {
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        let old = try decoder.decode(WizardOptions.self, from: Data("{}".utf8))
        #expect(old.strikeSlowMotion == nil && old.strikeFlash == nil)
        let oldStep = try decoder.decode(WizardStep2Options.self, from: Data("{}".utf8))
        #expect(oldStep.strikeSlowMotion == nil && oldStep.strikeFlash == nil)
        let plain = try #require(JSONSerialization.jsonObject(with: encoder.encode(old)) as? [String: Any])
        #expect(plain["strikeSlowMotion"] == nil && plain["strikeFlash"] == nil)
        var options = old
        options.strikeSlowMotion = "medium"
        options.strikeFlash = true
        let decoded = try decoder.decode(WizardOptions.self, from: encoder.encode(options))
        #expect(decoded.strikeSlowMotion == "medium" && decoded.strikeFlash == true)
        let step = try decoder.decode(WizardStep2Options.self, from: encoder.encode(options.step2))
        let merged = WizardOptions.merge(step1: options.step1, step2: step)
        #expect(merged.strikeSlowMotion == "medium" && merged.strikeFlash == true)
        let reset = WizardOptions.merge(step1: options.step1, step2: .init(), base: options)
        #expect(reset.strikeSlowMotion == nil && reset.strikeFlash == nil)
        let request = MiniStrikeStatusRequest(dataKey: "impact", videoID: 1, isFight: true,
            clips: [], options: old, xfadeDuration: 0.3)
        var changed = request
        changed.options.strikeSlowMotion = "medium"
        #expect(changed != request && changed.visible)
        changed = request
        changed.options.strikeFlash = true
        #expect(changed != request && changed.visible)
        let suite = "impact-options-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AISettingsPreferences.write(["strikeSlowMotion": .string("strong"), "strikeFlash": .bool(true)],
            kind: .wizard, scopes: [.options], defaults: defaults)
        let fields = AISettingsPreferences.wizard(defaults: defaults, profile: Fixtures.brand())
        #expect(fields["strikeSlowMotion"] == .string("strong"))
        #expect(fields["strikeFlash"] == .bool(true))
        let preset = WizardPresetStore.presetFields(fields)
        #expect(preset["strikeSlowMotion"] == .string("strong") && preset["strikeFlash"] == .bool(true))
    }

    @Test func miniMemoryBridgeAndAdoption() throws {
        let old = try JSONDecoder().decode(MiniWizardSettings.self, from: Data("{}".utf8))
        #expect(old.slowIntoContact == nil && old.slowIntoContactStrength == nil && old.flashOnContact == nil)
        #expect(old.resolvedSlowIntoContactStrength == "medium")
        let plain = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        #expect(plain["slowIntoContact"] == nil && plain["flashOnContact"] == nil)
        let plainFields = WizardPresetBridge.wizardFields(from: old)
        // Off is sent explicitly, so an untouched Express preset switches the Wizard's effects off.
        #expect(plainFields["strikeSlowMotion"] == .null && plainFields["strikeFlash"] == .null)
        let back = WizardPresetBridge.miniSettings(from: plainFields)
        #expect(back.slowIntoContact != true && back.flashOnContact != true)
        #expect(StrikeImpactRules.strength(saved: "") == nil)
        #expect(StrikeImpactRules.strength(saved: "bogus") == "medium")
        #expect(StrikeImpactRules.strength(saved: "strong") == "strong")
        var settings = old
        settings.slowIntoContact = true
        settings.slowIntoContactStrength = "strong"
        settings.flashOnContact = true
        let decoded = try JSONDecoder().decode(MiniWizardSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        let step = decoded.step2Options(base: .init())
        #expect(step.strikeSlowMotion == "strong" && step.strikeFlash == true)
        let adopted = old.adoptingOverlays(from: settings)
        #expect(adopted.slowIntoContact == true && adopted.flashOnContact == true)
        #expect(old.adoptingOverlays(from: settings, strikeActions: false).slowIntoContact == nil)
        let bridged = WizardPresetBridge.miniSettings(from: WizardPresetBridge.wizardFields(from: settings))
        #expect(bridged.slowIntoContact == true && bridged.slowIntoContactStrength == "strong" && bridged.flashOnContact == true)
        settings.slowIntoContact = false
        let off = WizardPresetBridge.miniSettings(from: WizardPresetBridge.wizardFields(from: settings))
        #expect(off.slowIntoContact == false && off.slowIntoContactStrength == "strong")
        let suite = "mini-impact-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.remember(profileName: Fixtures.brand().profileName, defaults: defaults)
        let remembered = MiniWizardSettings.remembered(profile: Fixtures.brand(), defaults: defaults)
        #expect(remembered.slowIntoContact == false && remembered.slowIntoContactStrength == "strong" && remembered.flashOnContact == true)
    }

    @Test(arguments: VideoType.allCases)
    func flowAndRoughCut(type: VideoType) {
        var video = Fixtures.video()
        video.videoType = type.rawValue
        var mini = MiniWizardSettings()
        mini.slowIntoContact = true
        mini.flashOnContact = true
        for scored in [true, false] {
            let flow = MiniWizardFlow(video: video, hasScoredStrikes: scored)
            let visible = type == .fight && scored
            let step = mini.effective(for: flow, introAvailable: false, outroAvailable: false).step2Options(base: .init())
            #expect(step.strikeSlowMotion == (visible ? "medium" : nil))
            #expect(step.strikeFlash == (visible ? true : nil))
        }
        var options = WizardOptions()
        options.strikeSlowMotion = "medium"
        options.strikeFlash = true
        let plain = WizardRoughCut.options(options)
        #expect(plain.strikeSlowMotion == "medium" && plain.strikeFlash == true)
        for visible in [false, true] {
            let extras = RoughCutExtras(overlays: .init(settings: mini, showsStrikeActions: visible))
            let rough = WizardRoughCut.options(options, extras: extras)
            let final = WizardRoughCut.pauseEligibilityOptions(options, extras: extras, oneReel: false)
            #expect(rough.strikeSlowMotion == (visible ? "medium" : nil))
            #expect(final.strikeFlash == (visible ? true : nil))
            let eligible = WizardStrikePauses.eligibilityOptions(rough, original: options)
            #expect(eligible.strikeSlowMotion == rough.strikeSlowMotion && eligible.strikeFlash == rough.strikeFlash)
        }
    }
}
