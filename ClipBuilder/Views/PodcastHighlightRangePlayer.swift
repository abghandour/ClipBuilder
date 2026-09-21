import AVKit
import SwiftUI

/// Each candidate owns one player. Dismantling cancels seeks before releasing it.
struct PodcastHighlightRangePlayer: NSViewRepresentable {
    let url: URL
    let candidate: HighlightCandidate

    final class Coordinator {
        var playbackTask: Task<Void, Never>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        let item = AVPlayerItem(url: url)
        item.forwardPlaybackEndTime = CMTime(seconds: candidate.sourceEnd, preferredTimescale: 600)
        item.reversePlaybackEndTime = CMTime(seconds: candidate.sourceStart, preferredTimescale: 600)
        let player = AVPlayer(playerItem: item)
        view.player = player
        // Prevent the full-source scrubber from escaping the candidate's range.
        view.controlsStyle = .none
        // AVPlayer can drop a seek issued before readiness. Do not expose or
        // play the source's opening frames while the candidate seek is pending.
        view.isHidden = true
        context.coordinator.playbackTask = Task { @MainActor [weak player, weak item, weak view] in
            guard let player, let item else { return }
            while item.status != .readyToPlay {
                guard !Task.isCancelled, item.status != .failed else { return }
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { return }
            }
            guard !Task.isCancelled, item.status == .readyToPlay else { return }
            let ready = await player.seek(to: item.reversePlaybackEndTime, toleranceBefore: .zero, toleranceAfter: .zero)
            guard ready, !Task.isCancelled, player.currentItem === item else { return }
            view?.isHidden = false
            player.play()
        }
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.playbackTask?.cancel()
        coordinator.playbackTask = nil
        view.player?.pause()
        view.player?.currentItem?.cancelPendingSeeks()
        view.player?.replaceCurrentItem(with: nil)
        view.player = nil
    }
}
