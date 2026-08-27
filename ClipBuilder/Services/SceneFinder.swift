import Foundation

/// Natural-language scene search: "the moment Ulberg hurts Błachowicz
/// against the fence" → ranked scene ids. The model reads a compact index of
/// every candidate scene (narrative, tags, people, scores) — no frames, so a
/// whole-library search answers in seconds on a fast model.
nonisolated enum SceneFinder {

    /// Library index cap per query — beyond this the most recent scenes win.
    static let maxCandidates = 800
    static let maxMatches = 30

    static func prompt(query: String, scenes: [SceneRecord], people: [PersonRecord]) -> String {
        let legend = people.filter { !$0.name.isEmpty }
            .map { "- \($0.name) → tag \"person:\($0.key)\"" }
            .joined(separator: "\n")
        let lines = scenes.map { scene in
            var line = "- id \(scene.id) | \(scene.videoFilename) | \(scene.startTime.timecode)–\(scene.endTime.timecode)"
            if let score = scene.score { line += String(format: " | score %.1f", score) }
            let tags = scene.tags.prefix(8)
            if !tags.isEmpty { line += " | " + tags.joined(separator: ", ") }
            if let narrative = scene.narrative, !narrative.isEmpty {
                line += " | \(String(narrative.prefix(140)))"
            }
            return line
        }
        return """
        You are searching a video-scene library. The user describes what they are looking for; you return the scenes that match, best match first.

        ## PEOPLE (name → the tag used on their scenes)
        \(legend.isEmpty ? "(no named people)" : legend)

        ## SCENES
        \(lines.joined(separator: "\n"))

        ## QUERY
        \(query)

        ## OUTPUT
        Return ONLY a JSON object with the ids of scenes that genuinely match, ranked best first, at most \(maxMatches):
        {"matches": [<id>, <id>, ...]}
        Match on what the scene actually shows (narrative, tags, people, timing) — not loose keyword overlap. An empty list is the right answer when nothing matches.
        """
    }

    /// Ranked ids out of the reply, restricted to ids that were offered.
    static func parse(_ response: String, validIDs: Set<Int64>) -> [Int64] {
        guard let object = AIResponseParser.jsonObject(from: response),
              let raw = object["matches"] as? [Any] else { return [] }
        var seen = Set<Int64>()
        return raw.compactMap { value in
            guard let id = (value as? NSNumber)?.int64Value,
                  validIDs.contains(id), seen.insert(id).inserted else { return nil }
            return id
        }
    }
}
