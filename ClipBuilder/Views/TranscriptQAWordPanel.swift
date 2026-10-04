import SwiftUI

/// Full-recording transcript; only visible lines are laid out. The two anchors
/// live above the scroll content, so moving a cut never replaces its gesture.
struct TranscriptQAWordPanel: View {
    @Environment(\.isEnabled) private var isEnabled
    let transcript: TranscriptQATrim.Transcript
    let videoID: Int64
    let translationLanguages: [String]
    let translationsByLanguage: [String: [Int: String]]
    let preferredTranslationLanguage: String?
    let sectionID: Int64
    let range: ClosedRange<Double>
    let otherRanges: [ClosedRange<Double>]
    let playback: PodcastHighlightTrimPlayback
    let canTrim: Bool
    let onSelect: (TranscriptQATrim.Word) -> Void
    let onPreview: (TranscriptQATrim.Edge, TranscriptQATrim.Word) -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void

    @State private var followsPlayback = true
    @AppStorage("transcriptQA.showTranslation") private var showTranslation = false
    @State private var selectedTranslationLanguages: [Int64: String] = [:]
    @State private var frames: [Int: CGRect] = [:]
    @State private var dragging: TranscriptQATrim.Edge?
    @State private var pointer: CGPoint?
    @State private var dragFrame: CGRect?
    @State private var scrollDirection = 0
    @State private var lastPreviewedWord: Int?
    private static let scrollSpace = "qaWordViewport"

    private var currentLine: Int? { transcript.lineID(at: playback.time) }
    private var firstWord: TranscriptQATrim.Word? { transcript.words.first { TranscriptQATrim.contains($0, in: range) } }
    private var lastWord: TranscriptQATrim.Word? { transcript.words.last { TranscriptQATrim.contains($0, in: range) } }
    private var translationLanguage: String? {
        TranscriptQATrim.translationLanguage(available: translationLanguages,
            selected: selectedTranslationLanguages[videoID], preferred: preferredTranslationLanguage)
    }
    private var showsTranslation: Bool { showTranslation && translationLanguage != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.spaceS) {
                    Text("Transcript").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
                    Spacer(minLength: 0)
                    transcriptControls
                }
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    Text("Transcript").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
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
            // Preserve readable columns in a compressed pane without changing
            // its preferred width. Extra width can be reached by scrolling.
            let contentWidth = showsTranslation
                ? max(geometry.size.width, 320 + 5 * Theme.spaceS) : geometry.size.width
            let columnWidth = (contentWidth - 5 * Theme.spaceS) / 2
            ScrollViewReader { proxy in
                ZStack(alignment: .topLeading) {
                    ScrollView(showsTranslation ? [.vertical, .horizontal] : [.vertical]) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(transcript.lines) { line in
                                transcriptLine(line, columnWidth: columnWidth).id(line.id)
                            }
                        }
                        .padding(Theme.spaceS)
                        .frame(width: contentWidth, alignment: .leading)
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
                    while !Task.isCancelled, dragging != nil, isEnabled {
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
        .background(line.id == currentLine ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Theme.mediaRadius))
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
                FlowLayout(spacing: 3) {
                    ForEach(line.words) { word in wordToken(word) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func wordToken(_ word: TranscriptQATrim.Word) -> some View {
        let inside = TranscriptQATrim.contains(word, in: range)
        let other = otherRanges.contains { TranscriptQATrim.contains(word, in: $0) }
        let spoken = playback.player != nil && playback.time >= word.start && playback.time < word.end
        return Button { onSelect(word) } label: {
            Text(word.text)
                .font(.callout).fontWeight(spoken ? .bold : .regular)
                .foregroundStyle(spoken ? Color.black : inside ? Color.primary : Color.secondary)
                .padding(.horizontal, 2)
                .background {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(spoken ? AnyShapeStyle(Color.yellow)
                              : inside ? AnyShapeStyle(Color.accentColor.opacity(0.28))
                              : other ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.clear))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canTrim)
        .background {
            // Measure the words in the scroll content using the stationary
            // viewport space, also used by the anchors' pointer coordinates.
            GeometryReader { geometry in
                Color.clear.preference(key: TranscriptQAWordFrames.self,
                                       value: [word.id: geometry.frame(in: .named(Self.scrollSpace))])
            }
        }
        .help("Move the \(TranscriptQATrim.nearestEdge(for: word, in: range) == .start ? "start" : "end") to this word")
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
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.scrollSpace))
                    .onChanged { value in
                        guard isEnabled, canTrim else { return }
                        if dragging == nil {
                            dragging = edge
                            dragFrame = frame
                            lastPreviewedWord = nil
                            playback.pause()
                        }
                        pointer = value.location
                        scrollDirection = value.location.y < 32 ? -1 : value.location.y > viewportHeight - 32 ? 1 : 0
                        previewAtPointer()
                    }
                    .onEnded { _ in
                        guard dragging != nil else { return }
                        clearDrag()
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
        guard isEnabled, let dragging, let pointer,
              let id = TranscriptQATrim.word(at: pointer, frames: frames), id != lastPreviewedWord,
              transcript.words.indices.contains(id) else { return }
        lastPreviewedWord = id
        onPreview(dragging, transcript.words[id])
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
        pointer = nil
        dragFrame = nil
        scrollDirection = 0
        lastPreviewedWord = nil
    }

    private func cancelDrag() {
        guard dragging != nil else { return }
        clearDrag()
        onCancel()
    }
}
