import Foundation
import Testing
@testable import Clip_Builder

@Suite("Filler cut options")
struct FillerCutOptionsTests {
    @Test("Old JSON stays off; all three option states survive steps and presets", arguments: [nil, false, true] as [Bool?])
    func roundTrips(enabled: Bool?) throws {
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        let old = try decoder.decode(WizardOptions.self, from: Data("{}".utf8))
        #expect(old.removeFillerWords == nil)
        #expect(try decoder.decode(WizardStep2Options.self, from: Data("{}".utf8)).removeFillerWords == nil)
        #expect(try decoder.decode(MiniWizardSettings.self, from: Data("{}".utf8)).removeFillerWords == nil)
        var options = old
        options.removeFillerWords = enabled
        let decoded = try decoder.decode(WizardOptions.self, from: encoder.encode(options))
        #expect(decoded.removeFillerWords == enabled)
        let step = try decoder.decode(WizardStep2Options.self, from: encoder.encode(decoded.step2))
        #expect(step.removeFillerWords == enabled)
        #expect(WizardOptions.merge(step1: decoded.step1, step2: step, base: old).removeFillerWords == enabled)
        #expect(options.neutralized(for: .podcastHighlights).removeFillerWords == enabled)
        var mini = MiniWizardSettings()
        mini.removeFillerWords = enabled
        mini = try decoder.decode(MiniWizardSettings.self, from: encoder.encode(mini))
        #expect(mini.removeFillerWords == enabled)
        #expect(mini.step2Options(base: old.step2).removeFillerWords == enabled)
        #expect(MiniWizardSettings().adoptingOverlays(from: mini).removeFillerWords == enabled)
        let fields = WizardPresetStore.presetFields(WizardPresetBridge.wizardFields(from: mini))
        let preset = WizardPreset(name: "Speech", savedAt: Date(timeIntervalSince1970: 0), settings: fields)
        let restored = try decoder.decode(WizardPreset.self, from: encoder.encode(preset))
        #expect(restored.settings["removeFillerWords"] == (enabled.map(JSONSetting.bool) ?? .null))
        #expect(WizardPresetBridge.miniSettings(from: restored.settings).removeFillerWords == enabled)
        #expect(AISettingsPreferences.wizardKeys["removeFillerWords"] == "wizard.removeFillerWords")
        let rough = WizardRoughCut.options(options, extras: .init(overlays: .init(settings: mini)))
        #expect(rough.removeFillerWords == enabled)
        #expect(WizardRoughCut.pauseEligibilityOptions(options, extras: .init(overlays: .init(settings: mini)),
            oneReel: true).removeFillerWords == enabled)
    }

    @Test("Express remembers the choice by profile and clears nil")
    func memory() throws {
        let suite = "FillerCutOptionsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = MiniWizardSettings()
        settings.removeFillerWords = true
        settings.remember(profileName: "Speech", defaults: defaults)
        #expect(MiniWizardSettings.remembered(profile: Fixtures.brand(name: "Speech"), defaults: defaults).removeFillerWords == true)
        #expect(MiniWizardSettings.remembered(profile: Fixtures.brand(name: "Other"), defaults: defaults).removeFillerWords == nil)
        let key = MiniWizardMemory.key(for: .removeFillerWords, profileName: "Speech")
        #expect(MiniWizardMemory.field(forKey: key, profileName: "Speech") == .removeFillerWords)
        settings.removeFillerWords = nil
        settings.remember(profileName: "Speech", defaults: defaults)
        #expect(defaults.object(forKey: key) == nil)
    }

    @Test("Hidden transcript settings cannot carry an enabled choice into silent footage")
    func transcriptAvailability() {
        var settings = MiniWizardSettings()
        settings.removeFillerWords = true
        var flow = MiniWizardFlow()
        #expect(settings.effective(for: flow, introAvailable: false, outroAvailable: false).removeFillerWords == false)
        flow.hasTranscript = true
        flow.footageKind = .transcript
        let effective = settings.effective(for: flow, introAvailable: false, outroAvailable: false)
        #expect(effective.removeFillerWords == true)
        let summary = flow.runSummaryCard(candidates: [], exchangeCount: 1, settings: effective)
        #expect(summary.sections.contains { $0.title == "Audio" && $0.items.contains("Filler words cut") })
        #expect(settings.removeFillerWords == true)
    }

    @Test("Saved plans and timelines retain cuts; old clips decode without continuation")
    func renderMetadata() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let old = Fixtures.planClip()
        let legacy = try decoder.decode(WizardPlanClip.self, from: encoder.encode(old))
        #expect(legacy.continuesPrevious == nil)
        var plan = Fixtures.plan(clips: [old])
        plan.clips[0].continuesPrevious = true
        plan.appliedFillerSpans = [7: [2...3]]
        let restored = try decoder.decode(WizardPlan.self, from: encoder.encode(plan))
        #expect(restored.clips[0].continuesPrevious == true && restored.appliedFillerSpans == plan.appliedFillerSpans)
        var document = TimelineDocument()
        document.appliedFillerSpans = plan.appliedFillerSpans
        #expect(try decoder.decode(TimelineDocument.self, from: encoder.encode(document)).appliedFillerSpans == plan.appliedFillerSpans)
        #expect(try decoder.decode(TimelineDocument.self, from: Data("{}".utf8)).appliedFillerSpans == nil)
    }
}
