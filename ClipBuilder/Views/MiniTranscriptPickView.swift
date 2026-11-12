import SwiftUI

/// Express Transcript mode: picks on the left, the player in the middle, words on
/// the right. A "New pick" row holds the span being composed; Add (in the transcript
/// column's footer) stores it and clears the selection for the next one. Each pick
/// has a Keep box: only checked picks become footage. Shift-drag marks another
/// passage in the same New pick; Add then stores them as one pick whose cuts
/// play in the order they were marked.
struct MiniTranscriptPickView: View {
    @Environment(AppStore.self) private var store
    let run: MiniWizardRun
    /// The passages marked for the next pick; empty = nothing selected yet.
    @State private var composing = TranscriptDraftSelection()
    /// Where the empty draft sits while the just-added pick is still being written.
    @State private var lastAddedEnd: Double?
    /// The selected pick (the reel's Select sets it).
    @State private var selectedOwner: Int64?
    /// The passage of the selected pick the reel asked for.
    @State private var requestedCut: Int?
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
        if let range = composing.currentRange { return range }
        let at = min(limits.upperBound, max(0, composing.startedAt ?? [picks.last?.end, lastAddedEnd].compactMap { $0 }.max() ?? 0))
        return at...at
    }

    /// The selected row. A unit is named by its first pick, which changes
    /// when its passages are reordered (here or in the reel): the row is
    /// looked up through whichever pick was remembered.
    private var selection: Binding<Int64?> {
        Binding(get: { selectedOwner.map { id in units.first { $0.contains { $0.id == id } }?[0].id ?? id } },
                set: { selectedOwner = $0 })
    }

    /// The list's rows: a pick, or the picks added together as one.
    private var units: [[TranscriptPick]] { TranscriptPickUnits.units(picks) }

    /// Checked picks become footage; the draft row has no box. A unit's box
    /// is checked while any of its cuts is kept.
    private var kept: Binding<Set<Int64>> {
        Binding(get: { Set(units.filter { $0.contains(where: \.kept) }.map { $0[0].id }) },
                set: { store.setMiniTranscriptPicksKept(TranscriptPickUnits.kept(picks, owners: $0)) })
    }

    private var draftCaptions: [RangeReviewItem.Caption] {
        guard draft.upperBound > draft.lowerBound || !composing.spans.isEmpty else { return [] }
        var captions: [RangeReviewItem.Caption] = []
        if draft.upperBound > draft.lowerBound { captions.append(.init(text: RangeReviewItem.rangeCaption(draft), monospaced: true)) }
        if composing.spans.count > 1 {
            let total = composing.spans.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
            let which = composing.currentRange == nil ? "" : "Selection \(composing.current + 1) of \(composing.spans.count) · "
            captions.append(.init(text: "\(which)\(composing.spans.count) selections, \(total.formatted(.number.precision(.fractionLength(1))))s",
                                  monospaced: true))
        }
        return captions
    }

    private var items: [RangeReviewItem] {
        let draftItem = RangeReviewItem(id: .init(ownerID: Self.draftOwnerID), title: "New pick",
            titleHelp: "Press a word in the transcript and drag to select a passage, adjust it, then press Add. Hold Shift and drag to add another passage to the same pick. With a saved pick selected, Shift-drag adds a passage to it.",
            keepLabel: "New pick",
            captions: draftCaptions,
            video: run.video, range: draft, originalRange: draft, limits: limits, trimPolicy: .pick,
            isAvailable: run.video.isPresent, isDraft: true)
        let pickItems = units.enumerated().map { index, unit in
            let pick = unit[0]
            let texts = unit.map { MiniWizardTranscriptRules.text(for: $0.range, words: wordsByVideo[$0.videoID] ?? []) }
            var item = RangeReviewItem(id: .init(ownerID: pick.id),
                title: "\(index + 1). " + MiniWizardTranscriptRules.title(text: texts[0], number: index + 1, limit: Self.labelLimit),
                titleHelp: texts.joined(separator: "\n\n"),
                keepLabel: "Pick \(index + 1)",
                captions: [.init(text: RangeReviewItem.rangeCaption(pick.range), monospaced: true)],
                video: run.video, range: pick.range, originalRange: pick.originalRange, limits: limits,
                trimPolicy: .qa, isAvailable: run.video.isPresent, titleLines: 2)
            // A pick alone is its own passage: the selection follows it into and out of a link.
            guard unit.count > 1 else { item.stableID = pick.id; return item }
            // Added together: one row, its passages as cuts in the order they play.
            let total = unit.reduce(0) { $0 + $1.end - $1.start }
            // Room is left for the count so the two title lines never cut it off.
            item.title = "\(index + 1). " + MiniWizardTranscriptRules.title(text: texts[0], number: index + 1,
                                                                            limit: Self.labelLimit - 12) + " (\(unit.count))"
            item.captions = [.init(text: "\(unit.count) passages · \(total.formatted(.number.precision(.fractionLength(1))))s", monospaced: true)]
            item.children = unit.enumerated().map { cut, pick in
                RangeReviewItem(id: .init(ownerID: unit[0].id, cutIndex: cut),
                    title: "#\(cut + 1) " + MiniWizardTranscriptRules.title(text: texts[cut], number: cut + 1, limit: Self.labelLimit),
                    titleHelp: texts[cut],
                    keepLabel: "Passage \(cut + 1)",
                    captions: [.init(text: RangeReviewItem.rangeCaption(pick.range), monospaced: true)],
                    video: run.video, range: pick.range, originalRange: pick.originalRange, limits: limits,
                    trimPolicy: .qa, isAvailable: run.video.isPresent, stableID: pick.id, titleLines: 2)
            }
            return item
        }
        return [draftItem] + pickItems
    }

    var body: some View {
        RangeReviewView(items: items, rows: rows, labels: transcript?.labels ?? [:],
                        speakerSpans: transcript?.speakerSpans ?? [], kept: kept,
                        palette: .transcript,
                        preferredTranslationLanguage: store.activeProfile.captionLanguages.first,
                        selection: selection, requestedCut: $requestedCut,
                        onDeleteCut: deleteCut, onMoveCut: moveCut,
                        onUnlink: { item in
                            store.setMiniTranscriptPicksLinked(units.first { $0[0].id == item.id.ownerID }?.map(\.id) ?? [], linked: false)
                        },
                        onLink: { owners in
                            store.setMiniTranscriptPicksLinked(owners.flatMap { owner in
                                units.first { $0[0].id == owner }?.map(\.id) ?? []
                            }, linked: true)
                        },
                        onAddCut: addCut, splitsCuts: true,
                        emptyTitle: "Pick a passage",
                        emptyMessage: "Select New pick, press a word in the transcript and drag, then press Add.",
                        resetTitle: "Reset to Added", autoplay: false,
                        onMove: { store.reorderMiniTranscriptPicks(TranscriptPickUnits.order(picks, unitOwners: $0)) },
                        onDelete: { item in
                            store.deleteMiniTranscriptPicks(units.first { $0[0].id == item.id.ownerID }?.map(\.id) ?? [item.id.ownerID])
                        },
                        onDeleteAll: { store.deleteAllMiniTranscriptPicks() },
                        onSplit: { item, time in store.splitMiniTranscriptPick(pickID(of: item), at: time) },
                        spanSelection: true,
                        draftSpans: RangeReviewDraftSpans(others: composing.others, currentNumber: composing.currentNumber,
                                                          begin: { composing.begin() },
                                                          select: { composing.select(number: $0) },
                                                          delete: { composing.remove(number: $0) },
                                                          clear: { composing = TranscriptDraftSelection() }),
                        playAll: true,
                        trimAccessory: { item in
                            // Add sits in the transcript footer once a passage is marked.
                            guard item.isDraft, item.range.upperBound > item.range.lowerBound, !composing.spans.isEmpty else { return nil }
                            return AnyView(addButton(item))
                        },
                        onSave: save) { _ in EmptyView() }
        .onChange(of: run.batchID) { _, _ in composing = TranscriptDraftSelection(); lastAddedEnd = nil }
        // The reel names one pick; its row is the unit it belongs to.
        .onMiniReelReveal(.transcript, contains: { id in picks.contains { $0.id == id } }) { id in
            let unit = units.first { $0.contains { $0.id == id } }
            requestedCut = unit.flatMap { $0.count > 1 ? $0.firstIndex { $0.id == id } : nil }
            selectedOwner = unit?[0].id ?? id
        }
        .onChange(of: rows, initial: true) { _, rows in
            wordsByVideo = Dictionary(grouping: rows, by: \.videoID).mapValues(MiniWizardTranscriptRules.orderedWords)
        }
    }

    /// A row's pick: a cut of a unit is its own pick, not the unit's first.
    private func pickID(of item: RangeReviewItem) -> Int64 {
        guard let cut = item.id.cutIndex, let unit = units.first(where: { $0[0].id == item.id.ownerID }),
              unit.indices.contains(cut) else { return item.id.ownerID }
        return unit[cut].id
    }

    /// A passage dragged among its pick's passages; the one on screen stays selected.
    private func moveCut(_ owner: RangeReviewItem, order: [Int], selected: RangeReviewItem.ID?) -> RangeReviewItem.ID? {
        guard let unit = units.first(where: { $0[0].id == owner.id.ownerID }),
              let moved = TranscriptPickUnits.moving(picks, unit: unit.map(\.id), order: order,
                                                     selected: selected?.ownerID == owner.id.ownerID ? selected?.cutIndex : nil)
        else { return nil }
        store.reorderMiniTranscriptPicks(moved.ids)
        guard selected?.ownerID == owner.id.ownerID else { return nil }
        return .init(ownerID: moved.owner, cutIndex: moved.cut)
    }

    /// A passage marked while a saved pick is selected joins it as its last.
    private func addCut(_ owner: RangeReviewItem, range: ClosedRange<Double>) -> RangeReviewItem.ID? {
        guard let unit = units.first(where: { $0[0].id == owner.id.ownerID }) else { return nil }
        store.addMiniTranscriptPassage(to: unit.map(\.id), range: range)
        return .init(ownerID: unit[0].id, cutIndex: unit.count)
    }

    /// One passage leaves its pick; the passage on screen stays the one selected.
    private func deleteCut(_ item: RangeReviewItem, selected: RangeReviewItem.ID) -> RangeReviewItem.ID? {
        guard let unit = units.first(where: { $0[0].id == item.id.ownerID }), let removed = item.id.cutIndex,
              let next = TranscriptPickUnits.selectionAfterRemoving(unit: unit.map(\.id), removed: removed,
                                                                    selected: selected.cutIndex ?? 0) else { return nil }
        store.deleteMiniTranscriptPick(unit[removed].id)
        return .init(ownerID: next.owner, cutIndex: next.cut)
    }

    private func save(_ item: RangeReviewItem, start: Double, end: Double) {
        if item.isDraft {
            composing.set(start...max(start, end))
        } else {
            store.setMiniTranscriptPickRange(pickID(of: item), start: start, end: end)
        }
    }

    private func addButton(_ item: RangeReviewItem) -> some View {
        Button {
            store.addMiniTranscriptPicks(ranges: composing.spans)
            lastAddedEnd = composing.spans.map(\.upperBound).max() ?? item.range.upperBound
            composing = TranscriptDraftSelection()
        } label: {
            Text(composing.spans.count > 1 ? "Add \(composing.spans.count) as One Pick" : "Add").lineLimit(1).fixedSize()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(store.isWizardRunning || !item.isAvailable)
        .help(composing.spans.count > 1 ? "Add the selections as one pick; they play in the order they were marked"
              : "Add the selected passage to the picks")
    }
}
