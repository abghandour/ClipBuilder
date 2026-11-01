import AVFoundation
import Foundation

/// Hear a proposed cut as if it were made: the second before the cut, then
/// a jump over it to the second after it. One player per sheet, reused for
/// every cut of the same recording (sound only, no picture).
@MainActor @Observable
final class CutAuditionPlayback {
    /// The cut being auditioned (nil when idle).
    private(set) var cutID: Int64?
    private(set) var isLoading = false

    /// Seconds played on each side of the cut.
    static let lead: Double = 1.0

    private enum Phase { case before, after }

    private var player: AVPlayer?
    private var loadedURL: URL?
    private var phase = Phase.before
    private var cut: ClosedRange<Double> = 0...0
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    /// Bumped by every audition, stop and tear-down: a seek completion or
    /// load that captured an older value belongs to a replaced audition and
    /// must not touch the state.
    private var generation = 0
    /// Bumped whenever the player is torn down or replaced: its time and
    /// end observers check it so a callback from an old player is ignored.
    private var playerGeneration = 0

    var isPlaying: Bool { cutID != nil }

    /// Play `[start - 1, start]`, then `[end, end + 1]`. Auditioning the cut
    /// already playing stops it.
    func audition(url: URL, cut: ClosedRange<Double>, id: Int64) {
        if cutID == id { stop(); return }
        stop()
        self.cut = cut
        if url == loadedURL, player != nil {
            generation += 1
            cutID = id
            begin()
            return
        }
        tearDown()
        generation += 1
        playerGeneration += 1
        let loadGeneration = generation
        let observerGeneration = playerGeneration
        cutID = id
        loadedURL = url
        isLoading = true
        loadTask = Task { [weak self] in
            guard await DrivePlayback.prepare(url), let self else { self?.finishLoading(loadGeneration); return }
            guard let asset = try? await DriveLocalAsset.make(url) else { self.finishLoading(loadGeneration); return }
            guard self.generation == loadGeneration else { return }
            let item = AVPlayerItem(asset: asset)
            item.audioTimePitchAlgorithm = .timeDomain
            let player = AVPlayer(playerItem: item)
            for _ in 0..<100 where item.status != .readyToPlay {
                if item.status == .failed || Task.isCancelled { self.finishLoading(loadGeneration); return }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled, item.status == .readyToPlay else { self.finishLoading(loadGeneration); return }
            // A newer audition, stop or tear-down replaced this load.
            guard self.generation == loadGeneration, self.playerGeneration == observerGeneration else { return }
            self.player = player
            self.timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
                Task { @MainActor in
                    guard let self, self.playerGeneration == observerGeneration else { return }
                    self.tick(time.seconds)
                }
            }
            // A cut near the end of the recording runs out before the lead.
            self.endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.playerGeneration == observerGeneration else { return }
                    self.stop()
                }
            }
            self.isLoading = false
            self.begin()
        }
    }

    /// End a failed or cancelled load, unless a newer audition replaced it.
    private func finishLoading(_ loadGeneration: Int) {
        guard generation == loadGeneration else { return }
        isLoading = false
        cutID = nil
    }

    private func begin() {
        guard let player else { return }
        phase = .before
        let from = max(0, cut.lowerBound - Self.lead)
        let seekGeneration = generation
        player.seek(to: CMTime(seconds: from, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == seekGeneration, self.cutID != nil, self.phase == .before else { return }
                self.player?.playImmediately(atRate: 1)
            }
        }
    }

    private func tick(_ seconds: Double) {
        guard cutID != nil, let player, player.rate != 0 else { return }
        switch phase {
        case .before where seconds >= cut.lowerBound:
            phase = .after
            player.pause()
            let seekGeneration = generation
            player.seek(to: CMTime(seconds: cut.upperBound, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == seekGeneration, self.cutID != nil, self.phase == .after else { return }
                    self.player?.playImmediately(atRate: 1)
                }
            }
        case .after where seconds >= cut.upperBound + Self.lead:
            stop()
        default:
            break
        }
    }

    func stop() {
        generation += 1
        player?.pause()
        cutID = nil
        isLoading = false
    }

    func tearDown() {
        generation += 1
        playerGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        loadedURL = nil
        cutID = nil
        isLoading = false
    }
}
