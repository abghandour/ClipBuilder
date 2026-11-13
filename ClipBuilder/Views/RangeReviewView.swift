import SwiftUI
import AVKit

/// Shared review surface; adapters own domain data and persistence.
struct RangeReviewView<Footer: View>: View {
    @Environment(AppStore.self) private var store
    @Environment(\.isEnabled) private var isEnabled
    let items: [RangeReviewItem]
    let rows: [TranscriptRow]
    let labels: [Int64: String]
    /// Named speaker turns; rows crossing a speaker change split into one line per speaker.
    var speakerSpans: [TranscriptQATrim.SpeakerSpan] = []
    var kept: Binding<Set<Int64>>? = nil
    /// The colour family of this list's bars and transcript blocks: each
    /// Express Footage section has its own, so no two share a colour.
    var palette: RangeReviewPalette.Family = .qa
    var preferredTranslationLanguage: String? = nil
    var selection: Binding<Int64?>? = nil
    /// The cut of the `selection` owner to show (the reel's Select names one
    /// passage of a pick made of several); taken once, then cleared.
    var requestedCut: Binding<Int?>? = nil
    /// Remove one cut of a saved multi-cut item: its passages then carry
    /// their number and a delete button in the transcript, as while composing.
    /// Gets the cut to remove and the selected one; returns the row to select
    /// afterwards (cuts are named by position, so the ones after it move up).
    var onDeleteCut: ((RangeReviewItem, RangeReviewItem.ID) -> RangeReviewItem.ID?)? = nil
    /// Drag a cut of a multi-cut item among its siblings: gets the owner,
    /// the cuts' old indices in their new order and the selected row;
    /// returns the row to select afterwards.
    var onMoveCut: ((RangeReviewItem, [Int], RangeReviewItem.ID?) -> RangeReviewItem.ID?)? = nil
    /// Split also applies to a cut of a multi-cut item (`onSplit` gets the cut).
    /// Turns an item made of several passages back into separate items; a
    /// chain button on its row.
    var onUnlink: ((RangeReviewItem) -> Void)? = nil
    /// Joins the highlighted rows (Shift-click) into one item: receives
    /// their owner ids in list order. A chain button in the list's footer.
    var onLink: (([Int64]) -> Void)? = nil
    /// A passage marked in the words while a saved item's row is selected
    /// (or with Shift from one of its passages) joins that item: receives
    /// the item and the range, returns the new passage's id.
    var onAddCut: ((RangeReviewItem, ClosedRange<Double>) -> RangeReviewItem.ID?)? = nil
    var splitsCuts = false
    var emptyTitle = "Select a Q&A section"
    var emptyMessage = "Choose an exchange to watch it and adjust its start and end."
    var resetTitle = "Reset to Original"
    /// Start playing when an item is shown or selected. Explicit word clicks always play.
    var autoplay = true
    /// Fixed list : transcript : player shares instead of the dragged widths.
    var columnShares: (list: CGFloat, transcript: CGFloat, player: CGFloat)? = nil
    /// Heading above the list when there is no Keep checkbox.
    var listTitle: String? = nil
    /// Drag to reorder: receives every top-level owner ID in its new order.
    var onMove: (([Int64]) -> Void)? = nil
    /// Delete from the row's context menu or the Delete key.
    var onDelete: ((RangeReviewItem) -> Void)? = nil
    /// A Remove All button in the list's footer toolbar, shown while the list has items.
    var onDeleteAll: (() -> Void)? = nil
    /// Split the selected saved item in two at a source time (the playhead).
    var onSplit: ((RangeReviewItem, Double) -> Void)? = nil
    @State private var confirmingDeleteAll = false
    /// Draft items select by pressing a word and dragging; an empty range means nothing selected.
    var spanSelection = false
    /// The draft item is made of several passages (Shift-drag adds one):
    /// the draft's range is the one being adjusted, these are the others.
    var draftSpans: RangeReviewDraftSpans? = nil
    /// A Play All button under the list plays every item in order.
    var playAll = false
    /// Replaces the transcript words column (Fight metrics shows its action grid there).
    var leadingPanel: AnyView? = nil
    /// A control for the transcript column's header, per selected item.
    var transcriptAccessory: ((RangeReviewItem) -> AnyView?)? = nil
    /// A control in the transcript column's footer while a span is marked
    /// (Express's Add button); the permanent Clear and Reset sit in the same row.
    var trimAccessory: ((RangeReviewItem) -> AnyView?)? = nil
    /// Shown in the trim column while a draft has no range yet.
    var emptyDraftHint = "Press a word in the transcript and drag to select a passage."
    /// Replaces the trim hint under the filmstrip (no transcript words to click in Fight metrics).
    var trimHint: String? = nil
    /// Shown in the player while the selected item cannot be previewed.
    var unavailableHint = "Footage unavailable: this video is not on this Mac."
    let onSave: (RangeReviewItem, Double, Double) -> Void
    @ViewBuilder var footer: (RangeReviewItem) -> Footer

    @State private var selectedID: RangeReviewItem.ID?
    /// The selected cut's `stableID`, to find it again after its siblings moved.
    @State private var selectedStable: Int64?
    /// A span being marked is a new passage of the selected item (Shift-drag).
    @State private var addingCut = false
    /// Rows highlighted together for Link, by owner id (Shift- or Command-click).
    @State private var highlighted: Set<Int64> = []
    /// The passage just added, selected when its row arrives.
    @State private var pendingCut: RangeReviewItem.ID?
    /// The user clicked the selected row to clear it; nothing is auto-selected until they pick again.
    @State private var userCleared = false
    /// A span dragged while nothing was selected: applied once the draft item is selected.
    @State private var pendingDraft: (start: Double, end: Double)?
    /// A commit that arrived in the same event as the activating span (a single word click).
    @State private var pendingCommit = false
    @State private var draggingID: RangeReviewItem.ID?
    @State private var dragTranslation: CGFloat = 0
    /// Slot between reorderable blocks where the dragged row would land (0 = first).
    @State private var dropSlot: Int?
    @State private var rowFrames: [RangeReviewItem.ID: CGRect] = [:]
    private static var listSpace: String { "rangeReview.list" }
    @Environment(\.workspacePageVisible) private var pageVisible
    @State private var playback = PodcastHighlightTrimPlayback()
    /// Seconds the ending button plays before the section's end; one
    /// remembered choice for every review surface.
    @AppStorage("playback.endingSeconds") private var endingSeconds = 3
    private static var endingChoices: [Int] { [5, 3, 2, 1] }
    @State private var loadedURL: URL?
    @State private var draft: (start: Double, end: Double)?
    /// Bumped per commit: a draft whose save never lands is dropped after a moment.
    @State private var draftGeneration = 0
    @State private var showingShortcuts = false
    /// The last one-click adjustment, so the next pick can take the same one.
    @State private var lastAdjustment: RangeAdjustment?
    /// The anchor being dragged in the transcript; the player and filmstrip
    /// hold the saved range until it is released, then jump to this edge.
    @State private var anchorDrag: TranscriptQATrim.Edge?
    @State private var window = ProposedCutTrim.Window(start: 0, span: 30)
    @State private var transcript = TranscriptQATrim.Transcript()
    @State private var transcriptVideoID: Int64?
    @State private var translationLanguages: [String] = []
    @State private var translationsByLanguage: [String: [Int: String]] = [:]
    @State private var playingAll = false
    /// Set while Play All moves the selection, so the pause it causes is not taken as the end.
    @State private var advancingPlayAll = false
    @AppStorage("transcriptQA.listWidth") private var listWidth = 220.0
    @AppStorage("transcriptQA.transcriptWidth") private var transcriptWidth = 360.0

    private var selectedParent: RangeReviewItem? { items.first { $0.id.ownerID == selectedID?.ownerID } }
    private var selected: RangeReviewItem? {
        guard let parent = selectedParent else { return nil }
        return parent.children.first { $0.id == selectedID } ?? parent.children.first ?? parent
    }
    private var video: VideoRecord? { selected?.video }
    /// The recording whose transcript shows even while nothing is selected.
    private var contextVideo: VideoRecord? { video ?? items.first?.video }
    private var range: ClosedRange<Double>? { selected?.range }
    private var limits: ClosedRange<Double> { selected?.limits ?? 0...0 }
    private var policy: RangeReviewItem.TrimPolicy { selected?.trimPolicy ?? .qa }
    private var canTrim: Bool {
        guard let selected, selected.isAvailable else { return false }
        return policy == .wizard ? limits.upperBound > limits.lowerBound
            : limits.upperBound - limits.lowerBound >= policy.minimumSpan
    }
    private var editRange: ClosedRange<Double> {
        let start = draft?.start ?? range?.lowerBound ?? 0
        let end = draft?.end ?? range?.upperBound ?? start
        // An unavailable item (its scene is gone, "Footage changed") has no
        // limits; clamping into 0...0 would hide its passage and park the words
        // at the top. It still marks its range, it just cannot be trimmed.
        guard limits.upperBound > limits.lowerBound else { return start...max(start, end) }
        return policy.clamp(start...max(start, end), limits: limits)
    }
    /// Nothing selected yet (pick drafts only).
    private var isEmptyRange: Bool { editRange.upperBound <= editRange.lowerBound }
    /// A range the player can hold even while nothing is selected.
    private func playable(_ range: ClosedRange<Double>) -> ClosedRange<Double> {
        range.upperBound > range.lowerBound ? range : range.lowerBound...(range.lowerBound + 1)
    }
    private var visibleTranscript: TranscriptQATrim.Transcript {
        transcriptVideoID == contextVideo?.id ? transcript : TranscriptQATrim.Transcript()
    }
    private var transcriptInput: TranscriptQATrim.Input {
        TranscriptQATrim.Input(rows: rows, labels: labels, videoID: contextVideo?.id ?? -1, speakerSpans: speakerSpans)
    }
    /// Position of a saved item among the saved items, for its palette colour.
    private func paletteIndex(_ item: RangeReviewItem) -> Int? {
        guard !item.isDraft,
              let index = items.filter({ !$0.isDraft }).firstIndex(where: { $0.id.ownerID == item.id.ownerID }) else { return nil }
        return RangeReviewPalette.slot(index, family: palette)
    }

    /// Saved picks of `video` as marked ranges, in the colour of their rows:
    /// the kept items (none when nothing is kept), or every item in a list
    /// without keep boxes, selection or not. The selected item paints itself
    /// through `range`; its sibling cuts paint here.
    private func markedRanges(excluding selectedID: RangeReviewItem.ID?, owner: Int64? = nil,
                              video: VideoRecord) -> [RangeReviewMarkedRange] {
        let ownerID = owner ?? selectedID?.ownerID
        let painted = RangeReviewItem.paintedOwnerIDs(items: items, selectedOwnerID: ownerID, kept: kept?.wrappedValue)
        return items.flatMap { owner in
            (owner.children.isEmpty ? [owner] : owner.children).compactMap { item -> RangeReviewMarkedRange? in
                // The selected cut paints through `range`; its sibling cuts
                // (the other clips of a multi-cut reel) still mark themselves.
                let sibling = ownerID != nil && owner.id.ownerID == ownerID
                guard painted.contains(owner.id.ownerID) || sibling, item.id != selectedID, item.video.id == video.id,
                      let index = paletteIndex(owner) else { return nil }
                return RangeReviewMarkedRange(range: item.range, paletteIndex: index)
            }
        }
    }

    private var visibleItems: [RangeReviewItem] {
        items.flatMap { item in [item] + (item.id.ownerID == selectedID?.ownerID ? item.children : []) }
    }

    var body: some View {
        GeometryReader { geometry in
            let widths = columnShares.map {
                TranscriptQAColumns.proportional(available: geometry.size.width,
                                                 list: $0.list, transcript: $0.transcript, player: $0.player)
            } ?? Self.columnWidths(available: geometry.size.width,
                                   list: CGFloat(listWidth), transcript: CGFloat(transcriptWidth))
            let playerWidth = max(0, geometry.size.width - widths.list - widths.transcript
                                  - 2 * TranscriptQAColumns.dividerWidth)
            HStack(spacing: 0) {
                itemList.frame(width: widths.list, alignment: .leading).clipped()
                columnDivider(.list, width: widths.list, otherWidth: widths.transcript,
                              available: geometry.size.width)
                // The word panel is one view whether or not something is
                // selected, so a drag that starts with nothing selected
                // keeps its gesture state while it selects the draft, and
                // the words stay readable with nothing marked.
                // Words sit next to the list, the player on the right.
                if let context = selected ?? items.first {
                    Group {
                        if let leadingPanel { leadingPanel }
                        else { wordPanel(selected: context, video: context.video, inactive: selected == nil) }
                    }
                    .frame(width: widths.transcript, alignment: .leading).clipped()
                    columnDivider(.transcript, width: widths.transcript, otherWidth: widths.list,
                                  available: geometry.size.width)
                    if let selected {
                        trimSurface(item: selected).padding(Theme.spaceS)
                        .frame(width: playerWidth).frame(maxHeight: .infinity, alignment: .top).clipped()
                    } else {
                        ContentUnavailableView(emptyTitle, systemImage: "text.bubble",
                                               description: Text(emptyMessage))
                            .frame(width: playerWidth, alignment: .center).frame(maxHeight: .infinity)
                    }
                } else {
                    ContentUnavailableView(emptyTitle, systemImage: "text.bubble",
                                           description: Text(emptyMessage))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .coordinateSpace(name: "transcriptQA.columns")
        }
        .task(id: transcriptInput) {
            let input = transcriptInput
            // Tokenize and match translations away from the main actor, once
            // per transcript change rather than on every playhead update.
            let task = Task.detached {
                let transcript = TranscriptQATrim.Transcript(input)
                let videoRows = input.rows.filter { $0.videoID == input.videoID }
                let languages = TranscriptQATrim.availableTranslationLanguages(rows: videoRows)
                let translations = Dictionary(uniqueKeysWithValues: languages.map { language in
                    (language, TranscriptQATrim.translations(for: transcript.lines, rows: videoRows, language: language))
                })
                return (transcript, languages, translations)
            }
            let result = await task.value
            guard !Task.isCancelled else { return }
            transcriptVideoID = input.videoID
            transcript = result.0
            translationLanguages = result.1
            translationsByLanguage = result.2
        }
        .onAppear { reconcileSelection(); selectItem() }
        .onChange(of: selectedID) { _, _ in
            // The user went elsewhere: a passage still being added no longer takes the selection.
            pendingCut = nil
            selectedStable = stableID(of: selectedID)
            selection?.wrappedValue = selectedID?.ownerID
            selectItem()
            applyPendingDraft()
            if playingAll {
                if advancingPlayAll, playback.player != nil, let range, range.upperBound > range.lowerBound {
                    playback.play()
                    advancingPlayAll = false
                } else if advancingPlayAll, loadedURL != nil, selected?.isAvailable == true {
                    // The next cut is in another file: play once it loads.
                } else {
                    // The user chose another item: Play All is over.
                    playingAll = false
                    advancingPlayAll = false
                }
            }
        }
        // Only a cut that played to its end advances: a pause from scrubbing
        // or dragging a trim handle keeps the cut and its draft.
        .onChange(of: playback.endCount) { _, _ in
            guard playingAll, !advancingPlayAll else { return }
            advancePlayAll()
        }
        .onChange(of: rowIdentities) { _, _ in reconcileSelection() }
        .speakerColors(for: Set(labels.values).union(speakerSpans.map(\.label)))
        .onChange(of: selection?.wrappedValue) { _, ownerID in
            if ownerID != selectedID?.ownerID { reconcileSelection() } else { applyRequestedCut() }
        }
        .onChange(of: requestedCut?.wrappedValue, initial: true) { _, _ in applyRequestedCut() }
        .onChange(of: range) { _, range in
            guard let range else { return }
            if let draft, abs(draft.start - range.lowerBound) < 0.05, abs(draft.end - range.upperBound) < 0.05 {
                self.draft = nil
            }
            guard draft == nil else { return }
            playback.setRange(playable(range))
            if window.needsRecentering(range) { recenter(range) }
        }
        .onChange(of: playback.player != nil) { _, ready in
            // Selection may have changed while the same file was loading.
            if ready, let range, selected?.isAvailable == true {
                playback.setRange(playable(range))
                playback.seek(to: range.lowerBound)
                if playingAll, advancingPlayAll {
                    advancingPlayAll = false
                    playback.play()
                } else if isEnabled, autoplay {
                    playback.play()
                }
            }
        }
        .onChange(of: video?.url) { _, _ in selectItem() }
        .onChange(of: selected?.isAvailable) { _, _ in selectItem() }
        .onChange(of: limits) { _, _ in
            draft = nil
            if let range { recenter(range) }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { draft = nil; playingAll = false; playback.pause() }
        }
        .onChange(of: pageVisible) { _, visible in if !visible { playback.pause() } }
        .onDisappear {
            playback.tearDown()
            loadedURL = nil
        }
        .background {
            PodcastHighlightScreeningKeys(isActive: { false }, rate: { _ in }, other: handleKey)
                .frame(width: 0, height: 0)
        }
    }

    /// The owner did not ask for another row since the cut was selected.
    private func followsSelection(_ match: RangeReviewItem) -> Bool {
        guard let asked = selection?.wrappedValue else { return selection == nil }
        return asked == match.id.ownerID || asked == selectedID?.ownerID
    }

    private func stableID(of id: RangeReviewItem.ID?) -> Int64? {
        guard let id else { return nil }
        for item in items {
            if item.id == id { return item.stableID }
            if let child = item.children.first(where: { $0.id == id }) { return child.stableID }
        }
        return nil
    }

    /// The row standing for `stable`: a cut, or an item that is one cut
    /// alone (a cut becomes one when its item is unlinked, and back).
    private func cut(stable: Int64) -> RangeReviewItem? {
        for item in items {
            if let child = item.children.first(where: { $0.stableID == stable }) { return child }
        }
        return items.first { $0.stableID == stable }
    }

    private struct RowIdentity: Equatable {
        var id: RangeReviewItem.ID
        var stable: Int64?
    }

    /// Every row, with what a cut stands for: cuts are named by position, so
    /// a reorder (here, in the reel, by Undo) leaves every id in place while
    /// the cuts behind them changed.
    private var rowIdentities: [RowIdentity] {
        var result: [RowIdentity] = []
        for item in items {
            result.append(RowIdentity(id: item.id, stable: item.stableID))
            for child in item.children { result.append(RowIdentity(id: child.id, stable: child.stableID)) }
        }
        return result
    }

    nonisolated static func columnWidths(available: CGFloat, list: CGFloat = 220,
                                         transcript: CGFloat = 360) -> (list: CGFloat, transcript: CGFloat) {
        TranscriptQAColumns.widths(available: available, list: list, transcript: transcript)
    }

    /// `inactive` shows the words with nothing marked while no item is
    /// selected; a word click selects the item under the word (else `selected`,
    /// the first item or the draft in pick lists) with just that word as its
    /// range, and a drag selects it and marks the span in one move.
    private func wordPanel(selected: RangeReviewItem, video: VideoRecord, inactive: Bool = false) -> some View {
        // Nothing marked, but the words open on the first painted (kept)
        // passage so the highlights are in view, else on `selected`.
        // The row of an item made of several passages is selected, not one
        // of them: none is the one being adjusted, and a passage marked now
        // is a new one. Shift-drag adds one from any saved passage.
        let wholeItem = !inactive && !selected.isDraft && onAddCut != nil && selectedID?.cutIndex == nil
            && selected.id.cutIndex != nil
        let adding = !inactive && (wholeItem || addingCut)
        let marked = markedRanges(excluding: inactive || adding ? nil : selected.id,
                                  owner: adding ? selected.id.ownerID : nil, video: video)
        let anchor = inactive ? marked.map(\.range.lowerBound).min() ?? selected.range.lowerBound : selected.range.lowerBound
        let emptyRange = anchor...anchor
        let contextCanTrim = inactive ? selected.isAvailable : canTrim
        func activate(at word: TranscriptQATrim.Word? = nil) {
            // The saved cut under the word wins (the cut itself, not its
            // owner: a multi-cut reel's first cut must not take a word from
            // its second); pick drafts fall back to `selected`.
            let under = word.flatMap { itemUnder($0, video: video) }
            let target = under ?? selected
            if let word, word.end > word.start, under?.isAvailable ?? contextCanTrim {
                // With nothing selected a click selects that word alone, not the
                // saved passage under it; Reset to Original brings the passage back.
                pendingDraft = (word.start, word.end)
                pendingCommit = true
            }
            if selectedID == target.id {
                // Already selected: no selection change will apply the draft.
                applyPendingDraft()
            } else {
                selectedID = target.id
            }
            userCleared = false
        }
        // A saved item made of several passages shows them numbered, like the
        // selection it was added from.
        let siblings: [RangeReviewItem] = !inactive && !selected.isDraft && onDeleteCut != nil && selected.id.cutIndex != nil
            ? (items.first { $0.id.ownerID == selected.id.ownerID }?.children ?? []).filter { $0.video.id == video.id } : []
        let numbered = siblings.count > 1
        func sibling(_ number: Int) -> RangeReviewItem? { siblings.first { $0.id.cutIndex == number - 1 } }
        return TranscriptQAWordPanel(transcript: visibleTranscript, videoID: video.id,
                              translationLanguages: transcriptVideoID == video.id ? translationLanguages : [],
                              translationsByLanguage: transcriptVideoID == video.id ? translationsByLanguage : [:],
                              preferredTranslationLanguage: preferredTranslationLanguage,
                              sectionID: selected.id,
                              range: inactive || (adding && draft == nil) ? emptyRange : editRange,
                              otherRanges: marked,
                              playback: playback, canTrim: contextCanTrim,
                              onSelect: inactive ? { activate(at: $0) } : selectWord,
                              onPreview: inactive ? { _, word in activate(at: word) } : previewWord,
                              onCommit: {
                                  if inactive { pendingCommit = pendingDraft != nil }
                                  else if wholeItem || addingCut { commitNewCut() }
                                  else { commitDraft(snap: false) }
                              },
                              onCancel: { draft = nil; anchorDrag = nil; addingCut = false },
                              spanSelection: spanSelection,
                              followsEmptyAnchor: inactive,
                              onSpanPreview: { span in
                                  guard isEnabled, contextCanTrim else { return }
                                  if inactive {
                                      pendingDraft = (span.lowerBound, span.upperBound)
                                      activate()
                                  } else {
                                      draft = (span.lowerBound, span.upperBound)
                                  }
                              },
                              draftSpans: selected.isDraft ? draftSpans?.others ?? []
                                  : numbered ? siblings.filter { adding || $0.id != selected.id }.compactMap { item in
                                      item.id.cutIndex.map { TranscriptDraftSpan(number: $0 + 1, range: item.range) }
                                  } : [],
                              paintsDraftSpans: selected.isDraft,
                              currentSpanNumber: selected.isDraft ? draftSpans?.currentNumber
                                  : numbered && !adding ? selected.id.cutIndex.map { $0 + 1 } : nil,
                              onBeginSpan: selected.isDraft ? draftSpans.map { spans in { dropDraft(); spans.begin() } }
                                  : onAddCut != nil && !inactive ? { dropDraft(); addingCut = true } : nil,
                              onSelectSpan: selected.isDraft ? draftSpans.map { spans in
                                  { number in
                                      dropDraft()
                                      spans.select(number)
                                      if inactive { activate() }
                                  }
                              } : numbered ? { number in
                                  guard let item = sibling(number), item.id != selectedID else { addingCut = false; return }
                                  dropDraft()
                                  selectedID = item.id
                              } : nil,
                              onDeleteSpan: selected.isDraft ? draftSpans.map { spans in { dropDraft(); spans.delete($0) } }
                                  : numbered ? onDeleteCut.map { delete in
                                      { number in
                                          guard let item = sibling(number) else { return }
                                          dropDraft()
                                          if let next = delete(item, selected.id) {
                                              userCleared = false
                                              selectedID = next
                                          }
                                      }
                                  } : nil,
                              accessory: inactive ? nil : transcriptAccessory?(selected),
                              footer: AnyView(rangeActions(selected, inactive: inactive)))
    }

    /// The passage being adjusted changes under the view: an edit in flight
    /// belongs to the one before and must not land on the next.
    private func dropDraft() {
        addingCut = false
        pendingCut = nil
        draft = nil
        anchorDrag = nil
        pendingDraft = nil
        pendingCommit = false
        draftGeneration += 1
    }

    /// Add for a marked draft, Clear, and Reset, pinned under the words. The
    /// row is always there so the column does not jump as the selection changes.
    private func rangeActions(_ item: RangeReviewItem, inactive: Bool) -> some View {
        HStack(spacing: Theme.spaceS) {
            if !inactive { draftActions(item) }
            clearButton(item, inactive: inactive)
            Spacer(minLength: 0)
            if !inactive { resetButton(item) }
        }
    }

    /// Drops any marked passage and deselects the item, like clicking the
    /// selected row: one button that leaves nothing selected.
    private func clearButton(_ item: RangeReviewItem, inactive: Bool) -> some View {
        Button {
            draft = nil
            anchorDrag = nil
            if item.isDraft, let draftSpans {
                // Every passage of the selection goes, not only the current one.
                draftGeneration += 1
                draftSpans.clear()
            } else if spanSelection, item.isDraft, canTrim, let range, !isEmptyRange {
                commit(range.lowerBound...range.lowerBound)
            }
            selectedID = nil
            userCleared = true
        } label: {
            Text("Clear Selection").lineLimit(1).fixedSize()
        }
        .controlSize(.small)
        .disabled(!isEnabled || inactive)
        .help("Clear the marked passage and deselect")
    }

    @ViewBuilder
    private func columnDivider(_ column: TranscriptQAColumns.Column, width: CGFloat,
                               otherWidth: CGFloat, available: CGFloat) -> some View {
        if columnShares != nil {
            // Fixed shares: the divider is a line, not a drag handle.
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
                .frame(width: TranscriptQAColumns.dividerWidth)
        } else {
        TranscriptQAColumnDivider(column: column, width: width, onResize: { proposed in
            guard let updated = TranscriptQAColumns.resizedWidth(proposed, column: column,
                available: available, otherWidth: otherWidth) else { return }
            if column == .list { listWidth = Double(updated) }
            else { transcriptWidth = Double(updated) }
        }, onReset: {
            if column == .list { listWidth = Double(column.defaultWidth) }
            else { transcriptWidth = Double(column.defaultWidth) }
        }, isLeading: true) // Both resized columns sit left of their divider.
        }
    }

    private var itemList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let kept {
                // The kept count titles the list; Select All sits in the footer toolbar.
                let ids = RangeReviewItem.keepableOwnerIDs(items)
                let count = kept.wrappedValue.intersection(ids).count
                SectionLabel("\(count) of \(ids.count) kept")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.spaceS)
            } else if let listTitle {
                SectionLabel(listTitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.spaceS)
            }
            // Selection is explicit so the sibling checkbox never selects a row.
            // Rows live in a plain stack so a row can be dragged to a new place
            // with a marker showing where it lands.
            ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleItems) { item in
                        itemRow(item)
                            .id(item.id)
                            .background(item.id == selectedID ? Color.accentColor.opacity(0.16)
                                        : highlighted.contains(item.id.ownerID) ? Color.accentColor.opacity(0.09) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .padding(.horizontal, Theme.spaceXS)
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: RowFramePreference.self,
                                                       value: [item.id: geometry.frame(in: .named(Self.listSpace))])
                            })
                            .offset(y: isDragging(item) ? dragTranslation : 0)
                            .opacity(isDragging(item) ? 0.75 : 1)
                            .zIndex(isDragging(item) ? 1 : 0)
                            .contextMenu {
                                if let onDelete, !item.isDraft, item.id.cutIndex == nil {
                                    Button("Delete", role: .destructive) { onDelete(item) }
                                }
                            }
                    }
                }
                .padding(.vertical, Theme.spaceXS)
                .coordinateSpace(name: Self.listSpace)
                .onPreferenceChange(RowFramePreference.self) { rowFrames = $0 }
                .overlay(alignment: .topLeading) {
                    if draggingID != nil, let y = dropMarkerY {
                        Capsule().fill(Color.accentColor)
                            .frame(height: 3)
                            .padding(.horizontal, Theme.spaceS)
                            .offset(y: y - 1.5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
            // A selection made elsewhere (the reel's Select) scrolls into view.
            .onChange(of: selection?.wrappedValue) { _, ownerID in
                guard let ownerID, let item = visibleItems.first(where: { $0.id.ownerID == ownerID }) else { return }
                withAnimation { scroller.scrollTo(item.id, anchor: .center) }
            }
            }
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand { direction in
                guard isEnabled, !visibleItems.isEmpty else { return }
                let index = visibleItems.firstIndex { $0.id == selectedID } ?? 0
                switch direction {
                case .up: selectedID = visibleItems[max(0, index - 1)].id
                case .down: selectedID = visibleItems[min(visibleItems.count - 1, index + 1)].id
                default: break
                }
            }
            // The list's toolbar: Play All at the leading edge, Select All or
            // Remove All at the trailing edge, level with the transcript's footer.
            if playAll || onDeleteAll != nil || kept != nil {
                HStack(spacing: Theme.spaceS) {
                    if playAll {
                        let playsCuts = RangeReviewPlayAll.playsCuts(items: items, selectedOwnerID: selectedID?.ownerID)
                        let playsSelected = selected.map { !$0.isDraft } ?? false
                        Button(playingAll ? "Stop" : "Play",
                               systemImage: playingAll ? "stop.fill" : "play.fill") {
                            if playingAll { stopPlayAll() } else { startPlayAll() }
                        }
                        .labelStyle(.iconOnly).fixedSize()
                        .disabled(!isEnabled || playableItems.isEmpty)
                        .help(playingAll ? "Stop playing"
                              : playsCuts ? "Play this reel's cuts back to back, as the video will be stitched"
                              : playsSelected ? "Play the selected item"
                              : kept != nil ? "Play the kept items in order, or every item when none is kept"
                              : "Play every item in order")
                        .accessibilityLabel(playingAll ? "Stop" : playsSelected ? "Play the selection" : "Play all")
                    }
                    Spacer(minLength: 0)
                    if let onLink {
                        let owners = linkableOwners
                        Button("Link", systemImage: "link") {
                            dropDraft()
                            highlighted = []
                            selectedID = owners.first.map { .init(ownerID: $0) }
                            userCleared = false
                            onLink(owners)
                        }
                        .labelStyle(.iconOnly).fixedSize()
                        .disabled(!isEnabled || owners.count < 2)
                        .help(owners.count < 2 ? "Link items into one: Shift-click rows to highlight several, then press this"
                              : "Link the \(owners.count) highlighted items into one, in list order")
                    }
                    if let kept {
                        let allKept = RangeReviewItem.allKept(kept.wrappedValue, items: items)
                        Button(allKept ? "Deselect All" : "Select All") {
                            kept.wrappedValue = RangeReviewItem.togglingAll(kept.wrappedValue, items: items)
                        }
                        .lineLimit(1).fixedSize()
                        .disabled(!isEnabled || items.allSatisfy(\.isDraft))
                        .help(allKept ? "Keep none of the items" : "Keep every item")
                    }
                    if let onDeleteAll, items.contains(where: { !$0.isDraft }) {
                        Button("Remove All", systemImage: "trash", role: .destructive) { confirmingDeleteAll = true }
                            .labelStyle(.iconOnly).fixedSize()
                            .disabled(!isEnabled)
                            .help("Remove every item from the list")
                            .confirmationDialog("Remove all \(items.filter { !$0.isDraft }.count) items?",
                                                isPresented: $confirmingDeleteAll) {
                                Button("Remove All", role: .destructive, action: onDeleteAll)
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("The list empties; the footage itself is untouched and can be added again.")
                            }
                    }
                }
                .controlSize(.small)
                .padding(Theme.spaceS)
            }
        }
    }

    /// The highlighted rows that still exist, in list order.
    private var linkableOwners: [Int64] {
        items.filter { !$0.isDraft && highlighted.contains($0.id.ownerID) }.map(\.id.ownerID)
    }

    /// Shift-click highlights from the selected row to this one;
    /// Command-click adds or removes this one. False = an ordinary click.
    private func highlight(_ item: RangeReviewItem) -> Bool {
        let flags = NSEvent.modifierFlags
        guard onLink != nil, !item.isDraft, flags.contains(.shift) || flags.contains(.command) else { return false }
        let owners = items.filter { !$0.isDraft }.map(\.id.ownerID)
        let anchor = selectedID.flatMap { id in owners.contains(id.ownerID) ? id.ownerID : nil }
        guard let anchor else {
            dropDraft()
            selectedID = .init(ownerID: item.id.ownerID)
            userCleared = false
            highlighted = [item.id.ownerID]
            return true
        }
        if flags.contains(.shift), let from = owners.firstIndex(of: anchor), let to = owners.firstIndex(of: item.id.ownerID) {
            highlighted.formUnion(owners[min(from, to)...max(from, to)])
        } else if highlighted.contains(item.id.ownerID), item.id.ownerID != anchor {
            highlighted.remove(item.id.ownerID)
        } else {
            highlighted.formUnion([anchor, item.id.ownerID])
        }
        return true
    }

    private var playableItems: [RangeReviewItem] {
        RangeReviewPlayAll.sequence(items: items, selectedOwnerID: selectedID?.ownerID, kept: kept?.wrappedValue)
    }

    private func startPlayAll() {
        guard isEnabled, let first = playableItems.first else { return }
        playingAll = true
        if selectedID == first.id, playback.player != nil {
            playback.setRange(first.range)
            playback.seek(to: first.range.lowerBound)
            playback.play()
        } else {
            advancingPlayAll = true
            selectedID = first.id
        }
    }

    private func stopPlayAll() {
        playingAll = false
        advancingPlayAll = false
        playback.pause()
    }

    /// The item that just finished moves the selection on; after the last one Play All ends.
    private func advancePlayAll() {
        let items = playableItems
        guard let index = items.firstIndex(where: { $0.id == selectedID }), index + 1 < items.count else {
            playingAll = false
            return
        }
        advancingPlayAll = true
        selectedID = items[index + 1].id
    }

    /// Up/down buttons beside each row when the adapter supports reordering.
    private func deleteButton(_ item: RangeReviewItem, onDelete: @escaping (RangeReviewItem) -> Void) -> some View {
        Button("Delete", systemImage: "trash") { onDelete(item) }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .fixedSize()
            .disabled(!isEnabled)
            .help("Remove this item")
    }

    private struct RowFramePreference: PreferenceKey {
        static var defaultValue: [RangeReviewItem.ID: CGRect] { [:] }
        static func reduce(value: inout [RangeReviewItem.ID: CGRect], nextValue: () -> [RangeReviewItem.ID: CGRect]) {
            value.merge(nextValue()) { $1 }
        }
    }

    private func isDragging(_ item: RangeReviewItem) -> Bool {
        guard let draggingID else { return false }
        // An owner drags its cuts along; a cut drags alone.
        return item.id == draggingID
            || (draggingID.cutIndex == nil && item.id.ownerID == draggingID.ownerID && item.id.cutIndex != nil)
    }

    private func canReorder(_ item: RangeReviewItem) -> Bool {
        guard !item.isDraft else { return false }
        if item.id.cutIndex != nil { return onMoveCut != nil && siblings(of: item.id).count > 1 }
        return onMove != nil
    }

    /// The cuts of the owner a cut belongs to.
    private func siblings(of id: RangeReviewItem.ID) -> [RangeReviewItem] {
        items.first { $0.id.ownerID == id.ownerID }?.children ?? []
    }

    /// Reorderable owners with the frame of their row plus their child cuts, in list order.
    private var reorderBlocks: [(owner: RangeReviewItem, frame: CGRect)] {
        // While a cut is dragged the blocks are its siblings.
        if let draggingID, draggingID.cutIndex != nil {
            return siblings(of: draggingID).compactMap { cut in rowFrames[cut.id].map { (cut, $0) } }
        }
        return visibleItems.filter { canReorder($0) && $0.id.cutIndex == nil }.compactMap { owner in
            guard var frame = rowFrames[owner.id] else { return nil }
            for child in owner.children { if let f = rowFrames[child.id] { frame = frame.union(f) } }
            return (owner, frame)
        }
    }

    /// Boundaries between blocks, top of the first to bottom of the last.
    private var dropBoundaries: [CGFloat] {
        let blocks = reorderBlocks
        guard let last = blocks.last else { return [] }
        return blocks.map(\.frame.minY) + [last.frame.maxY]
    }

    private var dropMarkerY: CGFloat? {
        guard let dropSlot else { return nil }
        let boundaries = dropBoundaries
        return boundaries.indices.contains(dropSlot) ? boundaries[dropSlot] : nil
    }

    /// The item the passage `item` belongs to.
    private func owner(of item: RangeReviewItem) -> RangeReviewItem? {
        items.first { $0.id.ownerID == item.id.ownerID }
    }

    /// Dragging `item` to a new place. With `barMoves` (a passage row's
    /// item), a drag that starts on the item's bar moves the item instead:
    /// the row's gesture wins over the bar's own handle there.
    private func reorderGesture(_ row: RangeReviewItem, barMoves: RangeReviewItem? = nil) -> some Gesture {
        // Rows sit `spaceXS` in from the list's edge; the bar starts there.
        func target(_ value: DragGesture.Value) -> RangeReviewItem {
            guard let barMoves, canReorder(barMoves),
                  value.startLocation.x < Theme.spaceXS + Self.handleWidth else { return row }
            return barMoves
        }
        return DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.listSpace))
            .onChanged { value in
                let item = target(value)
                guard isEnabled else { return }
                draggingID = item.id
                dragTranslation = value.translation.height
                let boundaries = dropBoundaries
                guard !boundaries.isEmpty else { return }
                dropSlot = boundaries.indices.min { abs(boundaries[$0] - value.location.y) < abs(boundaries[$1] - value.location.y) }
            }
            .onEnded { value in
                let item = target(value)
                defer { draggingID = nil; dragTranslation = 0; dropSlot = nil }
                if item.id.cutIndex != nil {
                    guard isEnabled, let onMoveCut, let slot = dropSlot,
                          let owner = items.first(where: { $0.id.ownerID == item.id.ownerID }) else { return }
                    let cuts = reorderBlocks.compactMap { $0.owner.id.cutIndex }
                    guard let cut = item.id.cutIndex, let from = cuts.firstIndex(of: cut), cuts.count == owner.children.count else { return }
                    var order = cuts
                    order.remove(at: from)
                    order.insert(cut, at: min(order.count, max(0, slot > from ? slot - 1 : slot)))
                    guard order != cuts else { return }
                    dropDraft()
                    if let next = onMoveCut(owner, order, selectedID) {
                        userCleared = false
                        selectedID = next
                    }
                    return
                }
                guard isEnabled, let onMove, let slot = dropSlot else { return }
                var ids = reorderBlocks.map { $0.owner.id.ownerID }
                guard let from = ids.firstIndex(of: item.id.ownerID) else { return }
                var to = slot
                ids.remove(at: from)
                if to > from { to -= 1 }
                ids.insert(item.id.ownerID, at: min(ids.count, max(0, to)))
                if ids != reorderBlocks.map({ $0.owner.id.ownerID }) { onMove(ids) }
            }
    }

    private func itemRow(_ item: RangeReviewItem) -> some View {
        let isChild = item.id.cutIndex != nil
        return ZStack(alignment: .topLeading) {
            // Clicking the selected row clears the selection.
            Button {
                if highlight(item) { return }
                highlighted = []
                if selectedID == item.id {
                    selectedID = nil
                    userCleared = true
                } else {
                    selectedID = item.id
                    userCleared = false
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.callout.weight(.medium)).italic(item.isDraft)
                        .foregroundStyle(item.isDraft ? Color.secondary : Color.primary)
                        .lineLimit(item.titleLines == 0 ? nil : item.titleLines).truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(item.titleHelp)
                    ForEach(item.captions.indices, id: \.self) { index in
                        let caption = item.captions[index]
                        Group {
                            if caption.monospaced { FormCaption(caption.text).monospacedDigit() }
                            else { FormCaption(caption.text) }
                        }
                        .lineLimit(caption.lineLimit).help(caption.text)
                    }
                }
                // A keep box is 18 wide at 8 in; the text starts 5 past it.
                .padding(.leading, (isChild ? 14 : kept != nil ? 15 : 0) + (item.isDraft ? 0 : RangeReviewPalette.barWidth + Theme.spaceXS))
                .padding(.trailing, onDelete != nil && !item.isDraft && !isChild
                         ? (onUnlink != nil && !item.children.isEmpty ? 56 : 30) : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Theme.spaceS)
                .padding(.horizontal, Theme.spaceS)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .leading) { bars(item) }
            .accessibilityAddTraits(item.id == selectedID ? .isSelected : [])
            // A passage moves inside its item from anywhere on its row; the
            // item itself moves only by its bar.
            .highPriorityGesture(reorderGesture(item, barMoves: isChild ? owner(of: item) : nil),
                                 including: isChild && canReorder(item) ? .all : .subviews)
            .help(isChild && canReorder(item) ? "Drag up or down to reorder inside this item" : "")
            if let onDelete, !item.isDraft, !isChild {
                HStack(spacing: Theme.spaceXS) {
                    if let onUnlink, !item.children.isEmpty {
                        Button("Unlink", systemImage: "link") {
                            dropDraft()
                            onUnlink(item)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(!isEnabled)
                        .help("Unlink: its \(item.children.count) passages become separate items")
                    }
                    deleteButton(item, onDelete: onDelete)
                }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.vertical, Theme.spaceS)
                    .padding(.trailing, Theme.spaceXS)
            }
            if let kept, !isChild, !item.isDraft {
                Toggle(item.keepLabel, isOn: Binding(
                    get: { kept.wrappedValue.contains(item.id.ownerID) },
                    set: { keep in
                        if keep { kept.wrappedValue.insert(item.id.ownerID) }
                        else { kept.wrappedValue.remove(item.id.ownerID) }
                    }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .fixedSize()
                    .frame(width: 18)
                    .padding(.vertical, Theme.spaceS)
                    .padding(.leading, Theme.spaceS)
                    .accessibilityLabel(item.keepLabel)
            }
        }
    }

    /// The row's left edge. The bar in the pick's colour (the one its first
    /// word carries in the transcript) is the handle that moves the pick;
    /// under an open pick with passages it runs unbroken down every passage,
    /// and each passage adds a thinner, lighter bar of its own (the passage
    /// moves inside the pick from that bar or anywhere on its row).
    @ViewBuilder
    private func bars(_ item: RangeReviewItem) -> some View {
        if let index = paletteIndex(item) {
            let isChild = item.id.cutIndex != nil
            let owner = isChild ? items.first { $0.id.ownerID == item.id.ownerID } : item
            let opensGroup = !isChild && !item.children.isEmpty && item.id.ownerID == selectedID?.ownerID
            let endsGroup = isChild && item.id == owner?.children.last?.id
            ZStack(alignment: .leading) {
                Rectangle().fill(RangeReviewPalette.bar(index))
                    .frame(width: RangeReviewPalette.barWidth)
                    .padding(.top, isChild ? 0 : Theme.spaceXS)
                    .padding(.bottom, opensGroup || (isChild && !endsGroup) ? 0 : Theme.spaceXS)
                    .allowsHitTesting(false)
                if isChild {
                    Rectangle().fill(RangeReviewPalette.cutBar(index))
                        .frame(width: RangeReviewPalette.barWidth / 2)
                        .padding(.vertical, Theme.spaceXS)
                        .padding(.leading, RangeReviewPalette.cutBarInset)
                        .allowsHitTesting(false)
                }
                if let owner, canReorder(owner) {
                    reorderHandle(owner, width: Self.handleWidth,
                                  help: owner.children.isEmpty ? "Drag up or down to reorder"
                                  : "Drag up or down to move this item with its \(owner.children.count) passages")
                }
                if isChild, canReorder(item) {
                    reorderHandle(item, width: Self.cutHandleWidth, help: "Drag up or down to reorder inside this item")
                        .padding(.leading, Self.handleWidth)
                }
            }
        }
    }

    /// The strip over a pick's bar that takes the drag; it ends where the keep box starts.
    private static var handleWidth: CGFloat { 8 }
    private static var cutHandleWidth: CGFloat { 16 }

    private func reorderHandle(_ item: RangeReviewItem, width: CGFloat, help: String) -> some View {
        Color.clear
            .frame(width: width)
            .contentShape(Rectangle())
            .pointerStyle(draggingID == nil ? .grabIdle : .grabActive)
            .gesture(reorderGesture(item), isEnabled: isEnabled)
            .help(help)
            .accessibilityHidden(true)
    }

    private func rangeCaption(_ range: ClosedRange<Double>) -> String {
        RangeReviewItem.rangeCaption(range)
    }

    private func trimSurface(item: RangeReviewItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            // The picture keeps the footage's shape instead of filling the
            // column's height, so no letterbox bars; the column may end up
            // shorter than its neighbours.
            PlayerView(player: playback.player, controlsStyle: .none)
                .aspectRatio(Self.pictureAspect(item.video), contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(.black, in: RoundedRectangle(cornerRadius: Theme.mediaRadius))
                .clipShape(RoundedRectangle(cornerRadius: Theme.mediaRadius))
                .overlay {
                    if playback.player == nil {
                        Text(item.isAvailable ? "Loading preview… If unavailable, download this video to this Mac."
                             : unavailableHint)
                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center).padding(Theme.spaceS)
                    }
                }
            if isEmptyRange {
                FormCaption(emptyDraftHint)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            } else {
                filmstrip(video: item.video)
                    .id(item.id)
                    .disabled(!canTrim)
                HStack(spacing: Theme.spaceS) {
                    playButton
                    Spacer(minLength: Theme.spaceS)
                    rangeLabel
                }
                if canTrim, !isEmptyRange {
                    RangeBoundaryWaveforms(url: item.video.url, range: shownRange, limits: limits,
                                           // Picks and Q&A shrink as far as the user wants (the step
                                           // buttons already do); only an empty range is kept out.
                                           minimumSpan: min(policy == .wizard ? policy.minimumSpan : RangeBoundary.shortestSpan,
                                                            max(0, limits.upperBound - limits.lowerBound)),
                                           lines: visibleTranscript.lines, words: visibleTranscript.words,
                                           onDrag: dragEdge, onRelease: releaseEdge,
                                           playback: playback, willPlay: { playingAll = false }) { edge in
                        // Each edge's step buttons sit under its own wave.
                        if policy != .wizard, !visibleTranscript.words.isEmpty {
                            RangeEdgeStepRow(edge: edge, range: editRange, transcript: visibleTranscript,
                                             spans: speakerSpans.filter { $0.videoID == nil || $0.videoID == contextVideo?.id },
                                             limits: limits, actions: stepActions.update(apply: apply, split: splitAtPlayhead))
                                .equatable()
                        }
                    }
                        .id(item.id)
                }
                if canTrim, !isEmptyRange, policy != .wizard, !visibleTranscript.words.isEmpty {
                    RangeStepControls(range: editRange, transcript: visibleTranscript,
                                      spans: speakerSpans.filter { $0.videoID == nil || $0.videoID == contextVideo?.id },
                                      limits: limits, policy: policy, lastAdjustment: lastAdjustment,
                                      canSplit: onSplit != nil && !item.isDraft && (splitsCuts || item.id.cutIndex == nil),
                                      playback: playback, actions: stepActions.update(apply: apply, split: splitAtPlayhead))
                        .equatable()
                        .padding(.top, Theme.spaceS)
                }
                HStack(alignment: .firstTextBaseline, spacing: Theme.spaceS) {
                    let hint = spanSelection ? Self.spanHint : (trimHint ?? Self.trimHint)
                    FormCaption(hint)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .help(hint)
                    Spacer(minLength: 0)
                    if policy != .wizard {
                        Button("Shortcuts", systemImage: "keyboard") { showingShortcuts.toggle() }
                            .labelStyle(.iconOnly).controlSize(.small).fixedSize()
                            .help("Keyboard shortcuts for trimming")
                            .popover(isPresented: $showingShortcuts, arrowEdge: .bottom) {
                                RangeReviewShortcutsList().padding(Theme.spaceM)
                            }
                    }
                }
            }
            footer(selectedParent ?? item)
        }
    }

    /// Width over height of the footage; 16:9 until the video's dimensions are known.
    static func pictureAspect(_ video: VideoRecord) -> CGFloat {
        video.width > 0 && video.height > 0 ? CGFloat(video.width) / CGFloat(video.height) : 16 / 9
    }

    private static var spanHint: String {
        "Press a word and drag to select a passage; drag a handle or a transcript anchor to adjust it."
    }

    private static var trimHint: String {
        "Click a word to select just that word; drag a handle or a transcript anchor to adjust the ends."
    }

    private var playButton: some View {
        HStack(spacing: Theme.spaceS) {
            Button(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
                playingAll = false
                playback.togglePlay()
            }
            .labelStyle(.iconOnly).fixedSize()
            .disabled(playback.player == nil)
            .help(playback.isPlaying ? "Pause (Space)" : "Play the section (Space)")
            Menu {
                ForEach(RangeReviewView.endingChoices, id: \.self) { seconds in
                    Button {
                        endingSeconds = seconds
                    } label: {
                        if seconds == endingSeconds {
                            Label("\(seconds) s", systemImage: "checkmark")
                        } else {
                            Text("\(seconds) s")
                        }
                    }
                }
            } label: {
                Label("\(endingSeconds) s", systemImage: "forward.end.fill")
                    .font(.callout.monospacedDigit()).lineLimit(1)
            } primaryAction: {
                playingAll = false
                playback.playEnding(seconds: Double(endingSeconds))
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(playback.player == nil || isEmptyRange)
            .help("Play the last \(endingSeconds) seconds of the section. The menu picks how many.")
            .accessibilityLabel("Play the ending")
            PlaybackSpeedControl(playback: playback)
        }
    }

    /// Stable callbacks for the step controls, so a skipped (equal) subview
    /// still reaches the current selection.
    @State private var stepActions = RangeStepActions()

    /// The range an adjustment would produce from the current one; nil when
    /// there is no such move.
    private func adjusted(_ adjustment: RangeAdjustment) -> ClosedRange<Double>? {
        guard canTrim, !isEmptyRange, policy != .wizard else { return nil }
        let spans = speakerSpans.filter { $0.videoID == nil || $0.videoID == contextVideo?.id }
        return RangeAdjustment.target(adjustment, range: editRange, words: visibleTranscript.words,
                                      spans: spans, limits: limits)
    }

    /// A boundary waveform drag: the range follows live, the picture shows the edge.
    private func dragEdge(_ proposed: ClosedRange<Double>, _ edge: TranscriptQATrim.Edge) {
        guard isEnabled, canTrim else { return }
        draft = (proposed.lowerBound, proposed.upperBound)
        playback.scrub(to: edge == .start ? proposed.lowerBound : proposed.upperBound)
    }

    /// A boundary waveform release: save the range (the wave then plays its
    /// stretch). Always through `commit`: with an earlier save still pending,
    /// a return to the range on record must be saved too, or the pending one
    /// would win.
    private func releaseEdge(_ proposed: ClosedRange<Double>, _ edge: TranscriptQATrim.Edge) {
        guard isEnabled, canTrim else { return }
        draft = (proposed.lowerBound, proposed.upperBound)
        commitDraft(snap: false)
    }

    private func apply(_ adjustment: RangeAdjustment) {
        guard let next = adjusted(adjustment) else { return }
        lastAdjustment = adjustment
        commit(next)
    }

    private var canSplit: Bool {
        guard onSplit != nil, let selected, !selected.isDraft, splitsCuts || selected.id.cutIndex == nil, canTrim, !isEmptyRange else { return false }
        let minimum = policy.minimumSpan
        let time = playback.time
        return time - editRange.lowerBound >= minimum && editRange.upperBound - time >= minimum
    }

    private func splitAtPlayhead() {
        guard canSplit, let selected, let onSplit else { return }
        onSplit(selected, playback.time)
    }

    private var rangeLabel: some View {
        ViewThatFits(in: .horizontal) {
            Text(rangeCaption(shownRange)).lineLimit(1).fixedSize()
            VStack(alignment: .leading, spacing: 2) {
                Text("\(shownRange.lowerBound.timecode)–\(shownRange.upperBound.timecode)").monospacedDigit()
                Text("\(shownRange.upperBound - shownRange.lowerBound, format: .number.precision(.fractionLength(1)))s").monospacedDigit()
            }
            .lineLimit(1).fixedSize()
        }
        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }

    /// Add (the caller's accessory) for a marked draft passage.
    @ViewBuilder
    private func draftActions(_ item: RangeReviewItem) -> some View {
        if spanSelection, item.isDraft, !isEmptyRange, let selected, selected.id == item.id,
           let accessory = trimAccessory?(selected) {
            accessory
        }
    }

    private func resetButton(_ item: RangeReviewItem) -> some View {
        Button(resetTitle) {
            commit(item.originalRange)
        }
        .controlSize(.small).lineLimit(1).fixedSize()
        .disabled(!item.isTrimmed || !canTrim)
        .help("Return to the original range")
    }

    private func filmstrip(video: VideoRecord) -> some View {
        VideoTrimSlider(url: video.url, duration: window.span,
                        start: Binding(get: { shownRange.lowerBound }, set: {
                            guard isEnabled, canTrim else { return }
                            draft = (start: $0, end: draft?.end ?? editRange.upperBound)
                        }),
                        end: Binding(get: { shownRange.upperBound }, set: {
                            guard isEnabled, canTrim else { return }
                            draft = (start: draft?.start ?? editRange.lowerBound, end: $0)
                        }),
                        timeOffset: window.start, rulerInterval: window.rulerInterval,
                        minimumSpan: min(policy.minimumSpan, window.span),
                        showsTimes: false, stripHeight: 48,
                        onScrub: { playback.scrub(to: min(editRange.upperBound, max(editRange.lowerBound, $0))) },
                        onDragEnded: { commitDraft(snap: true) })
            .overlay(alignment: .topLeading) {
                RangeReviewPlayhead(window: window, playback: playback)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .help(policy != .wizard ? "Drag a handle and release near an edge to see more. Ends snap to nearby words."
                  : "Drag a handle and release near the edge to see more of this scene")
    }

    private func reconcileSelection() {
        // A cleared selection stays cleared until the user picks a row or the owner asks for one.
        if let pending = pendingCut, items.contains(where: { $0.children.contains { $0.id == pending } }) {
            pendingCut = nil
            selectedID = pending
            return
        }
        if selectedID == nil, userCleared, selection?.wrappedValue == nil { return }
        // The selected cut moved among its siblings (or its owner is now
        // named by another cut): follow it, unless the owner asked for
        // another row meanwhile.
        if let stable = selectedStable, selectedID != nil,
           let match = cut(stable: stable),
           // An item selected as a whole stays so when it gains cuts (Link).
           !(selectedID?.cutIndex == nil && match.id.cutIndex != nil && match.id.ownerID == selectedID?.ownerID),
           followsSelection(match) {
            if selectedID != match.id {
                dropDraft()
                selectedID = match.id
            }
            applyRequestedCut()
            return
        }
        let ownerID = selection?.wrappedValue ?? selectedID?.ownerID
        let parent = items.first { $0.id.ownerID == ownerID } ?? items.first
        if let parent, selectedID == parent.id || parent.children.contains(where: { $0.id == selectedID }) {
            applyRequestedCut()
            return
        }
        selectedID = parent?.id
        applyRequestedCut()
    }

    /// The owner asked for one cut of its selection: show that one, not the first.
    private func applyRequestedCut() {
        guard let cut = requestedCut?.wrappedValue, let ownerID = selection?.wrappedValue,
              let parent = items.first(where: { $0.id.ownerID == ownerID }) else { return }
        requestedCut?.wrappedValue = nil
        guard let child = parent.children.first(where: { $0.id.cutIndex == cut }) else { return }
        userCleared = false
        selectedID = child.id
    }

    private func selectItem() {
        draft = nil
        playback.pause()
        guard let range, let video, selected?.isAvailable == true else {
            playback.tearDown()
            loadedURL = nil
            return
        }
        recenter(range)
        if loadedURL != video.url {
            loadedURL = video.url
            playback.load(url: video.url, range: playable(range), autoplay: false)
        } else if playback.player != nil {
            playback.setRange(playable(range))
            playback.seek(to: range.lowerBound)
            if isEnabled, autoplay { playback.play() }
        }
    }

    private func recenter(_ range: ClosedRange<Double>) {
        window = ProposedCutTrim.window(for: range, scene: limits)
    }

    /// The span just marked becomes a new passage of the selected item,
    /// which is selected once it is stored.
    private func commitNewCut() {
        guard isEnabled, canTrim, let current = draft, let parent = selectedParent else { dropDraft(); return }
        let updated = policy.clamp(current.start...max(current.start, current.end), limits: limits)
        dropDraft()
        guard updated.upperBound > updated.lowerBound, let id = onAddCut?(parent, updated) else { return }
        pendingCut = id
        userCleared = false
    }

    private func commitDraft(snap: Bool) {
        let edge = anchorDrag
        anchorDrag = nil
        guard draft != nil, let range else { return }
        let updated = snap ? policy.releasing(editRange, from: range, words: visibleTranscript.words, limits: limits) : editRange
        commit(updated)
        if let edge {
            playback.scrub(to: edge == .start ? updated.lowerBound : max(updated.lowerBound, updated.upperBound - 0.5))
        }
    }

    private func previewWord(_ edge: TranscriptQATrim.Edge, _ word: TranscriptQATrim.Word) {
        guard isEnabled, canTrim else { return }
        let updated = moving(edge, to: word)
        draft = (updated.lowerBound, updated.upperBound)
        // The words mark the new span at once; the picture waits for the release.
        anchorDrag = edge
    }

    /// The range the trim column shows: the saved one while a transcript
    /// anchor is in flight, otherwise the draft.
    private var shownRange: ClosedRange<Double> {
        guard anchorDrag != nil, let range else { return editRange }
        return policy.clamp(range, limits: limits)
    }

    private func moving(_ edge: TranscriptQATrim.Edge, to word: TranscriptQATrim.Word) -> ClosedRange<Double> {
        // Picks and Q&A shrink to a single word, as a click and the step
        // buttons already allow; a wizard cut keeps its own minimum.
        if policy != .wizard {
            return TranscriptQATrim.range(editRange, moving: edge, to: word, words: visibleTranscript.words, limits: limits)
        }
        switch edge {
        case .start: return policy.setting(.start, at: word.start, in: editRange, limits: limits)
        case .end: return policy.setting(.end, at: word.end, in: editRange, limits: limits)
        }
    }

    /// A click selects that word alone, wherever it is; the range grows only by
    /// dragging a marker or with the trim buttons.
    private func selectWord(_ word: TranscriptQATrim.Word) {
        guard isEnabled, canTrim, word.end > word.start else { return }
        guard limits.contains(word.mid) else {
            // Outside this item's limits the word belongs to another cut:
            // select that one with just this word, as a click with nothing
            // selected does. Clamping to this item would collapse the range.
            guard let video = contextVideo, let under = itemUnder(word, video: video), under.id != selected?.id else { return }
            pendingDraft = (word.start, word.end)
            pendingCommit = true
            selectedID = under.id
            return
        }
        let updated = word.start...max(word.start, word.end)
        commit(updated)
        playback.seek(to: updated.lowerBound)
    }

    private func commit(_ proposed: ClosedRange<Double>) {
        guard isEnabled, canTrim, let selected else { draft = nil; return }
        let updated = policy.clamp(proposed, limits: limits)
        if draft == nil, let range, abs(updated.lowerBound - range.lowerBound) < 0.001,
           abs(updated.upperBound - range.upperBound) < 0.001 {
            // Nothing moved (an anchor pressed and released): no save, no
            // refresh, and no draft to wait on. With a save still pending the
            // range on screen is not the saved one, so a return to it is saved.
            return
        }
        // The words keep showing the new range until the saved one catches up
        // (the save is asynchronous); `range`'s observer clears the draft then.
        // A save the adapter refuses (an empty range, a cut that no longer
        // resolves) never arrives: the draft is dropped after a moment so the
        // filmstrip and the words return to the saved range.
        draft = (updated.lowerBound, updated.upperBound)
        draftGeneration += 1
        let generation = draftGeneration
        let saved = range
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            // Only the draft this commit made: a span or filmstrip drag that
            // started since holds a different one and must keep it. The
            // player returns to the range that was saved when the refused
            // commit was made; the view's own data may be stale by now.
            guard generation == draftGeneration, anchorDrag == nil, let current = draft,
                  abs(current.start - updated.lowerBound) < 0.001, abs(current.end - updated.upperBound) < 0.001 else { return }
            draft = nil
            if let saved { playback.setRange(playable(saved)) }
        }
        onSave(selected, updated.lowerBound, updated.upperBound)
        playback.setRange(playable(updated))
        if window.needsRecentering(updated) { recenter(updated) }
        // Adapters observe saved ranges; their refreshes remain authoritative.
    }

    /// A queued one-word selection or span (made while another item, or
    /// nothing, was selected) becomes the draft of the now-selected item.
    private func applyPendingDraft() {
        guard let pendingDraft else { pendingCommit = false; return }
        draft = pendingDraft
        self.pendingDraft = nil
        if pendingCommit {
            pendingCommit = false
            commitDraft(snap: false)
        }
    }

    /// The saved cut whose limits hold the word (the cut itself for multi-cut
    /// reels), else the one whose range does; nil for an unmarked word.
    private func itemUnder(_ word: TranscriptQATrim.Word, video: VideoRecord) -> RangeReviewItem? {
        // Each cut has its own recording: a reel's owner carries its first cut's.
        let cuts = items.filter { !$0.isDraft }
            .flatMap { $0.children.isEmpty ? [$0] : $0.children }
            .filter { $0.video.id == video.id }
        return cuts.first { TranscriptQATrim.contains(word, in: $0.range) }
            ?? cuts.first { $0.limits.upperBound > $0.limits.lowerBound && $0.limits.contains(word.mid) }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        // The monitor is window-wide; a mounted but hidden review stays quiet.
        guard isEnabled, pageVisible, range != nil else { return false }
        // The preview's List owns Delete while it has focus.
        if let onDelete, let selected, event.keyCode == 51 || event.keyCode == 117,
           !selected.isDraft, selected.id.cutIndex == nil, !store.miniReelListFocused {
            onDelete(selected)
            return true
        }
        guard playback.player != nil else { return false }
        let flags = event.modifierFlags.intersection([.option, .shift, .command, .control])
        // ⌥←/→ step words at the end, ⇧⌥ at the start.
        if event.keyCode == 123 || event.keyCode == 124, flags.contains(.option), !flags.contains(.command) {
            let left = event.keyCode == 123
            let step: TranscriptQATrim.Step = flags.contains(.shift)
                ? (left ? .wordBefore : .dropFirstWord)
                : (left ? .dropLastWord : .wordAfter)
            apply(.step(step))
            return true
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case " ": playingAll = false; playback.togglePlay()
        case ",", ".", "<", ">":
            // , / . nudge the end by 0.1 s; ⇧ makes it 1 s; ⌥ moves the start.
            guard !flags.contains(.command), !flags.contains(.control) else { return false }
            let characters = event.charactersIgnoringModifiers ?? ""
            let earlier = characters == "," || characters == "<"
            let seconds = flags.contains(.shift) || characters == "<" || characters == ">" ? 1.0 : 0.1
            apply(.nudge(flags.contains(.option) ? .start : .end, earlier ? -seconds : seconds))
        case "i", "o":
            guard canTrim, !isEmptyRange else { return false }
            let edge: TranscriptQATrim.Edge = event.charactersIgnoringModifiers?.lowercased() == "i" ? .start : .end
            let time = policy != .wizard ? TranscriptQATrim.snap(playback.time, edge: edge, words: visibleTranscript.words) : playback.time
            // No minimum: the keys shrink a click-selected range like the buttons do.
            commit(policy.setting(edge, at: time, in: editRange, limits: limits, minimum: 0))
        default: return false
        }
        return true
    }
}

/// A one-click change to a marked range; the view remembers the last one so
/// the next pick can take it again.
nonisolated enum RangeAdjustment: Hashable, Sendable {
    case step(TranscriptQATrim.Step)
    case nudge(TranscriptQATrim.Edge, Double)
    case turn(TranscriptQATrim.Edge, grow: Bool)
    case trimSilence

    /// The range the adjustment would produce; nil when there is no such move.
    static func target(_ adjustment: RangeAdjustment, range: ClosedRange<Double>, words: [TranscriptQATrim.Word],
                       spans: [TranscriptQATrim.SpeakerSpan], limits: ClosedRange<Double>) -> ClosedRange<Double>? {
        switch adjustment {
        case .step(let step):
            TranscriptQATrim.stepped(range, by: step, words: words, limits: limits)
        case let .nudge(edge, delta):
            TranscriptQATrim.nudged(range, edge: edge, by: delta, limits: limits)
        case let .turn(edge, grow):
            TranscriptQATrim.turned(range, edge: edge, grow: grow, spans: spans, limits: limits)
        case .trimSilence:
            TranscriptQATrim.trimmedSilence(range, words: words, limits: limits)
        }
    }

    var label: String {
        switch self {
        case .step(.wordBefore): "add the word before"
        case .step(.dropFirstWord): "drop the first word"
        case .step(.sentenceBefore): "back to the start of the sentence"
        case .step(.dropFirstSentence): "forward to the next sentence start"
        case .step(.dropLastSentence): "back to the previous sentence end"
        case .step(.dropLastWord): "drop the last word"
        case .step(.wordAfter): "add the next word"
        case .step(.pauseAfter): "keep the pause after the last word"
        case .step(.sentenceAfter): "on to the end of the sentence"
        case let .nudge(edge, delta):
            "\(edge == .start ? "start" : "end") \(delta < 0 ? "earlier" : "later") by \(String(format: "%.1f", abs(delta))) s"
        case let .turn(edge, grow):
            switch (edge, grow) {
            case (.start, true): "back to the start of the speaker's turn"
            case (.start, false): "forward to the next speaker change"
            case (.end, true): "on to the end of the speaker's turn"
            case (.end, false): "back to the previous speaker change"
            }
        case .trimSilence: "trim the silence at both ends"
        }
    }
}

/// Non-observable callback storage for the step controls (see TranscriptQALineActions).
final class RangeStepActions {
    var apply: (RangeAdjustment) -> Void = { _ in }
    var split: () -> Void = {}

    func update(apply: @escaping (RangeAdjustment) -> Void, split: @escaping () -> Void) -> RangeStepActions {
        self.apply = apply
        self.split = split
        return self
    }
}

/// The kinds of one-click move; each edge's row shows one at a time.
nonisolated enum RangeStepKind: String, CaseIterable, Identifiable, Sendable {
    case word, sentence, speaker, nudge
    var id: String { rawValue }
    var label: String {
        switch self {
        case .word: "Word"
        case .sentence: "Sentence"
        case .speaker: "Speaker"
        case .nudge: "0.1 s"
        }
    }
}

/// One edge's one-click moves, under that edge's wave: what to step by
/// (word, sentence, speaker turn, tenth of a second), then earlier and
/// later. The wave's header above names the edge. Each edge remembers its own step. Equatable for the
/// same reason as `RangeStepControls`.
struct RangeEdgeStepRow: View, Equatable {
    let edge: TranscriptQATrim.Edge
    let range: ClosedRange<Double>
    let transcript: TranscriptQATrim.Transcript
    let spans: [TranscriptQATrim.SpeakerSpan]
    let limits: ClosedRange<Double>
    let actions: RangeStepActions
    @AppStorage private var kind: RangeStepKind

    init(edge: TranscriptQATrim.Edge, range: ClosedRange<Double>, transcript: TranscriptQATrim.Transcript,
         spans: [TranscriptQATrim.SpeakerSpan], limits: ClosedRange<Double>, actions: RangeStepActions) {
        self.edge = edge
        self.range = range
        self.transcript = transcript
        self.spans = spans
        self.limits = limits
        self.actions = actions
        // The start keeps the key the single picker used.
        _kind = AppStorage(wrappedValue: .word, edge == .start ? "rangeReview.stepKind" : "rangeReview.stepKind.end")
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.edge == rhs.edge && lhs.range == rhs.range && lhs.transcript == rhs.transcript
            && lhs.spans == rhs.spans && lhs.limits == rhs.limits
    }

    private var title: String { edge == .start ? "Start" : "End" }

    /// The move that takes this edge earlier, and the one that takes it later.
    private var moves: (earlier: RangeAdjustment, later: RangeAdjustment) {
        switch (kind, edge) {
        case (.word, .start): (.step(.wordBefore), .step(.dropFirstWord))
        case (.word, .end): (.step(.dropLastWord), .step(.wordAfter))
        case (.sentence, .start): (.step(.sentenceBefore), .step(.dropFirstSentence))
        case (.sentence, .end): (.step(.dropLastSentence), .step(.sentenceAfter))
        case (.speaker, .start): (.turn(.start, grow: true), .turn(.start, grow: false))
        case (.speaker, .end): (.turn(.end, grow: false), .turn(.end, grow: true))
        case (.nudge, .start): (.nudge(.start, -0.1), .nudge(.start, 0.1))
        case (.nudge, .end): (.nudge(.end, -0.1), .nudge(.end, 0.1))
        }
    }

    var body: some View {
        HStack(spacing: Theme.spaceXS) {
            Picker("\(title) steps by", selection: $kind) {
                ForEach(RangeStepKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize()
            .help("What the \(title) arrows move by")
            .accessibilityLabel("\(title) steps by")
            moveButton(moves.earlier, icon: "arrow.left.to.line")
            moveButton(moves.later, icon: "arrow.right.to.line")
        }
        .controlSize(.small)
    }

    private func moveButton(_ adjustment: RangeAdjustment, icon: String) -> some View {
        Button { actions.apply(adjustment) } label: { Image(systemName: icon) }
            .disabled(RangeAdjustment.target(adjustment, range: range, words: transcript.words, spans: spans, limits: limits) == nil)
            .help("\(title): \(adjustment.label)")
            .accessibilityLabel("\(title): \(adjustment.label)")
    }
}

/// The whole-range actions under the waves. Equatable and re-rendered only
/// when its inputs change: the targets scan the whole transcript, and the
/// parent's body runs on every drag step and playhead tick.
struct RangeStepControls: View, Equatable {
    let range: ClosedRange<Double>
    let transcript: TranscriptQATrim.Transcript
    let spans: [TranscriptQATrim.SpeakerSpan]
    let limits: ClosedRange<Double>
    let policy: RangeReviewItem.TrimPolicy
    let lastAdjustment: RangeAdjustment?
    /// The list offers Split for this item; the playhead decides if it is possible now.
    let canSplit: Bool
    let playback: PodcastHighlightTrimPlayback
    let actions: RangeStepActions

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.range == rhs.range && lhs.transcript == rhs.transcript && lhs.spans == rhs.spans
            && lhs.limits == rhs.limits && lhs.policy == rhs.policy && lhs.lastAdjustment == rhs.lastAdjustment
            && lhs.canSplit == rhs.canSplit
    }

    private func target(_ adjustment: RangeAdjustment) -> ClosedRange<Double>? {
        RangeAdjustment.target(adjustment, range: range, words: transcript.words, spans: spans, limits: limits)
    }

    var body: some View {
        FlowLayout(spacing: Theme.spaceS) {
            adjustmentButton(.step(.pauseAfter), "Keep Pause",
                             help: "Keep the pause after the last word: extend the end through the silence, up to the next word")
            adjustmentButton(.trimSilence, "Trim Silence", help: "Start at the first word and end at the last word")
            if canSplit {
                SplitButton(range: range, minimum: policy.minimumSpan, playback: playback, split: { actions.split() })
            }
            Button {
                if let lastAdjustment { actions.apply(lastAdjustment) }
            } label: {
                Text("Repeat Last").lineLimit(1).fixedSize()
            }
            .disabled(lastAdjustment.flatMap { target($0) } == nil)
            .help(lastAdjustment.map { "Repeat: \($0.label)" } ?? "Repeat the last adjustment on this selection")
        }
        .controlSize(.small)
    }

    private func adjustmentButton(_ adjustment: RangeAdjustment, _ title: String, help: String) -> some View {
        Button { actions.apply(adjustment) } label: { Text(title).lineLimit(1).fixedSize() }
            .disabled(target(adjustment) == nil)
            .help(help)
    }

    /// Reads the playhead on its own, so only this button follows the 10 Hz ticks.
    private struct SplitButton: View {
        let range: ClosedRange<Double>
        let minimum: Double
        let playback: PodcastHighlightTrimPlayback
        let split: () -> Void

        var body: some View {
            let time = playback.time
            Button(action: split) { Text("Split at Playhead").lineLimit(1).fixedSize() }
                .disabled(!(time - range.lowerBound >= minimum && range.upperBound - time >= minimum))
                .help("Split at the playhead: this pick keeps the first half, a new pick takes the rest")
        }
    }
}

/// The trim keys, listed once in a popover instead of a three-line caption.
struct RangeReviewShortcutsList: View {
    private static let rows: [(keys: String, action: String)] = [
        ("Space", "Play or pause"),
        ("I / O", "Set the start / end at the playhead"),
        ("⌥→ / ⌥←", "Add / drop a word at the end"),
        ("⇧⌥← / ⇧⌥→", "Add / drop a word at the start"),
        (", / .", "End 0.1 s earlier / later"),
        ("⇧, / ⇧.", "End 1 s earlier / later"),
        ("⌥, / ⌥.", "Start 0.1 s earlier / later"),
        ("⌫", "Remove the selected item"),
    ]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.spaceM, verticalSpacing: Theme.spaceXS) {
            ForEach(Self.rows, id: \.keys) { row in
                GridRow {
                    Text(row.keys).font(.body.monospaced()).lineLimit(1).fixedSize()
                    Text(row.action).font(.body).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
            }
        }
    }
}

/// The playhead over the filmstrip. Reads the time itself so the review's
/// body does not re-run on every tick of playback.
private struct RangeReviewPlayhead: View {
    let window: ProposedCutTrim.Window
    let playback: PodcastHighlightTrimPlayback

    var body: some View {
        GeometryReader { proxy in
            if let x = window.playheadX(at: playback.time, width: Double(proxy.size.width)) {
                Rectangle().fill(.white)
                    .frame(width: 2, height: 48).offset(x: CGFloat(x))
            }
        }
    }
}
