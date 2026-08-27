import Foundation

/// AI Curator: judges uncurated scenes against the profile's taste rubric —
/// with the user's grading history and existing Curated picks as worked
/// examples — and proposes which ones deserve promotion to the Curated set.
/// Text-only: narratives, scores, and tags say enough, so a pass over
/// hundreds of scenes stays cheap.
nonisolated enum SceneCurator {

    /// One proposed promotion, shown in the review sheet.
    struct Proposal: Identifiable, Sendable, Hashable {
        var sceneID: Int64
        var reason: String

        var id: Int64 { sceneID }
    }

    /// Scenes per AI call — enough context for consistent judgment, small
    /// enough that the reply stays focused.
    static let batchSize = 60
    private static let maxExamples = 8

    static func prompt(candidates: [SceneRecord], rubric: String,
                       categories: [TasteCategory],
                       graded: [SceneRecord], curatedExamples: [SceneRecord]) -> String {
        var sections: [String] = []

        let rubricText = rubric.trimmingCharacters(in: .whitespacesAndNewlines)
        sections.append("""
        ## TASTE RUBRIC (the brand's definition of a keeper)
        \(rubricText.isEmpty ? "No rubric is written yet — judge by general short-form social value: clear action, a story beat, emotion, or a moment worth rewatching." : rubricText)
        """)

        let categoryLines = categories.filter { !$0.rubric.isEmpty }.map { "- \($0.label): \($0.rubric)" }
        if !categoryLines.isEmpty {
            sections.append("## VIDEO-TYPE RUBRICS\n" + categoryLines.joined(separator: "\n"))
        }

        let good = graded.filter { ($0.lastGrade ?? 0) >= 4 }.suffix(maxExamples)
        let bad = graded.filter { ($0.lastGrade ?? 5) <= 2 }.suffix(maxExamples)
        let kept = curatedExamples.filter { $0.narrative?.isEmpty == false }.suffix(maxExamples)
        var examples: [String] = []
        examples += good.map { "- LIKED (graded \($0.lastGrade ?? 5)/5): \(exampleLine($0))" }
        examples += bad.map { "- DISLIKED (graded \($0.lastGrade ?? 1)/5): \(exampleLine($0))" }
        examples += kept.map { "- ALREADY CURATED: \(exampleLine($0))" }
        if !examples.isEmpty {
            sections.append("""
            ## THE USER'S OWN VERDICTS (ground truth for their taste)
            \(examples.joined(separator: "\n"))
            """)
        }

        let lines = candidates.map { scene in
            var line = "- id \(scene.id) | \(scene.videoFilename) | \(scene.startTime.timecode)–\(scene.endTime.timecode) (\(Int(scene.duration))s)"
            if let score = scene.score { line += String(format: " | score %.1f", score) }
            if let excitement = scene.excitement, excitement > 0 {
                line += String(format: " | crowd %.2f", excitement)
            }
            let tags = scene.tags.filter { !$0.hasPrefix("framed:") }.prefix(6)
            if !tags.isEmpty { line += " | " + tags.joined(separator: ", ") }
            if scene.favorite { line += " | FAVORITE" }
            if let narrative = scene.narrative, !narrative.isEmpty {
                line += " | \(String(narrative.prefix(180)))"
            }
            return line
        }
        sections.append("## CANDIDATE SCENES (uncurated)\n" + lines.joined(separator: "\n"))

        return """
        You are the content curator for a short-form social video brand. From the candidate scenes below, pick ONLY the ones that clearly deserve promotion to the hand-picked Curated set the AI Wizard builds reels from.

        \(sections.joined(separator: "\n\n"))

        ## OUTPUT
        Be selective — promoting everything makes the Curated set worthless; a typical pass promotes roughly 10–25% of candidates, and promoting none is a valid answer. Never promote a scene that resembles the user's DISLIKED examples. Return ONLY a JSON object:
        {"promote": [{"scene_id": <id>, "reason": "<at most 12 words on why it's a keeper>"}]}
        """
    }

    private static func exampleLine(_ scene: SceneRecord) -> String {
        let narrative = scene.narrative.map { String($0.prefix(140)) } ?? scene.tags.prefix(5).joined(separator: ", ")
        return "\(Int(scene.duration))s — \(narrative)"
    }

    /// Proposals out of the model's reply, restricted to ids that were
    /// actually offered so a hallucinated id can't promote a random scene.
    static func parse(_ response: String, validIDs: Set<Int64>) -> [Proposal] {
        guard let object = AIResponseParser.jsonObject(from: response),
              let raw = object["promote"] as? [[String: Any]] else { return [] }
        var seen = Set<Int64>()
        return raw.compactMap { entry in
            guard let sceneID = (entry["scene_id"] as? NSNumber)?.int64Value,
                  validIDs.contains(sceneID), seen.insert(sceneID).inserted else { return nil }
            let reason = (entry["reason"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Proposal(sceneID: sceneID, reason: reason)
        }
    }
}
