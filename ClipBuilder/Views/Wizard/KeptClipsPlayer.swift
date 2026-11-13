import AVKit
import Combine
import SwiftUI

/// The wizard pages' third column: the recording itself in its own shape
/// (never cropped to the output format), playing one kept clip's range at
/// a time. Nothing is
/// rendered over it; captions, name tags, overlays and the focus frame are
/// placed in the rough cut sheet. Under the picture: the transport across
/// the current clip, the clip stepper with the speed control, and Play All
/// with the length of every clip together.
struct KeptClipsPlayer: View {
    @Environment(\.workspacePageVisible) private var pageVisible
    @Environment(\.isEnabled) private var isEnabled
    let clips: [WizardPreviewClip]
    /// Width / height the frame takes until the recording's own shape has
    /// been read (the output format).
    let aspect: CGFloat
    @Binding var index: Int
    /// "Clip" for kept footage, "Scene" for analysis scenes.
    var noun = "Clip"
    var emptyMessage = "Choose a video to preview"

    @State private var player = AVPlayer()
    @State private var loadedURL: URL?
    /// Width / height of the loaded recording as displayed (rotation applied).
    @State private var sourceAspect: CGFloat?
    /// The playhead in source seconds.
    @State private var time = 0.0
    @State private var isPlaying = false
    /// Play All is running: a clip's end goes on to the next one.
    @State private var playsAll = false
    @State private var scrubbing: Double?
    /// A clip is being put in the player: until its seek lands the playhead
    /// still reads the clip before, which must not end the new one (a clip
    /// from earlier in the recording was skipped by Play All).
    @State private var loading = 0
    @State private var settled = 0
    @State private var timeObserver: Any?
    // The observer outlives the view value that installed it.
    @State private var playbackClips: [WizardPreviewClip] = []
    @State private var playbackActive = false
    /// A click on the picture takes the keyboard, so Space and Delete stop
    /// acting on the Footage list beside it.
    @FocusState private var pictureFocused: Bool
    @AppStorage(PlaybackSpeed.key) private var speed = 1.0

    private var current: WizardPreviewClip? {
        playbackClips.isEmpty ? nil : playbackClips[min(max(0, index), playbackClips.count - 1)]
    }

    var body: some View {
        GeometryReader { available in
            // The largest frame in the recording's shape that leaves room for the rows below.
            let aspect = max(0.01, sourceAspect ?? aspect)
            let reserve: CGFloat = clips.isEmpty ? 0 : 96
            let height = max(120, min(available.size.height - reserve, available.size.width / max(0.01, aspect)))
            VStack(alignment: .leading, spacing: Theme.spaceS) {
                picture
                    .frame(width: height * aspect, height: height)
                if let clip = current {
                    VStack(alignment: .leading, spacing: Theme.spaceS) {
                        transport(clip)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: Theme.spaceS) {
                                stepper
                                Spacer(minLength: 0)
                                PlaybackSpeedControl(rate: $speed)
                            }
                            VStack(alignment: .leading, spacing: Theme.spaceS) {
                                stepper
                                PlaybackSpeedControl(rate: $speed)
                            }
                        }
                        playAllRow
                    }
                    .frame(width: max(200, height * aspect))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { attach() }
        .onDisappear { detach() }
        .onReceive(player.publisher(for: \.rate).receive(on: RunLoop.main)) { isPlaying = $0 != 0 }
        .onChange(of: speed) { _, speed in player.setReviewSpeed(speed) }
        .onChange(of: index) { _, _ in load(play: playsAll) }
        .onChange(of: clips) { old, clips in
            // The observer always steps through the list as it is now, but
            // playback only stops when what is playing changed: a new pacing
            // clock or B-roll on the same footage leaves it running.
            let before = current
            playbackClips = clips
            let after = clips.indices.contains(index) ? clips[index] : nil
            let sameFootage = old.map(\.id) == clips.map(\.id)
                && before?.start == after?.start && before?.end == after?.end
                && before?.scene.videoURL == after?.scene.videoURL
            guard !sameFootage else { return }
            stop()
            if index >= clips.count { index = max(0, clips.count - 1) }
            load(play: false)
        }
        .onChange(of: pageVisible && isEnabled) { _, active in
            playbackActive = active
            if !active { stop() }
        }
    }

    private var picture: some View {
        Color.black
            .overlay {
                if current == nil {
                    Text(emptyMessage)
                        .font(.callout).foregroundStyle(.white)
                        .multilineTextAlignment(.center).padding(Theme.spaceM)
                } else {
                    // The whole recording, uncropped; the frame already has its shape.
                    InlinePlayerLayerView(player: player, gravity: .resizeAspect)
                        .accessibilityLabel("\(noun) video")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.mediaRadius))
            .contentShape(Rectangle())
            .focusable(current != nil, interactions: .edit)
            .focused($pictureFocused)
            .focusEffectDisabled()
            .keyboardFocusRing(pictureFocused, cornerRadius: Theme.mediaRadius)
            .onKeyPress(.space) {
                togglePlay()
                return .handled
            }
            .onTapGesture {
                pictureFocused = true
                togglePlay()
            }
    }

    private func transport(_ clip: WizardPreviewClip) -> some View {
        let shown = min(clip.duration, max(0, (scrubbing ?? time) - clip.start))
        return HStack(spacing: Theme.spaceS) {
            Button(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill") { togglePlay() }
                .labelStyle(.iconOnly).buttonStyle(.borderless).fixedSize()
                .help(isPlaying ? "Pause" : "Play this \(noun.lowercased())")
            Slider(value: Binding(
                get: { shown },
                set: { value in
                    scrubbing = clip.start + value
                    seek(to: clip.start + value)
                }), in: 0...max(0.01, clip.duration)) { editing in
                    if !editing { scrubbing = nil }
                }
                .controlSize(.small)
                .accessibilityLabel("Playhead")
            Text("\(WizardPreviewClips.clock(shown)) / \(WizardPreviewClips.clock(clip.duration))")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
    }

    private var stepper: some View {
        HStack(spacing: Theme.spaceS) {
            Button("Previous \(noun.lowercased())", systemImage: "chevron.left") { step(by: -1) }
                .disabled(index <= 0)
            Text("\(noun) \(min(index, clips.count - 1) + 1) of \(clips.count)")
                .font(.caption).monospacedDigit().lineLimit(1).fixedSize()
            Button("Next \(noun.lowercased())", systemImage: "chevron.right") { step(by: 1) }
                .disabled(index + 1 >= clips.count)
        }
        .labelStyle(.iconOnly)
        .controlSize(.small)
        .lineLimit(1).fixedSize()
    }

    private var playAllRow: some View {
        HStack(spacing: Theme.spaceS) {
            Button(playsAll ? "Stop" : "Play All",
                   systemImage: playsAll ? "stop.fill" : "play.square.stack") { togglePlayAll() }
                .controlSize(.small)
                .lineLimit(1).fixedSize()
                .help(playsAll ? "Stop playing every \(noun.lowercased())"
                      : "Play every \(noun.lowercased()) in order, from the first")
            Text("\(clips.count) \(noun.lowercased())\(clips.count == 1 ? "" : "s") · \(WizardPreviewClips.clock(KeptClipsPlayback.totalDuration(clips)))")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
                .help("How long every \(noun.lowercased()) runs together, before pacing")
        }
    }

    // MARK: Playback

    private func attach() {
        playbackClips = clips
        playbackActive = pageVisible && isEnabled
        // Clips can go while another Preview tab is showing; the index is the column's.
        if index >= clips.count { index = max(0, clips.count - 1) }
        player.setReviewSpeed(speed)
        player.actionAtItemEnd = .pause
        let observed = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main
        ) { current in
            let seconds = current.seconds
            Task { @MainActor in tick(seconds, player: observed) }
        }
        load(play: false)
    }

    private func detach() {
        playbackActive = false
        stop()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    private func stop() {
        // Invalidate any seek that still intends to start playing.
        loading += 1
        settled = loading
        player.pause()
        playsAll = false
    }

    private func tick(_ seconds: Double, player observed: AVPlayer) {
        guard playbackActive, observed === player, seconds.isFinite, scrubbing == nil, settled == loading else { return }
        time = seconds
        guard isPlaying else { return }
        switch KeptClipsPlayback.step(time: seconds, index: index, clips: playbackClips, playsAll: playsAll) {
        case .keepPlaying: break
        case .advance(let next): index = next   // onChange(of: index) loads and plays it
        case .stop:
            player.pause()
            playsAll = false
            if let clip = current { seek(to: clip.start) }
        }
    }

    /// The recording's displayed width / height: the video track's natural
    /// size turned by its preferred transform (a portrait phone clip is
    /// stored landscape). Nil when it cannot be read.
    nonisolated private static func displayAspect(of url: URL) async -> CGFloat? {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let shown = size.applying(transform)
        let width = abs(shown.width), height = abs(shown.height)
        return width > 0 && height > 0 ? width / height : nil
    }

    /// Puts the current clip in the player at its start.
    private func load(play: Bool) {
        loading += 1
        let request = loading
        guard let clip = current else {
            stop()
            player.replaceCurrentItem(with: nil)
            loadedURL = nil
            return
        }
        let url = clip.scene.videoURL
        if url != loadedURL {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            loadedURL = url
            Task {
                let shape = await Self.displayAspect(of: url)
                guard loadedURL == url else { return }
                sourceAspect = shape
            }
        }
        time = clip.start
        player.seek(to: CMTime(seconds: clip.start, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in
                // A seek a newer one replaced reports unfinished; the newest settles.
                guard request == loading else { return }
                settled = request
                if finished, play, playbackActive { player.play() }
            }
        }
        if !play { player.pause() }
    }

    private func seek(to seconds: Double) {
        time = seconds
        let tolerance = CMTime(seconds: 0.05, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    private func togglePlay() {
        guard playbackActive, let clip = current else { return }
        if isPlaying {
            stop()
        } else if time >= clip.end - KeptClipsPlayback.endTolerance || time < clip.start {
            // At the end (or outside the clip) Play starts the clip over.
            load(play: true)
        } else {
            player.play()
        }
    }

    private func togglePlayAll() {
        guard playbackActive else { return }
        if playsAll {
            stop()
            return
        }
        playsAll = true
        if index == 0 { load(play: true) } else { index = 0 }
    }

    private func step(by delta: Int) {
        playsAll = false
        index = min(max(0, index + delta), max(0, clips.count - 1))
    }
}
