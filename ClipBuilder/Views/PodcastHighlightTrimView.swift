import SwiftUI
import AVKit
import AppKit

/// Playback of one highlight candidate, held to its source range: the
/// picture stops at the end and rewinds to the start, the playhead follows,
/// and a range change retargets the item without reloading it.
@MainActor @Observable
final class PodcastHighlightTrimPlayback {
    private(set) var player: AVPlayer?
    private(set) var time: Double = 0
    private(set) var isPlaying = false
    private var range: ClosedRange<Double> = 0...1
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?

    func load(url: URL, range: ClosedRange<Double>, autoplay: Bool) {
        tearDown()
        self.range = range
        time = range.lowerBound
        loadTask = Task { [weak self] in
            guard await DrivePlayback.prepare(url), let self else { return }
            guard let asset = try? await DriveLocalAsset.make(url) else { return }
            let item = AVPlayerItem(asset: asset)
            item.forwardPlaybackEndTime = CMTime(seconds: range.upperBound, preferredTimescale: 600)
            let player = AVPlayer(playerItem: item)
            for _ in 0..<100 where item.status != .readyToPlay {
                if item.status == .failed || Task.isCancelled { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled, item.status == .readyToPlay else { return }
            _ = await player.seek(to: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                                  toleranceBefore: .zero, toleranceAfter: .zero)
            guard !Task.isCancelled else { return }
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
                Task { @MainActor in self?.time = time.seconds }
            }
            endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reachedEnd() }
            }
            self.player = player
            if autoplay { play() }
        }
    }

    private func reachedEnd() {
        isPlaying = false
        seek(to: range.lowerBound)
    }

    /// Retarget playback to a new source range: the end time moves with it
    /// and a playhead left outside it jumps to the new start.
    func setRange(_ newRange: ClosedRange<Double>) {
        guard newRange != range else { return }
        let startChanged = abs(newRange.lowerBound - range.lowerBound) > 0.01
        range = newRange
        player?.currentItem?.forwardPlaybackEndTime = CMTime(seconds: newRange.upperBound, preferredTimescale: 600)
        if startChanged || time < newRange.lowerBound - 0.05 || time > newRange.upperBound + 0.05 {
            seek(to: newRange.lowerBound)
        }
    }

    func seek(to seconds: Double) {
        time = seconds
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Show the frame under a dragged handle without playing.
    func scrub(to seconds: Double) {
        pause()
        time = seconds
        player?.currentItem?.cancelPendingSeeks()
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
                     toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600))
    }

    func play() {
        guard let player else { return }
        if time >= range.upperBound - 0.05 || time < range.lowerBound - 0.05 { seek(to: range.lowerBound) }
        player.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func tearDown() {
        loadTask?.cancel()
        loadTask = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player?.currentItem?.cancelPendingSeeks()
        player?.replaceCurrentItem(with: nil)
        player = nil
        isPlaying = false
    }
}

/// One highlight candidate with its ends adjustable: the picture on the
/// left over a filmstrip with start/end handles, the recording's transcript
/// on the right where the words inside the reel are highlighted and a click
/// on any word moves the nearer end to it. Every edit snaps to a word.
struct PodcastHighlightTrimView: View {
    let url: URL
    @Binding var candidate: HighlightCandidate
    let original: HighlightCandidate
    let trim: PodcastHighlightTrim
    var autoplay = true

    @State private var playback = PodcastHighlightTrimPlayback()
    /// Handle positions while a drag is in flight; committed (snapped) on release.
    @State private var draft: (start: Double, end: Double)?
    @State private var windowStart: Double = 0
    @State private var windowSpan: Double = 60
    @State private var followsPlayback = true

    private var range: ClosedRange<Double> { candidate.sourceRange }
    private var editStart: Double { draft?.start ?? candidate.sourceStart }
    private var editEnd: Double { draft?.end ?? candidate.sourceEnd }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.spaceS) {
                PlayerView(player: playback.player, controlsStyle: .none)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black, in: RoundedRectangle(cornerRadius: Theme.mediaRadius))
                    .overlay(alignment: .center) {
                        if playback.player == nil {
                            ProgressView().controlSize(.small)
                        }
                    }
                filmstrip
                HStack(spacing: Theme.spaceM) {
                    Button(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
                        playback.togglePlay()
                    }
                    .labelStyle(.iconOnly)
                    .help(playback.isPlaying ? "Pause (Space)" : "Play the reel from its start (Space)")
                    Text("\(editStart.timecode)–\(editEnd.timecode) · \(editEnd - editStart, format: .number.precision(.fractionLength(1)))s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if candidate.isTrimmed(from: original) {
                        Text("suggested \(original.sourceStart.timecode)–\(original.sourceEnd.timecode)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Reset to Suggested") { commit(original.sourceRange, snap: false) }
                        .controlSize(.small)
                        .disabled(!candidate.isTrimmed(from: original))
                        .help("Return to the start and end the analysis suggested")
                }
                Text("Drag the handles, or click a word on the right to move the nearer end to it · I / O set the start / end at the playhead")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Divider().padding(.horizontal, Theme.spaceM)
            transcriptPanel
        }
        .onAppear {
            recenterWindow()
            playback.load(url: url, range: range, autoplay: autoplay)
        }
        .onDisappear { playback.tearDown() }
        .onChange(of: candidate.id) { _, _ in
            draft = nil
            recenterWindow()
            playback.load(url: url, range: range, autoplay: autoplay)
        }
        .onChange(of: range) { _, newRange in
            if draft == nil { playback.setRange(newRange) }
        }
        .background {
            PodcastHighlightScreeningKeys(isActive: { false }, rate: { _ in }, other: handleKey)
                .frame(width: 0, height: 0)
        }
    }

    // MARK: - Filmstrip

    private var filmstrip: some View {
        VideoTrimSlider(url: url, duration: windowSpan,
                        start: Binding(get: { editStart }, set: { draft = (start: $0, end: editEnd) }),
                        end: Binding(get: { editEnd }, set: { draft = (start: editStart, end: $0) }),
                        timeOffset: windowStart,
                        rulerInterval: windowSpan > 90 ? 10 : 5,
                        minimumSpan: PodcastHighlightTrim.minimumSpan,
                        showsTimes: false, stripHeight: 48,
                        onScrub: { playback.scrub(to: $0) },
                        onDragEnded: commitDraft)
            .overlay(alignment: .topLeading) {
                GeometryReader { proxy in
                    let fraction = (playback.time - windowStart) / max(0.001, windowSpan)
                    if fraction >= 0, fraction <= 1 {
                        Rectangle().fill(.white)
                            .frame(width: 2, height: 48)
                            .offset(x: proxy.size.width * CGFloat(fraction) - 1)
                    }
                }
                .allowsHitTesting(false)
            }
            .help("The reel's start and end over the recording — drag past the edge and release to see more")
    }

    /// Window the filmstrip around the selection with room on both sides,
    /// so a handle can reach beyond the suggestion.
    private func recenterWindow() {
        let total = max(trim.duration, candidate.sourceEnd)
        let span = min(total, max(30, min(180, candidate.duration + 40)))
        windowSpan = span
        let center = (candidate.sourceStart + candidate.sourceEnd) / 2
        windowStart = min(max(0, center - span / 2), max(0, total - span))
    }

    private func commitDraft() {
        guard let draft else { return }
        self.draft = nil
        commit(draft.start...max(draft.start, draft.end), snap: true)
    }

    /// Apply a new range (snapped to words unless told otherwise), retarget
    /// playback, and re-window the strip if the range escaped it.
    private func commit(_ newRange: ClosedRange<Double>, snap: Bool) {
        let snapped = snap ? trim.snapped(start: newRange.lowerBound, end: newRange.upperBound) : newRange
        candidate.sourceStart = snapped.lowerBound
        candidate.sourceEnd = snapped.upperBound
        playback.setRange(snapped)
        let margin = windowSpan * 0.05
        if snapped.lowerBound < windowStart + margin || snapped.upperBound > windowStart + windowSpan - margin {
            withAnimation(.easeInOut(duration: 0.2)) { recenterWindow() }
        }
    }

    /// Space plays or pauses; I and O move the start or end to the playhead.
    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case " ":
            playback.togglePlay()
        case "i":
            commit(playback.time...max(playback.time + PodcastHighlightTrim.minimumSpan, candidate.sourceEnd), snap: true)
        case "o":
            commit(min(candidate.sourceStart, playback.time - PodcastHighlightTrim.minimumSpan)...playback.time, snap: true)
        default:
            return false
        }
        return true
    }

    // MARK: - Transcript

    private var transcriptPanel: some View {
        let current = trim.lineID(at: playback.time)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transcript").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Toggle("Follow", isOn: $followsPlayback).toggleStyle(.checkbox).controlSize(.small)
                    .help("Keep the line being spoken in view")
            }
            .padding(.horizontal, Theme.spaceS)
            .padding(.bottom, Theme.spaceS)
            Divider()
            if trim.lines.isEmpty {
                Text("No transcript for this recording. Transcribe the file from the Sources screen to trim by words.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(Theme.spaceM)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(trim.lines) { line in
                                transcriptLine(line, isCurrent: line.id == current)
                                    .id(line.id)
                            }
                        }
                        .padding(Theme.spaceS)
                    }
                    .onAppear { scrollToSelection(proxy) }
                    .onChange(of: candidate.id) { _, _ in scrollToSelection(proxy) }
                    .onChange(of: current) { _, id in
                        guard followsPlayback, playback.isPlaying, let id else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .frame(width: 360)
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        guard let id = trim.lineID(at: candidate.sourceStart + 0.1) else { return }
        proxy.scrollTo(id, anchor: .top)
    }

    private func transcriptLine(_ line: PodcastHighlightTrim.Line, isCurrent: Bool) -> some View {
        HStack(alignment: .top, spacing: Theme.spaceS) {
            Button(line.start.timecode) {
                playback.seek(to: line.start)
            }
            .buttonStyle(.plain)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 40, alignment: .trailing)
            .help("Move the playhead to \(line.start.timecode)")
            VStack(alignment: .leading, spacing: 2) {
                if let speaker = line.speaker {
                    Text(speaker).font(.caption.weight(.semibold)).foregroundStyle(SpeakerColors.color(for: speaker))
                }
                FlowLayout(spacing: 3) {
                    ForEach(line.words) { word in
                        wordToken(word)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.spaceS)
        .padding(.vertical, 4)
        .background(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func wordToken(_ word: PodcastHighlightTrim.Word) -> some View {
        let inside = trim.contains(word, in: range)
        let spoken = playback.time >= word.start && playback.time < word.end
        return Button {
            select(word)
        } label: {
            Text(word.text)
                .font(.callout)
                .fontWeight(spoken ? .semibold : .regular)
                .foregroundStyle(inside ? Color.primary : Color.secondary)
                .padding(.horizontal, 2)
                .background(inside ? Color.accentColor.opacity(0.28) : Color.clear, in: RoundedRectangle(cornerRadius: 3))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(inside ? "Trim the reel's \(trim.edge(for: word, in: range) == .start ? "start" : "end") to here"
                     : "Extend the reel's \(trim.edge(for: word, in: range) == .start ? "start" : "end") to here")
        .accessibilityLabel("\(word.text), \(word.start.timecode)")
        .accessibilityAddTraits(inside ? .isSelected : [])
    }

    /// Move the nearer end to the clicked word and play from the new cut so
    /// the user hears what changed.
    private func select(_ word: PodcastHighlightTrim.Word) {
        let edge = trim.edge(for: word, in: range)
        commit(trim.range(range, selecting: word), snap: false)
        switch edge {
        case .start:
            playback.seek(to: candidate.sourceStart)
        case .end:
            playback.seek(to: max(candidate.sourceStart, candidate.sourceEnd - 3))
        }
        playback.play()
    }
}

/// The Play button's sheet in the list view: the same trim surface with a
/// Done button. Edits land on the bound candidate as they are made.
struct PodcastHighlightTrimSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    @Binding var candidate: HighlightCandidate
    let original: HighlightCandidate
    let trim: PodcastHighlightTrim

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            HStack {
                VStack(alignment: .leading, spacing: Theme.spaceXS) {
                    Text(candidate.title).font(.headline).lineLimit(1)
                    Text(candidate.reason).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            PodcastHighlightTrimView(url: url, candidate: $candidate, original: original, trim: trim)
        }
        .padding(Theme.spaceM)
        .frame(width: PodcastHighlightTrimView.sheetWidth, height: PodcastHighlightTrimView.sheetHeight)
        .modalCloseButton { dismiss() }
    }
}

extension PodcastHighlightTrimView {
    /// Sheet size that fits the picture, the filmstrip and the transcript column.
    static let sheetWidth: CGFloat = 1240
    static let sheetHeight: CGFloat = 780
}
