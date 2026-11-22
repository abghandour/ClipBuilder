import AVKit
import Observation

@MainActor @Observable
final class FightActionPlayback {
    private(set) var player: AVPlayer?
    private(set) var time = 0.0
    private(set) var frameDuration = 1.0 / 30
    private(set) var playing = false
    private(set) var selected: FightActionDetail.Row?
    private(set) var highlight: StrikeHighlightRules.Track?
    private(set) var error: String?
    /// The selected strike has no limb track: the highlight cannot be drawn.
    private(set) var highlightMissing = false
    var loop = true
    var showHighlight = true
    var pauseOnImpact = false {
        didSet {
            if !pauseOnImpact, holdTask != nil { cancelHold(); resume() }
        }
    }
    var speed: Float = 1 { didSet { if playing, holdTask == nil { player?.rate = speed } } }
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var impactObserver: Any?
    @ObservationIgnored private var highlightTask: Task<Void, Never>?
    @ObservationIgnored private var holdTask: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var loadRevision = 0
    @ObservationIgnored private var duration = 0.0
    @ObservationIgnored private var seeking = false
    @ObservationIgnored private var seekRevision = 0

    func open(video: VideoRecord) async {
        close()
        let token = loadRevision
        duration = video.duration
        do {
            guard video.isLocal, await DrivePlayback.prepare(video.url) else {
                throw AIError.notConfigured("This video is not available on this Mac. Download it from Sources first.")
            }
            let asset = try await DriveLocalAsset.make(video.url)
            guard try await asset.load(.isPlayable) else { throw AIError.notConfigured("This video cannot be played.") }
            _ = try await asset.load(.duration, .preferredTransform)
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let rate = try await track.load(.nominalFrameRate)
                if rate > 0 { frameDuration = 1 / Double(rate) }
            }
            guard !Task.isCancelled, loadRevision == token else { return }
            let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            self.player = player
            if let selected {
                seek(to: selected.loopRange.lowerBound, play: true)
                // A row chosen while the file was still loading had no player
                // to put its impact hold on.
                if StrikeStatsSummary.strikeFamily.contains(selected.event.action) {
                    holdOnImpact(at: highlight?.contact ?? selected.event.time, token: revision)
                }
            }
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main) { [weak self] time in
                MainActor.assumeIsolated { self?.tick(time.seconds) }
            }
        } catch {
            guard !Task.isCancelled, loadRevision == token else { return }
            self.error = error.localizedDescription
            ErrorLog.record("Fight Action preview", error.localizedDescription)
        }
    }

    func select(_ row: FightActionDetail.Row, video: VideoRecord, store: AppStore) {
        clearAction()
        selected = row
        seek(to: row.loopRange.lowerBound, play: true)
        refreshHighlight(video: video, store: store)
    }

    func refreshHighlight(video: VideoRecord, store: AppStore) {
        highlightTask?.cancel()
        highlight = nil
        highlightMissing = false
        if let impactObserver { player?.removeTimeObserver(impactObserver) }
        impactObserver = nil
        guard let row = selected, StrikeStatsSummary.strikeFamily.contains(row.event.action) else { return }
        let token = revision, profile = store.profileGeneration
        highlightTask = Task { [weak self] in
            let track = await store.strikeHighlight(video: video, time: row.event.time,
                fighterKey: row.event.fighterKey, detail: StrikeDetail(row.event.detail), eventGeneration: row.event.generation)
            guard let self, !Task.isCancelled, self.revision == token, profile == store.profileGeneration else { return }
            self.highlight = track
            // No limb could be followed in the picture: nothing to draw, and the
            // hold stays on the scorer's own stamp.
            self.highlightMissing = track == nil
            if let track { self.holdOnImpact(at: track.contact, token: token) }
        }
        // Until the limb is found (or when it never is) the hold is at the
        // time the scorer logged, a still within about a quarter second of contact.
        holdOnImpact(at: row.event.time, token: token)
    }

    private func holdOnImpact(at contact: Double, token: Int) {
        guard let player else { return }
        if let impactObserver { player.removeTimeObserver(impactObserver) }
        impactObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: contact, preferredTimescale: 600))], queue: .main
        ) { [weak self] in
            MainActor.assumeIsolated { self?.hold(at: token) }
        }
    }

    private func hold(at token: Int) {
        guard playing, pauseOnImpact, revision == token, !seeking else { return }
        player?.pause()
        cancelHold()
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(StrikeHighlightRules.impactHold))
            guard let self, !Task.isCancelled, revision == token, playing else { return }
            holdTask = nil
            resume()
        }
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        time = seconds
        guard playing, !seeking, holdTask == nil else { return }
        let end = min(duration, selected?.loopRange.upperBound ?? duration)
        if seconds >= end - 0.02 {
            if loop, let selected { seek(to: selected.loopRange.lowerBound, play: true) }
            else { pause() }
        }
    }

    func togglePlay() {
        if playing { pause() }
        else if let selected, time >= min(duration, selected.loopRange.upperBound) - 0.03 {
            seek(to: selected.loopRange.lowerBound, play: true)
        } else { resume() }
    }

    func pause() { seekRevision += 1; seeking = false; playing = false; cancelHold(); player?.pause() }
    private func resume() { guard player != nil else { return }; playing = true; player?.rate = speed }
    private func cancelHold() { holdTask?.cancel(); holdTask = nil }

    func seek(to seconds: Double, play: Bool = false) {
        pause()
        guard let player else { return }
        seeking = true
        let token = revision, seekToken = seekRevision
        let target = min(duration, max(0, seconds))
        time = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.revision == token, self.seekRevision == seekToken else { return }
                self.seeking = false
                if finished, play { self.resume() }
            }
        }
    }

    func seekFreely(to seconds: Double) { clearAction(); seek(to: seconds) }
    func step(_ count: Int) { pause(); player?.currentItem?.step(byCount: count) }

    func clearAction() {
        revision += 1
        pause()
        selected = nil
        highlightTask?.cancel()
        highlightTask = nil
        highlight = nil
        highlightMissing = false
        if let impactObserver { player?.removeTimeObserver(impactObserver) }
        impactObserver = nil
        seeking = false
    }

    func close() {
        loadRevision += 1
        clearAction()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player = nil
        error = nil
    }
}
