import SwiftUI

/// Express Transcript mode: picks on the left, the player in the middle, words on
/// the right. A "New pick" row holds the span being composed; Add (in the transcript
/// column's footer) stores it and clears the selection for the next one. Each pick
/// has a Keep box: only checked picks become footage.
struct MiniTranscriptPickView: View {
    @Environment(AppStore.self) private var store
    let run: MiniWizardRun
    /// nil = nothing selected yet.
    @State private var draftRange: ClosedRange<Double>?
    /// Where the empty draft sits while the just-added pick is still being written.
    @State private var lastAddedEnd: Double?
    /// The selected pick (the reel's Select sets it).
    @State private var selectedOwner: Int64?
    /// The transcript's words per recording, decoded when the rows change
    /// rather than on every body run (each run used to decode them twice).
    @State private var wordsByVideo: [Int64: [TranscriptQATrim.Word]] = [:]

    /// The draft's owner ID can never collide with a stored pick.
    private static let draftOwnerID: Int64 = -1
    /// Enough words for two lines of the list column.
    private static let labelLimit = 90

    private var transcript: MiniWizardTranscript? {
        store.miniRuns[.transcript]?.batchID == run.batchID ? store.miniRuns[.transcript]?.transcript : run.transcript
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

    /// Checked picks become footage; the draft row has no box.
    private var kept: Binding<Set<Int64>> {
        Binding(get: { Set(picks.filter(\.kept).map(\.id)) },
                set: { store.setMiniTranscriptPicksKept($0) })
    }

    private var items: [RangeReviewItem] {
        let empty = draft.upperBound <= draft.lowerBound
        let draftItem = RangeReviewItem(id: .init(ownerID: Self.draftOwnerID), title: "New pick",
            titleHelp: "Press a word in the transcript and drag to select a passage, adjust it, then press Add.",
            keepLabel: "New pick",
            captions: empty ? [] : [.init(text: RangeReviewItem.rangeCaption(draft), monospaced: true)],
            video: run.video, range: draft, originalRange: draft, limits: limits, trimPolicy: .pick,
            isAvailable: run.video.isPresent, isDraft: true)
        let pickItems = picks.enumerated().map { index, pick in
            let text = MiniWizardTranscriptRules.text(for: pick.range, words: wordsByVideo[pick.videoID] ?? [])
            return RangeReviewItem(id: .init(ownerID: pick.id),
                title: "\(index + 1). " + MiniWizardTranscriptRules.title(text: text, number: index + 1, limit: Self.labelLimit),
                titleHelp: text,
                keepLabel: "Pick \(index + 1)",
                captions: [.init(text: RangeReviewItem.rangeCaption(pick.range), monospaced: true)],
                video: run.video, range: pick.range, originalRange: pick.originalRange, limits: limits,
                trimPolicy: .qa, isAvailable: run.video.isPresent, titleLines: 2)
        }
        return [draftItem] + pickItems
    }

    var body: some View {
        RangeReviewView(items: items, rows: rows, labels: transcript?.labels ?? [:],
                        speakerSpans: transcript?.speakerSpans ?? [], kept: kept,
                        preferredTranslationLanguage: store.activeProfile.captionLanguages.first,
                        selection: $selectedOwner,
                        emptyTitle: "Pick a passage",
                        emptyMessage: "Select New pick, press a word in the transcript and drag, then press Add.",
                        resetTitle: "Reset to Added", autoplay: false,
                        onMove: { store.reorderMiniTranscriptPicks($0) },
                        onDelete: { item in store.deleteMiniTranscriptPick(item.id.ownerID) },
                        onDeleteAll: { store.deleteAllMiniTranscriptPicks() },
                        onSplit: { item, time in store.splitMiniTranscriptPick(item.id.ownerID, at: time) },
                        spanSelection: true, playAll: true,
                        trimAccessory: { item in
                            // Add sits in the transcript footer once a passage is marked.
                            guard item.isDraft, item.range.upperBound > item.range.lowerBound else { return nil }
                            return AnyView(addButton(item))
                        },
                        onSave: save) { _ in EmptyView() }
        .onChange(of: run.batchID) { _, _ in draftRange = nil; lastAddedEnd = nil }
        .onMiniReelReveal(.transcript, contains: { id in picks.contains { $0.id == id } }) { selectedOwner = $0 }
        .onChange(of: rows, initial: true) { _, rows in
            wordsByVideo = Dictionary(grouping: rows, by: \.videoID).mapValues(MiniWizardTranscriptRules.orderedWords)
        }
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
