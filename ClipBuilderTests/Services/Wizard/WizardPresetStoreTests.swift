import Foundation
import Testing
@testable import Clip_Builder

@Suite("Wizard presets and per-profile memory")
struct WizardPresetStoreTests {
    private func scratchDefaults(_ name: String) -> UserDefaults {
        let suite = "WizardPresetStoreTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func listRulesAreSharedWithExpress() {
        let a = WizardPreset(name: "Podcast", savedAt: Date(timeIntervalSince1970: 10), settings: ["formatPreset": .string("podcast")])
        var presets = NamedPresets.upsert(a, into: [])
        presets = NamedPresets.upsert(WizardPreset(name: " fights ", savedAt: Date(timeIntervalSince1970: 20), settings: [:]), into: presets)
        #expect(presets.map(\.name) == ["fights", "Podcast"])
        // Same name, different case, replaces.
        presets = NamedPresets.upsert(WizardPreset(name: "PODCAST", savedAt: Date(timeIntervalSince1970: 30), settings: [:]), into: presets)
        #expect(presets.map(\.name) == ["fights", "PODCAST"])
        #expect(NamedPresets.rename("fights", to: "podcast", in: presets) == nil)
        #expect(NamedPresets.rename("fights", to: " ", in: presets) == nil)
        #expect(NamedPresets.rename("fights", to: "Fight night", in: presets)?.map(\.name) == ["Fight night", "PODCAST"])
        #expect(NamedPresets.delete("PODCAST", in: presets).map(\.name) == ["fights"])
        #expect(NamedPresets.suggestedName(lastUsed: "fights", presets: presets) == "fights")
        #expect(NamedPresets.suggestedName(lastUsed: "gone", presets: presets) == "PODCAST")
        #expect(NamedPresets.suggestedName(lastUsed: nil, presets: [WizardPreset]()) == "Default")
        #expect(NamedPresets.cardTitle(loadedName: nil, modified: true) == "Settings")
        #expect(NamedPresets.cardTitle(loadedName: "Podcast", modified: false) == "Settings - Podcast")
        #expect(NamedPresets.cardTitle(loadedName: "Podcast", modified: true) == "Settings - Podcast (modified)")
        // Express still goes through the same rules.
        let mini = MiniWizardPresetStore.upsert(name: " Clips ", settings: MiniWizardSettings(), into: [])
        #expect(mini.map(\.name) == ["Clips"])
    }

    @Test func presetsDropSourceAndRunFieldsAndTravelWithTheProfile() throws {
        let settings: [String: JSONSetting] = [
            "formatPreset": .string("podcast"), "selectedRunIDs": .array([.number(3)]), "sourcePeople": .array([.string("a")]),
            "projectID": .number(9), "templateJSON": .string("{}"), "aiInstructions": .string("brief"),
            "lookPreset": .string("vintage"), "musicTrack": .null,
        ]
        let presets = WizardPresetStore.upsert(name: "Podcast", settings: settings, savedAt: Date(timeIntervalSince1970: 100), into: [])
        let kept = try #require(presets.first?.settings)
        #expect(kept["formatPreset"] == .string("podcast") && kept["lookPreset"] == .string("vintage"))
        for field in ["selectedRunIDs", "sourcePeople", "projectID", "templateJSON", "aiInstructions", "musicTrack"] {
            #expect(kept[field] == nil, "\(field) must not be saved")
        }
        var profile = Fixtures.brand(name: "First")
        #expect(profile.wizardPresets == nil)
        profile.wizardPresets = presets
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(BrandProfile.self, from: data)
        #expect(decoded.wizardPresets == presets)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["wizard_presets"] != nil)
        #expect(TeamProfileDocument.keys.contains("wizard_presets"))
        // Older profiles without the key still decode.
        let legacy = try JSONDecoder().decode(BrandProfile.self, from: Data(#"{"profile_name":"Old"}"#.utf8))
        #expect(legacy.wizardPresets == nil)
        #expect(WizardPresetStore.summary(presets[0]).contains("Vintage film"))
    }

    @MainActor
    @Test func captureAndApplyRoundTripThroughTheLiveDefaults() {
        let source = scratchDefaults("source")
        let profile = Fixtures.brand(name: "Round trip")
        source.set("podcast", forKey: "wizard.formatPreset")
        source.set("reviewMoments", forKey: WizardDefaults.workflowKey)
        source.set(true, forKey: "wizard.bumperIntro")
        source.set("vintage", forKey: "wizard.lookPreset")
        source.set(false, forKey: "wizard.useFightResearch")
        source.set("custom", forKey: WizardDefaults.durationModeKey)
        source.set(25, forKey: WizardDefaults.customDurationKey)
        source.set("none", forKey: WizardDefaults.brandingOverrideKey)
        source.set("3,4", forKey: "wizard.selectedRunIDs")
        var render = RenderSettings()
        render.quality = .compact
        var pacing = EditPacing()
        pacing.curve = .accelerate
        let captured = WizardMemory.capture(profile: profile, renderSettings: render, pacing: pacing, defaults: source)
        #expect(captured["formatPreset"] == .string("podcast"))
        #expect(captured["workflow"] == .string("reviewMoments"))
        #expect(captured["includeIntroBumper"] == .bool(true))
        #expect(captured["lookPreset"] == .string("vintage"))
        #expect(captured["useFightResearch"] == .bool(false))
        #expect(captured["targetDurationSeconds"] == .number(25))
        #expect(captured["includeWatermark"] == .bool(false))
        #expect(captured["selectedRunIDs"] == nil && captured["projectID"] == nil)

        let target = scratchDefaults("target")
        let restored = WizardMemory.apply(captured, profileName: profile.profileName, defaults: target)
        #expect(target.string(forKey: "wizard.formatPreset") == "podcast")
        #expect(target.string(forKey: WizardDefaults.workflowKey) == "reviewMoments")
        #expect(target.bool(forKey: "wizard.bumperIntro"))
        #expect(target.string(forKey: "wizard.lookPreset") == "vintage")
        #expect(target.object(forKey: "wizard.useFightResearch") != nil && !target.bool(forKey: "wizard.useFightResearch"))
        #expect(target.string(forKey: WizardDefaults.durationModeKey) == "custom" && target.integer(forKey: WizardDefaults.customDurationKey) == 25)
        #expect(target.string(forKey: WizardDefaults.brandingOverrideKey) == "none")
        // No "Pasted from" snapshot, and no source keys.
        #expect(target.string(forKey: AISettingsPreferences.snapshotKey) == nil)
        #expect(target.string(forKey: "wizard.selectedRunIDs") == nil)
        #expect(restored.renderSettings?.quality == .compact)
        #expect(restored.pacing?.curve == .accelerate)
    }

    @MainActor
    /// Counts `didChangeNotification` posts for one suite. Each write posts
    /// once, so an idle Wizard that re-remembers unchanged answers would be
    /// visible here as a nonzero count.
    private final class ChangeCounter: @unchecked Sendable {
        private(set) var count = 0
        private var token: NSObjectProtocol?
        init(_ defaults: UserDefaults) {
            token = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                           object: defaults, queue: nil) { [weak self] _ in
                self?.count += 1
            }
        }
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }

    @Test func rememberingUnchangedAnswersWritesNothing() {
        let defaults = scratchDefaults("quiet")
        let profile = Fixtures.brand(name: "Quiet")
        defaults.set("podcast", forKey: "wizard.formatPreset")
        #expect(WizardMemory.remember(profile: profile, renderSettings: nil, pacing: nil, defaults: defaults))
        let counter = ChangeCounter(defaults)
        #expect(!WizardMemory.remember(profile: profile, renderSettings: nil, pacing: nil, defaults: defaults))
        #expect(!WizardMemory.remember(profile: profile, renderSettings: nil, pacing: nil, defaults: defaults))
        #expect(counter.count == 0)
        defaults.set("fight", forKey: "wizard.formatPreset")
        #expect(WizardMemory.remember(profile: profile, renderSettings: nil, pacing: nil, defaults: defaults))
        #expect(counter.count == 2)

        let loaded = WizardPresetStore.Loaded(name: "Tight", settings: ["formatPreset": .string("fight")])
        WizardPresetStore.rememberLoaded(loaded, profileName: profile.profileName, defaults: defaults)
        let afterLoad = counter.count
        WizardPresetStore.rememberLoaded(loaded, profileName: profile.profileName, defaults: defaults)
        #expect(counter.count == afterLoad)
        WizardPresetStore.rememberLoaded(nil, profileName: profile.profileName, defaults: defaults)
        let afterClear = counter.count
        #expect(afterClear > afterLoad)
        WizardPresetStore.rememberLoaded(nil, profileName: profile.profileName, defaults: defaults)
        #expect(counter.count == afterClear)
    }

    @Test func setIfChangedComparesBridgedValues() {
        let defaults = scratchDefaults("bridge")
        #expect(defaults.setIfChanged(true, forKey: "flag"))
        #expect(!defaults.setIfChanged(true, forKey: "flag"))
        #expect(defaults.setIfChanged(false, forKey: "flag"))
        #expect(defaults.setIfChanged(["a": "b"], forKey: "dict"))
        #expect(!defaults.setIfChanged(["a": "b"], forKey: "dict"))
        #expect(defaults.setIfChanged(["a", "b"], forKey: "list"))
        #expect(!defaults.setIfChanged(["a", "b"], forKey: "list"))
        #expect(defaults.setIfChanged(["b", "a"], forKey: "list"))
        #expect(defaults.setIfChanged(0.5, forKey: "number"))
        #expect(!defaults.setIfChanged(0.5, forKey: "number"))
        #expect(!defaults.setIfChanged(nil, forKey: "missing"))
        #expect(defaults.setIfChanged(nil, forKey: "number"))
        #expect(defaults.object(forKey: "number") == nil)
        let optional: String? = nil
        #expect(!defaults.setIfChanged(optional, forKey: "number"))
    }

    @Test func eachProfileRemembersItsOwnAnswers() {
        let defaults = scratchDefaults("memory")
        let first = Fixtures.brand(name: "First")
        let second = Fixtures.brand(name: "Second")
        // Nothing remembered yet: the live answers stand (an install migrates in place).
        #expect(WizardMemory.restore(profileName: first.profileName, defaults: defaults) == nil)
        defaults.set("podcast", forKey: "wizard.formatPreset")
        WizardMemory.remember(profile: first, renderSettings: nil, pacing: nil, defaults: defaults)
        defaults.set("fight", forKey: "wizard.formatPreset")
        WizardMemory.remember(profile: second, renderSettings: nil, pacing: nil, defaults: defaults)
        #expect(WizardMemory.restore(profileName: first.profileName, defaults: defaults) != nil)
        #expect(defaults.string(forKey: "wizard.formatPreset") == "podcast")
        #expect(WizardMemory.restore(profileName: second.profileName, defaults: defaults) != nil)
        #expect(defaults.string(forKey: "wizard.formatPreset") == "fight")
    }

    @MainActor
    @Test func cardTitleTracksTheLoadedPreset() {
        let defaults = scratchDefaults("title")
        let profile = Fixtures.brand(name: "Title")
        #expect(WizardPresetStore.loaded(profileName: profile.profileName, defaults: defaults) == nil)
        defaults.set("podcast", forKey: "wizard.formatPreset")
        let current = WizardMemory.capture(profile: profile, renderSettings: nil, pacing: nil, defaults: defaults)
        WizardPresetStore.rememberLoaded(.init(name: "Podcast", settings: current), profileName: profile.profileName, defaults: defaults)
        let loaded = WizardPresetStore.loaded(profileName: profile.profileName, defaults: defaults)
        #expect(loaded?.name == "Podcast")
        #expect(WizardPresetStore.cardTitle(loaded: loaded, current: current) == "Settings - Podcast")
        defaults.set("fight", forKey: "wizard.formatPreset")
        let changed = WizardMemory.capture(profile: profile, renderSettings: nil, pacing: nil, defaults: defaults)
        #expect(WizardPresetStore.cardTitle(loaded: loaded, current: changed) == "Settings - Podcast (modified)")
        WizardPresetStore.rememberLoaded(nil, profileName: profile.profileName, defaults: defaults)
        #expect(WizardPresetStore.cardTitle(loaded: nil, current: changed) == "Settings")
    }
}
