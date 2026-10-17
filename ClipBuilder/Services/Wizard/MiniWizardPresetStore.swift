import Foundation

/// One named set of Express settings.
nonisolated struct MiniWizardPreset: Codable, Identifiable, Equatable, Hashable, Sendable {
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

    static func sorted(_ presets: [MiniWizardPreset]) -> [MiniWizardPreset] {
        presets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func cleaned(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func preset(named name: String, in presets: [MiniWizardPreset]) -> MiniWizardPreset? {
        let wanted = cleaned(name)
        return presets.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    /// Save under `name`, replacing a preset with the same name (case-insensitively).
    static func upsert(name: String, settings: MiniWizardSettings, savedAt: Date = Date(),
                       into presets: [MiniWizardPreset]) -> [MiniWizardPreset] {
        let wanted = cleaned(name)
        guard !wanted.isEmpty else { return presets }
        var result = presets.filter { $0.name.caseInsensitiveCompare(wanted) != .orderedSame }
        result.append(MiniWizardPreset(name: wanted, savedAt: savedAt, settings: settings))
        return sorted(result)
    }

    /// Nil when the new name is empty or already taken by another preset.
    static func rename(_ oldName: String, to newName: String,
                       in presets: [MiniWizardPreset]) -> [MiniWizardPreset]? {
        let target = cleaned(newName)
        guard !target.isEmpty, let index = presets.firstIndex(where: { $0.name == oldName }) else { return nil }
        let taken = presets.enumerated().contains { offset, preset in
            offset != index && preset.name.caseInsensitiveCompare(target) == .orderedSame
        }
        guard !taken else { return nil }
        var result = presets
        result[index].name = target
        return sorted(result)
    }

    static func delete(_ name: String, in presets: [MiniWizardPreset]) -> [MiniWizardPreset] {
        presets.filter { $0.name != name }
    }

    /// The name the Save sheet proposes: the last one used when it still
    /// exists, else the most recently saved, else "Default".
    static func suggestedName(lastUsed: String?, presets: [MiniWizardPreset]) -> String {
        if let lastUsed = lastUsed.map(cleaned), !lastUsed.isEmpty,
           let match = preset(named: lastUsed, in: presets) {
            return match.name
        }
        return presets.max { $0.savedAt < $1.savedAt }?.name ?? defaultName
    }
}
