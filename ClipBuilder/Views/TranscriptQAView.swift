import SwiftUI
import AVKit

/// Q&A ranges save through the caller; this surface owns selection and playback.
struct TranscriptQAView: View {
    @Environment(\.isEnabled) private var isEnabled
    let video: VideoRecord
    let sections: [TranscriptQASections.Section]
    let rows: [TranscriptRow]
    let labels: [Int64: String]
    var kept: Binding<Set<Int64>>? = nil
    var preferredTranslationLanguage: String? = nil
    let onSave: (SceneRecord, Double, Double) -> Void

    @State private var selectedID: Int64?
    @State private var playback = PodcastHighlightTrimPlayback()
    @State private var loadedURL: URL?
    @State private var draft: (start: Double, end: Double)?
    @State private var window = ProposedCutTrim.Window(start: 0, span: 30)
    @State private var transcript = TranscriptQATrim.Transcript()
    @State private var translationLanguages: [String] = []
    @State private var translationsByLanguage: [String: [Int: String]] = [:]
    @AppStorage("transcriptQA.listWidth") private var listWidth = 220.0
    @AppStorage("transcriptQA.transcriptWidth") private var transcriptWidth = 360.0

    private var selected: TranscriptQASections.Section? { sections.first { $0.id == selectedID } }
    private var range: ClosedRange<Double>? { selected?.range }
    private var limits: ClosedRange<Double> {
        guard let selected else { return 0...max(0, video.duration) }
        return TranscriptQATrim.limits(for: selected, in: sections, duration: video.duration)
    }
    private var canTrim: Bool { limits.upperBound - limits.lowerBound >= TranscriptQATrim.minimumSpan }
    private var editRange: ClosedRange<Double> {
        let start = draft?.start ?? range?.lowerBound ?? 0
        let end = draft?.end ?? range?.upperBound ?? start
        return TranscriptQATrim.clamped(start...max(start, end), limits: limits)
    }

    var body: some View {
        GeometryReader { geometry in
            let widths = Self.columnWidths(available: geometry.size.width,
                                           list: CGFloat(listWidth), transcript: CGFloat(transcriptWidth))
            HStack(spacing: 0) {
                exchangeList.frame(width: widths.list)
                    .clipped()
                columnDivider(.list, width: widths.list, otherWidth: widths.transcript,
                              available: geometry.size.width)
                if let selected {
                    trimSurface(section: selected)
                        .padding(Theme.spaceS)
                        .frame(width: max(0, geometry.size.width - widths.list - widths.transcript
                                          - 2 * TranscriptQAColumns.dividerWidth))
                        .clipped()
                    columnDivider(.transcript, width: widths.transcript, otherWidth: widths.list,
                                  available: geometry.size.width)
                    TranscriptQAWordPanel(transcript: transcript, videoID: video.id,
                                          translationLanguages: translationLanguages,
                                          translationsByLanguage: translationsByLanguage,
                                          preferredTranslationLanguage: preferredTranslationLanguage,
                                          sectionID: selected.id,
                                          range: editRange,
                                          otherRanges: sections.filter { $0.id != selected.id && $0.scene.videoID == video.id }.map(\.range),
                                          playback: playback, canTrim: canTrim,
                                          onSelect: selectWord, onPreview: previewWord,
                                          onCommit: { commitDraft(snap: false) }, onCancel: { draft = nil })
                        .frame(width: widths.transcript)
                        .clipped()
                } else {
                    ContentUnavailableView("Select a Q&A section", systemImage: "text.bubble",
                                           description: Text("Choose an exchange to watch it and adjust its start and end."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .coordinateSpace(name: "transcriptQA.columns")
        }
        .task(id: TranscriptQATrim.Input(rows: rows, labels: labels, videoID: video.id)) {
            let input = TranscriptQATrim.Input(rows: rows, labels: labels, videoID: video.id)
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
            transcript = result.0
            translationLanguages = result.1
            translationsByLanguage = result.2
        }
        .onAppear { selectedID = sections.first?.id }
        .onChange(of: selectedID) { _, _ in selectSection() }
        .onChange(of: sections.map(\.id)) { _, ids in
            if selectedID.map({ !ids.contains($0) }) ?? true { selectedID = ids.first }
        }
        .onChange(of: range) { _, range in
            guard let range, draft == nil else { return }
            playback.setRange(range)
            if window.needsRecentering(range) { recenter(range) }
        }
        .onChange(of: playback.player != nil) { _, ready in
            // Selection may have changed while the same file was loading.
            if ready, let range {
                playback.setRange(range)
                playback.seek(to: range.lowerBound)
                if isEnabled { playback.play() }
            }
        }
        .onChange(of: video.url) { _, _ in selectSection() }
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

    private var exchangeList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let kept {
                let ids = Set(sections.map(\.id))
                let count = kept.wrappedValue.intersection(ids).count
                VStack(alignment: .leading, spacing: Theme.spaceXS) {
                    Button(count == sections.count ? "Deselect All" : "Select All") {
                        kept.wrappedValue = count == sections.count ? [] : ids
                    }
                    .controlSize(.small).lineLimit(1).fixedSize()
                    FormCaption("\(count) of \(sections.count) kept")
                        .lineLimit(1).fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.spaceS)
                Divider()
            }
            // Selection is explicit so the sibling checkbox never selects a row.
            List {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    sectionRow(section, number: index + 1)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(section.id == selectedID ? Color.accentColor.opacity(0.16) : Color.clear)
                }
            }
            .listStyle(.sidebar)
            .onMoveCommand { direction in
                guard isEnabled, !sections.isEmpty else { return }
                let index = sections.firstIndex { $0.id == selectedID } ?? 0
                switch direction {
                case .up: selectedID = sections[max(0, index - 1)].id
                case .down: selectedID = sections[min(sections.count - 1, index + 1)].id
                default: break
                }
            }
        }
    }

    private func sectionRow(_ section: TranscriptQASections.Section, number: Int) -> some View {
        ZStack(alignment: .topLeading) {
            Button { selectedID = section.id } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(number). \(section.question.split(whereSeparator: \.isNewline).first.map(String.init) ?? section.question)")
                        .font(.callout.weight(.medium)).lineLimit(1).truncationMode(.tail)
                        .help(section.question)
                    if section.asker != nil || section.answerer != nil {
                        FormCaption(speakers(section)).lineLimit(1).help(speakers(section))
                    }
                    FormCaption(rangeCaption(section.range))
                        .monospacedDigit().lineLimit(1).help(rangeCaption(section.range))
                }
                .padding(.leading, kept == nil ? 0 : 26)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Theme.spaceS)
                .padding(.horizontal, Theme.spaceS)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(section.id == selectedID ? .isSelected : [])
            if let kept {
                Toggle("Keep exchange \(number)", isOn: Binding(
                    get: { kept.wrappedValue.contains(section.id) },
                    set: { keep in
                        if keep { kept.wrappedValue.insert(section.id) }
                        else { kept.wrappedValue.remove(section.id) }
                    }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .fixedSize()
                    .frame(width: 18)
                    .padding(.vertical, Theme.spaceS)
                    .padding(.leading, Theme.spaceS)
                    .accessibilityLabel("Keep exchange \(number)")
            }
        }
    }

    private func speakers(_ section: TranscriptQASections.Section) -> String {
        [section.asker.map { "Asks: \($0)" }, section.answerer.map { "Answers: \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func rangeCaption(_ range: ClosedRange<Double>) -> String {
        "\(range.lowerBound.timecode)–\(range.upperBound.timecode) · \((range.upperBound - range.lowerBound).formatted(.number.precision(.fractionLength(1))))s"
    }

    private func trimSurface(section: TranscriptQASections.Section) -> some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            PlayerView(player: playback.player, controlsStyle: .none)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .background(.black, in: RoundedRectangle(cornerRadius: Theme.mediaRadius))
                .clipShape(RoundedRectangle(cornerRadius: Theme.mediaRadius))
                .overlay {
                    if playback.player == nil {
                        Text("Loading preview… If unavailable, download this video to this Mac.")
                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center).padding(Theme.spaceS)
                    }
                }
            filmstrip.disabled(!canTrim)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.spaceS) {
                    playButton
                    rangeLabel
                    Spacer(minLength: 0)
                    resetButton(section)
                }
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    playButton
                    rangeLabel
                    resetButton(section)
                }
            }
            FormCaption(Self.trimHint)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .help(Self.trimHint)
        }
    }

    private static let trimHint = "Drag the handles or the transcript anchors, or click a word to move the nearer end to it · I / O set the start / end at the playhead"

    private var playButton: some View {
        Button(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
            playback.togglePlay()
        }
        .labelStyle(.iconOnly).fixedSize()
        .disabled(playback.player == nil)
        .help(playback.isPlaying ? "Pause (Space)" : "Play the section (Space)")
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

    private func resetButton(_ section: TranscriptQASections.Section) -> some View {
        Button("Reset to Original") {
            commit(section.scene.originalStart...max(section.scene.originalStart, section.scene.originalEnd))
        }
        .controlSize(.small).lineLimit(1).fixedSize()
        .disabled(!section.isTrimmed || !canTrim)
        .help("Return to the original range")
    }

    private var filmstrip: some View {
        VideoTrimSlider(url: video.url, duration: window.span,
                        start: Binding(get: { editRange.lowerBound }, set: {
                            draft = (start: $0, end: draft?.end ?? editRange.upperBound)
                        }),
                        end: Binding(get: { editRange.upperBound }, set: {
                            draft = (start: draft?.start ?? editRange.lowerBound, end: $0)
                        }),
                        timeOffset: window.start, rulerInterval: window.rulerInterval,
                        minimumSpan: min(TranscriptQATrim.minimumSpan, window.span),
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
            .help("Drag a handle and release near an edge to see more. Ends snap to nearby words.")
    }

    private func selectSection() {
        draft = nil
        playback.pause()
        guard let range else {
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
        window = TranscriptQASections.window(for: range, videoDuration: video.duration)
    }

    private func commitDraft(snap: Bool) {
        guard draft != nil, let range else { return }
        let updated = snap ? TranscriptQATrim.releasing(editRange, from: range, words: transcript.words, limits: limits) : editRange
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
        case .start: TranscriptQATrim.range(editRange, movingStartTo: word, limits: limits)
        case .end: TranscriptQATrim.range(editRange, movingEndTo: word, limits: limits)
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
        let updated = TranscriptQATrim.clamped(proposed, limits: limits)
        draft = nil
        onSave(selected.scene, updated.lowerBound, updated.upperBound)
        playback.setRange(updated)
        if window.needsRecentering(updated) { recenter(updated) }
        // Both callers observe saved scenes; those refreshes remain authoritative.
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard isEnabled, range != nil, playback.player != nil else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case " ": playback.togglePlay()
        case "i", "o":
            guard canTrim else { return false }
            let edge: TranscriptQATrim.Edge = event.charactersIgnoringModifiers?.lowercased() == "i" ? .start : .end
            let time = TranscriptQATrim.snap(playback.time, edge: edge, words: transcript.words)
            commit(TranscriptQATrim.setting(edge, at: time, in: editRange, limits: limits))
        default: return false
        }
        return true
    }
}
