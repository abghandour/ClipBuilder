import Foundation

/// A model a provider's CLI says it offers right now, as opposed to the
/// built-in catalog's guess of what it offered when the app shipped.
nonisolated struct DiscoveredModel: Codable, Sendable, Hashable, Identifiable {
    var provider: String
    /// The id the CLI takes on its model flag.
    var id: String
    var name: String
    var description: String?
}

/// What discovery found for one provider. `authoritative` means the list
/// is the CLI's own and complete, so a catalog model missing from it is one
/// the CLI no longer serves; otherwise the list only adds to the catalog.
nonisolated struct DiscoveredProviderModels: Codable, Sendable, Hashable {
    var models: [DiscoveredModel]
    var authoritative: Bool
}

/// Asks each provider what it offers, where a provider can be asked at all:
/// Codex keeps a models cache on disk; Claude Code takes family aliases
/// that always mean the latest model. Gemini, Qwen and Kimi publish nothing
/// locally and stay on the catalog.
nonisolated enum ModelDiscovery {
    /// Codex's own cache of the models its account can use (refreshed by
    /// the CLI itself). Not a documented interface: read tolerantly and
    /// fall back to the catalog when it is missing or changes shape.
    static var codexCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/models_cache.json")
    }

    static func discover(codexCache: URL = codexCacheURL) -> [String: DiscoveredProviderModels] {
        var result: [String: DiscoveredProviderModels] = [:]
        if let data = try? Data(contentsOf: codexCache) {
            let models = codexModels(data: data)
            if !models.isEmpty { result["codex"] = DiscoveredProviderModels(models: models, authoritative: true) }
        }
        result["claude"] = DiscoveredProviderModels(models: claudeAliases, authoritative: false)
        return result
    }

    /// The visible entries of Codex's models cache, in the cache's order.
    static func codexModels(data: Data) -> [DiscoveredModel] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let entries: [[String: Any]]
        if let object = json as? [String: Any], let models = object["models"] as? [[String: Any]] {
            entries = models
        } else if let list = json as? [[String: Any]] {
            entries = list
        } else {
            return []
        }
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard let slug = (entry["slug"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !slug.isEmpty, seen.insert(slug).inserted else { return nil }
            // Codex hides its internal models ("hide"); anything else lists.
            if let visibility = entry["visibility"] as? String, visibility.lowercased() == "hide" { return nil }
            if let hidden = entry["hidden"] as? Bool, hidden { return nil }
            let name = (entry["display_name"] as? String ?? entry["name"] as? String ?? slug)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let description = (entry["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return DiscoveredModel(provider: "codex", id: slug, name: name.isEmpty ? slug : name,
                                   description: description?.isEmpty == false ? description : nil)
        }
    }

    /// Claude Code's family aliases: each always resolves to the newest
    /// model of that family, so the picker never falls behind a release.
    static let claudeAliases: [DiscoveredModel] = [
        DiscoveredModel(provider: "claude", id: "haiku", name: "Haiku (latest)",
                        description: "Whatever Haiku is newest — fast and cheap"),
        DiscoveredModel(provider: "claude", id: "sonnet", name: "Sonnet (latest)",
                        description: "Whatever Sonnet is newest — the everyday balance"),
        DiscoveredModel(provider: "claude", id: "opus", name: "Opus (latest)",
                        description: "Whatever Opus is newest"),
        DiscoveredModel(provider: "claude", id: "fable", name: "Fable (latest)",
                        description: "Whatever Fable is newest — the strongest reasoning"),
    ]
}
