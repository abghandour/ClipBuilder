import AVKit
import Combine
import SwiftUI

/// A player with its own transport row: play/pause, a scrubber across the
/// whole file and the time. AVKit's inline controls drop the scrubber once
/// the view is narrower than a phone preview, which is exactly how the
/// result cards show a 9:16 reel, so this draws the transport itself.
struct ScrubbingPlayerView<Overlay: View>: View {
    let player: AVPlayer?
    /// Width / height of the picture; the player keeps this shape.
    var aspect: CGFloat = 9 / 16
    /// Drawn over the picture only, not the transport (platform chrome).
    @ViewBuilder var pictureOverlay: () -> Overlay

    @State private var transport = PlayerTransport()
    @State private var scrubbing: Double?
    @AppStorage(PlaybackSpeed.key) private var speed = 1.0

    var body: some View {
        VStack(spacing: Theme.spaceXS) {
            PlayerView(player: player, controlsStyle: .none)
                .aspectRatio(aspect, contentMode: .fit)
                .background(.black, in: RoundedRectangle(cornerRadius: Theme.mediaRadius))
                .clipShape(RoundedRectangle(cornerRadius: Theme.mediaRadius))
                .contentShape(Rectangle())
                .onTapGesture { transport.togglePlay() }
                .overlay { pictureOverlay() }
            HStack(spacing: Theme.spaceS) {
                Button(transport.isPlaying ? "Pause" : "Play",
                       systemImage: transport.isPlaying ? "pause.fill" : "play.fill") {
                    transport.togglePlay()
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless).fixedSize()
                .disabled(player == nil)
                .help(transport.isPlaying ? "Pause" : "Play")
                Slider(value: Binding(
                    get: { scrubbing ?? min(transport.time, transport.duration) },
                    set: { scrubbing = $0; transport.seek(to: $0) }),
                       in: 0...max(0.01, transport.duration)) { editing in
                    if editing { transport.beginScrub() } else {
                        transport.endScrub()
                        scrubbing = nil
                    }
                }
                .controlSize(.small)
                .disabled(player == nil || transport.duration <= 0)
                .accessibilityLabel("Playhead")
                Text("\((scrubbing ?? transport.time).timecode) / \(transport.duration.timecode)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
            }
            // Its own row: a reel card is too narrow for the scrubber and
            // the speed control side by side.
            PlaybackSpeedControl(rate: $speed)
                .disabled(player == nil)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .onAppear { transport.attach(player); player?.setReviewSpeed(speed) }
        .onChange(of: player) { _, player in transport.attach(player); player?.setReviewSpeed(speed) }
        .onChange(of: speed) { _, speed in player?.setReviewSpeed(speed) }
        .onDisappear { transport.attach(nil) }
    }
}

extension ScrubbingPlayerView where Overlay == EmptyView {
    init(player: AVPlayer?, aspect: CGFloat = 9 / 16) {
        self.init(player: player, aspect: aspect, pictureOverlay: { EmptyView() })
    }
}

/// The playhead, duration and play state of one player, kept outside the
/// view body so the 10 Hz tick invalidates only the transport row.
@Observable
@MainActor
final class PlayerTransport {
    private(set) var time = 0.0
    private(set) var duration = 0.0
    private(set) var isPlaying = false

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var rateSink: AnyCancellable?
    private var endSink: AnyCancellable?
    private var durationTask: Task<Void, Never>?
    private var resumeAfterScrub = false
    private var seekInFlight = false
    private var pendingSeek: Double?

    func attach(_ player: AVPlayer?) {
        guard player !== self.player else { return }
        detach()
        self.player = player
        guard let player else { return }
        time = player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] current in
            let seconds = current.seconds
            let itemDuration = player.currentItem?.duration.seconds
            Task { @MainActor in self?.tick(seconds, itemDuration: itemDuration) }
        }
        rateSink = player.publisher(for: \.rate).receive(on: RunLoop.main).sink { [weak self] rate in
            self?.isPlaying = rate != 0
        }
        if let item = player.currentItem {
            endSink = NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.isPlaying = false
                    self.time = self.duration
                }
            durationTask = Task { [weak self] in
                guard let seconds = try? await item.asset.load(.duration).seconds, seconds.isFinite else { return }
                self?.duration = seconds
            }
        }
    }

    private func tick(_ seconds: Double, itemDuration: Double?) {
        guard !seekInFlight else { return }
        if seconds.isFinite, seconds != time { time = seconds }
        if let itemDuration, itemDuration.isFinite, itemDuration > 0, itemDuration != duration { duration = itemDuration }
    }

    private func detach() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        rateSink = nil
        endSink = nil
        durationTask?.cancel()
        durationTask = nil
        player = nil
        time = 0
        duration = 0
        isPlaying = false
        resumeAfterScrub = false
        seekInFlight = false
        pendingSeek = nil
    }

    func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            // At the end, Play starts over instead of doing nothing.
            if duration > 0, time >= duration - 0.05 {
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                time = 0
            }
            player.play()
        }
    }

    func beginScrub() {
        resumeAfterScrub = isPlaying
        player?.pause()
    }

    func seek(to seconds: Double) {
        time = seconds
        guard !seekInFlight else { pendingSeek = seconds; return }
        issueSeek(seconds)
    }

    func endScrub() {
        if resumeAfterScrub { player?.play() }
        resumeAfterScrub = false
    }

    /// One seek at a time; a drag queues the newest target and the previous
    /// completion issues it, so the player never falls behind the thumb.
    private func issueSeek(_ seconds: Double) {
        guard let player else { return }
        seekInFlight = true
        let tolerance = CMTime(seconds: 0.05, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.seekInFlight = false
                if let next = self.pendingSeek {
                    self.pendingSeek = nil
                    self.issueSeek(next)
                }
            }
        }
    }
}
