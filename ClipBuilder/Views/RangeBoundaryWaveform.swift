import SwiftUI
import AppKit
import AVFoundation

/// The selection's start and end, each over its own few seconds of the
/// recording's sound wave, in the colour of the speaker talking there. Drag
/// (or click) on a wave to move that edge to the hundredth of a second;
/// Option snaps to the nearest word edge. Zoom narrows both windows.
struct RangeBoundaryWaveforms: View {
    let url: URL
    let range: ClosedRange<Double>
    let limits: ClosedRange<Double>
    let minimumSpan: Double
    let lines: [TranscriptQATrim.Line]
    let words: [TranscriptQATrim.Word]
    /// Live while dragging: the new range, and the edge being dragged.
    let onDrag: (ClosedRange<Double>, TranscriptQATrim.Edge) -> Void
    /// On release: the range to save, and the edge that moved.
    let onRelease: (ClosedRange<Double>, TranscriptQATrim.Edge) -> Void
    /// Plays each edge's stretch and shows its progress.
    let playback: PodcastHighlightTrimPlayback
    /// Before a stretch plays (the owner stops Play All).
    let willPlay: () -> Void
    @AppStorage("rangeReview.waveZoom") private var zoom = 0

    private var halfWidth: Double {
        AudioPeaks.zoomLevels[min(max(zoom, 0), AudioPeaks.zoomLevels.count - 1)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceXS) {
            graph(.start)
            graph(.end)
        }
    }

    private func graph(_ edge: TranscriptQATrim.Edge) -> some View {
        let time = edge == .start ? range.lowerBound : range.upperBound
        let speaker = Self.speaker(at: edge == .start ? time + 0.05 : time - 0.05, lines: lines)
        return BoundaryWaveform(edge: edge, url: url, time: time, other: edge == .start ? range.upperBound : range.lowerBound,
                                limits: limits, minimumSpan: minimumSpan, words: words, speaker: speaker,
                                halfWidth: halfWidth, zoom: $zoom,
                                onDrag: { onDrag(Self.range(range, edge: edge, to: $0), edge) },
                                onRelease: { onRelease(Self.range(range, edge: edge, to: $0), edge) },
                                playback: playback, willPlay: willPlay)
    }

    static func range(_ range: ClosedRange<Double>, edge: TranscriptQATrim.Edge, to time: Double) -> ClosedRange<Double> {
        edge == .start ? time...max(time, range.upperBound) : range.lowerBound...max(range.lowerBound, time)
    }

    /// The name on the transcript line playing at `time`, else the nearest line's.
    static func speaker(at time: Double, lines: [TranscriptQATrim.Line]) -> String? {
        if let line = lines.first(where: { $0.start <= time && time < $0.end }), let speaker = line.speaker {
            return speaker
        }
        return lines.filter { $0.speaker != nil }
            .min { distance($0, time) < distance($1, time) }?.speaker
    }

    private static func distance(_ line: TranscriptQATrim.Line, _ time: Double) -> Double {
        time < line.start ? line.start - time : max(0, time - line.end)
    }
}

/// One edge over its sound wave.
private struct BoundaryWaveform: View {
    let edge: TranscriptQATrim.Edge
    let url: URL
    let time: Double
    let other: Double
    let limits: ClosedRange<Double>
    let minimumSpan: Double
    let words: [TranscriptQATrim.Word]
    let speaker: String?
    let halfWidth: Double
    @Binding var zoom: Int
    let onDrag: (Double) -> Void
    let onRelease: (Double) -> Void
    let playback: PodcastHighlightTrimPlayback
    let willPlay: () -> Void

    /// The window's centre: the edge, held still while it is dragged.
    @State private var center: Double?
    @State private var dragging = false
    @State private var peaks: AudioPeaks?
    @State private var failed = false
    @State private var pinchStart: Int?
    /// Where this wave's own stretch started playing, while it plays.
    @State private var playFrom: Double?

    private var title: String { edge == .start ? "Start" : "End" }
    private var color: Color { speaker.map(SpeakerColors.color(for:)) ?? .accentColor }
    private var window: ClosedRange<Double> {
        AudioPeaks.window(center: center ?? time, halfWidth: halfWidth, limits: limits)
    }
    /// Where this edge may go: inside the limits and at least the minimum span from the other.
    private var allowed: ClosedRange<Double> {
        switch edge {
        case .start: limits.lowerBound...max(limits.lowerBound, min(limits.upperBound, other - minimumSpan))
        case .end: min(limits.upperBound, max(limits.lowerBound, other + minimumSpan))...limits.upperBound
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            wave
        }
        .task(id: LoadKey(url: url, window: window)) { await load() }
        .onChange(of: time) { _, _ in if !dragging { center = nil } }
        .onChange(of: url) { _, _ in peaks = nil; failed = false }
        .onChange(of: playback.isPlaying) { _, playing in if !playing { playFrom = nil } }
    }

    private var header: some View {
        HStack(spacing: Theme.spaceS) {
            let playing = playFrom != nil && playback.isPlaying
            Button(playing ? "Stop" : (edge == .start ? "Play From Start" : "Play To End"),
                   systemImage: playing ? "stop.fill" : "play.fill") {
                if playing { playback.pause() } else { playStretch(around: time) }
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small)
            .frame(width: 22, height: 20).contentShape(Rectangle())
            .help(edge == .start ? "Play from the start to the end of this box" : "Play from the start of this box to the end")
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            if let speaker {
                SpeakerPill(speaker: speaker, font: .caption2.weight(.semibold)).fixedSize()
            }
            Spacer(minLength: Theme.spaceXS)
            Text(Self.timecode(time)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
            if edge == .start { zoomButtons }
        }
    }

    private var zoomButtons: some View {
        HStack(spacing: 0) {
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { zoom = max(0, zoom - 1) }
                .disabled(zoom <= 0)
                .help("Show more of the sound around each edge")
            Button("Zoom In", systemImage: "plus.magnifyingglass") { zoom = min(AudioPeaks.zoomLevels.count - 1, zoom + 1) }
                .disabled(zoom >= AudioPeaks.zoomLevels.count - 1)
                .help("Show less around each edge, to place it more precisely")
        }
        .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small).fixedSize()
    }

    private var wave: some View {
        GeometryReader { geometry in
            let width = geometry.size.width, height = geometry.size.height
            let window = window
            Canvas { context, size in
                draw(in: &context, size: size, window: window)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !dragging { dragging = true; center = center ?? time }
                    onDrag(target(x: value.location.x, width: width, window: window))
                }
                .onEnded { value in
                    let final = target(x: value.location.x, width: width, window: window)
                    dragging = false
                    center = nil
                    onRelease(final)
                    playStretch(around: final)
                })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in
                    if pinchStart == nil { pinchStart = zoom }
                    let steps = Int((log2(value.magnification)).rounded())
                    zoom = min(max((pinchStart ?? zoom) + steps, 0), AudioPeaks.zoomLevels.count - 1)
                }
                .onEnded { _ in pinchStart = nil })
            .overlay {
                WaveProgress(playback: playback, window: window, from: playFrom, color: color, band: Self.wordBand)
                    .allowsHitTesting(false)
            }
            .overlay {
                if peaks == nil {
                    Text(failed ? "No sound to show" : "Reading the sound…")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(width: width, height: height)
        }
        .frame(height: 66)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.chipRadius))
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .help("\(title): drag or click on the wave to move it; hold Option to snap to a word edge. Pinch to zoom.")
        .accessibilityElement()
        .accessibilityLabel("\(title) of the selection")
        .accessibilityValue(Self.timecode(time))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.05 : -0.05
            onRelease(clamp(time + step))
        }
    }

    /// This edge's stretch in the box centred on `edge`: from the start to
    /// the box's right side, or from the box's left side to the end, never
    /// past the other edge.
    private func stretch(around edgeTime: Double) -> ClosedRange<Double>? {
        let box = AudioPeaks.window(center: edgeTime, halfWidth: halfWidth, limits: limits)
        let from = edge == .start ? edgeTime : max(box.lowerBound, other)
        let to = edge == .start ? min(box.upperBound, other) : edgeTime
        return to > from + 0.05 ? from...to : nil
    }

    private func playStretch(around edgeTime: Double) {
        guard let stretch = stretch(around: edgeTime) else { return }
        willPlay()
        playback.play(from: stretch.lowerBound, until: stretch.upperBound)
        playFrom = stretch.lowerBound
    }

    private func target(x: Double, width: Double, window: ClosedRange<Double>) -> Double {
        let raw = AudioPeaks.time(forX: x, in: window, width: width)
        guard NSEvent.modifierFlags.contains(.option) else { return clamp(raw) }
        let edges = words.map { edge == .start ? $0.start : $0.end }
        let snapped = edges.min { abs($0 - raw) < abs($1 - raw) } ?? raw
        return clamp(snapped)
    }

    private func clamp(_ time: Double) -> Double {
        min(max(time, allowed.lowerBound), allowed.upperBound)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, window: ClosedRange<Double>) {
        let width = Double(size.width), height = Double(size.height)
        let band = Self.wordBand
        let mid = band + (height - band) / 2
        let marker = AudioPeaks.x(for: time, in: window, width: width)
        // The words along the top, each from where it starts; a word that
        // would overlap the one before it is left out.
        var lastRight = -Double.infinity
        for word in words where word.end > window.lowerBound && word.start < window.upperBound {
            let x = max(1, AudioPeaks.x(for: word.start, in: window, width: width))
            guard x > lastRight + 3 else { continue }
            let inside = edge == .start ? word.mid >= time : word.mid <= time
            let label = context.resolve(Text(word.text).font(.system(size: 10))
                .foregroundStyle(inside ? Color.primary : Color.secondary))
            let measured = label.measure(in: CGSize(width: width, height: band))
            guard x + measured.width <= width - 1 else { continue }
            context.draw(label, at: CGPoint(x: x, y: 1), anchor: .topLeading)
            lastRight = x + measured.width
        }
        // Word edges, faint, along the bottom.
        for word in words where word.end > window.lowerBound && word.start < window.upperBound {
            let x = AudioPeaks.x(for: edge == .start ? word.start : word.end, in: window, width: width)
            context.fill(Path(CGRect(x: x, y: height - 5, width: 1, height: 5)), with: .color(.secondary.opacity(0.5)))
        }
        if let peaks {
            let step = 2.0
            let columns = peaks.columns(Int(width / step), window: window)
            for (index, level) in columns.enumerated() {
                let x = Double(index) * step
                let inside = edge == .start ? x + step / 2 >= marker : x + step / 2 <= marker
                let amplitude = max(1, Double(level) * ((height - band) / 2 - 4))
                let bar = CGRect(x: x, y: mid - amplitude, width: step - 0.5, height: amplitude * 2)
                context.fill(Path(bar), with: .color(inside ? color : color.opacity(0.28)))
            }
        } else {
            context.fill(Path(CGRect(x: 0, y: mid - 0.5, width: width, height: 1)), with: .color(.secondary.opacity(0.4)))
        }
        // The edge: a bar with a grip at the top.
        context.fill(Path(CGRect(x: marker - 1, y: band, width: 2, height: height - band)), with: .color(.primary))
        var grip = Path()
        grip.move(to: CGPoint(x: marker - 5, y: band))
        grip.addLine(to: CGPoint(x: marker + 5, y: band))
        grip.addLine(to: CGPoint(x: marker, y: band + 6))
        grip.closeSubpath()
        context.fill(grip, with: .color(.primary))
    }

    /// The strip above the wave that holds the words.
    static let wordBand = 14.0

    private struct LoadKey: Hashable {
        var url: URL
        /// The window to the nearest half second: a drag inside the cached chunk does not reload.
        var lower: Int
        var upper: Int
        init(url: URL, window: ClosedRange<Double>) {
            self.url = url
            lower = Int((window.lowerBound * 2).rounded(.down))
            upper = Int((window.upperBound * 2).rounded(.up))
        }
    }

    private func load() async {
        let window = window
        if let peaks, peaks.covers(window) { return }
        do {
            peaks = try await AudioPeaksReader.shared.peaks(url: url, window: window)
            failed = peaks?.isEmpty ?? true
            if failed { peaks = nil }
        } catch is CancellationError {
        } catch {
            failed = true
        }
    }

    /// Minutes, seconds and hundredths: 1:00.24.
    static func timecode(_ seconds: Double) -> String {
        let hundredths = Int((max(0, seconds) * 100).rounded())
        return String(format: "%d:%02d.%02d", hundredths / 6000, (hundredths / 100) % 60, hundredths % 100)
    }
}

/// The playhead over a wave while playback runs inside its box, drawn every
/// frame from the player's clock; a stretch this wave started also shades
/// what has played.
private struct WaveProgress: View {
    let playback: PodcastHighlightTrimPlayback
    let window: ClosedRange<Double>
    let from: Double?
    let color: Color
    let band: Double

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: 1 / 60, paused: !playback.isPlaying)) { timeline in
            GeometryReader { proxy in
                let width = Double(proxy.size.width), height = Double(proxy.size.height)
                if let now = Self.now(playback, at: timeline.date), window.contains(now) {
                    let x = AudioPeaks.x(for: now, in: window, width: width)
                    let start = from.map { max(0, AudioPeaks.x(for: $0, in: window, width: width)) }
                    ZStack(alignment: .topLeading) {
                        if let start, x > start {
                            Rectangle().fill(.white.opacity(0.16))
                                .frame(width: x - start, height: height - band)
                                .offset(x: start, y: band)
                        }
                        Rectangle().fill(.white)
                            .frame(width: 2, height: height - band + 4)
                            .offset(x: x - 1, y: band - 4)
                            .shadow(color: .black.opacity(0.5), radius: 1)
                    }
                    .frame(width: width, height: height, alignment: .topLeading)
                }
            }
        }
    }

    /// The player's position now; nil while it is not playing.
    private static func now(_ playback: PodcastHighlightTrimPlayback, at _: Date) -> Double? {
        guard playback.isPlaying else { return nil }
        let seconds = playback.player?.currentTime().seconds ?? playback.time
        return seconds.isFinite ? seconds : playback.time
    }
}
