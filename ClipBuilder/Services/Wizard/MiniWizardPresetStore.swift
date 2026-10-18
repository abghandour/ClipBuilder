import Foundation

/// One named set of Express settings.
nonisolated struct MiniWizardPreset: NamedPreset, Hashable {
    var name: String
    var savedAt: Date
    var settings: MiniWizardSettings

    var id: String { name.lowercased() }
}

/// Saved Express settings live on the brand profile (`express_presets`), so
/// Team Sync shares them with every member through the profile document.
/// Pure list operations live here; 1.102 kept a per-profile file instead,
/// which is read once and adopted into the profile.
nonisolated enum MiniWizardPresetStore {
    static let defaultName = "Default"

    /// 1.102's location: `~/Documents/ClipBuilder/express_presets/<profile>.json`.
    static func legacyFileURL(profileName: String, root: URL = ProfileStore.profilesDirectory) -> URL {
        root.appendingPathComponent("express_presets", isDirectory: true)
            .appendingPathComponent(ProfileStore.sanitize(profileName) + ".json")
    }

    static func legacyPresets(profileName: String, root: URL = ProfileStore.profilesDirectory) -> [MiniWizardPreset] {
        guard let data = try? Data(contentsOf: legacyFileURL(profileName: profileName, root: root)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return sorted((try? decoder.decode([MiniWizardPreset].self, from: data)) ?? [])
    }

    /// The remembered name of the last saved or loaded preset.
    static func lastUsedKey(profileName: String) -> String { "mini.\(profileName).presetName" }
    /// The settings as they were when that preset was last saved or loaded,
    /// so the card can say "(modified)" once they drift.
    static func baselineKey(profileName: String) -> String { "mini.\(profileName).presetBaseline" }

    /// A loaded or saved preset the Settings card is tracking.
    struct Loaded: Equatable, Sendable {
        var name: String
        var settings: MiniWizardSettings
    }

    static func rememberLoaded(_ loaded: Loaded?, profileName: String, defaults: UserDefaults = .standard) {
        guard let loaded else {
            defaults.removeObject(forKey: lastUsedKey(profileName: profileName))
            defaults.removeObject(forKey: baselineKey(profileName: profileName))
            return
        }
        defaults.set(loaded.name, forKey: lastUsedKey(profileName: profileName))
        defaults.set(try? JSONEncoder().encode(loaded.settings), forKey: baselineKey(profileName: profileName))
    }

    /// Nil until a preset has been saved or loaded for this profile.
    static func loaded(profileName: String, defaults: UserDefaults = .standard) -> Loaded? {
        guard let name = defaults.string(forKey: lastUsedKey(profileName: profileName)), !name.isEmpty,
              let data = defaults.data(forKey: baselineKey(profileName: profileName)),
              let settings = try? JSONDecoder().decode(MiniWizardSettings.self, from: data) else { return nil }
        return Loaded(name: name, settings: settings)
    }

    /// "Settings", "Settings - Podcast", or "Settings - Podcast (modified)".
    static func cardTitle(base: String = "Settings", loaded: Loaded?, current: MiniWizardSettings) -> String {
        guard let loaded else { return base }
        return "\(base) - \(loaded.name)" + (loaded.settings == current ? "" : " (modified)")
    }

    // MARK: - Pure list operations

    // The list rules are shared with the AI Wizard's presets (NamedPresets).
    static func sorted(_ presets: [MiniWizardPreset]) -> [MiniWizardPreset] { NamedPresets.sorted(presets) }
    static func cleaned(_ name: String) -> String { NamedPresets.cleaned(name) }
    static func preset(named name: String, in presets: [MiniWizardPreset]) -> MiniWizardPreset? {
        NamedPresets.preset(named: name, in: presets)
    }
    static func upsert(name: String, settings: MiniWizardSettings, savedAt: Date = Date(),
                       into presets: [MiniWizardPreset]) -> [MiniWizardPreset] {
        NamedPresets.upsert(MiniWizardPreset(name: name, savedAt: savedAt, settings: settings), into: presets)
    }
    static func rename(_ oldName: String, to newName: String,
                       in presets: [MiniWizardPreset]) -> [MiniWizardPreset]? {
        NamedPresets.rename(oldName, to: newName, in: presets)
    }
    static func delete(_ name: String, in presets: [MiniWizardPreset]) -> [MiniWizardPreset] {
        NamedPresets.delete(name, in: presets)
    }
    static func suggestedName(lastUsed: String?, presets: [MiniWizardPreset]) -> String {
        NamedPresets.suggestedName(lastUsed: lastUsed, presets: presets)
    }
}
