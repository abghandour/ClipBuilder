import Foundation

/// File Name Wizard prompt + parsing: builds one descriptive filename per
/// video from the metadata already on record — people detection, video type,
/// fight outcome/research, scene narratives, moments, transcript — with no
/// frame extraction, so it runs on fast text-only models.
nonisolated enum FileNamer {

    /// Metadata cap per section — the point is a name, not a full re-read of
    /// the analysis, and small models choke on unbounded scene dumps.
    private static let maxScenes = 12
    private static let maxMoments = 10
    private static let maxTranscriptChars = 1000

    static func prompt(video: VideoRecord,
                       scenes: [SceneRecord],
                       people: [VideoPersonRecord],
                       outcome: FightOutcome?,
                       research: FightResearchRecord?,
                       moments: [MomentRecord],
                       transcripts: [TranscriptRow]) -> String {
        var sections: [String] = []

        sections.append("""
        ## FILE
        Current name: "\(video.filename)"
        Duration: \(video.duration.timecode). Resolution: \(video.width)×\(video.height) (\(video.wide ? "landscape" : "vertical")).
        Type: \(video.type?.label ?? "not classified").
        """)

        if !people.isEmpty {
            let lines = people.map { person in
                person.name.isEmpty
                    ? "- Unnamed person (key \"\(person.key)\"): \(person.descriptor)"
                    : "- \(person.name) (key \"\(person.key)\")"
            }
            sections.append("## PEOPLE DETECTED\n" + lines.joined(separator: "\n"))
        }

        if let outcome {
            func personName(_ key: String?) -> String? {
                guard let key else { return nil }
                let match = people.first { $0.key == key }
                return match.map { $0.name.isEmpty ? key : $0.name } ?? key
            }
            var line = "Method: \(outcome.method.uppercased())"
            if let winner = personName(outcome.winnerKey) { line += ". Winner: \(winner)" }
            if let loser = personName(outcome.loserKey) { line += ". Loser: \(loser)" }
            if let event = outcome.event { line += ". Event: \(event)" }
            if let round = outcome.round { line += ". Round: \(round)" }
            sections.append("## FIGHT RESULT\n" + line)
        }

        if let research {
            var lines = ["Fight: \(research.fightLabel)"]
            if !research.event.isEmpty { lines.append("Event: \(research.event)") }
            if !research.fightDate.isEmpty { lines.append("Date: \(research.fightDate)") }
            sections.append("## FIGHT RESEARCH (user-confirmed identity)\n"
                            + lines.joined(separator: "\n"))
        }

        let described = scenes
            .filter { $0.narrative?.isEmpty == false }
            .sorted { ($0.score ?? 0) > ($1.score ?? 0) }
            .prefix(maxScenes)
        if !described.isEmpty {
            let lines = described.map { scene in
                let score = scene.score.map { String(format: " (score %.1f)", $0) } ?? ""
                return "- \(scene.startTime.timecode)–\(scene.endTime.timecode)\(score): \(String((scene.narrative ?? "").prefix(200)))"
            }
            sections.append("## SCENES (highest scored first)\n" + lines.joined(separator: "\n"))
        }

        if !moments.isEmpty {
            let lines = moments.prefix(maxMoments).map { moment in
                var line = "- \(moment.atTime.timecode): \(moment.note)"
                if let dialog = moment.dialog, !dialog.isEmpty { line += " — \"\(dialog)\"" }
                return line
            }
            sections.append("## KEY MOMENTS\n" + lines.joined(separator: "\n"))
        }

        // The original-language rows only — a translation duplicates them.
        let speech = transcripts.filter { !$0.isTranslation }
        if !speech.isEmpty {
            var sample = ""
            for row in speech {
                guard sample.count < maxTranscriptChars else { break }
                sample += (sample.isEmpty ? "" : " ") + row.text
            }
            sections.append("## TRANSCRIPT (opening)\n" + String(sample.prefix(maxTranscriptChars)))
        }

        return """
        You are naming a video file in a content library. From the metadata below, build ONE short, human-readable filename that says what the footage shows: the people (real names when known), the event, the round, and the content type.

        \(sections.joined(separator: "\n\n"))

        ## OUTPUT
        Return ONLY a JSON object:
        {"suggested_filename": "<the name>", "reason": "<one short sentence on what it was built from>"}
        Rules for the name: plain text — no file extension, no slashes, colons, or quotes — at most 60 characters. Example: "Du Plessis vs Strickland - UFC Middleweight Championship R5". Prefer named people and confirmed fight identity over guesses; never invent people or events the metadata doesn't support. Fix improper spellings: if a person's or event's name is misspelled in the current filename or metadata, use its standard, well-documented spelling. If the current name is already the best description the metadata allows — and spelled correctly — return it unchanged (without its extension).
        """
    }

    /// The proposal out of the model's reply, sanitized the same way the
    /// analyzer's end-of-run suggestion is so it is always usable on disk.
    static func parseSuggestion(from response: String) -> (name: String, reason: String?)? {
        guard let object = AIResponseParser.jsonObject(from: response),
              let raw = object["suggested_filename"] as? String else { return nil }
        let cleaned = raw
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\"\n\r"))
            .joined(separator: " ")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !cleaned.isEmpty else { return nil }
        let reason = (object["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(cleaned.prefix(80)), reason?.isEmpty == false ? reason : nil)
    }
}
