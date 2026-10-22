import AVFoundation
import Observation

/// Local source playback only; no rendering or synthesis, and no automatic play on load.
@MainActor @Observable
final class DubReviewPlayback {
    private(set) var player: AVPlayer?
    private(set) var lineID: UUID?
    private(set) var error: String?
    private var request = UUID()

    func stop() {
        request = UUID()
        player?.pause()
        player = nil
        lineID = nil
    }

    func play(_ line: DubLine, prepared: DubPreparation.Prepared) async {
        stop()
        let token = request
        error = nil
        do {
            let item = try await DubPreview.item(for: line, prepared: prepared)
            guard token == request, !Task.isCancelled else { return }
            let player = AVPlayer(playerItem: item)
            self.player = player
            lineID = line.id
            player.play()
        } catch {
            if token == request { self.error = error.userMessage }
        }
    }
}
