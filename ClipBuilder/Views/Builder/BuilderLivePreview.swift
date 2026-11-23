import AVFoundation
import Foundation
import Observation

/// One fast player for the Builder monitor. Preparation is cancellation-safe;
/// the composer does all asset/composition work off the main actor.
@MainActor @Observable
final class BuilderLivePreview {
    private(set) var player: AVPlayer?
    private(set) var preparing = false
    private(set) var error: String?
    private var request = UUID()
    private var seekRevision = 0
    private var seeking = false
    private var target = 0.0
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var buildTask: Task<Void, Never>?

    func dismissError() { error = nil }

    func stop() {
        request = UUID()
        buildTask?.cancel(); buildTask = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil; endObserver = nil
        player?.pause(); player = nil
        preparing = false
        seekRevision += 1
        seeking = false
    }

    func scrubbed(to time: Double) {
        target = max(0, time)
        seekRevision += 1
        guard let player else { return }
        seeking = true
        let revision = seekRevision, token = request
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.request == token, self.seekRevision == revision else { return }
                self.seeking = false
            }
        }
    }

    func start(store: AppStore) {
        stop()
        store.builder.claimPlayback(.live, stopExact: store.stopBuilderPreview)
        target = store.builder.playhead
        error = nil
        let token = request
        preparing = true
        buildTask = Task { [weak self] in
            await self?.prepare(store: store, token: token)
        }
    }

    private func prepare(store: AppStore, token: UUID) async {
        guard token == request, !Task.isCancelled else { return }
        defer { if token == request { preparing = false; buildTask = nil } }
        let model = store.builder
        var document = model.document
        let revision = model.revision, generation = store.profileGeneration
        let enabled = model.liveDubEnabled
        let plan = model.previewPlan()
        guard !plan.segments.isEmpty else { return }
        do {
            if enabled, document.dub?.enabled == true, let lines = document.dubLines, !lines.isEmpty {
                document.dubLines = try await DubSynthesizer.shared.restoringAudio(lines: lines,
                    database: store.database, allowSynthesis: false)
            }
            let missing = await BuilderDubLayout.missingAudio(lines: document.dubLines ?? [])
            guard token == request, !Task.isCancelled, generation == store.profileGeneration,
                  revision == model.revision else { return }
            if let lines = document.dubLines {
                model.restoreDubAudio(lines, missingAudio: missing)
            } else {
                model.missingDubAudio = missing
            }
            let item = try await TimelinePreviewComposer.makePlayerItem(segments: plan.segments, music: plan.music,
                settings: document.renderSettings, dubDocument: document, dubEnabled: enabled)
            guard token == request, !Task.isCancelled, generation == store.profileGeneration,
                  revision == model.revision else { return }
            let player = AVPlayer(playerItem: item)
            // A seek during preparation updates target; even a seek arriving
            // during this await must be applied before playback starts.
            var positioned = false
            while !positioned {
                let revision = seekRevision
                await player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
                guard token == request, !Task.isCancelled else { return }
                positioned = revision == seekRevision
            }
            guard token == request, !Task.isCancelled, generation == store.profileGeneration,
                  revision == model.revision else { return }
            self.player = player
            preparing = false
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self, weak model] time in
                MainActor.assumeIsolated {
                    guard let self, let model, self.request == token, !self.seeking else { return }
                    model.reportLivePlayhead(time.seconds)
                }
            }
            endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: item, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.request == token else { return }
                        self.stop()
                    }
                }
            player.setReviewSpeed(PlaybackSpeed.stored())
            player.play()
        } catch {
            guard token == request, !Task.isCancelled else { return }
            preparing = false
            self.error = error.userMessage
            ErrorLog.record("Builder live preview", error.userMessage)
        }
    }
}
