import SwiftUI

/// Full-recording transcript; only visible lines are laid out. The two anchors
/// live above the scroll content, so moving a cut never replaces its gesture.
struct TranscriptQAWordPanel<SelectionID: Hashable>: View {
    @Environment(\.isEnabled) private var isEnabled
    let transcript: TranscriptQATrim.Transcript
    let videoID: Int64
    let translationLanguages: [String]
    let translationsByLanguage: [String: [Int: String]]
    let preferredTranslationLanguage: String?
    let sectionID: SelectionID
    let range: ClosedRange<Double>
    /// Saved picks' ranges with their palette index; their words show as
    /// pastel blocks and the first word carries the list row's bar.
    let otherRanges: [RangeReviewMarkedRange]
    let playback: PodcastHighlightTrimPlayback
    let canTrim: Bool
    let onSelect: (TranscriptQATrim.Word) -> Void
    let onPreview: (TranscriptQATrim.Edge, TranscriptQATrim.Word) -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void
    /// Press a word and drag to select; a click on the selection clears it.
    /// Word clicks then no longer move the nearer end; the anchors still adjust.
    var spanSelection = false
    /// With nothing selected `range` is an empty anchor on the first painted
    /// passage; follow it when it moves. Off while an item is selected: a pick
    /// click commits an empty range on its way to the word and must not jump.
    var followsEmptyAnchor = false
    var onSpanPreview: ((ClosedRange<Double>) -> Void)? = nil
    /// The other passages of a selection made of several (span selection
    /// only); `range` is the one being edited.
    var draftSpans: [TranscriptDraftSpan] = []
    /// False when the passages are saved items that `otherRanges` already paints.
    var paintsDraftSpans = true
    /// The number of `range` among them; nil while it is the only passage.
    var currentSpanNumber: Int? = nil
    /// A press with Shift held: the next span is another passage, not a
    /// change to the current one.
    var onBeginSpan: (() -> Void)? = nil
    /// A click on another passage makes it the one being edited.
    var onSelectSpan: ((Int) -> Void)? = nil
    var onDeleteSpan: ((Int) -> Void)? = nil
    /// Shown after the Follow / Translation controls (Express puts its Add button here).
    var accessory: AnyView? = nil
    /// A row pinned under the words (the range review puts Add / Clear / Reset here).
    var footer: AnyView? = nil

    @State private var followsPlayback = true
    @AppStorage("transcriptQA.showTranslation") private var showTranslation = false
    @State private var selectedTranslationLanguages: [Int64: String] = [:]
    @State private var store = TranscriptQAWordFrames()
    private var frames: [Int: CGRect] { store.frames }
    @State private var dragging: TranscriptQATrim.Edge?
    /// The word the span drag started on.
    @State private var spanAnchor: Int?
    /// The first word on each wrapped line of each saved pick, from the measured frames.
    @State private var lineActions = TranscriptQALineActions()
    @State private var spanMoved = false
    /// The span under way began with Shift held: it is a new passage.
    @State private var spanAdds = false
    @State private var pointer: CGPoint?
    @State private var dragFrame: CGRect?
    @State private var scrollDirection = 0
    @State private var lastPreviewedWord: Int?
    private static var scrollSpace: String { "qaWordViewport" }

    private var firstWord: TranscriptQATrim.Word? { transcript.words.first { TranscriptQATrim.contains($0, in: range) } }
    private var lastWord: TranscriptQATrim.Word? { transcript.words.last { TranscriptQATrim.contains($0, in: range) } }
    private var translationLanguage: String? {
        TranscriptQATrim.translationLanguage(available: translationLanguages,
            selected: selectedTranslationLanguages[videoID], preferred: preferredTranslationLanguage)
    }
    private var showsTranslation: Bool { showTranslation && translationLanguage != nil }

    private func transcriptChanged() {
        cancelDrag()
        store.keep(wordIDs: Set(transcript.words.map(\.id)))
    }

    var body: some View {
        let time = playback.time
        let spokenWordID = transcript.spokenWordID(at: time, isPlaying: playback.isPlaying)
        let currentLine = transcript.lineID(at: time)
        // The equatable lines retain this reference, so even an unchanged line
        // invokes the current selection's callbacks after Clear or a pick switch.
        let actions = lineActions.update(onSelect: onSelect, onSeek: { [playback] in playback.seek(to: $0) })
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.spaceS) {
                    SectionLabel("Transcript")
                    Spacer(minLength: 0)
                    transcriptControls
                    if let accessory { accessory }
                }
                // Narrow column: the accessory keeps the title row, the toggles get their own.
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    HStack(spacing: Theme.spaceS) {
                        SectionLabel("Transcript")
                        Spacer(minLength: 0)
                        if let accessory { accessory }
                    }
                    ScrollView(.horizontal) { transcriptControls }
                        .scrollIndicators(.hidden)
                        .frame(height: 24)
                }
            }
            .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            .padding(Theme.spaceS)
            if transcript.lines.isEmpty {
                FormCaption("No transcript for this recording. Use the filmstrip handles to adjust the exchange.")
                    .padding(Theme.spaceM)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                transcriptScroll(spokenWordID: spokenWordID, currentLine: currentLine, actions: actions)
            }
            if let footer {
                footer
                    .lineLimit(1).fixedSize(horizontal: false, vertical: true)
                    .padding(Theme.spaceS)
            }
        }
        .onChange(of: sectionID) { _, _ in cancelDrag() }
        .onChange(of: isEnabled) { _, enabled in if !enabled { cancelDrag() } }
        .onChange(of: transcript) { _, _ in transcriptChanged() }
        // The lines report their frames again if translation changes the
        // layout; clearing them would lose anchors when the layout stays equal.
        .onChange(of: showsTranslation) { _, _ in cancelDrag() }
        .onChange(of: translationLanguage) { _, _ in cancelDrag() }
        .onDisappear { cancelDrag() }
    }

    private var transcriptControls: some View {
        HStack(spacing: Theme.spaceS) {
            Toggle("Follow", isOn: $followsPlayback)
                .toggleStyle(.checkbox).controlSize(.small)
                .lineLimit(1).fixedSize()
                .help("Keep the line being spoken in view")
            if let language = translationLanguage {
                Toggle("Translation", isOn: $showTranslation)
                    .toggleStyle(.checkbox).controlSize(.small)
                    .lineLimit(1).fixedSize()
                    .help("Show the translation beside each line")
                if translationLanguages.count > 1 {
                    Menu {
                        ForEach(translationLanguages, id: \.self) { option in
                            Button {
                                selectedTranslationLanguages[videoID] = option
                            } label: {
                                if option == language {
                                    Label(languageName(option), systemImage: "checkmark")
                                } else {
                                    Text(languageName(option))
                                }
                            }
                        }
                    } label: {
                        Text(languageName(language)).lineLimit(1).fixedSize()
                    }
                    .controlSize(.small).fixedSize()
                    .help("Translation language")
                    .accessibilityLabel("Translation language")
                    .accessibilityValue(languageName(language))
                }
            }
        }
        .fixedSize()
    }

    private func languageName(_ language: String) -> String {
        Locale.current.localizedString(forLanguageCode: language) ?? language
    }

    private func transcriptScroll(spokenWordID: Int?, currentLine: Int?, actions: TranscriptQALineActions) -> some View {
        GeometryReader { geometry in
            // Both columns always fit the pane (the scroller's gutter included):
            // text wraps in a narrow pane and the user widens the column for
            // more room. Sideways scrolling would hide the translation.
            let contentWidth = max(120, geometry.size.width - 16)
            let columnWidth = max(40, (contentWidth - 5 * Theme.spaceS) / 2)
            ScrollViewReader { proxy in
                ZStack(alignment: .topLeading) {
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(transcript.lines) { line in
                                TranscriptQALineView(
                                    line: line,
                                    columnWidth: columnWidth,
                                    selection: TranscriptQATrim.selectionRange(range, in: line),
                                    startEdgeWordIDs: spanSelection ? [] : TranscriptQATrim.startEdgeWordIDs(in: line, range: range),
                                    otherRanges: paintedRanges.filter { TranscriptQATrim.touches($0.range, line: line) },
                                    spokenWordID: spokenWordID.flatMap { id in line.words.contains { $0.id == id } ? id : nil },
                                    showsTranslation: showsTranslation,
                                    translation: translationLanguage.flatMap { translationsByLanguage[$0]?[line.id] },
                                    canTrim: canTrim,
                                    spanSelection: spanSelection,
                                    store: store,
                                    onSelect: { actions.onSelect($0) },
                                    onSeek: { actions.onSeek($0) })
                                    .equatable()
                                    .id(line.id)
                            }
                        }
                        .padding(Theme.spaceS)
                        .frame(width: contentWidth, alignment: .leading)
                        .contentShape(Rectangle())
                        .gesture(spanGesture(viewportHeight: geometry.size.height),
                                 including: spanSelection && canTrim && isEnabled ? .all : .subviews)
                        // Word clicks outside span mode: the word under the
                        // pointer, found by its frame (words are not buttons).
                        .gesture(SpatialTapGesture(coordinateSpace: .named(Self.scrollSpace)).onEnded { value in
                            guard isEnabled, canTrim, !spanSelection,
                                  let id = TranscriptQATrim.word(at: value.location, frames: frames),
                                  transcript.words.indices.contains(id) else { return }
                            actions.onSelect(transcript.words[id])
                        }, including: !spanSelection && canTrim && isEnabled ? .all : .subviews)
                    }
                    // Scrolling changes the word under a stationary pointer.
                    .onChange(of: store.frames) { _, _ in previewAtPointer() }
                    anchor(.start, word: firstWord, viewportHeight: geometry.size.height)
                    anchor(.end, word: lastWord, viewportHeight: geometry.size.height)
                    ForEach(numberedSpans, id: \.number) { spanControls($0, among: numberedSpans) }
                    TranscriptOverviewMarks(transcript: transcript, range: range, otherRanges: paintedRanges)
                        .frame(width: TranscriptOverviewMarks.width, height: geometry.size.height)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .coordinateSpace(name: Self.scrollSpace)
                .clipped()
                .onAppear { scrollToSelection(proxy) }
                .onChange(of: sectionID) { _, _ in
                    // A word click on another item selects it with that word;
                    // the new range arrives with the next update, so scroll then.
                    // Once more a moment later: a passage far down the lazy
                    // stack has no row yet on the first try, and the scroll
                    // stops short of it.
                    Task { @MainActor in
                        scrollToSelection(proxy)
                        try? await Task.sleep(for: .milliseconds(120))
                        if dragging == nil, spanAnchor == nil { scrollToSelection(proxy) }
                    }
                }
                .onChange(of: range) { old, new in
                    // With nothing selected the range is an empty anchor on the
                    // first painted passage; it moves when the kept items load
                    // after the words. Edits of a real range never scroll.
                    if followsEmptyAnchor, new.lowerBound == new.upperBound, old != new { scrollToSelection(proxy) }
                }
                .onChange(of: transcript) { _, _ in
                    // The new lines are not laid out in this update yet, so a
                    // scroll issued now finds no target and the words stay at
                    // the top. Scroll once the lazy stack has them.
                    Task { @MainActor in scrollToSelection(proxy) }
                }
                .onChange(of: currentLine) { _, id in
                    guard followsPlayback, playback.isPlaying, dragging == nil, let id else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
                .onChange(of: followsPlayback) { _, follows in
                    if follows, dragging == nil, let currentLine { proxy.scrollTo(currentLine, anchor: .center) }
                }
                .task(id: scrollDirection) {
                    guard scrollDirection != 0 else { return }
                    while !Task.isCancelled, dragging != nil || spanAnchor != nil, isEnabled {
                        scrollOneLine(proxy, viewportHeight: geometry.size.height)
                        do { try await Task.sleep(for: .milliseconds(120)) }
                        catch { return }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func anchor(_ edge: TranscriptQATrim.Edge, word: TranscriptQATrim.Word?, viewportHeight: CGFloat) -> some View {
        let frame = word.flatMap { frames[$0.id] } ?? (dragging == edge ? dragFrame : nil)
        if let frame {
            Rectangle().fill(Color.accentColor)
                .frame(width: 3, height: max(18, frame.height))
                .overlay(alignment: edge == .start ? .top : .bottom) {
                    Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                }
                .frame(width: 20, height: max(28, frame.height + 8))
                .contentShape(Rectangle())
                .position(x: edge == .start ? frame.minX : frame.maxX, y: frame.midY)
                .onHover { hovering in
                    guard canTrim else { return }
                    // An open hand over the handle, a closed one while dragging.
                    if hovering { if dragging == nil { TranscriptQAWordCursor.set(.openHand) } }
                    else if dragging == nil { TranscriptQAWordCursor.set(nil) }
                }
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.scrollSpace))
                    .onChanged { value in
                        guard isEnabled, canTrim else { return }
                        if dragging == nil {
                            dragging = edge
                            dragFrame = frame
                            lastPreviewedWord = nil
                            playback.pause()
                            TranscriptQAWordCursor.set(.closedHand)
                        }
                        pointer = value.location
                        scrollDirection = value.location.y < 32 ? -1 : value.location.y > viewportHeight - 32 ? 1 : 0
                        // The handle is wider than the word's edge: a press
                        // without movement must not take the neighbouring word.
                        if abs(value.translation.width) > 3 || abs(value.translation.height) > 3 { previewAtPointer() }
                    }
                    .onEnded { _ in
                        guard dragging != nil else { return }
                        clearDrag()
                        TranscriptQAWordCursor.set(nil)
                        if isEnabled { onCommit() } else { onCancel() }
                    })
                .help(edge == .start ? "Drag to move the start" : "Drag to move the end")
                .accessibilityElement()
                .accessibilityLabel(edge == .start ? "Selection start" : "Selection end")
                .accessibilityValue((edge == .start ? range.lowerBound : range.upperBound).timecode)
                .accessibilityAdjustableAction { direction in
                    guard isEnabled, canTrim, let word,
                          let index = transcript.words.firstIndex(where: { $0.id == word.id }) else { return }
                    let next: Int
                    switch direction {
                    case .increment: next = index + 1
                    case .decrement: next = index - 1
                    @unknown default: return
                    }
                    guard transcript.words.indices.contains(next) else { return }
                    onPreview(edge, transcript.words[next])
                    onCommit()
                }
                .disabled(!canTrim)
        }
    }

    /// Saved items' passages plus the selection's other passages.
    private var paintedRanges: [RangeReviewMarkedRange] {
        guard paintsDraftSpans else { return otherRanges }
        return otherRanges + draftSpans.map { RangeReviewMarkedRange(range: $0.range, paletteIndex: RangeReviewMarkedRange.draftSlot) }
    }

    /// Every passage of a selection made of several, the current one included.
    private var numberedSpans: [TranscriptDraftSpan] {
        guard spanSelection, !draftSpans.isEmpty else { return [] }
        let current = currentSpanNumber.flatMap { number in
            range.upperBound > range.lowerBound ? TranscriptDraftSpan(number: number, range: range) : nil
        }
        return (draftSpans + [current].compactMap { $0 }).sorted { $0.number < $1.number }
    }

    /// "#2" at the passage's first word and a delete button at its last.
    @ViewBuilder
    private func spanControls(_ span: TranscriptDraftSpan, among spans: [TranscriptDraftSpan]) -> some View {
        let firstWord = transcript.words.first { TranscriptQATrim.contains($0, in: span.range) }
        let lastWord = transcript.words.last { TranscriptQATrim.contains($0, in: span.range) }
        let first = firstWord.flatMap { frames[$0.id] }
        let last = lastWord.flatMap { frames[$0.id] }
        // Overlapping passages can start or end on the same word: their
        // controls sit side by side, in number order, not on top of each other.
        let earlier = spans.filter { $0.number < span.number }
        let badgeShift = CGFloat(earlier.filter { other in
            transcript.words.first { TranscriptQATrim.contains($0, in: other.range) }?.id == firstWord?.id
        }.count) * 26
        let deleteShift = CGFloat(earlier.filter { other in
            transcript.words.last { TranscriptQATrim.contains($0, in: other.range) }?.id == lastWord?.id
        }.count) * 20
        let isCurrent = span.number == currentSpanNumber
        if let first {
            Button { onSelectSpan?(span.number) } label: {
                Text("#\(span.number)")
                    .font(.caption2.weight(.bold)).monospacedDigit().lineLimit(1).fixedSize()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(isCurrent ? Color.accentColor : Color.secondary, in: .capsule)
            }
            .buttonStyle(.plain)
            .position(x: first.minX + 4 + badgeShift, y: first.minY - 5)
            .disabled(!isEnabled || !canTrim)
            .help(isCurrent ? "Selection \(span.number): the one being adjusted" : "Adjust selection \(span.number)")
            .accessibilityLabel("Selection \(span.number)")
        }
        if let last, let onDeleteSpan {
            Button { onDeleteSpan(span.number) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, isCurrent ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .position(x: last.maxX + 12 + deleteShift, y: last.minY - 5)
            .disabled(!isEnabled || !canTrim)
            .help("Remove selection \(span.number)")
            .accessibilityLabel("Remove selection \(span.number)")
        }
    }

    private func previewAtPointer() {
        guard isEnabled, let pointer,
              let id = TranscriptQATrim.nearestWord(at: pointer, frames: frames), id != lastPreviewedWord,
              transcript.words.indices.contains(id) else { return }
        if let spanAnchor, transcript.words.indices.contains(spanAnchor) {
            lastPreviewedWord = id
            onSpanPreview?(Self.span(from: transcript.words[spanAnchor], to: transcript.words[id]))
        } else if let dragging {
            lastPreviewedWord = id
            onPreview(dragging, transcript.words[id])
        }
    }

    /// The words between two ends, whichever order they were dragged in.
    nonisolated static func span(from a: TranscriptQATrim.Word, to b: TranscriptQATrim.Word) -> ClosedRange<Double> {
        min(a.start, b.start)...max(a.end, b.end)
    }

    private func spanGesture(viewportHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.scrollSpace))
            .onChanged { value in
                guard isEnabled, canTrim, spanSelection else { return }
                if spanAnchor == nil {
                    guard dragging == nil,
                          let id = TranscriptQATrim.nearestWord(at: value.startLocation, frames: frames)
                            ?? TranscriptQATrim.nearestWord(at: value.location, frames: frames) else { return }
                    // Shift adds a passage to the selection; without it the
                    // span replaces the current passage.
                    spanAdds = onBeginSpan != nil && NSEvent.modifierFlags.contains(.shift) && range.upperBound > range.lowerBound
                    if spanAdds { onBeginSpan?() }
                    spanAnchor = id
                    spanMoved = false
                    lastPreviewedWord = nil
                    playback.pause()
                }
                if abs(value.translation.width) > 3 || abs(value.translation.height) > 3 { spanMoved = true }
                pointer = value.location
                scrollDirection = value.location.y < 32 ? -1 : value.location.y > viewportHeight - 32 ? 1 : 0
                if spanMoved { previewAtPointer() }
            }
            .onEnded { value in
                guard let anchor = spanAnchor else { return }
                let moved = spanMoved
                let added = spanAdds
                clearDrag()
                guard isEnabled, transcript.words.indices.contains(anchor) else { onCancel(); return }
                let word = transcript.words[anchor]
                if moved {
                    onCommit()
                } else if !added, let onSelectSpan,
                          let other = draftSpans.filter({ TranscriptQATrim.contains(word, in: $0.range) })
                            .min(by: { ($0.range.upperBound - $0.range.lowerBound) < ($1.range.upperBound - $1.range.lowerBound) }) {
                    // A click on another passage of the selection edits that one.
                    onSelectSpan(other.number)
                    onCancel()
                } else if word.end > word.start {
                    // A click, inside or outside the current selection, drops
                    // it and starts a new one at this word; Clear empties it.
                    onSpanPreview?(Self.span(from: word, to: word))
                    onCommit()
                } else {
                    onCancel()
                }
            }
    }

    /// Advance one visible line per tick; the gesture and pointer stay in the
    /// fixed viewport while newly materialized LazyVStack words update frames.
    private func scrollOneLine(_ proxy: ScrollViewProxy, viewportHeight: CGFloat) {
        let visible = frames.filter { $0.value.maxY > 0 && $0.value.minY < viewportHeight }
        let id = scrollDirection < 0 ? visible.keys.min() : visible.keys.max()
        guard let id, let index = transcript.lines.firstIndex(where: { $0.words.contains { $0.id == id } }) else { return }
        let next = min(transcript.lines.count - 1, max(0, index + scrollDirection))
        proxy.scrollTo(transcript.lines[next].id, anchor: scrollDirection < 0 ? .top : .bottom)
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        let line = transcript.lines.first { $0.words.contains { TranscriptQATrim.contains($0, in: range) } }
            ?? transcript.lines.first { $0.end > range.lowerBound }
        if let line { proxy.scrollTo(line.id, anchor: .top) }
    }

    private func clearDrag() {
        if dragging != nil { TranscriptQAWordCursor.set(nil) }
        dragging = nil
        spanAnchor = nil
        spanMoved = false
        spanAdds = false
        pointer = nil
        dragFrame = nil
        scrollDirection = 0
        lastPreviewedWord = nil
    }

    private func cancelDrag() {
        guard dragging != nil || spanAnchor != nil else { return }
        clearDrag()
        onCancel()
    }
}

/// Constants and the anchor cursor shared by every word panel instance.
enum TranscriptQAWordCursor {
    /// Gap between word tokens on a line; a selected block fills it.
    static let wordSpacing: CGFloat = 3
    /// Gap between wrapped rows of one line; a selected block fills it too.
    static let rowSpacing: CGFloat = 2

    /// The accent toned down over the window background, opaque so adjoining
    /// word rectangles join without seams.
    /// The selection's other passages: lighter than the one being edited.
    static var draftColor: Color {
        Color(nsColor: NSColor.controlAccentColor.blended(withFraction: 0.85, of: .windowBackgroundColor)
              ?? NSColor.controlAccentColor.withAlphaComponent(0.15))
    }

    static var selectionColor: Color {
        Color(nsColor: NSColor.controlAccentColor.blended(withFraction: 0.7, of: .windowBackgroundColor)
              ?? NSColor.controlAccentColor.withAlphaComponent(0.3))
    }

    /// One pushed cursor at a time: nil restores the arrow.
    private static var pushed = false
    static func set(_ cursor: NSCursor?) {
        if pushed { NSCursor.pop(); pushed = false }
        if let cursor { cursor.push(); pushed = true }
    }
}

/// Non-observable callback storage: refreshing callbacks must not invalidate
/// every line, and an equatable line must not keep a previous pick's action.
private final class TranscriptQALineActions {
    var onSelect: (TranscriptQATrim.Word) -> Void = { _ in }
    var onSeek: (Double) -> Void = { _ in }

    func update(onSelect: @escaping (TranscriptQATrim.Word) -> Void,
                onSeek: @escaping (Double) -> Void) -> TranscriptQALineActions {
        self.onSelect = onSelect
        self.onSeek = onSeek
        return self
    }
}

/// Rendering inputs are local to one speaker line. No playback observation or
/// panel-wide frame/selection state is read while constructing its word tokens.
private struct TranscriptQALineView: View, Equatable {
    let line: TranscriptQATrim.Line
    let columnWidth: CGFloat
    let selection: ClosedRange<Double>?
    let startEdgeWordIDs: Set<Int>
    let otherRanges: [RangeReviewMarkedRange]
    let spokenWordID: Int?
    let showsTranslation: Bool
    let translation: String?
    let canTrim: Bool
    let spanSelection: Bool
    /// Where the words' frames go; a reference, so not part of `==`.
    let store: TranscriptQAWordFrames
    let onSelect: (TranscriptQATrim.Word) -> Void
    let onSeek: (Double) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.line == rhs.line && lhs.columnWidth == rhs.columnWidth
            && lhs.selection == rhs.selection && lhs.startEdgeWordIDs == rhs.startEdgeWordIDs
            && lhs.otherRanges == rhs.otherRanges && lhs.spokenWordID == rhs.spokenWordID
            && lhs.showsTranslation == rhs.showsTranslation && lhs.translation == rhs.translation
            && lhs.canTrim == rhs.canTrim && lhs.spanSelection == rhs.spanSelection
    }

    private func isSelected(_ word: TranscriptQATrim.Word) -> Bool {
        selection.map { TranscriptQATrim.contains(word, in: $0) } ?? false
    }

    private func reportPlacement(_ frames: [Int: CGRect]) {
        // Layout runs during a view update; the store publishes on the next turn.
        store.place(line: line.id, frames: frames)
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.spaceS) {
            originalLine(line)
                .frame(width: showsTranslation ? columnWidth : nil, alignment: .leading)
            if showsTranslation {
                translationText(line)
                    .frame(width: columnWidth, alignment: .topLeading)
            }
        }
        .padding(.horizontal, Theme.spaceS)
        .padding(.vertical, 4)
        // The line being spoken is not tinted: a block behind the whole turn
        // read as part of the selection. The yellow spoken word and Follow
        // scrolling show where playback is.
    }

    @ViewBuilder
    private func translationText(_ line: TranscriptQATrim.Line) -> some View {
        if let text = translation {
            let inside = line.words.contains { isSelected($0) }
            Text(text)
                .font(.callout)
                .foregroundStyle(inside ? Color.primary : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else {
            Text("—").font(.callout).foregroundStyle(.tertiary)
        }
    }

    private func originalLine(_ line: TranscriptQATrim.Line) -> some View {
        HStack(alignment: .top, spacing: Theme.spaceS) {
            Button(line.start.timecode) { onSeek(line.start) }
                .buttonStyle(.plain)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
                .help("Move the playhead to \(line.start.timecode)")
            VStack(alignment: .leading, spacing: 2) {
                if let speaker = line.speaker, !line.continuesSpeaker {
                    SpeakerPill(speaker: speaker, font: .caption.weight(.semibold))
                        .help(speaker)
                }
                FlowLayout(spacing: TranscriptQAWordCursor.wordSpacing,
                           rowSpacing: TranscriptQAWordCursor.rowSpacing,
                           onPlace: FlowLayoutPlacementReporter(report: reportPlacement)) {
                    let marks = line.words.map(mark)
                    ForEach(line.words.indices, id: \.self) { index in
                        wordToken(line.words[index], mark: marks[index],
                                  joinsPrevious: joins(marks, index, index - 1), joinsNext: joins(marks, index, index + 1))
                            .layoutValue(key: FlowLayoutItemID.self, value: line.words[index].id)
                    }
                }
                // One accessibility element per line, not per word.
                .accessibilityElement(children: .combine)
                .help(spanSelection ? "Click a word to start a selection there, or press and drag to select a passage. Hold Shift to add another passage to the selection."
                      : "Click to select just this word; drag an anchor or use the Start / End buttons to extend")
                .onGeometryChange(for: CGPoint.self, of: { $0.frame(in: .named("qaWordViewport")).origin }) {
                    store.move(line: line.id, to: $0)
                }
                .onAppear { store.appear(line: line.id) }
                .onDisappear { store.disappear(line: line.id) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// What paints a word: the selection, or the tightest saved pick holding it.
    private enum Mark: Equatable {
        case selection
        case other(Int)
    }

    private func mark(_ word: TranscriptQATrim.Word) -> Mark? {
        if isSelected(word) { return .selection }
        // Nested picks: the tightest range owns the word.
        return otherRanges.filter { TranscriptQATrim.contains(word, in: $0.range) }
            .min { ($0.range.upperBound - $0.range.lowerBound) < ($1.range.upperBound - $1.range.lowerBound) }
            .map { .other($0.paletteIndex) }
    }

    private func joins(_ marks: [Mark?], _ index: Int, _ neighbour: Int) -> Bool {
        guard let mark = marks[index], marks.indices.contains(neighbour) else { return false }
        return marks[neighbour] == mark
    }

    /// A painted word's block reaches over the whole gap to a neighbour in the
    /// same mark (plus a point, so rounding on a 1x display leaves no seam)
    /// and only a little past a neighbour that is not.
    private func wordToken(_ word: TranscriptQATrim.Word, mark: Mark?, joinsPrevious: Bool, joinsNext: Bool) -> some View {
        let inside = mark == .selection
        let other: Int? = if case .other(let index) = mark { index } else { nil }
        let reach = TranscriptQAWordCursor.wordSpacing + 1
        let edge: CGFloat = 1
        // The spoken word is marked only while playing; a parked playhead would
        // otherwise sit yellow inside the selection being made. The weight never
        // changes: a bold word is wider and rewraps the line under Follow.
        let spoken = spokenWordID == word.id
        // Plain text, not a button: a button per word is a focus responder
        // per word, and with an accessibility client attached every focus
        // update walks them all (a 1-2 s stall per section switch). The
        // panel resolves clicks to words through their frames instead.
        return Text(word.text)
                .font(.callout)
                .foregroundStyle(spoken ? Color.black : inside || other != nil ? Color.primary : Color.secondary)
                .padding(.horizontal, 2)
                .background {
                    if spoken {
                        RoundedRectangle(cornerRadius: 3).fill(Color.yellow)
                    } else if inside {
                        // Reach across the gaps to the neighbouring words and
                        // rows so the selection reads as one block, spaces
                        // included. The fill is opaque: translucent rectangles
                        // would show their overlaps as darker seams.
                        Rectangle().fill(TranscriptQAWordCursor.selectionColor)
                            .padding(.leading, joinsPrevious ? -reach : -edge)
                            .padding(.trailing, joinsNext ? -reach : -edge)
                            .padding(.vertical, -TranscriptQAWordCursor.rowSpacing - 1)
                    } else if let other {
                        // A saved pick's words sit on a block in the colour
                        // of its list row's bar.
                        Rectangle().fill(RangeReviewPalette.block(other))
                            .padding(.leading, joinsPrevious ? -reach : -edge)
                            .padding(.trailing, joinsNext ? -reach : -edge)
                            .padding(.vertical, -TranscriptQAWordCursor.rowSpacing - 1)
                    }
                }
    }
}

/// Marks in the transcript's scroller track for every painted passage and
/// the selection, like an editor's overview ruler: each sits at the
/// passage's share of the words, so the eye finds the picks in a long
/// recording without scrolling. Not clickable; the scroller stays on top.
struct TranscriptOverviewMarks: View {
    let transcript: TranscriptQATrim.Transcript
    let range: ClosedRange<Double>
    let otherRanges: [RangeReviewMarkedRange]
    static let width: CGFloat = 6
    private static let minimumHeight: CGFloat = 3

    /// The share of the words (a proxy for the laid-out height) before the
    /// first word of the range and after its last; nil for a range without words.
    nonisolated static func span(of range: ClosedRange<Double>, words: [TranscriptQATrim.Word]) -> ClosedRange<CGFloat>? {
        guard range.upperBound > range.lowerBound, !words.isEmpty,
              let first = words.firstIndex(where: { TranscriptQATrim.contains($0, in: range) }),
              let last = words.lastIndex(where: { TranscriptQATrim.contains($0, in: range) }) else { return nil }
        let count = CGFloat(words.count)
        return (CGFloat(first) / count)...(CGFloat(last + 1) / count)
    }

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            ZStack(alignment: .topLeading) {
                ForEach(otherRanges.indices, id: \.self) { index in
                    if let span = Self.span(of: otherRanges[index].range, words: transcript.words) {
                        mark(span, color: RangeReviewPalette.bar(otherRanges[index].paletteIndex), height: height)
                    }
                }
                if let span = Self.span(of: range, words: transcript.words) {
                    mark(span, color: Color.accentColor, height: height)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func mark(_ span: ClosedRange<CGFloat>, color: Color, height: CGFloat) -> some View {
        let top = span.lowerBound * height
        let size = max(Self.minimumHeight, (span.upperBound - span.lowerBound) * height)
        return RoundedRectangle(cornerRadius: 1.5).fill(color)
            .frame(width: Self.width, height: min(size, height - top))
            .offset(y: top)
    }
}
