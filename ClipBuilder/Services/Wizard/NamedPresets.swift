import Foundation

/// A named, dated set of saved answers. Express and the AI Wizard keep their
/// own settings shapes but share every list rule through `NamedPresets`.
nonisolated protocol NamedPreset: Codable, Identifiable, Equatable, Sendable {
    var name: String { get set }
    var savedAt: Date { get }
}

/// Pure list operations over any preset type: sorting, lookup by name
/// (case-insensitive), save-or-replace, rename, delete and the name a Save
/// sheet should propose.
nonisolated enum NamedPresets {
    static let defaultName = "Default"

    static func sorted<P: NamedPreset>(_ presets: [P]) -> [P] {
        presets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func cleaned(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func preset<P: NamedPreset>(named name: String, in presets: [P]) -> P? {
        let wanted = cleaned(name)
        return presets.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    /// Save `preset` under its cleaned name, replacing a preset with the same
    /// name (case-insensitively). An empty name saves nothing.
    static func upsert<P: NamedPreset>(_ preset: P, into presets: [P]) -> [P] {
        var preset = preset
        preset.name = cleaned(preset.name)
        guard !preset.name.isEmpty else { return presets }
        var result = presets.filter { $0.name.caseInsensitiveCompare(preset.name) != .orderedSame }
        result.append(preset)
        return sorted(result)
    }

    /// Nil when the new name is empty or already taken by another preset.
    static func rename<P: NamedPreset>(_ oldName: String, to newName: String, in presets: [P]) -> [P]? {
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

    static func delete<P: NamedPreset>(_ name: String, in presets: [P]) -> [P] {
        presets.filter { $0.name != name }
    }

    /// The name the Save sheet proposes: the last one used when it still
    /// exists, else the most recently saved, else "Default".
    static func suggestedName<P: NamedPreset>(lastUsed: String?, presets: [P]) -> String {
        if let lastUsed = lastUsed.map(cleaned), !lastUsed.isEmpty,
           let match = preset(named: lastUsed, in: presets) {
            return match.name
        }
        return presets.max { $0.savedAt < $1.savedAt }?.name ?? defaultName
    }

    /// "Settings", "Settings - Podcast", or "Settings - Podcast (modified)".
    static func cardTitle(base: String = "Settings", loadedName: String?, modified: Bool) -> String {
        guard let loadedName else { return base }
        return "\(base) - \(loadedName)" + (modified ? " (modified)" : "")
    }
}
