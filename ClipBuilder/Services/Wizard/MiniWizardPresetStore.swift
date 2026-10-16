import Foundation

/// One named set of Express settings.
nonisolated struct MiniWizardPreset: Codable, Identifiable, Equatable, Sendable {
    var name: String
    var savedAt: Date
    var settings: MiniWizardSettings

    var id: String { name.lowercased() }
}

/// Saved Express settings per profile, as one JSON file the user can see:
/// `~/Documents/ClipBuilder/express_presets/<profile>.json`. Pure list
/// operations are separate from the file I/O so they can be tested.
nonisolated enum MiniWizardPresetStore {
    static let defaultName = "Default"

    static func directory(root: URL = ProfileStore.profilesDirectory) -> URL {
        root.appendingPathComponent("express_presets", isDirectory: true)
    }

    static func fileURL(profileName: String, root: URL = ProfileStore.profilesDirectory) -> URL {
        directory(root: root).appendingPathComponent(ProfileStore.sanitize(profileName) + ".json")
    }

    /// The remembered name of the last saved or loaded preset.
    static func lastUsedKey(profileName: String) -> String { "mini.\(profileName).presetName" }

    static func load(profileName: String, root: URL = ProfileStore.profilesDirectory) -> [MiniWizardPreset] {
        guard let data = try? Data(contentsOf: fileURL(profileName: profileName, root: root)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return sorted((try? decoder.decode([MiniWizardPreset].self, from: data)) ?? [])
    }

    static func save(_ presets: [MiniWizardPreset], profileName: String,
                     root: URL = ProfileStore.profilesDirectory) throws {
        try FileManager.default.createDirectory(at: directory(root: root), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(sorted(presets)).write(to: fileURL(profileName: profileName, root: root), options: .atomic)
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
