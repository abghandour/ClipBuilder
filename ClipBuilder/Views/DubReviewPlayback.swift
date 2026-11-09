import AVFoundation
import Observation

/// Local source playback only; no rendering or synthesis, and no automatic play on load.
@MainActor @Observable
final class DubReviewPlayback {
    private(set) var player: AVPlayer?
    /// The line playing now; cleared when it reaches its end so its row's
    /// Stop button turns back into Play.
    private(set) var lineID: UUID?
    private(set) var error: String?
    private var request = UUID()
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    func stop() {
        request = UUID()
        removeEndObserver()
        player?.pause()
        player = nil
        lineID = nil
    }

    func play(_ line: DubLine, prepared: DubPreparation.Prepared, withVideo: Bool = true) async {
        stop()
        let token = request
        error = nil
        do {
            let item = try await DubPreview.item(for: line, prepared: prepared, includeVideo: withVideo)
            guard token == request, !Task.isCancelled else { return }
            let player = AVPlayer(playerItem: item)
            self.player = player
            lineID = line.id
            endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, token == self.request else { return }
                    self.removeEndObserver()
                    self.lineID = nil
                    // Keep the last video frame on screen; audio alone has nothing to show.
                    if !withVideo { self.player = nil }
                }
            }
            player.play()
        } catch {
            if token == request { self.error = error.userMessage }
        }
    }

    private func removeEndObserver() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }
}
