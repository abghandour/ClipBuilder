import SwiftUI
import AVKit

/// Q&A ranges save through the sheet; this surface owns only selection and playback.
struct TranscriptQAView: View {
    let video: VideoRecord
    let sections: [TranscriptQASections.Section]
    let rows: [TranscriptRow]
    let labels: [Int64: String]
    let onSave: (SceneRecord, Double, Double) -> Void

    @State private var selectedID: Int64?
    @State private var playback = PodcastHighlightTrimPlayback()
    @State private var loadedURL: URL?
    @State private var draft: (start: Double, end: Double)?
    @State private var window = ProposedCutTrim.Window(start: 0, span: 30)

    private var selected: TranscriptQASections.Section? { sections.first { $0.id == selectedID } }
    private var range: ClosedRange<Double>? { selected?.range }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    sectionRow(section, number: index + 1).tag(section.id)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 260)
            Divider()
            if let selected {
                transcript(section: selected)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                trimSurface(section: selected)
                    .padding(Theme.spaceM)
                    .frame(width: 420)
            } else {
                ContentUnavailableView("Select a Q&A section", systemImage: "text.bubble",
                                       description: Text("Choose an exchange to watch it and adjust its start and end."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
                playback.play()
            }
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

    private func sectionRow(_ section: TranscriptQASections.Section, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(number). \(section.question)")
                .font(.callout.weight(.medium)).lineLimit(2)
                .help(section.question)
            if section.asker != nil || section.answerer != nil {
                Text(speakers(section))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).help(speakers(section))
            }
            HStack(spacing: 4) {
                Text("\(section.scene.startTime.timecode)–\(section.scene.endTime.timecode) · \(section.scene.duration, format: .number.precision(.fractionLength(1)))s")
                    .monospacedDigit()
                if section.isTrimmed {
                    Text("trimmed")
                        .help("The range differs from the original section")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Theme.spaceS)
    }

    private func speakers(_ section: TranscriptQASections.Section) -> String {
        [section.asker.map { "Asks: \($0)" }, section.answerer.map { "Answers: \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func transcript(section: TranscriptQASections.Section) -> some View {
        let lines = TranscriptQASections.lines(rows: rows, range: section.range)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !lines.contains(where: \.isInside) {
                        Text("No transcript lines in this section. Use the handles or nearby lines to adjust it.")
                            .font(.callout).foregroundStyle(.secondary).padding(Theme.spaceM)
                    }
                    ForEach(lines) { line in
                        transcriptLine(line, range: section.range)
                            .id(line.id)
                        Divider()
                    }
                }
            }
            .onChange(of: selectedID, initial: true) { _, _ in
                if let first = lines.first(where: \.isInside) ?? lines.first {
                    proxy.scrollTo(first.id, anchor: .top)
                }
            }
        }
    }

    private func transcriptLine(_ line: TranscriptQASections.Line, range: ClosedRange<Double>) -> some View {
        let row = line.row
        let current = playback.player != nil && playback.time >= row.startTime && playback.time < row.endTime
        return VStack(alignment: .leading, spacing: Theme.spaceS) {
            HStack {
                Text(row.startTime.timecode).monospacedDigit()
                if let label = labels[row.id] { Text(label).fontWeight(.semibold) }
                Spacer(minLength: 0)
                if current { Image(systemName: "speaker.wave.2.fill").accessibilityLabel("At playhead") }
                if !line.isInside { Text("Context") }
            }
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            Text(row.text)
                .foregroundStyle(line.isInside ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            HStack(spacing: Theme.spaceS) {
                Button("Start here") { set(.start, at: row.startTime, in: range) }
                    .help("Start this section at \(ProposedCutTrim.timecode(row.startTime))")
                Button("End here") { set(.end, at: row.endTime, in: range) }
                    .help("End this section at \(ProposedCutTrim.timecode(row.endTime))")
            }
            .controlSize(.small).lineLimit(1).fixedSize()
            .disabled(video.duration <= 0)
        }
        .padding(Theme.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(current ? Color.accentColor.opacity(0.18)
                    : line.isInside ? Color.accentColor.opacity(0.05) : Color.clear)
    }

    private func trimSurface(section: TranscriptQASections.Section) -> some View {
        let range = section.range
        let start = draft?.start ?? range.lowerBound
        let end = draft?.end ?? range.upperBound
        return VStack(alignment: .leading, spacing: Theme.spaceS) {
            PlayerView(player: playback.player, controlsStyle: .none)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black, in: RoundedRectangle(cornerRadius: Theme.mediaRadius))
                .overlay {
                    if playback.player == nil {
                        Text("Loading preview… If unavailable, download this video to this Mac.")
                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center).padding()
                    }
                }
            filmstrip(range: range)
                .disabled(video.duration <= 0)
            HStack(spacing: Theme.spaceS) {
                Button(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
                    playback.togglePlay()
                }
                .disabled(playback.player == nil)
                .help(playback.isPlaying ? "Pause (Space)" : "Play the section (Space)")
                Text("\(ProposedCutTrim.timecode(start))–\(ProposedCutTrim.timecode(end)) · \(end - start, format: .number.precision(.fractionLength(1)))s")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .lineLimit(1).fixedSize()
            HStack {
                Text("Space: Play/Pause · I: Start · O: End")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Reset to Original") {
                    commit(start: section.scene.originalStart, end: section.scene.originalEnd)
                }
                .controlSize(.small).fixedSize()
                .disabled(!section.isTrimmed)
            }
            .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            Text("Changes save immediately. Drag a handle, or use Start here / End here beside a line.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func filmstrip(range: ClosedRange<Double>) -> some View {
        VideoTrimSlider(url: video.url, duration: window.span,
                        start: Binding(get: { draft?.start ?? range.lowerBound }, set: {
                            draft = (start: $0, end: draft?.end ?? range.upperBound)
                        }),
                        end: Binding(get: { draft?.end ?? range.upperBound }, set: {
                            draft = (start: draft?.start ?? range.lowerBound, end: $0)
                        }),
                        timeOffset: window.start, rulerInterval: window.rulerInterval,
                        minimumSpan: min(TranscriptQASections.minimumSpan, window.span),
                        showsTimes: false, stripHeight: 48,
                        onScrub: { playback.scrub(to: $0) }, onDragEnded: commitDraft)
            .overlay(alignment: .topLeading) {
                GeometryReader { proxy in
                    if let x = window.playheadX(at: playback.time, width: Double(proxy.size.width)) {
                        Rectangle().fill(.white)
                            .frame(width: 2, height: 48).offset(x: CGFloat(x))
                    }
                }
                .allowsHitTesting(false).accessibilityHidden(true)
            }
            .help("Drag a handle and release near an edge to see more of the video. Ends snap to transcript lines within 1.5 seconds.")
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
            playback.play()
        }
    }

    private func recenter(_ range: ClosedRange<Double>) {
        window = TranscriptQASections.window(for: range, videoDuration: video.duration)
    }

    private func commitDraft() {
        guard let draft, let range else { return }
        let updated = TranscriptQASections.releasing(start: draft.start, end: draft.end, from: range,
                                                    rows: rows, videoDuration: video.duration)
        commit(start: updated.lowerBound, end: updated.upperBound)
    }

    private func set(_ edge: TranscriptQASections.Edge, at time: Double, in range: ClosedRange<Double>) {
        let updated = TranscriptQASections.setting(edge, at: time, in: range, videoDuration: video.duration)
        commit(start: updated.lowerBound, end: updated.upperBound)
    }

    private func commit(start: Double, end: Double) {
        guard let selected else { return }
        draft = nil
        onSave(selected.scene, start, end)
        // The observed saved scene retargets playback and the filmstrip together.
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let range, playback.player != nil else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case " ": playback.togglePlay()
        case "i": set(.start, at: playback.time, in: range)
        case "o": set(.end, at: playback.time, in: range)
        default: return false
        }
        return true
    }
}
