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
    var onSpanPreview: ((ClosedRange<Double>) -> Void)? = nil
    var onSpanClear: (() -> Void)? = nil
    /// Shown after the Follow / Translation controls (Express puts its Add button here).
    var accessory: AnyView? = nil

    @State private var followsPlayback = true
    @AppStorage("transcriptQA.showTranslation") private var showTranslation = false
    @State private var selectedTranslationLanguages: [Int64: String] = [:]
    @State private var frames: [Int: CGRect] = [:]
    @State private var dragging: TranscriptQATrim.Edge?
    /// The word the span drag started on.
    @State private var spanAnchor: Int?
    /// The first word of each saved pick, found once per transcript and pick set.
    @State private var firstWordIDs: [RangeReviewMarkedRange: Int] = [:]
    @State private var spanMoved = false
    @State private var pointer: CGPoint?
    @State private var dragFrame: CGRect?
    @State private var scrollDirection = 0
    @State private var lastPreviewedWord: Int?
    private static var scrollSpace: String { "qaWordViewport" }

    private var currentLine: Int? { transcript.lineID(at: playback.time) }
    private var firstWord: TranscriptQATrim.Word? { transcript.words.first { TranscriptQATrim.contains($0, in: range) } }
    private var lastWord: TranscriptQATrim.Word? { transcript.words.last { TranscriptQATrim.contains($0, in: range) } }
    private var translationLanguage: String? {
        TranscriptQATrim.translationLanguage(available: translationLanguages,
            selected: selectedTranslationLanguages[videoID], preferred: preferredTranslationLanguage)
    }
    private var showsTranslation: Bool { showTranslation && translationLanguage != nil }

    private struct FirstWordKey: Equatable {
        var words: [TranscriptQATrim.Word]
        var ranges: [RangeReviewMarkedRange]
    }

    private func refreshFirstWords() {
        var result: [RangeReviewMarkedRange: Int] = [:]
        for marked in otherRanges {
            result[marked] = transcript.words.first { TranscriptQATrim.contains($0, in: marked.range) }?.id
        }
        firstWordIDs = result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.spaceS) {
                    Text("Transcript").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
                    Spacer(minLength: 0)
                    transcriptControls
                    if let accessory { accessory }
                }
                // Narrow column: the accessory keeps the title row, the toggles get their own.
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    HStack(spacing: Theme.spaceS) {
                        Text("Transcript").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .lineLimit(1).fixedSize()
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
            Divider()
            if transcript.lines.isEmpty {
                FormCaption("No transcript for this recording. Use the filmstrip handles to adjust the exchange.")
                    .padding(Theme.spaceM)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                transcriptScroll
            }
        }
        .onChange(of: sectionID) { _, _ in cancelDrag() }
        .onAppear { refreshFirstWords() }
        .onChange(of: FirstWordKey(words: transcript.words, ranges: otherRanges)) { _, _ in refreshFirstWords() }
        .onChange(of: isEnabled) { _, enabled in if !enabled { cancelDrag() } }
        .onChange(of: transcript) { _, _ in cancelDrag(); frames = [:] }
        .onChange(of: showsTranslation) { _, _ in cancelDrag(); frames = [:] }
        .onChange(of: translationLanguage) { _, _ in cancelDrag(); frames = [:] }
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

    private var transcriptScroll: some View {
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
                                transcriptLine(line, columnWidth: columnWidth).id(line.id)
                            }
                        }
                        .padding(Theme.spaceS)
                        .frame(width: contentWidth, alignment: .leading)
                        .contentShape(Rectangle())
                        .gesture(spanGesture(viewportHeight: geometry.size.height),
                                 including: spanSelection && canTrim && isEnabled ? .all : .subviews)
                    }
                    .onPreferenceChange(TranscriptQAWordFrames.self) { updated in
                        frames = updated
                        // Scrolling changes the word under a stationary pointer.
                        previewAtPointer()
                    }
                    anchor(.start, word: firstWord, viewportHeight: geometry.size.height)
                    anchor(.end, word: lastWord, viewportHeight: geometry.size.height)
                }
                .coordinateSpace(name: Self.scrollSpace)
                .clipped()
                .onAppear { scrollToSelection(proxy) }
                .onChange(of: sectionID) { _, _ in scrollToSelection(proxy) }
                .onChange(of: transcript) { _, _ in scrollToSelection(proxy) }
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

    private func transcriptLine(_ line: TranscriptQATrim.Line, columnWidth: CGFloat) -> some View {
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
        if let language = translationLanguage, let text = translationsByLanguage[language]?[line.id] {
            let inside = line.words.contains { TranscriptQATrim.contains($0, in: range) }
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
            Button(line.start.timecode) { playback.seek(to: line.start) }
                .buttonStyle(.plain)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
                .help("Move the playhead to \(line.start.timecode)")
            VStack(alignment: .leading, spacing: 2) {
                if let speaker = line.speaker {
                    Text(speaker).font(.caption.weight(.semibold))
                        .foregroundStyle(SpeakerColors.color(for: speaker))
                        .lineLimit(1).help(speaker)
                }
                FlowLayout(spacing: TranscriptQAWordCursor.wordSpacing, rowSpacing: TranscriptQAWordCursor.rowSpacing) {
                    ForEach(line.words) { word in wordToken(word) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func wordToken(_ word: TranscriptQATrim.Word) -> some View {
        let inside = TranscriptQATrim.contains(word, in: range)
        // Nested picks: the tightest range owns the word.
        let other = otherRanges.filter { TranscriptQATrim.contains(word, in: $0.range) }
            .min { ($0.range.upperBound - $0.range.lowerBound) < ($1.range.upperBound - $1.range.lowerBound) }
        let startsOther = other.map { firstWordIDs[$0] == word.id } ?? false
        // The spoken word is marked only while playing; a parked playhead would
        // otherwise sit yellow inside the selection being made.
        let spoken = playback.isPlaying && playback.time >= word.start && playback.time < word.end
        return Button { if !spanSelection { onSelect(word) } } label: {
            Text(word.text)
                .font(.callout).fontWeight(spoken ? .bold : .regular)
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
                            .padding(.horizontal, -TranscriptQAWordCursor.wordSpacing / 2 - 0.5)
                            .padding(.vertical, -TranscriptQAWordCursor.rowSpacing / 2 - 0.5)
                    } else if let other {
                        // Saved picks read as the same kind of block in their
                        // own pastel; the first word carries the row's bar.
                        Rectangle().fill(RangeReviewPalette.block(other.paletteIndex))
                            .overlay(alignment: .leading) {
                                if startsOther {
                                    Rectangle().fill(RangeReviewPalette.bar(other.paletteIndex))
                                        .frame(width: RangeReviewPalette.barWidth)
                                }
                            }
                            .padding(.horizontal, -TranscriptQAWordCursor.wordSpacing / 2 - 0.5)
                            .padding(.vertical, -TranscriptQAWordCursor.rowSpacing / 2 - 0.5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canTrim)
        // In span mode the drag gesture on the content owns the pointer.
        .allowsHitTesting(!spanSelection)
        .background {
            // Measure the words in the scroll content using the stationary
            // viewport space, also used by the anchors' pointer coordinates.
            GeometryReader { geometry in
                Color.clear.preference(key: TranscriptQAWordFrames.self,
                                       value: [word.id: geometry.frame(in: .named(Self.scrollSpace))])
            }
        }
        .help(spanSelection ? (inside ? "Click to clear the selection, or drag to select" : "Press and drag to select")
              : "Move the \(TranscriptQATrim.nearestEdge(for: word, in: range) == .start ? "start" : "end") to this word")
        .accessibilityLabel("\(word.text), \(word.start.timecode)")
        .accessibilityAddTraits(inside ? .isSelected : [])
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
                        previewAtPointer()
                    }
                    .onEnded { _ in
                        guard dragging != nil else { return }
                        clearDrag()
                        TranscriptQAWordCursor.set(nil)
                        if isEnabled { onCommit() } else { onCancel() }
                    })
                .help(edge == .start ? "Drag to move the start" : "Drag to move the end")
                .accessibilityElement()
                .accessibilityLabel(edge == .start ? "Exchange start" : "Exchange end")
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

    private func previewAtPointer() {
        guard isEnabled, let pointer,
              let id = TranscriptQATrim.word(at: pointer, frames: frames), id != lastPreviewedWord,
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
                    guard dragging == nil, let id = TranscriptQATrim.word(at: value.startLocation, frames: frames) else { return }
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
                clearDrag()
                guard isEnabled, transcript.words.indices.contains(anchor) else { onCancel(); return }
                let word = transcript.words[anchor]
                if moved {
                    onCommit()
                } else if TranscriptQATrim.contains(word, in: range) {
                    onSpanClear?()
                } else {
                    onSpanPreview?(Self.span(from: word, to: word))
                    onCommit()
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
        dragging = nil
        spanAnchor = nil
        spanMoved = false
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
