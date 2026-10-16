import Foundation

/// Pure rules for Express transcript picks: titles, plans and the span a new pick starts from.
nonisolated enum MiniWizardTranscriptRules {
    static let titleLimit = 60

    /// The spoken words inside the pick, in order, for titles and the AI prompt.
    static func text(for range: ClosedRange<Double>, rows: [TranscriptRow]) -> String {
        let ordered = rows.filter { !$0.isTranslation }
            .sorted { $0.startTime == $1.startTime ? $0.id < $1.id : $0.startTime < $1.startTime }
        var words: [String] = []
        for row in ordered {
            for word in TranscriptQATrim.words(for: row) where TranscriptQATrim.contains(word, in: range) {
                words.append(word.text)
            }
        }
        return words.joined(separator: " ")
    }

    /// The first words of the passage: the pick's label and selection name.
    static func title(for range: ClosedRange<Double>, rows: [TranscriptRow], number: Int,
                      limit: Int = titleLimit) -> String {
        let text = self.text(for: range, rows: rows)
        guard !text.isEmpty else { return "Pick \(number)" }
        guard text.count > limit else { return text }
        // Cut at a word boundary so the label never ends mid-word.
        let head = String(text.prefix(limit - 1))
        let cut = head.lastIndex(where: \.isWhitespace).map { String(head[..<$0]) } ?? head
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    static func title(for pick: TranscriptPick, rows: [TranscriptRow], number: Int, limit: Int = titleLimit) -> String {
        title(for: pick.range, rows: rows.filter { $0.videoID == pick.videoID }, number: number, limit: limit)
    }

    /// Picks have no target duration: the whole passage, including hand edits, is the clip.
    static func plan(for pick: TranscriptPick, sceneID: Int64, name: String) -> WizardPlan {
        let clip = WizardPlanClip(sceneID: sceneID, start: pick.start, end: pick.end)
        return WizardPlan(targetDuration: pick.end - pick.start, rationale: name, musicName: nil,
                          musicVolume: 0, clips: [clip], transitions: [], headline: name)
    }

    /// Where composing starts: the first transcript line at or after `after`
    /// (the last pick's end), else the first line, else the first second.
    static func draftRange(rows: [TranscriptRow], videoID: Int64, after: Double?, duration: Double) -> ClosedRange<Double> {
        let lines = rows.filter { $0.videoID == videoID && !$0.isTranslation && $0.endTime > $0.startTime }
            .sorted { $0.startTime == $1.startTime ? $0.id < $1.id : $0.startTime < $1.startTime }
        let line = after.flatMap { after in lines.first { $0.startTime >= after - 0.01 } } ?? lines.first
        if let line {
            return line.startTime...max(line.endTime, line.startTime + TranscriptQATrim.minimumSpan)
        }
        return 0...max(TranscriptQATrim.minimumSpan, min(duration, 5))
    }
}
