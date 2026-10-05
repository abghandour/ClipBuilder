import SwiftUI

/// Q&A supplies its captions and recording-wide bounds to the shared review.
struct TranscriptQAView: View {
    let video: VideoRecord
    let sections: [TranscriptQASections.Section]
    let rows: [TranscriptRow]
    let labels: [Int64: String]
    var kept: Binding<Set<Int64>>? = nil
    var preferredTranslationLanguage: String? = nil
    let onSave: (SceneRecord, Double, Double) -> Void

    var body: some View {
        RangeReviewView(items: items, rows: rows, labels: labels, kept: kept,
                        preferredTranslationLanguage: preferredTranslationLanguage,
                        onSave: { item, start, end in
                            guard let section = sections.first(where: { $0.id == item.id.ownerID }) else { return }
                            onSave(section.scene, start, end)
                        }, footer: { _ in EmptyView() })
    }

    private var items: [RangeReviewItem] {
        sections.enumerated().map { index, section in
            var captions: [RangeReviewItem.Caption] = []
            if section.asker != nil || section.answerer != nil {
                let speakers = [section.asker.map { "Asks: \($0)" }, section.answerer.map { "Answers: \($0)" }]
                    .compactMap { $0 }.joined(separator: " · ")
                captions.append(.init(text: speakers))
            }
            captions.append(.init(text: RangeReviewItem.rangeCaption(section.range), monospaced: true))
            return RangeReviewItem(id: .init(ownerID: section.id),
                title: "\(index + 1). \(section.question.split(whereSeparator: \.isNewline).first.map(String.init) ?? section.question)",
                titleHelp: section.question, keepLabel: "Keep exchange \(index + 1)", captions: captions,
                video: video, range: section.range,
                originalRange: ProposedCutTrim.range(start: section.scene.originalStart, end: section.scene.originalEnd),
                limits: TranscriptQATrim.limits(for: section, in: sections, duration: video.duration), trimPolicy: .qa)
        }
    }

    nonisolated static func columnWidths(available: CGFloat, list: CGFloat = 220,
                                         transcript: CGFloat = 360) -> (list: CGFloat, transcript: CGFloat) {
        TranscriptQAColumns.widths(available: available, list: list, transcript: transcript)
    }
}
