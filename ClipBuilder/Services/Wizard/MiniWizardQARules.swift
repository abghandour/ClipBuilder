import Foundation

nonisolated enum MiniWizardQARules {
    static func title(question: String?, number: Int) -> String {
        let firstLine = question?.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let text = firstLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return "Exchange \(number)" }
        return text.count > 60 ? String(text.prefix(59)) + "…" : text
    }

    /// Q&A has no target duration: preserve the whole current exchange, including
    /// hand edits, rather than applying the highlight planner's length constraints.
    static func plans(sections: [TranscriptQASections.Section], kept: Set<Int64>,
                      rows: [TranscriptRow], turns: [SpeakerTurn]) -> [WizardPlan] {
        let ordered = sections.sorted {
            $0.scene.startTime == $1.scene.startTime ? $0.id < $1.id : $0.scene.startTime < $1.scene.startTime
        }
        return ordered.enumerated().compactMap { index, section in
            guard kept.contains(section.id), section.scene.startTime.isFinite,
                  section.scene.endTime.isFinite, section.scene.endTime > section.scene.startTime else { return nil }
            let videoRows = rows.filter { $0.videoID == section.scene.videoID }
            let question = TranscriptQASections.lines(rows: videoRows, range: section.range, context: 0).first?.row.text
            let name = title(question: question, number: index + 1)
            let result = WizardPlanRules.podcastExchangeCuts(scene: section.range,
                sentenceEnds: videoRows.filter { !$0.isTranslation }.map(\.endTime),
                turns: turns.filter { $0.videoID == section.scene.videoID },
                proposed: [section.range], targetSeconds: nil)
            guard let range = result.cuts.first else { return nil }
            let clip = WizardPlanClip(sceneID: section.id, start: range.lowerBound, end: range.upperBound)
            let plan = WizardPlan(targetDuration: range.upperBound - range.lowerBound,
                rationale: name, musicName: nil, musicVolume: 0, clips: [clip], transitions: [], headline: name)
            return WizardSelectionRules.snapshot(plan, scenes: [section.scene])
        }
    }
}
