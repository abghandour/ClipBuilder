import AVKit
import SwiftUI

struct MiniBRollEditor: View {
    let cut: BRollCut
    let piece: MiniBRollRules.Piece
    let words: [MiniBRollRules.Word]
    let scene: SceneRecord?
    let paletteIndex: Int
    /// The podcast recording; its sound plays under the muted B-roll.
    let sourceURL: URL?
    /// The source time being heard while playing, nil when stopped.
    var onSpoken: (Double?) -> Void = { _ in }
    let onChange: (BRollCut) -> Void
    let onReplace: () -> Void
    let onRemove: () -> Void
    @State private var playback = PodcastHighlightTrimPlayback()
    /// The recording's audio for the cut's words, played with the scene.
    @State private var voice = PodcastHighlightTrimPlayback()

    private var ends: [Double] {
        scene.map { MiniBRollRules.wordEnds(cut: cut, piece: piece, words: words, scene: $0) } ?? []
    }
    private var shorterEnd: Double? { ends.last { $0 < cut.end - 1e-6 } }
    private var longerEnd: Double? { ends.first { $0 > cut.end + 1e-6 } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            Text(cut.reason).font(.callout).lineLimit(1).fixedSize(horizontal: false, vertical: true).help(cut.reason)
            if let scene {
                PlayerView(player: playback.player, controlsStyle: .none)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(minHeight: 100)
                HStack {
                    Button(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
                        togglePlay()
                    }
                    .lineLimit(1).fixedSize().disabled(playback.player == nil)
                    .help("Play the B-roll with the podcast audio it covers")
                    // Scene and voice must run at the same speed to stay in step.
                    PlaybackSpeedControl(rate: Binding(get: { playback.rate },
                                                      set: { playback.setRate($0); voice.setRate($0) }))
                        .disabled(playback.player == nil)
                }
                HStack {
                    Text("Length \(cut.end - cut.start, specifier: "%.1f") s").lineLimit(1).fixedSize()
                    Spacer(minLength: 0)
                    Button { resize(end: shorterEnd, scene: scene) } label: { stepIcon("minus") }
                        .disabled(shorterEnd == nil)
                        .accessibilityLabel("Shorter").help("End one word earlier")
                    Button { resize(end: longerEnd, scene: scene) } label: { stepIcon("plus") }
                        .disabled(longerEnd == nil)
                        .accessibilityLabel("Longer").help("End one word later")
                }
                Text("Scene offset \(cut.sceneOffset, specifier: "%.1f") s").font(.caption).lineLimit(1).fixedSize()
                let limit = max(0, scene.duration - (cut.end - cut.start))
                Slider(value: Binding(get: { min(limit, cut.sceneOffset) }, set: {
                    onChange(MiniBRollRules.offset(cut, to: $0, scene: scene))
                }), in: 0...max(0.001, limit))
                .disabled(limit == 0).accessibilityLabel("Scene offset")
            } else {
                FormCaption("This scene is unavailable. Pick a replacement.", tone: .warning)
            }
            ViewThatFits(in: .horizontal) {
                HStack { actions }
                VStack(alignment: .leading) { actions }
            }
        }
        .padding(Theme.spaceM)
        .background(RangeReviewPalette.bar(paletteIndex).opacity(0.12), in: .rect(cornerRadius: Theme.cardRadius))
        .overlay(alignment: .leading) { Rectangle().fill(RangeReviewPalette.bar(paletteIndex)).frame(width: 3) }
        .task(id: scene?.id) {
            guard let scene else { playback.tearDown(); return }
            playback.load(url: scene.videoURL, range: playbackRange(scene), autoplay: false, muted: true)
            if let sourceURL { voice.load(url: sourceURL, range: cut.start...cut.end, autoplay: false) }
        }
        .onChange(of: cut) { _, _ in
            pause()
            if let scene { playback.setRange(playbackRange(scene)); playback.seek(to: playbackRange(scene).lowerBound) }
            voice.setRange(cut.start...cut.end)
            voice.seek(to: cut.start)
        }
        .onChange(of: voice.time) { _, time in if voice.isPlaying { onSpoken(time) } }
        // The voice ends the preview when it reaches the cut's last word.
        .onChange(of: voice.isPlaying) { _, playing in
            if !playing { playback.pause(); onSpoken(nil) }
        }
        .onDisappear {
            playback.tearDown()
            voice.tearDown()
            onSpoken(nil)
        }
    }

    private func stepIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.body.weight(.semibold))
            .frame(width: 16, height: 16)
    }

    /// Scene and voice start and stop together; both run for the cut's length.
    private func togglePlay() {
        if playback.isPlaying || voice.isPlaying { pause(); return }
        if voice.time >= cut.end - 0.05 || voice.time < cut.start - 0.05, let scene {
            playback.seek(to: playbackRange(scene).lowerBound)
            voice.seek(to: cut.start)
        }
        playback.play()
        voice.play()
    }

    private func pause() {
        playback.pause()
        voice.pause()
        onSpoken(nil)
    }

    @ViewBuilder private var actions: some View {
        Button("Replace Scene", action: onReplace).lineLimit(1).fixedSize()
        Button("Remove", role: .destructive, action: onRemove).lineLimit(1).fixedSize()
    }

    private func playbackRange(_ scene: SceneRecord) -> ClosedRange<Double> {
        let start = scene.startTime + cut.sceneOffset
        return start...max(start, min(scene.endTime, start + cut.end - cut.start))
    }

    private func resize(end: Double?, scene: SceneRecord) {
        guard let end else { return }
        onChange(MiniBRollRules.resized(cut, end: end, piece: piece, words: words, scene: scene))
    }
}
