import Foundation

/// People Roles wizard: reads what the footage says about each uncategorized
/// person — the kinds of videos they appear in, the scene tags and
/// narratives around them, and what they say in interviews and podcasts —
/// and proposes a `PersonCategory` for each. Proposals are reviewed by the
/// user before anything is written; the wizard never files a person itself.
nonisolated enum PersonRoleInference {

    /// Everything the prompt knows about one person.
    struct Dossier: Sendable, Hashable {
        var personID: Int64
        var name: String
        var descriptor: String
        /// "Podcast 01.mp4 (Podcast)" — every video they appear in, with its type.
        var videos: [String]
        /// A sample of scene tags and narratives featuring them.
        var scenes: [String]
        /// A sample of lines they say on camera.
        var quotes: [String]
    }

    /// One proposed role, with the model's reasoning for the review sheet.
    struct Proposal: Identifiable, Sendable, Hashable {
        var personID: Int64
        var category: PersonCategory
        var confidence: Double
        var reason: String

        var id: Int64 { personID }
    }

    static let maxScenesPerPerson = 12
    static let maxQuotesPerPerson = 15
    static let maxQuoteLength = 160

    static func prompt(dossiers: [Dossier], domain: String) -> String {
        let roles = PersonCategory.allCases.map { "- \($0.rawValue): \(definition($0))" }.joined(separator: "\n")
        let people = dossiers.map(render).joined(separator: "\n\n")
        return """
        You classify the people who appear in a \(domain) short-form video brand's footage by their role. For each person below, decide which role fits best from what the footage shows: the kinds of videos they appear in, what happens in their scenes, and what they say on camera.

        Roles:
        \(roles)

        \(people)

        Rules:
        - Someone who competes in the footage is a fighter even when they also give interviews; someone who only talks about fights from outside the cage is press.
        - A trainer coaches, holds pads, or corners others; staff work the event or the brand behind the scenes.
        - Use "other" when nothing above fits; never invent a role outside the list.
        - Confidence is 0 to 1: how sure the evidence makes you. Weak evidence (one scene, no speech) is at most 0.5.
        - The reason is one short sentence quoting the evidence (a video type, a tag, a line they say).

        Return ONLY a JSON object:
        {"people": [{"id": <person id>, "category": "<role>", "confidence": <0-1>, "reason": "<one sentence>"}]}
        """
    }

    static func definition(_ category: PersonCategory) -> String {
        switch category {
        case .fighter: "competes in fights or spars as the subject of training footage"
        case .trainer: "coaches, corners, or runs training for others"
        case .press: "interviews, hosts, comments, or reports on the fighters"
        case .official: "referee, judge, commission, or ring official"
        case .fan: "audience member or supporter caught on camera"
        case .staff: "event, gym, or brand crew working behind the scenes"
        case .other: "none of the above"
        }
    }

    private static func render(_ dossier: Dossier) -> String {
        var lines = ["### PERSON \(dossier.personID): \(dossier.name)"]
        if !dossier.descriptor.isEmpty { lines.append("Looks: \(dossier.descriptor)") }
        lines.append("Videos: " + (dossier.videos.isEmpty ? "none" : dossier.videos.joined(separator: "; ")))
        if !dossier.scenes.isEmpty {
            lines.append("Scenes:")
            lines.append(contentsOf: dossier.scenes.map { "- \($0)" })
        }
        if !dossier.quotes.isEmpty {
            lines.append("Says on camera:")
            lines.append(contentsOf: dossier.quotes.map { "- \"\($0)\"" })
        } else {
            lines.append("Says on camera: nothing attributed")
        }
        return lines.joined(separator: "\n")
    }

    /// Proposals for the people asked about, in the order asked; anyone the
    /// model skipped or answered with an unknown role is left out.
    static func parse(_ response: String, personIDs: [Int64]) -> [Proposal] {
        guard let object = AIResponseParser.jsonObject(from: response),
              let raw = object["people"] as? [[String: Any]] else { return [] }
        var byID: [Int64: Proposal] = [:]
        for entry in raw {
            let id: Int64? = (entry["id"] as? Int).map(Int64.init)
                ?? (entry["id"] as? Int64)
                ?? (entry["id"] as? Double).map(Int64.init)
                ?? (entry["id"] as? String).flatMap(Int64.init)
            guard let id, personIDs.contains(id), byID[id] == nil,
                  let rawCategory = (entry["category"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  let category = PersonCategory(rawValue: rawCategory) else { continue }
            let confidence = (entry["confidence"] as? Double)
                ?? (entry["confidence"] as? Int).map(Double.init)
                ?? (entry["confidence"] as? String).flatMap(Double.init) ?? 0
            let reason = (entry["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            byID[id] = Proposal(personID: id, category: category,
                                confidence: min(1, max(0, confidence)), reason: reason)
        }
        return personIDs.compactMap { byID[$0] }
    }

    /// Lines a person says: rows the user attributed to them, plus rows left
    /// on automatic whose overlapping speaker turn is theirs.
    static func quotes(for key: String, transcripts: [TranscriptRow], turns: [SpeakerTurn]) -> [String] {
        let theirTurns = turns.filter { $0.personKey == key }
        var quotes: [String] = []
        for row in transcripts where !row.isTranslation {
            let theirs: Bool
            if let speakerKey = row.speakerKey {
                theirs = speakerKey == key
            } else {
                theirs = theirTurns.contains { $0.start < row.endTime && row.startTime < $0.end }
            }
            guard theirs else { continue }
            let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 12 else { continue }
            quotes.append(text.count > maxQuoteLength ? String(text.prefix(maxQuoteLength)) + "…" : text)
            if quotes.count >= maxQuotesPerPerson { break }
        }
        return quotes
    }
}
