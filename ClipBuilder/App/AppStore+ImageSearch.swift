import Foundation

extension AppStore {
    func searchImages(query: String, candidates: [AssetItem], metadata: [String: LibraryAssetMetadata],
                      provider: String?, model: String?, log: @escaping @Sendable (String) -> Void) async throws -> [String] {
        let useLocal = OnDevicePolicy.isEnabled(item: "image-search", config: settings.ai)
        if useLocal {
            let paths = try await AppJobWork.run {
                let rows = try candidates.map { item in
                    try Task.checkCancellation()
                    let info = metadata[item.url.path]
                    return LocalTextMatcher.Row(id: item.url.path,
                        fields: (info?.subjects ?? []) + (info?.tags ?? []),
                        date: (try? item.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
                }
                return LocalImageMatcher.match(query: query, rows: rows)
            }
            try Task.checkCancellation()
            if !paths.isEmpty { log("Matched \(paths.count) images by keyword"); return paths }
        }
        log(useLocal ? "Keyword match found nothing — asking the model" : "Image search — asking the model")
        let inventory = candidates.enumerated().map { index, item in
            let info = metadata[item.url.path]
            return "- id \(index) | \(item.name) | subjects: \(info?.subjects.joined(separator: ", ") ?? "untagged") | tags: \(info?.tags.joined(separator: ", ") ?? "untagged")"
        }.joined(separator: "\n")
        let prompt = """
            Rank the owned images which match this request: \(query)

            \(inventory)

            Return only JSON: {"ids":[0,1]}. Include only strong matches, best first. Never invent an id.
            """
        let response = try await ai.call(prompt: prompt, task: "search", model: model, provider: provider,
                                         timeout: 120, log: log)
        try Task.checkCancellation()
        let ids = AIResponseParser.jsonObject(from: response.text)?["ids"] as? [Int] ?? []
        return ids.compactMap { candidates.indices.contains($0) ? candidates[$0].url.path : nil }
    }
}
