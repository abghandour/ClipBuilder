import SwiftUI
import AVKit

/// Shared review surface; adapters own domain data and persistence.
struct RangeReviewView<Footer: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    let items: [RangeReviewItem]
    let rows: [TranscriptRow]
    let labels: [Int64: String]
    /// Named speaker turns; rows crossing a speaker change split into one line per speaker.
    var speakerSpans: [TranscriptQATrim.SpeakerSpan] = []
    var kept: Binding<Set<Int64>>? = nil
    var preferredTranslationLanguage: String? = nil
    var selection: Binding<Int64?>? = nil
    var emptyTitle = "Select a Q&A section"
    var emptyMessage = "Choose an exchange to watch it and adjust its start and end."
    var resetTitle = "Reset to Original"
    /// Start playing when an item is shown or selected. Explicit word clicks always play.
    var autoplay = true
    /// Transcript words on the left and the item list on the right (Transcript picks).
    var transcriptLeading = false
    /// Heading above the list when there is no Keep checkbox.
    var listTitle: String? = nil
    /// Drag to reorder: receives every top-level owner ID in its new order.
    var onMove: (([Int64]) -> Void)? = nil
    /// Delete from the row's context menu or the Delete key.
    var onDelete: ((RangeReviewItem) -> Void)? = nil
    /// A Remove All button beside the list title, shown while the list has items.
    var onDeleteAll: (() -> Void)? = nil
    @State private var confirmingDeleteAll = false
    /// Draft items select by pressing a word and dragging; an empty range means nothing selected.
    var spanSelection = false
    /// A Play All button under the list plays every item in order.
    var playAll = false
    /// Replaces the transcript words column (Fight metrics shows its action grid there).
    var leadingPanel: AnyView? = nil
    /// A control for the transcript column's header, per selected item.
    var transcriptAccessory: ((RangeReviewItem) -> AnyView?)? = nil
    /// A control shown under the picture while a span is marked (Express's
    /// Add button); a Clear button that drops the span sits beside it.
    var trimAccessory: ((RangeReviewItem) -> AnyView?)? = nil
    /// Shown in the trim column while a draft has no range yet.
    var emptyDraftHint = "Press a word in the transcript and drag to select a passage."
    /// Replaces the trim hint under the filmstrip (no transcript words to click in Fight metrics).
    var trimHint: String? = nil
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
    @State private var playback = PodcastHighlightTrimPlayback()
    @State private var loadedURL: URL?
    @State private var draft: (start: Double, end: Double)?
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
        guard !item.isDraft else { return nil }
        return items.filter { !$0.isDraft }.firstIndex { $0.id.ownerID == item.id.ownerID }
    }

    /// Saved picks of `video` as marked ranges, in the colour of their rows.
    private func markedRanges(excluding selectedID: RangeReviewItem.ID?, video: VideoRecord) -> [RangeReviewMarkedRange] {
        items.flatMap { owner in
            (owner.children.isEmpty ? [owner] : owner.children).compactMap { item -> RangeReviewMarkedRange? in
                guard item.id != selectedID, item.video.id == video.id, let index = paletteIndex(owner) else { return nil }
                return RangeReviewMarkedRange(range: item.range, paletteIndex: index)
            }
        }
    }

    private var visibleItems: [RangeReviewItem] {
        items.flatMap { item in [item] + (item.id.ownerID == selectedID?.ownerID ? item.children : []) }
    }

    var body: some View {
        GeometryReader { geometry in
            let widths = Self.columnWidths(available: geometry.size.width,
                                           list: CGFloat(listWidth), transcript: CGFloat(transcriptWidth))
            let playerWidth = max(0, geometry.size.width - widths.list - widths.transcript
                                  - 2 * TranscriptQAColumns.dividerWidth)
            HStack(spacing: 0) {
                if transcriptLeading {
                    // The word panel is one view whether or not something is
                    // selected, so a drag that starts with nothing selected
                    // keeps its gesture state while it selects the draft.
                    if let context = selected ?? items.first {
                        Group {
                            if let leadingPanel { leadingPanel }
                            else { wordPanel(selected: context, video: context.video, inactive: selected == nil) }
                        }
                        .frame(width: widths.transcript).clipped()
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
                    columnDivider(.list, width: widths.list, otherWidth: widths.transcript,
                                  available: geometry.size.width)
                    itemList.frame(width: widths.list).clipped()
                } else {
                    itemList.frame(width: widths.list).clipped()
                    columnDivider(.list, width: widths.list, otherWidth: widths.transcript,
                                  available: geometry.size.width)
                    if let selected, let video {
                        trimSurface(item: selected).padding(Theme.spaceS)
                            .frame(width: playerWidth).frame(maxHeight: .infinity, alignment: .top).clipped()
                        columnDivider(.transcript, width: widths.transcript, otherWidth: widths.list,
                                      available: geometry.size.width)
                        wordPanel(selected: selected, video: video).frame(width: widths.transcript).clipped()
                    } else {
                        ContentUnavailableView(emptyTitle, systemImage: "text.bubble",
                                               description: Text(emptyMessage))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
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
            if let pendingDraft {
                draft = pendingDraft
                self.pendingDraft = nil
                if pendingCommit {
                    pendingCommit = false
                    commitDraft(snap: false)
                }
            }
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
            guard let range, draft == nil else { return }
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
    /// selected; a word click selects `selected` (the first item, the draft in
    /// pick lists) and a drag selects it and marks the span in one move.
    private func wordPanel(selected: RangeReviewItem, video: VideoRecord, inactive: Bool = false) -> some View {
        let emptyRange = selected.range.lowerBound...selected.range.lowerBound
        let contextCanTrim = inactive ? selected.isAvailable : canTrim
        func activate() {
            selectedID = selected.id
            userCleared = false
        }
        return TranscriptQAWordPanel(transcript: visibleTranscript, videoID: video.id,
                              translationLanguages: transcriptVideoID == video.id ? translationLanguages : [],
                              translationsByLanguage: transcriptVideoID == video.id ? translationsByLanguage : [:],
                              preferredTranslationLanguage: preferredTranslationLanguage,
                              sectionID: selected.id,
                              range: inactive ? emptyRange : editRange,
                              otherRanges: markedRanges(excluding: inactive ? nil : selected.id, video: video),
                              playback: playback, canTrim: contextCanTrim,
                              onSelect: inactive ? { _ in activate() } : selectWord,
                              onPreview: inactive ? { _, _ in activate() } : previewWord,
                              onCommit: { if inactive { pendingCommit = pendingDraft != nil } else { commitDraft(snap: false) } },
                              onCancel: { draft = nil; anchorDrag = nil },
                              spanSelection: spanSelection && selected.isDraft,
                              onSpanPreview: { span in
                                  guard isEnabled, contextCanTrim else { return }
                                  if inactive {
                                      pendingDraft = (span.lowerBound, span.upperBound)
                                      activate()
                                  } else {
                                      draft = (span.lowerBound, span.upperBound)
                                  }
                              },
                              onSpanClear: {
                                  guard isEnabled, canTrim, let range else { draft = nil; return }
                                  draft = nil
                                  commit(range.lowerBound...range.lowerBound)
                              },
                              accessory: inactive ? nil : transcriptAccessory?(selected))
    }

    private func columnDivider(_ column: TranscriptQAColumns.Column, width: CGFloat,
                               otherWidth: CGFloat, available: CGFloat) -> some View {
        TranscriptQAColumnDivider(column: column, width: width, onResize: { proposed in
            guard let updated = TranscriptQAColumns.resizedWidth(proposed, column: column,
                available: available, otherWidth: otherWidth) else { return }
            if column == .list { listWidth = Double(updated) }
            else { transcriptWidth = Double(updated) }
        }, onReset: {
            if column == .list { listWidth = Double(column.defaultWidth) }
            else { transcriptWidth = Double(column.defaultWidth) }
        }, isLeading: (column == .list) != transcriptLeading)
    }

    private var itemList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let kept {
                let ids = Set(items.map { $0.id.ownerID })
                let count = kept.wrappedValue.intersection(ids).count
                VStack(alignment: .leading, spacing: Theme.spaceXS) {
                    Button(RangeReviewItem.allKept(kept.wrappedValue, items: items) ? "Deselect All" : "Select All") {
                        kept.wrappedValue = RangeReviewItem.togglingAll(kept.wrappedValue, items: items)
                    }
                    .controlSize(.small).lineLimit(1).fixedSize()
                    FormCaption("\(count) of \(items.count) kept")
                        .lineLimit(1).fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.spaceS)
                Divider()
            } else if let listTitle {
                HStack(spacing: Theme.spaceS) {
                    Text(listTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
                    Spacer(minLength: 0)
                    if let onDeleteAll, items.contains(where: { !$0.isDraft }) {
                        Button("Remove All", role: .destructive) { confirmingDeleteAll = true }
                            .controlSize(.small).lineLimit(1).fixedSize()
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
                .padding(Theme.spaceS)
                Divider()
            }
            // Selection is explicit so the sibling checkbox never selects a row.
            // Rows live in a plain stack so a row can be dragged to a new place
            // with a marker showing where it lands.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleItems) { item in
                        itemRow(item)
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
            if playAll {
                Divider()
                HStack(spacing: Theme.spaceS) {
                    let playsCuts = RangeReviewPlayAll.playsCuts(items: items, selectedOwnerID: selectedID?.ownerID)
                    Button(playingAll ? "Stop" : "Play All",
                           systemImage: playingAll ? "stop.fill" : "play.fill") {
                        if playingAll { stopPlayAll() } else { startPlayAll() }
                    }
                    .lineLimit(1).fixedSize()
                    .disabled(!isEnabled || playableItems.isEmpty)
                    .help(playingAll ? "Stop playing"
                          : playsCuts ? "Play this reel's cuts back to back, as the video will be stitched"
                          : "Play every item in order")
                    if playsCuts, !playingAll {
                        Text("Plays the selected reel's cuts in order")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .padding(Theme.spaceS)
            }
        }
    }

    private var playableItems: [RangeReviewItem] {
        RangeReviewPlayAll.sequence(items: items, selectedOwnerID: selectedID?.ownerID)
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
                        .lineLimit(item.titleLines).truncationMode(.tail)
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
                .padding(.leading, (isChild ? 42 : kept != nil ? 26 : 0) + (item.isDraft ? 0 : RangeReviewPalette.barWidth + Theme.spaceXS))
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
            if let kept, !isChild {
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
                             : "Footage changed. Regenerate this candidate to preview it.")
                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center).padding(Theme.spaceS)
                    }
                }
            if spanSelection, item.isDraft, !isEmptyRange, let selected, selected.id == item.id {
                HStack(spacing: Theme.spaceS) {
                    if let accessory = trimAccessory?(selected) { accessory }
                    Button {
                        guard isEnabled, canTrim, let range else { draft = nil; return }
                        draft = nil
                        commit(range.lowerBound...range.lowerBound)
                    } label: {
                        Text("Clear").lineLimit(1).fixedSize()
                    }
                    .controlSize(.small)
                    .disabled(!canTrim)
                    .help("Clear the marked passage")
                    Spacer(minLength: 0)
                }
            }
            if isEmptyRange {
                FormCaption(emptyDraftHint)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            } else {
                filmstrip(video: item.video)
                    .id(item.id)
                    .disabled(!canTrim)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.spaceS) {
                        playButton
                        rangeLabel
                        Spacer(minLength: 0)
                        resetButton(item)
                    }
                    VStack(alignment: .leading, spacing: Theme.spaceS) {
                        playButton
                        rangeLabel
                        resetButton(item)
                    }
                }
                let hint = spanSelection && item.isDraft ? Self.spanHint : (trimHint ?? Self.trimHint)
                FormCaption(hint)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .help(hint)
            }
            footer(selectedParent ?? item)
        }
    }

    /// Width over height of the footage; 16:9 until the video's dimensions are known.
    static func pictureAspect(_ video: VideoRecord) -> CGFloat {
        video.width > 0 && video.height > 0 ? CGFloat(video.width) / CGFloat(video.height) : 16 / 9
    }

    private static var spanHint: String {
        "Drag the handles or the transcript anchors to adjust · click the selection to clear it · I / O set the start / end at the playhead"
    }

    private static var trimHint: String {
        "Drag the handles or the transcript anchors, or click a word to move the nearer end to it · I / O set the start / end at the playhead"
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
            PlaybackSpeedControl(playback: playback)
        }
    }

    private var rangeLabel: some View {
        ViewThatFits(in: .horizontal) {
            Text(rangeCaption(shownRange)).lineLimit(1).fixedSize()
            VStack(alignment: .leading, spacing: 2) {
                Text("\(shownRange.lowerBound.timecode)–\(shownRange.upperBound.timecode)")
                Text("\(shownRange.upperBound - shownRange.lowerBound, format: .number.precision(.fractionLength(1)))s")
            }
            .lineLimit(1).fixedSize()
        }
        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
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
                GeometryReader { proxy in
                    if let x = window.playheadX(at: playback.time, width: Double(proxy.size.width)) {
                        Rectangle().fill(.white)
                            .frame(width: 2, height: 48).offset(x: CGFloat(x))
                    }
                }
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

    private func selectWord(_ word: TranscriptQATrim.Word) {
        guard isEnabled, canTrim else { return }
        let edge = TranscriptQATrim.nearestEdge(for: word, in: editRange)
        let updated = moving(edge, to: word)
        commit(updated)
        playback.seek(to: edge == .start ? updated.lowerBound : max(updated.lowerBound, updated.upperBound - 3))
        playback.play()
    }

    private func commit(_ proposed: ClosedRange<Double>) {
        guard isEnabled, canTrim, let selected else { draft = nil; return }
        let updated = policy.clamp(proposed, limits: limits)
        draft = nil
        onSave(selected, updated.lowerBound, updated.upperBound)
        playback.setRange(playable(updated))
        if window.needsRecentering(updated) { recenter(updated) }
        // Adapters observe saved ranges; their refreshes remain authoritative.
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard isEnabled, range != nil, playback.player != nil else { return false }
        if let onDelete, let selected, event.keyCode == 51 || event.keyCode == 117,
           !selected.isDraft, selected.id.cutIndex == nil {
            onDelete(selected)
            return true
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case " ": playingAll = false; playback.togglePlay()
        case "i", "o":
            guard canTrim, !isEmptyRange else { return false }
            let edge: TranscriptQATrim.Edge = event.charactersIgnoringModifiers?.lowercased() == "i" ? .start : .end
            let time = policy != .wizard ? TranscriptQATrim.snap(playback.time, edge: edge, words: visibleTranscript.words) : playback.time
            commit(policy.setting(edge, at: time, in: editRange, limits: limits))
        default: return false
        }
        return true
    }
}
