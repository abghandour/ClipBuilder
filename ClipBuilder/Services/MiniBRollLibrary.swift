import Foundation

/// Local project search. No ranking, mention matching, or AI provider calls.
nonisolated enum MiniBRollLibrary {
    struct Item: Identifiable, Sendable {
        var scene: SceneRecord
        var name: String
        var searchText: String
        var id: Int64 { scene.id }
    }

    @concurrent
    static func catalog(scenes: [SceneRecord], people: [PersonRecord]) async -> [Item] {
        let names = PodcastHighlightBRollPlanner.personNames(people)
        return scenes.filter { $0.duration.isFinite && $0.duration > 0 }.map { scene in
            let name = scene.narrative?.components(separatedBy: " — ").first ?? scene.videoFilename
            let people = scene.tags.compactMap { tag -> String? in
                guard tag.hasPrefix("person:") else { return nil }
                return names[String(tag.dropFirst(7))]
            }
            return Item(scene: scene, name: name,
                searchText: ([name, scene.narrative ?? "", scene.videoFilename] + scene.tags + people).joined(separator: " "))
        }
    }

    @concurrent
    static func search(_ items: [Item], query: String) async -> [Item] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return items.filter { item in terms.allSatisfy { item.searchText.localizedStandardContains($0) } }
    }
}
