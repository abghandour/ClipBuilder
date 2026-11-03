import AVKit
import SwiftUI

/// The rough cut job's result: a player per cut, so framing and focus can be
/// checked in motion, beside the framing controls the cut was made with.
/// Regenerate re-runs the same takes with the edited framing and swaps the
/// new cuts into this same sheet; Apply hands the framing to the page it came
/// from, Discard changes nothing. The cuts are small and plain by design
/// (docs/Rough-Cut-Plan.md); nothing is saved.
struct RoughCutReviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// The job whose result is on screen; Regenerate moves it to the new job.
    @State private var jobID: UUID
    @State private var review: RoughCutReview
    @State private var framing: Framing
    @State private var players: [String: AVPlayer] = [:]
    @State private var aspects: [String: CGFloat] = [:]
    /// Playback rate for every player, so a setting can be judged quickly or slowly.
    @State private var speed: Float = 1
    /// The Regenerate job this sheet is waiting for.
    @State private var pendingJobID: UUID?

    static let speeds: [Float] = [0.5, 1, 1.5, 2]
    /// Wide enough for the framing rows' label column, a segmented picker
    /// and a short detail; the rows never spill past the sheet.
    private static let controlsWidth: CGFloat = 480
    /// Under each player: its caption and the grid's spacing.
    private static let playerChromeHeight: CGFloat = 44

    init(jobID: UUID, review: RoughCutReview) {
        _jobID = State(initialValue: jobID)
        _review = State(initialValue: review)
        _framing = State(initialValue: review.framing)
    }

    private var idealSize: CGSize {
        let players = WizardResultsLayout.idealSize(count: review.cuts.count,
            cardSize: CGSize(width: WizardResultsLayout.minCardWidth, height: 720),
            screen: NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900))
        return CGSize(width: players.width + Self.controlsWidth, height: players.height)
    }
    private var framingChanged: Bool { framing != review.framing }
    private var busy: Bool { store.isWizardRunning || store.isWizardBatchJobRunning(projectID: review.projectID) }
    private var pendingJob: AppJob? {
        guard let pendingJobID else { return nil }
        return store.jobs.items.first { $0.id == pendingJobID }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text(review.cuts.count == 1 ? "Rough cut" : "\(review.cuts.count) rough cuts")
                    .font(.headline)
                    .lineLimit(1).fixedSize()
                Text("Framing and focus only, small and plain. Left out: \(WizardRoughCut.leftOut). Change the framing and regenerate; Apply puts it on the page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()

            HStack(spacing: 0) {
                GeometryReader { geometry in
                    let grid = WizardResultsLayout.grid(count: review.cuts.count, available: geometry.size,
                                                        chromeHeight: Self.playerChromeHeight)
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.spaceM), count: grid.columns),
                                  spacing: Theme.spaceM) {
                            ForEach(review.cuts) { cut in
                                let size = WizardResultsLayout.playerSize(in: grid, aspect: aspects[cut.id] ?? 9 / 16)
                                VStack(spacing: 6) {
                                    PlayerView(player: players[cut.id])
                                        .frame(width: size.width, height: size.height)
                                        .background(Color.black, in: RoundedRectangle(cornerRadius: 8))
                                    HStack(spacing: 6) {
                                        Text(cut.name).lineLimit(1).truncationMode(.middle)
                                        Text(cut.duration.timecode).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                    .overlay { if let pendingJob { rendering(pendingJob) } }
                }
                controls
                    .frame(width: Self.controlsWidth)
            }

            HStack {
                if pendingJob != nil {
                    Text("Rendering the rough cut again with the framing on the right.")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                } else if framingChanged {
                    Text("Framing changed. Regenerate to see it, Apply to keep it.")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer()
                // Regenerate only once the preview is stale: the framing on
                // the right differs from what the players show.
                Button("Regenerate") {
                    pendingJobID = store.rerunRoughCut(requestID: review.requestID, framing: framing)
                }
                .disabled(busy || !framingChanged)
                .help(busy ? "The Wizard is already working on this project."
                      : framingChanged ? "Render the rough cut again with the framing above; the new cut replaces this one here"
                      : "The preview already shows this framing")
                Button("Discard") { finish() }
                    .keyboardShortcut(.cancelAction)
                    .help("Close without changing the page's framing")
                Button("Apply") {
                    send(WizardAssistant.applyFramingAction)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help("Make the framing above the page's framing")
            }
            .padding()
        }
        .frame(minWidth: 420 + Self.controlsWidth, idealWidth: idealSize.width, maxWidth: .infinity,
               minHeight: 480, idealHeight: idealSize.height, maxHeight: .infinity)
        .presentationSizing(.fitted)
        .modalCloseButton { finish() }
        .task { await loadPlayers() }
        .onChange(of: speed) { _, rate in
            for player in players.values {
                player.defaultRate = rate
                if player.rate != 0 { player.rate = rate }
            }
        }
        .onChange(of: pendingJob) { _, job in
            // Gone from the list (an empty result is removed at once) or finished.
            guard let job else { pendingJobID = nil; return }
            guard job.status != .running else { return }
            pendingJobID = nil
            // A failed or stopped run reports through the status bar; the
            // sheet keeps the cuts it has.
            guard job.status == .done, case .roughCut(let next)? = job.result else { return }
            adopt(next, from: job.id)
        }
        .onDisappear {
            for player in players.values { player.pause() }
            players = [:]
        }
        .onChange(of: store.profileGeneration) { _, _ in finish() }
    }

    /// Over the players while Regenerate renders: progress, the job's
    /// last line and Stop, the same as its status-bar row.
    private func rendering(_ job: AppJob) -> some View {
        VStack(spacing: Theme.spaceM) {
            ProgressView(value: job.progress)
                .progressViewStyle(.linear)
                .frame(maxWidth: 240)
            Text(job.statusLine.isEmpty ? "Rendering…" : job.statusLine)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).multilineTextAlignment(.center)
            Button("Stop") { store.jobs.cancel(job.id) }
                .help("Stop this render and keep the cut on screen")
        }
        .padding(Theme.spaceL)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.35))
    }

    /// The new job's cuts replace the old ones in place: the old job is
    /// closed out (its files go with the next prune), the new job becomes
    /// the one this sheet closes, and its players load.
    private func adopt(_ next: RoughCutReview, from newJobID: UUID) {
        for player in players.values { player.pause() }
        players = [:]
        aspects = [:]
        store.jobs.markReviewed(jobID)
        jobID = newJobID
        review = next
        Task { await loadPlayers() }
    }

    private func loadPlayers() async {
        let cuts = review.cuts
        for cut in cuts {
            let asset = AVURLAsset(url: cut.url)
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.defaultRate = speed
            players[cut.id] = player
            if let aspect = try? await Self.aspect(of: asset), review.cuts == cuts { aspects[cut.id] = aspect }
            // A paused player that never played shows nothing; once the item
            // is ready, a muted play-and-pause puts the first frame on screen.
            Task { await Self.showPoster(of: player, item: item) }
        }
    }

    /// The page's framing rows, bound to the sheet's own copy, and the
    /// playback speed.
    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spaceM) {
                SettingsRow("Speed", detail: "Playback speed of the rough cuts above.") {
                    Picker("Speed", selection: $speed) {
                        ForEach(Self.speeds, id: \.self) { rate in
                            Text(rate == 1 ? "1×" : rate.formatted(.number.precision(.fractionLength(0...1))) + "×")
                                .lineLimit(1).fixedSize().tag(rate)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Playback speed")
                }
                FramingRows(framing: $framing, type: review.sourceType, videoIDs: review.videoIDs,
                            canvasAspect: review.canvasAspect)
            }
            .padding()
        }
        .environment(\.settingsDetailBelow, true)
        .environment(\.settingsRowDividers, false)
    }

    /// The command is consumed by the page that made the cut, so bring that
    /// page back first: its project, the Wizard page and its mode. The
    /// pending command waits for it to mount.
    private func send(_ actionID: String) {
        _ = store.selectProject(review.projectID)
        store.isShowingProjectsHome = false
        store.selectedSection = .wizard
        store.wizardMode = review.namespace == WizardAssistant.expressNamespace ? .express : .full
        store.assistant.sendCommand(actionID, text: framing.joined, namespace: review.namespace)
        finish()
    }

    private func finish() {
        store.jobs.markReviewed(jobID)
        dismiss()
    }

    /// Puts a ready item's first frame on screen without the user pressing
    /// play: AVPlayerView renders nothing for a player that never ran, and
    /// a seek alone does not wake it. A muted play until the first frame
    /// lands, then pause. Does nothing if the user already played.
    private static func showPoster(of player: AVPlayer, item: AVPlayerItem) async {
        for _ in 0..<100 where item.status == .unknown {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard item.status == .readyToPlay, player.rate == 0, item.currentTime() == .zero else { return }
        let muted = player.isMuted
        player.isMuted = true
        player.play()
        for _ in 0..<40 where item.currentTime().seconds < 0.03 {
            try? await Task.sleep(for: .milliseconds(25))
        }
        if player.currentItem === item, item.currentTime().seconds < 0.5 { player.pause() }
        player.isMuted = muted
    }

    nonisolated private static func aspect(of asset: AVAsset) async throws -> CGFloat? {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let size = CGRect(origin: .zero, size: natural).applying(transform).size
        guard size.width > 0, size.height > 0 else { return nil }
        return abs(size.width) / abs(size.height)
    }
}
