import Foundation
import Testing
@testable import Clip_Builder

@Suite("Mini Wizard presets")
struct MiniWizardPresetStoreTests {
    private func settings(captions: Bool) -> MiniWizardSettings {
        var settings = MiniWizardSettings()
        settings.captions = captions
        settings.quality = .compact
        settings.overlay = true
        settings.overlayTemplate = "Main"
        settings.overlayTexts = ["Hook", ""]
        settings.watermarkOpacity = 0.3
        settings.outputMode = .oneReel
        return settings
    }

    @Test func presetsTravelWithTheProfileAndTheTeamDocument() throws {
        var profile = Fixtures.brand(name: "First")
        #expect(profile.expressPresets == nil)
        profile.expressPresets = MiniWizardPresetStore.upsert(name: " Podcast ", settings: settings(captions: true),
                                                              savedAt: Date(timeIntervalSince1970: 100), into: [])
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(BrandProfile.self, from: data)
        #expect(decoded.expressPresets?.map(\.name) == ["Podcast"])
        #expect(decoded.expressPresets?.first?.settings == settings(captions: true))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["express_presets"] != nil)
        #expect(TeamProfileDocument.keys.contains("express_presets"))
        let shared = try JSONDecoder().decode(SyncMapping.WireRow.self,
                                              from: Data(try TeamProfileDocument.encode(profile).utf8))
        #expect(shared["express_presets"] != nil)
        let receiver = try TeamProfileDocument.applying(try TeamProfileDocument.encode(profile),
                                                        to: Fixtures.brand(name: "First"))
        #expect(receiver.expressPresets == profile.expressPresets)
        // A profile saved before presets existed decodes with none.
        let old = try JSONDecoder().decode(BrandProfile.self, from: Data(#"{"profile_name":"Old"}"#.utf8))
        #expect(old.expressPresets == nil)
    }

    @Test func legacyFileFromOneHundredTwoStillReads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("presets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(MiniWizardPresetStore.legacyPresets(profileName: "First", root: root).isEmpty)
        let url = MiniWizardPresetStore.legacyFileURL(profileName: "First", root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let presets = [MiniWizardPreset(name: "Zed", savedAt: Date(timeIntervalSince1970: 5), settings: settings(captions: false)),
                       MiniWizardPreset(name: "Alpha", savedAt: Date(timeIntervalSince1970: 9), settings: settings(captions: true))]
        try encoder.encode(presets).write(to: url)
        let loaded = MiniWizardPresetStore.legacyPresets(profileName: "First", root: root)
        #expect(loaded.map(\.name) == ["Alpha", "Zed"])
        #expect(loaded.first?.settings == settings(captions: true))
        #expect(MiniWizardPresetStore.legacyPresets(profileName: "Second", root: root).isEmpty)
    }

    @Test func upsertReplacesByNameRenameRejectsClashesAndDeleteRemoves() {
        var presets = MiniWizardPresetStore.upsert(name: "Default", settings: settings(captions: false),
                                                   savedAt: Date(timeIntervalSince1970: 1), into: [])
        presets = MiniWizardPresetStore.upsert(name: "Zebra", settings: settings(captions: false),
                                               savedAt: Date(timeIntervalSince1970: 2), into: presets)
        presets = MiniWizardPresetStore.upsert(name: "default", settings: settings(captions: true),
                                               savedAt: Date(timeIntervalSince1970: 3), into: presets)
        #expect(presets.map(\.name) == ["default", "Zebra"])
        #expect(presets.first?.settings.captions == true)
        #expect(MiniWizardPresetStore.upsert(name: "  ", settings: settings(captions: true), into: presets) == presets)

        #expect(MiniWizardPresetStore.rename("default", to: "zebra", in: presets) == nil)
        #expect(MiniWizardPresetStore.rename("default", to: " ", in: presets) == nil)
        #expect(MiniWizardPresetStore.rename("Missing", to: "X", in: presets) == nil)
        let renamed = MiniWizardPresetStore.rename("default", to: "Alpha", in: presets)
        #expect(renamed?.map(\.name) == ["Alpha", "Zebra"])
        #expect(MiniWizardPresetStore.rename("default", to: "DEFAULT", in: presets)?.first?.name == "DEFAULT")

        #expect(MiniWizardPresetStore.delete("Zebra", in: presets).map(\.name) == ["default"])
        #expect(MiniWizardPresetStore.delete("nobody", in: presets) == presets)
    }

    @Test func suggestedNamePrefersLastUsedThenNewestThenDefault() {
        #expect(MiniWizardPresetStore.suggestedName(lastUsed: nil, presets: []) == "Default")
        #expect(MiniWizardPresetStore.suggestedName(lastUsed: "Gone", presets: []) == "Default")
        let presets = [MiniWizardPreset(name: "Old", savedAt: Date(timeIntervalSince1970: 1), settings: MiniWizardSettings()),
                       MiniWizardPreset(name: "New", savedAt: Date(timeIntervalSince1970: 9), settings: MiniWizardSettings())]
        #expect(MiniWizardPresetStore.suggestedName(lastUsed: nil, presets: presets) == "New")
        #expect(MiniWizardPresetStore.suggestedName(lastUsed: "old", presets: presets) == "Old")
        #expect(MiniWizardPresetStore.suggestedName(lastUsed: "Gone", presets: presets) == "New")
    }

    @Test func settingsDecodeWithMissingKeysAndRejectCustomPresets() throws {
        let empty = try JSONDecoder().decode(MiniWizardSettings.self, from: Data("{}".utf8))
        #expect(empty == MiniWizardSettings())
        let partial = try JSONDecoder().decode(MiniWizardSettings.self,
            from: Data(#"{"captions":true,"quality":"custom","preset":"custom","outputMode":"oneReel"}"#.utf8))
        #expect(partial.captions && partial.quality == .balanced && partial.preset == .portrait1080 && partial.outputMode == .oneReel)
        let full = settings(captions: true)
        #expect(try JSONDecoder().decode(MiniWizardSettings.self, from: JSONEncoder().encode(full)) == full)
    }

    @Test func cardTitleNamesTheLoadedPresetAndFlagsEdits() throws {
        let suite = "MiniWizardPresetStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var current = settings(captions: true)
        #expect(MiniWizardPresetStore.cardTitle(loaded: nil, current: current) == "Settings")
        #expect(MiniWizardPresetStore.loaded(profileName: "P", defaults: defaults) == nil)
        MiniWizardPresetStore.rememberLoaded(.init(name: "Podcast", settings: current), profileName: "P", defaults: defaults)
        let loaded = try #require(MiniWizardPresetStore.loaded(profileName: "P", defaults: defaults))
        #expect(loaded.name == "Podcast" && loaded.settings == current)
        #expect(MiniWizardPresetStore.cardTitle(loaded: loaded, current: current) == "Settings - Podcast")
        current.captions = false
        #expect(MiniWizardPresetStore.cardTitle(loaded: loaded, current: current) == "Settings - Podcast (modified)")
        #expect(MiniWizardPresetStore.loaded(profileName: "Other", defaults: defaults) == nil)
        MiniWizardPresetStore.rememberLoaded(nil, profileName: "P", defaults: defaults)
        #expect(MiniWizardPresetStore.loaded(profileName: "P", defaults: defaults) == nil)
        #expect(defaults.string(forKey: MiniWizardPresetStore.lastUsedKey(profileName: "P")) == nil)
    }
}
