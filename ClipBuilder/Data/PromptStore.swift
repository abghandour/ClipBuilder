import Foundation

/// A named, reusable analysis prompt.
nonisolated struct SavedPrompt: Codable, Identifiable, Sendable, Equatable {
    var id = UUID()
    var name: String
    var text: String
}

/// Persists the analysis-instructions history as one JSON file under the
/// data folder, alongside the app settings.
nonisolated enum PromptStore {
    static var url: URL {
        SettingsStore.dataDirectory.appendingPathComponent("analysis_prompts.json")
    }

    static func load() -> [SavedPrompt] {
        guard let data = try? Data(contentsOf: url),
              let prompts = try? JSONDecoder().decode([SavedPrompt].self, from: data) else {
            return []
        }
        return prompts
    }

    static func save(_ prompts: [SavedPrompt]) {
        try? FileManager.default.createDirectory(at: SettingsStore.dataDirectory,
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(prompts) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Save under `name`, replacing an existing prompt with the same name
    /// (case-insensitive) — that's how editing a saved prompt works.
    static func upsert(name: String, text: String) -> [SavedPrompt] {
        var prompts = load()
        if let index = prompts.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            prompts[index].text = text
        } else {
            prompts.append(SavedPrompt(name: name, text: text))
        }
        save(prompts)
        return prompts
    }
}
