import SwiftUI
import AVKit

/// Shared review surface; adapters own domain data and persistence.
struct RangeReviewView<Footer: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    let items: [RangeReviewItem]
    let rows: [TranscriptRow]
    let labels: [Int64: String]
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
    /// Draft items select by pressing a word and dragging; an empty range means nothing selected.
    var spanSelection = false
    /// A Play All button under the list plays every item in order.
    var playAll = false
    let onSave: (RangeReviewItem, Double, Double) -> Void
    @ViewBuilder var footer: (RangeReviewItem) -> Footer

    @State private var selectedID: RangeReviewItem.ID?
    @State private var playback = PodcastHighlightTrimPlayback()
    @State private var loadedURL: URL?
    @State private var draft: (start: Double, end: Double)?
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
        transcriptVideoID == video?.id ? transcript : TranscriptQATrim.Transcript()
    }
    private var transcriptInput: TranscriptQATrim.Input {
        TranscriptQATrim.Input(rows: rows, labels: labels, videoID: video?.id ?? -1)
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
                    if let selected, let video {
                        wordPanel(selected: selected, video: video).frame(width: widths.transcript).clipped()
                        columnDivider(.transcript, width: widths.transcript, otherWidth: widths.list,
                                      available: geometry.size.width)
                        trimSurface(item: selected).padding(Theme.spaceS).frame(width: playerWidth).clipped()
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
                        trimSurface(item: selected).padding(Theme.spaceS).frame(width: playerWidth).clipped()
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
            if playingAll {
                if advancingPlayAll, playback.player != nil, let range, range.upperBound > range.lowerBound {
                    playback.play()
                } else {
                    // The user chose another item: Play All is over.
                    playingAll = false
                }
                advancingPlayAll = false
            }
        }
        .onChange(of: playback.isPlaying) { _, playing in
            guard playingAll, !playing, !advancingPlayAll else { return }
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
                if isEnabled, autoplay { playback.play() }
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

    private func wordPanel(selected: RangeReviewItem, video: VideoRecord) -> some View {
        TranscriptQAWordPanel(transcript: visibleTranscript, videoID: video.id,
                              translationLanguages: transcriptVideoID == video.id ? translationLanguages : [],
                              translationsByLanguage: transcriptVideoID == video.id ? translationsByLanguage : [:],
                              preferredTranslationLanguage: preferredTranslationLanguage,
                              sectionID: selected.id,
                              range: editRange,
                              otherRanges: items.flatMap { $0.children.isEmpty ? [$0] : $0.children }
                                  .filter { $0.id != selected.id && $0.video.id == video.id }.map(\.range),
                              playback: playback, canTrim: canTrim,
                              onSelect: selectWord, onPreview: previewWord,
                              onCommit: { commitDraft(snap: false) }, onCancel: { draft = nil },
                              spanSelection: spanSelection && selected.isDraft,
                              highlightsCurrentLine: !spanSelection,
                              onSpanPreview: { span in
                                  guard isEnabled, canTrim else { return }
                                  draft = (span.lowerBound, span.upperBound)
                              },
                              onSpanClear: {
                                  guard isEnabled, canTrim, let range else { draft = nil; return }
                                  draft = nil
                                  commit(range.lowerBound...range.lowerBound)
                              })
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
                Text(listTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
                    .padding(Theme.spaceS)
                Divider()
            }
            // Selection is explicit so the sibling checkbox never selects a row.
            List {
                ForEach(visibleItems) { item in
                    itemRow(item)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(item.id == selectedID ? Color.accentColor.opacity(0.16) : Color.clear)
                        .moveDisabled(item.isDraft || item.id.cutIndex != nil)
                        .contextMenu {
                            if let onDelete, !item.isDraft, item.id.cutIndex == nil {
                                Button("Delete", role: .destructive) { onDelete(item) }
                            }
                        }
                }
                .onMove(perform: onMove == nil ? nil : moveItems)
            }
            .listStyle(.sidebar)
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
                    Button(playingAll ? "Stop" : "Play All",
                           systemImage: playingAll ? "stop.fill" : "play.fill") {
                        if playingAll { stopPlayAll() } else { startPlayAll() }
                    }
                    .lineLimit(1).fixedSize()
                    .disabled(!isEnabled || !visibleItems.contains { !$0.isDraft && $0.isAvailable })
                    .help(playingAll ? "Stop playing" : "Play every item in order")
                    Spacer(minLength: 0)
                }
                .padding(Theme.spaceS)
            }
        }
    }

    private var playableItems: [RangeReviewItem] {
        visibleItems.filter { !$0.isDraft && $0.id.cutIndex == nil && $0.isAvailable && $0.range.upperBound > $0.range.lowerBound }
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
    private func moveButtons(_ item: RangeReviewItem) -> some View {
        let owners = visibleItems.filter { !$0.isDraft && $0.id.cutIndex == nil }
        let index = owners.firstIndex { $0.id == item.id } ?? 0
        return HStack(spacing: 0) {
            Button("Move up", systemImage: "chevron.up") { moveOwner(item, by: -1) }
                .disabled(index == 0)
                .help("Move up")
            Button("Move down", systemImage: "chevron.down") { moveOwner(item, by: 1) }
                .disabled(index >= owners.count - 1)
                .help("Move down")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .fixedSize()
    }

    private func moveOwner(_ item: RangeReviewItem, by offset: Int) {
        guard isEnabled, let onMove else { return }
        var ids = visibleItems.filter { !$0.isDraft && $0.id.cutIndex == nil }.map { $0.id.ownerID }
        guard let index = ids.firstIndex(of: item.id.ownerID), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        onMove(ids)
    }

    /// Top-level owners in their new order; drafts and child cuts stay where they are.
    private func moveItems(from source: IndexSet, to destination: Int) {
        guard isEnabled, let onMove else { return }
        var visible = visibleItems
        visible.move(fromOffsets: source, toOffset: destination)
        onMove(visible.filter { !$0.isDraft && $0.id.cutIndex == nil }.map { $0.id.ownerID })
    }

    private func itemRow(_ item: RangeReviewItem) -> some View {
        let isChild = item.id.cutIndex != nil
        return ZStack(alignment: .topLeading) {
            Button { selectedID = item.id } label: {
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
                .padding(.leading, isChild ? 42 : kept != nil ? 26 : 0)
                .padding(.trailing, onMove != nil && !item.isDraft && !isChild ? 44 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Theme.spaceS)
                .padding(.horizontal, Theme.spaceS)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(item.id == selectedID ? .isSelected : [])
            if onMove != nil, !item.isDraft, !isChild {
                moveButtons(item)
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
            PlayerView(player: playback.player, controlsStyle: .none)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
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
            if isEmptyRange {
                FormCaption("Press a word in the transcript and drag to select a passage.")
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
                FormCaption(spanSelection && item.isDraft ? Self.spanHint : Self.trimHint)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .help(spanSelection && item.isDraft ? Self.spanHint : Self.trimHint)
            }
            footer(selectedParent ?? item)
        }
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
            PlaybackSpeedSlider(playback: playback)
        }
    }

    private var rangeLabel: some View {
        ViewThatFits(in: .horizontal) {
            Text(rangeCaption(editRange)).lineLimit(1).fixedSize()
            VStack(alignment: .leading, spacing: 2) {
                Text("\(editRange.lowerBound.timecode)–\(editRange.upperBound.timecode)")
                Text("\(editRange.upperBound - editRange.lowerBound, format: .number.precision(.fractionLength(1)))s")
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
                        start: Binding(get: { editRange.lowerBound }, set: {
                            guard isEnabled, canTrim else { return }
                            draft = (start: $0, end: draft?.end ?? editRange.upperBound)
                        }),
                        end: Binding(get: { editRange.upperBound }, set: {
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
        guard draft != nil, let range else { return }
        let updated = snap ? policy.releasing(editRange, from: range, words: visibleTranscript.words, limits: limits) : editRange
        commit(updated)
    }

    private func previewWord(_ edge: TranscriptQATrim.Edge, _ word: TranscriptQATrim.Word) {
        guard isEnabled, canTrim else { return }
        let updated = moving(edge, to: word)
        draft = (updated.lowerBound, updated.upperBound)
        playback.scrub(to: edge == .start ? updated.lowerBound : updated.upperBound)
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
