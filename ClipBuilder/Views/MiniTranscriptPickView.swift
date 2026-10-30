import SwiftUI

/// Express Transcript mode: picks on the left, the player in the middle, words on
/// the right. A "New pick" row holds the span being composed; Add (in the transcript
/// column's footer) stores it and clears the selection for the next one.
struct MiniTranscriptPickView: View {
    @Environment(AppStore.self) private var store
    let run: MiniWizardRun
    /// nil = nothing selected yet.
    @State private var draftRange: ClosedRange<Double>?
    /// Where the empty draft sits while the just-added pick is still being written.
    @State private var lastAddedEnd: Double?

    /// The draft's owner ID can never collide with a stored pick.
    private static let draftOwnerID: Int64 = -1
    /// Enough words for two lines of the list column.
    private static let labelLimit = 90

    private var transcript: MiniWizardTranscript? {
        store.miniRun?.batchID == run.batchID ? store.miniRun?.transcript : run.transcript
    }
    private var picks: [TranscriptPick] { transcript?.picks ?? [] }
    private var rows: [TranscriptRow] { transcript?.rows ?? [] }
    private var limits: ClosedRange<Double> { 0...max(run.video.duration, TranscriptQATrim.minimumSpan) }

    /// An empty range marks "nothing selected"; it sits where the next pick would start.
    private var draft: ClosedRange<Double> {
        if let draftRange { return draftRange }
        let at = min(limits.upperBound, max(0, [picks.last?.end, lastAddedEnd].compactMap { $0 }.max() ?? 0))
        return at...at
    }

    private var items: [RangeReviewItem] {
        let empty = draft.upperBound <= draft.lowerBound
        let draftItem = RangeReviewItem(id: .init(ownerID: Self.draftOwnerID), title: "New pick",
            titleHelp: "Press a word in the transcript and drag to select a passage, adjust it, then press Add.",
            keepLabel: "New pick",
            captions: empty ? [] : [.init(text: RangeReviewItem.rangeCaption(draft), monospaced: true)],
            video: run.video, range: draft, originalRange: draft, limits: limits, trimPolicy: .pick,
            isAvailable: run.video.isPresent, isDraft: true)
        // Decode the transcript once per rebuild, not twice per pick.
        let allWords = MiniWizardTranscriptRules.orderedWords(rows: rows)
        let wordsByVideo = Dictionary(grouping: rows, by: \.videoID).mapValues(MiniWizardTranscriptRules.orderedWords)
        let pickItems = picks.enumerated().map { index, pick in
            RangeReviewItem(id: .init(ownerID: pick.id),
                title: "\(index + 1). " + MiniWizardTranscriptRules.title(
                    text: MiniWizardTranscriptRules.text(for: pick.range, words: wordsByVideo[pick.videoID] ?? []),
                    number: index + 1, limit: Self.labelLimit),
                titleHelp: MiniWizardTranscriptRules.text(for: pick.range, words: allWords),
                keepLabel: "Pick \(index + 1)",
                captions: [.init(text: RangeReviewItem.rangeCaption(pick.range), monospaced: true)],
                video: run.video, range: pick.range, originalRange: pick.originalRange, limits: limits,
                trimPolicy: .qa, isAvailable: run.video.isPresent, titleLines: 2)
        }
        return [draftItem] + pickItems
    }

    var body: some View {
        RangeReviewView(items: items, rows: rows, labels: transcript?.labels ?? [:],
                        speakerSpans: transcript?.speakerSpans ?? [],
                        preferredTranslationLanguage: store.activeProfile.captionLanguages.first,
                        emptyTitle: "Pick a passage",
                        emptyMessage: "Select New pick, press a word in the transcript and drag, then press Add.",
                        resetTitle: "Reset to Added", autoplay: false, transcriptLeading: true,
                        listTitle: picks.isEmpty ? "Picks" : (picks.count == 1 ? "1 pick" : "\(picks.count) picks"),
                        onMove: { store.reorderMiniTranscriptPicks($0) },
                        onDelete: { item in store.deleteMiniTranscriptPick(item.id.ownerID) },
                        onDeleteAll: { store.deleteAllMiniTranscriptPicks() },
                        spanSelection: true, playAll: true,
                        trimAccessory: { item in
                            // Add sits in the transcript footer once a passage is marked.
                            guard item.isDraft, item.range.upperBound > item.range.lowerBound else { return nil }
                            return AnyView(addButton(item))
                        },
                        onSave: save) { _ in EmptyView() }
        .onChange(of: run.batchID) { _, _ in draftRange = nil; lastAddedEnd = nil }
    }

    private func save(_ item: RangeReviewItem, start: Double, end: Double) {
        if item.isDraft {
            draftRange = end > start ? start...end : nil
        } else {
            store.setMiniTranscriptPickRange(item.id.ownerID, start: start, end: end)
        }
    }

    private func addButton(_ item: RangeReviewItem) -> some View {
        Button {
            store.addMiniTranscriptPick(range: item.range)
            lastAddedEnd = item.range.upperBound
            draftRange = nil
        } label: {
            Text("Add").lineLimit(1).fixedSize()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(store.isWizardRunning || !item.isAvailable)
        .help("Add the selected passage to the picks")
    }
}
