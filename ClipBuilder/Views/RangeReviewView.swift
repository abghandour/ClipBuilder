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
    private func markedRanges(excluding selectedID: RangeReviewItem.ID?, video: VideoRecord) -> [RangeReviewMarkedRange] {
        let painted = RangeReviewItem.paintedOwnerIDs(items: items, selectedOwnerID: selectedID?.ownerID, kept: kept?.wrappedValue)
        return items.flatMap { owner in
            (owner.children.isEmpty ? [owner] : owner.children).compactMap { item -> RangeReviewMarkedRange? in
                // The selected cut paints through `range`; its sibling cuts
                // (the other clips of a multi-cut reel) still mark themselves.
                let sibling = selectedID != nil && owner.id.ownerID == selectedID?.ownerID
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
        .onChange(of: items.flatMap { [$0.id] + $0.children.map(\.id) }) { _, _ in reconcileSelection() }
        .onChange(of: selection?.wrappedValue) { _, ownerID in
            if ownerID != selectedID?.ownerID { reconcileSelection() }
        }
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
        let marked = markedRanges(excluding: inactive ? nil : selected.id, video: video)
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
        return TranscriptQAWordPanel(transcript: visibleTranscript, videoID: video.id,
                              translationLanguages: transcriptVideoID == video.id ? translationLanguages : [],
                              translationsByLanguage: transcriptVideoID == video.id ? translationsByLanguage : [:],
                              preferredTranslationLanguage: preferredTranslationLanguage,
                              sectionID: selected.id,
                              range: inactive ? emptyRange : editRange,
                              otherRanges: marked,
                              playback: playback, canTrim: contextCanTrim,
                              onSelect: inactive ? { activate(at: $0) } : selectWord,
                              onPreview: inactive ? { _, word in activate(at: word) } : previewWord,
                              onCommit: { if inactive { pendingCommit = pendingDraft != nil } else { commitDraft(snap: false) } },
                              onCancel: { draft = nil; anchorDrag = nil },
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
                              accessory: inactive ? nil : transcriptAccessory?(selected),
                              footer: AnyView(rangeActions(selected, inactive: inactive)))
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
            if spanSelection, item.isDraft, canTrim, let range, !isEmptyRange {
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
                            .background(item.id == selectedID ? Color.accentColor.opacity(0.16) : Color.clear,
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
        return item.id == draggingID || (item.id.ownerID == draggingID.ownerID && item.id.cutIndex != nil)
    }

    private func canReorder(_ item: RangeReviewItem) -> Bool {
        onMove != nil && !item.isDraft && item.id.cutIndex == nil
    }

    /// Reorderable owners with the frame of their row plus their child cuts, in list order.
    private var reorderBlocks: [(owner: RangeReviewItem, frame: CGRect)] {
        visibleItems.filter(canReorder).compactMap { owner in
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

    private func reorderGesture(_ item: RangeReviewItem) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.listSpace))
            .onChanged { value in
                guard isEnabled else { return }
                draggingID = item.id
                dragTranslation = value.translation.height
                let boundaries = dropBoundaries
                guard !boundaries.isEmpty else { return }
                dropSlot = boundaries.indices.min { abs(boundaries[$0] - value.location.y) < abs(boundaries[$1] - value.location.y) }
            }
            .onEnded { _ in
                defer { draggingID = nil; dragTranslation = 0; dropSlot = nil }
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
                .padding(.leading, (isChild ? 42 : kept != nil ? 15 : 0) + (item.isDraft ? 0 : RangeReviewPalette.barWidth + Theme.spaceXS))
                .padding(.trailing, onDelete != nil && !item.isDraft && !isChild ? 30 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Theme.spaceS)
                .padding(.horizontal, Theme.spaceS)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .leading) {
                // The same bar the pick's first word carries in the transcript.
                if let index = paletteIndex(item) {
                    Rectangle().fill(RangeReviewPalette.bar(index))
                        .frame(width: RangeReviewPalette.barWidth)
                        .padding(.vertical, Theme.spaceXS)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityAddTraits(item.id == selectedID ? .isSelected : [])
            .highPriorityGesture(reorderGesture(item), including: canReorder(item) ? .all : .subviews)
            .help(canReorder(item) ? "Drag up or down to reorder" : "")
            if let onDelete, !item.isDraft, !isChild {
                deleteButton(item, onDelete: onDelete)
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
                                           minimumSpan: min(policy.minimumSpan, max(0, limits.upperBound - limits.lowerBound)),
                                           lines: visibleTranscript.lines, words: visibleTranscript.words,
                                           onDrag: dragEdge, onRelease: releaseEdge,
                                           playback: playback, willPlay: { playingAll = false })
                        .id(item.id)
                }
                if canTrim, !isEmptyRange, policy != .wizard, !visibleTranscript.words.isEmpty {
                    RangeStepControls(range: editRange, transcript: visibleTranscript,
                                      spans: speakerSpans.filter { $0.videoID == nil || $0.videoID == contextVideo?.id },
                                      limits: limits, policy: policy, lastAdjustment: lastAdjustment,
                                      canSplit: onSplit != nil && !item.isDraft && item.id.cutIndex == nil,
                                      playback: playback, actions: stepActions.update(apply: apply, split: splitAtPlayhead))
                        .equatable()
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
        guard onSplit != nil, let selected, !selected.isDraft, selected.id.cutIndex == nil, canTrim, !isEmptyRange else { return false }
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
        if selectedID == nil, userCleared, selection?.wrappedValue == nil { return }
        let ownerID = selection?.wrappedValue ?? selectedID?.ownerID
        let parent = items.first { $0.id.ownerID == ownerID } ?? items.first
        if let parent, selectedID == parent.id || parent.children.contains(where: { $0.id == selectedID }) { return }
        selectedID = parent?.id
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
        switch edge {
        case .start: policy.setting(.start, at: word.start, in: editRange, limits: limits)
        case .end: policy.setting(.end, at: word.end, in: editRange, limits: limits)
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

/// The kinds of one-click move; the control shows one at a time.
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

/// One-click adjustments under the filmstrip: a Step-by picker (word,
/// sentence, speaker turn, tenth of a second) with a Start and an End pair,
/// then the whole-range actions. Four buttons instead of twenty; the keys
/// still reach every move. Equatable and re-rendered only when its inputs
/// change: the targets scan the whole transcript, and the parent's body
/// runs on every drag step and playhead tick.
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
    @AppStorage("rangeReview.stepKind") private var kind = RangeStepKind.word

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.range == rhs.range && lhs.transcript == rhs.transcript && lhs.spans == rhs.spans
            && lhs.limits == rhs.limits && lhs.policy == rhs.policy && lhs.lastAdjustment == rhs.lastAdjustment
            && lhs.canSplit == rhs.canSplit
    }

    private func target(_ adjustment: RangeAdjustment) -> ClosedRange<Double>? {
        RangeAdjustment.target(adjustment, range: range, words: transcript.words, spans: spans, limits: limits)
    }

    private var moves: (start: (shrink: RangeAdjustment, grow: RangeAdjustment), end: (shrink: RangeAdjustment, grow: RangeAdjustment)) {
        switch kind {
        case .word: ((.step(.dropFirstWord), .step(.wordBefore)), (.step(.dropLastWord), .step(.wordAfter)))
        case .sentence: ((.step(.dropFirstSentence), .step(.sentenceBefore)), (.step(.dropLastSentence), .step(.sentenceAfter)))
        case .speaker: ((.turn(.start, grow: false), .turn(.start, grow: true)), (.turn(.end, grow: false), .turn(.end, grow: true)))
        case .nudge: ((.nudge(.start, 0.1), .nudge(.start, -0.1)), (.nudge(.end, -0.1), .nudge(.end, 0.1)))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.spaceM) {
                    stepPicker(.segmented)
                    edgePairs
                }
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    stepPicker(.segmented)
                    edgePairs
                }
                // Narrowest column: a menu instead of the four segments.
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    stepPicker(.menu)
                    edgePairs
                }
            }
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
        }
        .controlSize(.small)
    }

    private enum PickerKind { case segmented, menu }

    @ViewBuilder
    private func stepPicker(_ style: PickerKind) -> some View {
        let picker = Picker("Step by", selection: $kind) {
            ForEach(RangeStepKind.allCases) { kind in
                Text(kind.label).lineLimit(1).fixedSize().tag(kind)
            }
        }
        .help("What the Start and End buttons move by")
        .accessibilityLabel("Step by")
        switch style {
        case .segmented: picker.pickerStyle(.segmented).labelsHidden().fixedSize()
        case .menu: picker.pickerStyle(.menu).fixedSize()
        }
    }

    private var edgePairs: some View {
        HStack(spacing: Theme.spaceM) {
            edgePair("Start", moves.start.shrink, moves.start.grow)
            edgePair("End", moves.end.shrink, moves.end.grow)
        }
    }

    /// Shrink and grow one edge by the chosen step.
    private func edgePair(_ title: String, _ shrink: RangeAdjustment, _ grow: RangeAdjustment) -> some View {
        HStack(spacing: Theme.spaceXS) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Button { actions.apply(shrink) } label: {
                Image(systemName: title == "Start" ? "arrow.right.to.line" : "arrow.left.to.line")
            }
            .disabled(target(shrink) == nil)
            .help("\(title): \(shrink.label)")
            .accessibilityLabel("\(title): \(shrink.label)")
            Button { actions.apply(grow) } label: {
                Image(systemName: title == "Start" ? "arrow.left.to.line" : "arrow.right.to.line")
            }
            .disabled(target(grow) == nil)
            .help("\(title): \(grow.label)")
            .accessibilityLabel("\(title): \(grow.label)")
        }
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
