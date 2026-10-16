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

    @Test func presetsRoundTripPerProfileFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("presets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(MiniWizardPresetStore.load(profileName: "First", root: root).isEmpty)
        let saved = MiniWizardPresetStore.upsert(name: " Podcast ", settings: settings(captions: true),
                                                 savedAt: Date(timeIntervalSince1970: 100), into: [])
        try MiniWizardPresetStore.save(saved, profileName: "First", root: root)
        let loaded = MiniWizardPresetStore.load(profileName: "First", root: root)
        #expect(loaded.count == 1 && loaded.first?.name == "Podcast")
        #expect(loaded.first?.settings == settings(captions: true))
        #expect(loaded.first?.savedAt == Date(timeIntervalSince1970: 100))
        #expect(MiniWizardPresetStore.load(profileName: "Second", root: root).isEmpty)
        #expect(MiniWizardPresetStore.fileURL(profileName: "A/B", root: root).lastPathComponent.hasSuffix(".json"))
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
}
