import AVFoundation
import SwiftUI

/// Plays the sound of the Reel list's clips, one or all in order, without a
/// picture: the list has no player of its own and the Source Video tab is
/// elsewhere. Each clip plays its own stretch of its recording.
@Observable final class ReelClipAudioPlayer {
    struct Item: Equatable {
        var id: String
        var url: URL
        var start: Double
        var end: Double
    }

    private(set) var playingID: String?
    private(set) var playsAll = false

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var loadedURL: URL?
    @ObservationIgnored private var current: Item?
    @ObservationIgnored private var queue: [Item] = []
    /// Bumped per start: a seek an older start asked for must not play or end the new clip.
    @ObservationIgnored private var request = 0
    @ObservationIgnored private var settled = 0

    /// Plays one clip, or stops it when it is the one playing.
    func toggle(_ item: Item) {
        if playingID == item.id, !playsAll { stop(); return }
        playsAll = false
        queue = []
        start(item)
    }

    /// Plays every clip in order, or stops when that is already running.
    func toggleAll(_ items: [Item]) {
        if playsAll { stop(); return }
        guard let first = items.first else { return }
        playsAll = true
        queue = Array(items.dropFirst())
        start(first)
    }

    func stop() {
        request += 1
        settled = request
        player.pause()
        playingID = nil
        playsAll = false
        queue = []
        current = nil
    }

    private func start(_ item: Item) {
        guard item.end > item.start else { finished(); return }
        request += 1
        let asked = request
        current = item
        playingID = item.id
        if observer == nil {
            player.actionAtItemEnd = .pause
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
                let seconds = time.seconds
                Task { @MainActor in self?.tick(seconds) }
            }
        }
        if item.url != loadedURL {
            player.replaceCurrentItem(with: AVPlayerItem(url: item.url))
            loadedURL = item.url
        }
        player.pause()
        player.seek(to: CMTime(seconds: item.start, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] done in
            Task { @MainActor in
                guard let self, asked == self.request else { return }
                self.settled = asked
                if done { self.player.play() } else { self.stop() }
            }
        }
    }

    private func tick(_ seconds: Double) {
        guard let current, settled == request, seconds.isFinite else { return }
        // The end of the clip, or the recording ran out under it.
        if seconds >= current.end - 0.02 || (player.rate == 0 && seconds > current.start + 0.1
                                              && player.currentItem?.status == .readyToPlay
                                              && seconds >= (player.currentItem?.duration.seconds ?? .infinity) - 0.1) {
            finished()
        }
    }

    private func finished() {
        if playsAll, !queue.isEmpty {
            start(queue.removeFirst())
        } else {
            stop()
        }
    }
}
