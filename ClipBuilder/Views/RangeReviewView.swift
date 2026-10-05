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
            HStack(spacing: 0) {
                itemList.frame(width: widths.list)
                    .clipped()
                columnDivider(.list, width: widths.list, otherWidth: widths.transcript,
                              available: geometry.size.width)
                if let selected, let video {
                    trimSurface(item: selected)
                        .padding(Theme.spaceS)
                        .frame(width: max(0, geometry.size.width - widths.list - widths.transcript
                                          - 2 * TranscriptQAColumns.dividerWidth))
                        .clipped()
                    columnDivider(.transcript, width: widths.transcript, otherWidth: widths.list,
                                  available: geometry.size.width)
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
                                          onCommit: { commitDraft(snap: false) }, onCancel: { draft = nil })
                        .frame(width: widths.transcript)
                        .clipped()
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
        }
        .onChange(of: items.flatMap { [$0.id] + $0.children.map(\.id) }) { _, _ in reconcileSelection() }
        .onChange(of: selection?.wrappedValue) { _, ownerID in
            if ownerID != selectedID?.ownerID { reconcileSelection() }
        }
        .onChange(of: range) { _, range in
            guard let range, draft == nil else { return }
            playback.setRange(range)
            if window.needsRecentering(range) { recenter(range) }
        }
        .onChange(of: playback.player != nil) { _, ready in
            // Selection may have changed while the same file was loading.
            if ready, let range, selected?.isAvailable == true {
                playback.setRange(range)
                playback.seek(to: range.lowerBound)
                if isEnabled { playback.play() }
            }
        }
        .onChange(of: video?.url) { _, _ in selectItem() }
        .onChange(of: selected?.isAvailable) { _, _ in selectItem() }
        .onChange(of: limits) { _, _ in
            draft = nil
            if let range { recenter(range) }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { draft = nil; playback.pause() }
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
        })
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
            }
            // Selection is explicit so the sibling checkbox never selects a row.
            List {
                ForEach(visibleItems) { item in
                    itemRow(item)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(item.id == selectedID ? Color.accentColor.opacity(0.16) : Color.clear)
                }
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
        }
    }

    private func itemRow(_ item: RangeReviewItem) -> some View {
        let isChild = item.id.cutIndex != nil
        return ZStack(alignment: .topLeading) {
            Button { selectedID = item.id } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.callout.weight(.medium)).lineLimit(1).truncationMode(.tail)
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Theme.spaceS)
                .padding(.horizontal, Theme.spaceS)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(item.id == selectedID ? .isSelected : [])
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
            FormCaption(Self.trimHint)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .help(Self.trimHint)
            footer(selectedParent ?? item)
        }
    }

    private static var trimHint: String {
        "Drag the handles or the transcript anchors, or click a word to move the nearer end to it · I / O set the start / end at the playhead"
    }

    private var playButton: some View {
        HStack(spacing: Theme.spaceS) {
            Button(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
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
            .help(policy == .qa ? "Drag a handle and release near an edge to see more. Ends snap to nearby words."
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
            playback.load(url: video.url, range: range, autoplay: false)
        } else if playback.player != nil {
            playback.setRange(range)
            playback.seek(to: range.lowerBound)
            if isEnabled { playback.play() }
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
        playback.setRange(updated)
        if window.needsRecentering(updated) { recenter(updated) }
        // Adapters observe saved ranges; their refreshes remain authoritative.
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard isEnabled, range != nil, playback.player != nil else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case " ": playback.togglePlay()
        case "i", "o":
            guard canTrim else { return false }
            let edge: TranscriptQATrim.Edge = event.charactersIgnoringModifiers?.lowercased() == "i" ? .start : .end
            let time = policy == .qa ? TranscriptQATrim.snap(playback.time, edge: edge, words: visibleTranscript.words) : playback.time
            commit(policy.setting(edge, at: time, in: editRange, limits: limits))
        default: return false
        }
        return true
    }
}
