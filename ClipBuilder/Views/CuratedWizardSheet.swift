import AVKit
import SwiftUI

/// The Curated Video wizard — a guided middle ground between the AI Wizard
/// and the Builder. The app proposes scenes one at a time (best-scored
/// first); the user previews each inline, trims it, toggles Center Stage,
/// and approves or skips until the reel reaches its target duration. Then
/// three quick polish passes — overlays per scene, music per scene, outro —
/// and the result renders through the Builder's multitrack pipeline.
struct CuratedWizardSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var model: CuratedWizardModel
    @State private var player: AVPlayer?
    @State private var loopObserver: Any?
    @State private var isScrubbing = false
    @State private var scrubResumeTask: Task<Void, Never>?
    // Pause/mute for the proposal/overlay preview player — persists across
    // scene changes, steps, and app launches so a muted preview stays muted.
    // Native-control changes are captured into these on every player swap.
    @AppStorage("curatedWizard.previewAutoplay") private var previewPlaying = true
    @AppStorage("curatedWizard.previewMuted") private var previewMuted = false
    /// Left edge of the fine-trim strip's 10s window (absolute source time).
    @State private var zoomWindowStart: Double = 0
    @State private var showFramingSheet = false
    /// Scene whose Center Stage path is being computed right now.
    @State private var computingPathSceneID: Int64?
    // Reel-preview column: the approved picks stitched into one looping
    // composition (cuts only — overlays/music/transitions render at generate).
    @State private var reelPlayer: AVPlayer?
    @AppStorage("curatedWizard.reelAutoplay") private var reelPlaying = true
    @AppStorage("curatedWizard.reelMuted") private var reelMuted = true
    @State private var reelEndObserver: NSObjectProtocol?
    @State private var reelRebuildTask: Task<Void, Never>?
    // Exact preview: the reel rendered through the REAL pipeline to a temp
    // file — pixel-for-pixel what Generate produces. Any edit invalidates it
    // back to the live stitched approximation.
    @State private var exactPreviewURL: URL?
    @State private var exactPreviewTask: Task<Void, Never>?


    init(scenes: [SceneRecord], targetDuration: Int, includeOutro: Bool,
         batchNames: [Int64: String] = [:],
         selectedBatchIDs: [Int64] = []) {
        _model = State(initialValue: CuratedWizardModel(queue: scenes,
                                                        targetDuration: Double(targetDuration),
                                                        includeOutro: includeOutro,
                                                        batchNames: batchNames,
                                                        selectedBatchIDs: selectedBatchIDs))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch model.step {
                case .scenes: scenesStep
                case .overlays: overlaysStep
                case .music: musicStep
                case .outro: outroStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 1080, idealWidth: 1280, maxWidth: .infinity,
               minHeight: 660, idealHeight: 840, maxHeight: .infinity)
        .onAppear {
            syncPlayer()
            refreshZoomWindow(force: true)
            ensureCameraPath()
            rebuildReelPreview()
        }
        .onDisappear {
            teardownPlayer()
            teardownReelPlayer()
        }
        .onChange(of: model.picks) { rebuildReelPreview() }
        // Only affects the render, so the stitched preview needn't
        // rebuild — but a standing exact preview no longer matches.
        // (Transition changes don't invalidate: the picker only stamps
        // FUTURE adds; edits to a pick's transition flow through picks.)
        .onChange(of: model.includeOutro) { invalidateExactPreviewOnly() }
        .onChange(of: model.step) { _, step in
            // The reel column lives in steps 1 and 4 — don't keep decoding
            // (or fighting the overlay step's player) off screen.
            if step == .scenes || step == .outro {
                if reelPlaying { reelPlayer?.play() }
            } else {
                reelPlayer?.pause()
            }
        }
        .onChange(of: model.previewKey) {
            syncPlayer()
            refreshZoomWindow(force: true)
            ensureCameraPath()
        }
        .onChange(of: model.editStart) { refreshZoomWindow() }
        .onChange(of: model.editEnd) { refreshZoomWindow() }
        .onChange(of: model.editSpeed) {
            // Retime a playing preview on the spot — no reload needed.
            if previewPlaying, !isScrubbing { player?.rate = previewRate }
        }
        .onChange(of: model.editCenterStage) { ensureCameraPath() }
        .sheet(isPresented: $showFramingSheet, onDismiss: {
            resumeLoopPlayback()
            // Framing edits live on the scene records, not the picks — pick
            // up the workbench's changes in the stitched preview.
            rebuildReelPreview()
        }) {
            if let scene = model.currentScene {
                CurateSceneSheet(sceneID: scene.id)
            }
        }
    }

    /// Fight-action pace across [start, end] of this scene's video, for the
    /// trim sliders' red sparkline — trim toward the spikes.
    private func fightPace(for scene: SceneRecord, start: Double, end: Double) -> [Double] {
        guard let events = store.fightEvents[scene.videoID] else { return [] }
        return FightGraphView.paceCurve(events: events, start: start, end: end,
                                        buckets: max(2, Int((end - start).rounded())))
    }

    /// Keep the fine-trim window (10s of source) around the selection,
    /// recentering only when the selection escapes it so drags stay stable.
    private func refreshZoomWindow(force: Bool = false) {
        guard let scene = model.currentScene else { return }
        let span = min(10.0, scene.videoDuration)
        let fits = model.editStart >= zoomWindowStart
            && model.editEnd <= zoomWindowStart + span
        guard force || !fits else { return }
        let mid = (model.editStart + model.editEnd) / 2
        zoomWindowStart = min(max(0, mid - span / 2), max(0, scene.videoDuration - span))
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                teardownPlayer()
                dismiss()
            } label: {
                Label("Close", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.title3)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close — your picks are discarded")
            Label("Curated Video", systemImage: "checklist")
                .font(.headline)
            StepIndicator(current: model.step)
            if model.step == .scenes, model.batchIDs.count > 1, let active = model.activeBatchID {
                Picker("Analyze Batch", selection: Binding(get: { active },
                                                   set: { model.switchBatch(to: $0) })) {
                    ForEach(model.batchIDs, id: \.self) { id in
                        Text(model.batchName(id)
                             + (model.batchHasProposals(id) ? "" : " — no matches"))
                            .tag(id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
                .help("Which analyze batch's footage is being proposed — approved clips from every batch land in the same reel")
            }
            Spacer()
            if model.step == .scenes {
                HStack(spacing: 6) {
                    Text("Target")
                        .foregroundStyle(.secondary)
                    TextField("Target", value: $model.targetDuration, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 44)
                        .multilineTextAlignment(.trailing)
                    Text("s")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .help("How long the finished reel should run")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            if model.step != .scenes {
                Button("Back") { model.goBack() }
            }
            Spacer()
            durationSummary
            Spacer()
            switch model.step {
            case .scenes:
                Button("Continue") { model.goForward() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.picks.isEmpty)
                    .help(model.picks.isEmpty ? "Approve at least one scene first"
                                              : "On to overlays — you can come back")
            case .overlays, .music:
                Button("Continue") { model.goForward() }
                    .buttonStyle(.borderedProminent)
            case .outro:
                Button("Open in Builder") {
                    store.openCuratedInBuilder(model.buildDocument())
                    teardownPlayer()
                    dismiss()
                }
                .help("Load these picks into the Builder timeline for detailed editing instead of rendering now")
                Button {
                    store.renderCuratedDocument(model.buildDocument(),
                                                includeOutro: model.includeOutro)
                    teardownPlayer()
                    dismiss()
                } label: {
                    Label("Generate Video", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help("Render the curated reel to the Library — progress shows in the Generation Log")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var durationSummary: some View {
        let total = model.totalDuration
        let reached = total >= model.targetDuration
        return HStack(spacing: 8) {
            Text("\(model.picks.count) scene\(model.picks.count == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
            ProgressView(value: min(1, model.targetDuration > 0 ? total / model.targetDuration : 0))
                .frame(width: 140)
                .tint(reached ? .green : .accentColor)
            Text(String(format: "%.1fs / %.0fs", total, model.targetDuration))
                .monospacedDigit()
                .foregroundStyle(reached ? .green : .secondary)
        }
        .font(.callout)
        .help("Total length of the approved scenes vs the target duration")
    }

    // MARK: - Step 1: scene curation

    @ViewBuilder
    private var scenesStep: some View {
        VStack(spacing: 0) {
            if !model.proposalList.isEmpty {
                proposalCarousel
                Divider()
            }
            HSplitView {
                proposalPane
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                // Reel preview + the approved-clips list share the right
                // column — the old bottom reel strip's height now belongs
                // to the scene player, which wide footage sorely needs.
                VStack(spacing: 0) {
                    reelPreviewPane
                    Divider()
                    reelListPane
                }
                .rememberedPaneWidth("pane.curatedWizard.reel", min: 200, initial: 250, max: 340)
                .frame(maxHeight: .infinity)
            }
        }
    }

    /// The proposal queue across the top: every scene still on offer as a
    /// small thumbnail, the one being previewed highlighted. Click to jump.
    private var proposalCarousel: some View {
        let currentID = model.editingPickID == nil ? model.currentScene?.id : nil
        return ScrollViewReader { scrollProxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.proposalList) { scene in
                        let isCurrent = scene.id == currentID
                        VideoThumbnail(url: scene.videoURL, time: scene.startTime + 0.1)
                            .frame(width: 76, height: 46)
                            .overlay(alignment: .bottomTrailing) {
                                Text(String(format: "%.0fs", scene.duration))
                                    .font(.caption2.monospacedDigit())
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.black.opacity(0.6), in: Capsule())
                                    .foregroundStyle(.white)
                                    .padding(3)
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(isCurrent ? Color.accentColor : .secondary.opacity(0.3),
                                                  lineWidth: isCurrent ? 3 : 1)
                            }
                            .opacity(isCurrent ? 1 : 0.7)
                            .onTapGesture { model.jumpToProposal(scene.id) }
                            .help(scene.videoFilename
                                  + (scene.score.map { String(format: " — score %.0f/10", $0) } ?? ""))
                            .id(scene.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: currentID) { _, id in
                guard let id else { return }
                withAnimation { scrollProxy.scrollTo(id, anchor: .center) }
            }
            .onAppear {
                if let currentID { scrollProxy.scrollTo(currentID, anchor: .center) }
            }
        }
    }

    /// Third column: the reel so far, stitched and looping — what Generate
    /// would cut together from the current picks.
    @ViewBuilder
    private var reelPreviewPane: some View {
        VStack(spacing: 8) {
            Text("Reel Preview")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let reelPlayer {
                PlayerFillView(player: reelPlayer)
                    .aspectRatio(9 / 16, contentMode: .fit)
                    // Capped so the reel list below keeps its room in the
                    // shared right column.
                    .frame(maxHeight: 360)
                    .background(.black, in: RoundedRectangle(cornerRadius: 8))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 10) {
                    Button {
                        reelPlaying.toggle()
                        if reelPlaying { reelPlayer.play() } else { reelPlayer.pause() }
                    } label: {
                        Image(systemName: reelPlaying ? "pause.fill" : "play.fill")
                    }
                    .help(reelPlaying ? "Pause the reel preview" : "Play the reel preview")
                    Button {
                        reelMuted.toggle()
                        reelPlayer.isMuted = reelMuted
                    } label: {
                        Image(systemName: reelMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .help(reelMuted ? "Unmute (mutes the proposal player's audio rival)" : "Mute")
                    Spacer()
                    Text(String(format: "%.1fs", model.totalDuration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if store.isCuratedPreviewRendering {
                        ProgressView().controlSize(.small)
                        Text("Rendering exact preview…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if exactPreviewURL != nil {
                        Label("Exact — this is the final video", systemImage: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .help("Rendered by the real pipeline — Generate produces exactly this, pixel for pixel")
                    } else {
                        Button("Exact Preview") { renderExactPreview() }
                            .controlSize(.small)
                            .help("Render the reel through the real pipeline — framing, transitions, music, overlays, outro — and play the finished file here. Takes about as long as Generate.")
                    }
                    Spacer()
                }
                if exactPreviewURL == nil, !store.isCuratedPreviewRendering {
                    Text("Live preview honors each clip's crop, speed, and Center Stage camera — transitions, music, and overlays show in the Exact Preview.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Spacer()
                Image(systemName: "film.stack")
                    .font(.title)
                    .foregroundStyle(.tertiary)
                Text("Approve clips to watch the reel build up here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
        }
        .padding(10)
    }

    /// The inline preview player + trim controls + approve/skip actions for
    /// the scene currently on offer (or an approved pick being re-edited).
    @ViewBuilder
    private var proposalPane: some View {
        VStack(spacing: 10) {
            if let range = model.currentRange {
                ZStack {
                    if let player {
                        PlayerView(player: player)
                    } else {
                        Rectangle().fill(.black)
                        ProgressView()
                    }
                }
                .overlay { centerStageOverlay }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                trimControls(range: range)
                actionButtons
            } else {
                VStack(spacing: 12) {
                    if model.activeBatchIsEmpty, model.batchIDs.count > 1 {
                        ContentUnavailableView(
                            "Nothing to suggest from this analyze batch",
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: Text("The wizard's Source Selection filters — picked people, curated-only, Center Stage fit — matched none of this analyze batch's scenes. Adjust those filters and reopen, or switch to another analyze batch."))
                    } else {
                        ContentUnavailableView(
                            model.batchIDs.count > 1 ? "No more scenes in this analyze batch"
                                                     : "No more scenes to review",
                            systemImage: "checkmark.rectangle.stack",
                            description: Text(model.batchIDs.count > 1
                                ? "This analyze batch's suggestions are done — switch analyze batches to keep going."
                                : (model.picks.isEmpty
                                    ? "Every scene in the current source selection has been shown. Adjust the wizard's Source Selection and reopen."
                                    : "You've seen every scene. Reorder or re-trim your picks below, then Continue.")))
                    }
                    if model.batchIDs.count > 1 {
                        Button {
                            model.cycleBatch(1)
                        } label: {
                            Label("Next Analyze Batch", systemImage: "forward.frame")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func trimControls(range: ClosedRange<Double>) -> some View {
        if let scene = model.currentScene {
            // Fine-grain pass: a 10s window with 0.5s ticks, so a 2s
            // selection isn't a sliver on an 86s filmstrip.
            let zoomed = model.editEnd - model.editStart < 10 && scene.videoDuration > 10.5
            VStack(alignment: .leading, spacing: 4) {
                Text(zoomed ? "Fine trim — 10s window, 0.5s ticks"
                            : "Clip range — drag to trim or extend into the source footage")
                    .font(.caption.weight(.medium))
                VStack(spacing: 0) {
                    if zoomed {
                        VideoTrimSlider(url: scene.videoURL,
                                        duration: min(10, scene.videoDuration),
                                        start: $model.editStart, end: $model.editEnd,
                                        pace: fightPace(for: scene, start: zoomWindowStart,
                                                        end: zoomWindowStart + min(10, scene.videoDuration)),
                                        timeOffset: zoomWindowStart,
                                        tickInterval: 0.5, rulerInterval: 0.5,
                                        minimumSpan: 0.5,
                                        showsTimes: false, stripHeight: 64) { time in
                            scrub(to: time)
                        }
                        zoomConnector(videoDuration: scene.videoDuration)
                    }
                    VideoTrimSlider(url: scene.videoURL, duration: scene.videoDuration,
                                    start: $model.editStart, end: $model.editEnd,
                                    pace: fightPace(for: scene, start: 0,
                                                    end: scene.videoDuration),
                                    rulerInterval: Self.coarseRulerInterval(scene.videoDuration)) { time in
                        scrub(to: time)
                    }
                    .help("Clip range — drag to trim or extend into the source footage")
                }
                HStack {
                    Button("Reset to scene") {
                        model.editStart = range.lowerBound
                        model.editEnd = range.upperBound
                        refreshZoomWindow(force: true)
                        resumeLoopPlayback()
                    }
                    .controlSize(.small)
                    .disabled(abs(model.editStart - range.lowerBound) < 0.05
                              && abs(model.editEnd - range.upperBound) < 0.05)
                    Picker("Speed", selection: $model.editSpeed) {
                        Text("0.5× slow").tag(0.5)
                        Text("0.75×").tag(0.75)
                        Text("1× normal").tag(1.0)
                        Text("1.5×").tag(1.5)
                        Text("2×").tag(2.0)
                    }
                    .fixedSize()
                    .help("Playback speed for this clip — the preview plays at this rate, and the reel's screen time stretches or shrinks to match (audio tempo follows in the render)")
                    Spacer()
                    if scene.wide {
                        Toggle("Center Stage camera", isOn: $model.editCenterStage)
                            .toggleStyle(.checkbox)
                            .help("Track the people with a virtual camera instead of a static crop — wide footage only")
                        if model.editCenterStage {
                            Button("Adjust Framing…") {
                                player?.pause()
                                showFramingSheet = true
                            }
                            .controlSize(.small)
                            .help("Compute the Center Stage camera for this scene and steer it: pin framing hints on the paused frame in the Curate workbench")
                        }
                    }
                }
            }
        }
    }

    /// Ruler spacing for the full-clip strip — coarser than the loupe's
    /// 0.5s: clean steps that keep roughly 10–30 marks across any length.
    private static func coarseRulerInterval(_ duration: Double) -> Double {
        switch duration {
        case ..<20: return 1
        case ..<60: return 2
        case ..<180: return 5
        default: return 10
        }
    }

    /// Loupe funnel between the fine-trim strip and the full-clip strip: the
    /// zoom strip's full width tapers down to the 10s window it magnifies on
    /// the source filmstrip below, so the two surfaces read as one lens.
    private func zoomConnector(videoDuration: Double) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let span = min(10.0, videoDuration)
            let safeDuration = max(videoDuration, 0.001)
            let x0 = width * CGFloat(min(1, zoomWindowStart / safeDuration))
            let x1 = width * CGFloat(min(1, (zoomWindowStart + span) / safeDuration))
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0))
                    path.addLine(to: CGPoint(x: width, y: 0))
                    path.addLine(to: CGPoint(x: x1, y: height))
                    path.addLine(to: CGPoint(x: x0, y: height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [.yellow.opacity(0.22), .yellow.opacity(0.05)],
                                     startPoint: .top, endPoint: .bottom))
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0))
                    path.addLine(to: CGPoint(x: x0, y: height))
                    path.move(to: CGPoint(x: width, y: 0))
                    path.addLine(to: CGPoint(x: x1, y: height))
                }
                .stroke(.yellow.opacity(0.6), lineWidth: 1)
                // Underline the magnified window right where it sits on the
                // full-clip strip.
                Path { path in
                    path.move(to: CGPoint(x: x0, y: height - 0.5))
                    path.addLine(to: CGPoint(x: x1, y: height - 0.5))
                }
                .stroke(.yellow.opacity(0.8), lineWidth: 1.5)
            }
        }
        .frame(height: 16)
        .allowsHitTesting(false)
        .help("The strip above is a magnified view of this slice of the full clip")
    }

    // MARK: - Reel preview

    /// Stitch the approved picks (in order, at their trims) into one
    /// composition and loop it. A video composition applies each clip's real
    /// framing — source orientation, the static cropXFrac window, or the
    /// Center Stage camera path as animated transform ramps — so the preview
    /// matches what Generate renders. Rebuilt whenever the picks change.
    private func rebuildReelPreview() {
        reelRebuildTask?.cancel()
        // Edits outdate any standing exact render — fall back to the live
        // stitched approximation until Exact Preview is run again.
        invalidateExactPreviewOnly()
        let picks = model.picks
        guard !picks.isEmpty else {
            teardownReelPlayer()
            return
        }
        // Fresh scene records, so framing edited in the workbench is honored.
        let scenes = Dictionary(uniqueKeysWithValues: picks.map { ($0.scene.id, freshScene($0.scene)) })
        reelRebuildTask = Task {
            let renderSize = CGSize(width: 540, height: 960)
            let composition = AVMutableComposition()
            let videoComposition = AVMutableVideoComposition()
            videoComposition.renderSize = renderSize
            videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
            guard let videoTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
            let audioTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            var instructions: [AVMutableVideoCompositionInstruction] = []
            var cursor = CMTime.zero
            var assets: [URL: AVURLAsset] = [:]
            for pick in picks {
                let scene = scenes[pick.scene.id] ?? pick.scene
                let url = scene.videoURL
                let asset = assets[url] ?? AVURLAsset(url: url)
                assets[url] = asset
                guard let source = try? await asset.loadTracks(withMediaType: .video).first,
                      let (orientation, orientedSize) = try? await Self.orientation(of: source)
                else { continue }
                let range = CMTimeRange(
                    start: CMTime(seconds: pick.trimStart, preferredTimescale: 600),
                    duration: CMTime(seconds: pick.sourceSpan, preferredTimescale: 600))
                guard (try? videoTrack.insertTimeRange(range, of: source, at: cursor)) != nil else { continue }
                let hasAudio: Bool
                if let audioSource = try? await asset.loadTracks(withMediaType: .audio).first {
                    hasAudio = (try? audioTrack?.insertTimeRange(range, of: audioSource, at: cursor)) != nil
                } else {
                    hasAudio = false
                }
                // Slow motion / speed-up: the inserted source span stretches
                // or shrinks to the pick's screen time. Screen durations are
                // rounded to 0.1s exactly like buildDocument, so the preview
                // timeline matches the render's clip boundaries.
                let screenSeconds = (pick.duration * 10).rounded() / 10
                let screen = CMTime(seconds: screenSeconds, preferredTimescale: 600)
                var segmentDuration = range.duration
                if pick.speed != 1 || abs(pick.sourceSpan - screenSeconds) > 0.001 {
                    let inserted = CMTimeRange(start: cursor, duration: range.duration)
                    videoTrack.scaleTimeRange(inserted, toDuration: screen)
                    if hasAudio { audioTrack?.scaleTimeRange(inserted, toDuration: screen) }
                    segmentDuration = screen
                }
                let segment = CMTimeRange(start: cursor, duration: segmentDuration)
                instructions.append(Self.framingInstruction(
                    segment: segment, track: videoTrack, pick: pick, scene: scene,
                    orientation: orientation, orientedSize: orientedSize, renderSize: renderSize))
                cursor = cursor + segmentDuration
            }
            guard !Task.isCancelled, cursor > .zero else { return }
            videoComposition.instructions = instructions
            let item = AVPlayerItem(asset: composition)
            item.videoComposition = videoComposition
            installReelItem(item)
        }
    }

    /// Orientation-corrected transform + display size of a source track —
    /// screen recordings store rotated frames the renderer auto-rotates;
    /// the composition must do the same explicitly.
    private static func orientation(of track: AVAssetTrack) async throws -> (CGAffineTransform, CGSize) {
        let (naturalSize, preferred) = try await track.load(.naturalSize, .preferredTransform)
        let rect = CGRect(origin: .zero, size: naturalSize).applying(preferred)
        let correction = preferred.concatenating(
            CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        return (correction, CGSize(width: abs(rect.width), height: abs(rect.height)))
    }

    /// One segment's framing: the Center Stage path as piecewise transform
    /// ramps when the pick tracks, else the static cropXFrac / centered
    /// aspect-fill window.
    private static func framingInstruction(segment: CMTimeRange, track: AVAssetTrack,
                                           pick: CuratedWizardModel.Pick, scene: SceneRecord,
                                           orientation: CGAffineTransform, orientedSize: CGSize,
                                           renderSize: CGSize) -> AVMutableVideoCompositionInstruction {
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = segment
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)

        func transform(cropping rect: CGRect) -> CGAffineTransform {
            let scale = renderSize.width / max(1, rect.width)
            let crop = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                         tx: -rect.minX * scale, ty: -rect.minY * scale)
            return orientation.concatenating(crop)
        }

        func staticCropRect() -> CGRect {
            let targetAspect = renderSize.width / renderSize.height
            let sourceAspect = orientedSize.width / max(1, orientedSize.height)
            if sourceAspect > targetAspect {
                let width = orientedSize.height * targetAspect
                let x = scene.wide ? (scene.cropXFrac ?? 0.5) * (orientedSize.width - width)
                                   : (orientedSize.width - width) / 2
                return CGRect(x: x, y: 0, width: width, height: orientedSize.height)
            }
            let height = orientedSize.width / targetAspect
            return CGRect(x: 0, y: (orientedSize.height - height) / 2,
                          width: orientedSize.width, height: height)
        }

        if pick.centerStage, let path = scene.centerStagePath, !path.keyframes.isEmpty {
            let localStart = pick.trimStart - scene.startTime
            let localEnd = pick.trimEnd - scene.startTime
            func rect(at t: Double) -> CGRect? {
                guard let crop = CenterStageService.interpolated(path.keyframes, at: t) else { return nil }
                return CGRect(x: crop.x * orientedSize.width, y: crop.y * orientedSize.height,
                              width: crop.w * orientedSize.width, height: crop.h * orientedSize.height)
            }
            var samples: [(Double, CGRect)] = []
            if let r = rect(at: localStart) { samples.append((localStart, r)) }
            for keyframe in path.keyframes where keyframe.t > localStart && keyframe.t < localEnd {
                if let r = rect(at: keyframe.t) { samples.append((keyframe.t, r)) }
            }
            if let r = rect(at: localEnd) { samples.append((localEnd, r)) }
            if samples.count >= 2 {
                for index in 0..<(samples.count - 1) {
                    let (t0, r0) = samples[index]
                    let (t1, r1) = samples[index + 1]
                    guard t1 > t0 else { continue }
                    // Source offsets land in the segment through the speed —
                    // the scaled (slow/fast) composition time.
                    let rampRange = CMTimeRange(
                        start: segment.start + CMTime(seconds: (t0 - localStart) / pick.speed,
                                                      preferredTimescale: 600),
                        duration: CMTime(seconds: (t1 - t0) / pick.speed, preferredTimescale: 600))
                    layer.setTransformRamp(fromStart: transform(cropping: r0),
                                           toEnd: transform(cropping: r1),
                                           timeRange: rampRange)
                }
                instruction.layerInstructions = [layer]
                return instruction
            }
        }
        layer.setTransform(transform(cropping: staticCropRect()), at: segment.start)
        instruction.layerInstructions = [layer]
        return instruction
    }

    private func installReelItem(_ item: AVPlayerItem) {
        if let reelEndObserver {
            NotificationCenter.default.removeObserver(reelEndObserver)
        }
        let player = reelPlayer ?? AVPlayer()
        player.isMuted = reelMuted
        player.replaceCurrentItem(with: item)
        reelPlayer = player
        reelEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { _ in
            Task { @MainActor in
                self.reelPlayer?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                if self.reelPlaying { self.reelPlayer?.play() }
            }
        }
        if reelPlaying { player.play() }
    }

    /// Render the reel through the actual pipeline and play the result —
    /// what shows afterwards IS the file Generate would produce.
    private func renderExactPreview() {
        exactPreviewTask?.cancel()
        reelRebuildTask?.cancel()
        let document = model.buildDocument()
        let includeOutro = model.includeOutro
        exactPreviewTask = Task {
            guard let url = await store.renderCuratedExactPreview(document,
                                                                  includeOutro: includeOutro)
            else { return }
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            if let old = exactPreviewURL { try? FileManager.default.removeItem(at: old) }
            exactPreviewURL = url
            installReelItem(AVPlayerItem(url: url))
        }
    }

    /// Drop a standing exact render (the edit made it stale) without
    /// touching the live stitched preview.
    private func invalidateExactPreviewOnly() {
        exactPreviewTask?.cancel()
        exactPreviewTask = nil
        if let url = exactPreviewURL { try? FileManager.default.removeItem(at: url) }
        exactPreviewURL = nil
    }

    private func teardownReelPlayer() {
        reelRebuildTask?.cancel()
        reelRebuildTask = nil
        invalidateExactPreviewOnly()
        if let reelEndObserver {
            NotificationCenter.default.removeObserver(reelEndObserver)
        }
        reelEndObserver = nil
        reelPlayer?.pause()
        reelPlayer = nil
    }

    // MARK: - Center Stage frame

    /// The scene with live store state (the workbench and the auto-compute
    /// below write the path/range to the DB; the model's queue snapshot
    /// doesn't see those updates).
    private func freshScene(_ scene: SceneRecord) -> SceneRecord {
        store.scenes.first { $0.id == scene.id } ?? scene
    }

    /// The Center Stage frame drawn over the preview while the toggle is on:
    /// the recorded tracking camera rides along during playback; without a
    /// path yet, the static auto-crop window shows with a status caption.
    @ViewBuilder
    private var centerStageOverlay: some View {
        if model.editCenterStage, let staleScene = model.currentScene, staleScene.wide,
           let video = store.videos.first(where: { $0.id == staleScene.videoID }),
           video.width > 0, video.height > 0 {
            let scene = freshScene(staleScene)
            GeometryReader { geo in
                let videoRect = AVMakeRect(
                    aspectRatio: CGSize(width: max(1, video.width), height: max(1, video.height)),
                    insideRect: CGRect(origin: .zero, size: geo.size))
                if let path = scene.centerStagePath {
                    SwiftUI.TimelineView(.animation) { _ in
                        if let player,
                           let crop = CenterStageService.interpolated(
                               path.keyframes, at: player.currentTime().seconds - scene.startTime) {
                            cameraFrame(CGRect(x: videoRect.minX + crop.x * videoRect.width,
                                               y: videoRect.minY + crop.y * videoRect.height,
                                               width: crop.w * videoRect.width,
                                               height: crop.h * videoRect.height),
                                        in: videoRect,
                                        label: "Center Stage — Adjust Framing to steer")
                        }
                    }
                } else {
                    // Static 9:16 auto-crop window — what rendering falls
                    // back to until a path exists.
                    let widthFraction = (9.0 / 16.0) * Double(video.height) / Double(video.width)
                    let x = (scene.cropXFrac ?? 0.5) * (1 - widthFraction)
                    cameraFrame(CGRect(x: videoRect.minX + x * videoRect.width,
                                       y: videoRect.minY,
                                       width: widthFraction * videoRect.width,
                                       height: videoRect.height),
                                in: videoRect,
                                label: computingPathSceneID == scene.id
                                    ? "Computing Center Stage path…"
                                    : "Static crop — no tracking path yet")
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Dim everything outside the crop, stroke the crop, tag it with a label.
    private func cameraFrame(_ rect: CGRect, in videoRect: CGRect, label: String) -> some View {
        ZStack(alignment: .topLeading) {
            Path { dim in
                dim.addRect(videoRect)
                dim.addRect(rect)
            }
            .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
            Rectangle()
                .strokeBorder(.yellow, lineWidth: 3)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            Text(label)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.65), in: Capsule())
                .foregroundStyle(.yellow)
                .position(x: rect.midX, y: max(videoRect.minY + 10, rect.minY - 12))
        }
    }

    /// "When Center Stage is checked, it should be calculated": kick off the
    /// tracking-path computation the moment the toggle is on for a wide
    /// scene that has none — the live frame appears as soon as it lands.
    private func ensureCameraPath() {
        guard model.step == .scenes, model.editCenterStage,
              let scene = model.currentScene, scene.wide,
              freshScene(scene).centerStagePath == nil,
              computingPathSceneID != scene.id else { return }
        computingPathSceneID = scene.id
        let camera = WizardDefaults.fallbackFramingCamera
        let sceneID = scene.id
        Task {
            await store.computeCameraPath(sceneID: sceneID, videoID: scene.videoID,
                                          start: scene.startTime, end: scene.endTime,
                                          camera: camera)
            if computingPathSceneID == sceneID { computingPathSceneID = nil }
            // A freshly landed path may belong to an already-approved pick —
            // restitch so the reel preview tracks with it.
            if model.picks.contains(where: { $0.scene.id == sceneID }) {
                rebuildReelPreview()
            }
        }
    }

    /// Follow a trim-handle drag: pause and show the frame under the handle,
    /// then fall back into the trimmed-range loop shortly after the drag ends.
    private func scrub(to time: Double) {
        guard let player else { return }
        isScrubbing = true
        player.pause()
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                    toleranceBefore: tolerance, toleranceAfter: tolerance)
        scrubResumeTask?.cancel()
        scrubResumeTask = Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            resumeLoopPlayback()
        }
    }

    private func resumeLoopPlayback() {
        scrubResumeTask?.cancel()
        scrubResumeTask = nil
        isScrubbing = false
        // A paused preview stays paused on the scrubbed frame.
        guard previewPlaying, let player, let range = model.currentLoopRange else { return }
        player.seek(to: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        player.rate = previewRate
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 12) {
            if model.editingPickID == nil {
                if model.batchIDs.count > 1 {
                    Button {
                        model.cycleBatch(-1)
                    } label: {
                        Label("Prev Analyze Batch", systemImage: "backward.frame")
                    }
                    .help("Jump to the previous analyze batch's footage (wraps around)")
                    Button {
                        model.cycleBatch(1)
                    } label: {
                        Label("Next Analyze Batch", systemImage: "forward.frame")
                    }
                    .help("Jump to the next analyze batch's footage (wraps around)")
                }
                Button {
                    model.goToPreviousProposal()
                } label: {
                    Label("Prev Scene", systemImage: "chevron.backward")
                }
                .disabled(!model.hasPreviousProposal)
                .help("Go back to a scene you skipped")
                Button {
                    model.skipCurrent()
                } label: {
                    Label("Skip Scene", systemImage: "chevron.forward")
                }
                .keyboardShortcut(.delete, modifiers: [])
                .help("Not this one — show the next moment (⌫)")
                Spacer()
                transitionPicker(selection: $model.transitionStyle)
                Button {
                    approveAndCurate()
                } label: {
                    Label("Add to Reel", systemImage: "plus.circle.fill")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help("Approve this clip: it joins the reel AND is saved to Curated Scenes with this trim, then the next moment shows (↩)")
            } else {
                Spacer()
                if let index = model.picks.firstIndex(where: { $0.id == model.editingPickID }) {
                    transitionPicker(selection: $model.picks[index].transition)
                }
                Button("Done Editing") { finishEditingAndSync() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .help("Save the new trim for this approved clip (updates its Curated Scenes entry too)")
            }
        }
    }

    /// The transition applied to the clip being added (or re-edited) —
    /// lives beside Add to Reel so what's selected is what the add uses.
    private func transitionPicker(selection: Binding<String>) -> some View {
        Picker("Transition", selection: selection) {
            Text("Hard cut").tag("cut")
            Text("Crossfade").tag("fade")
            Text("Action mix").tag("action")
        }
        .fixedSize()
        .help("How this clip joins the reel: a straight cut, a soft crossfade, or hard cuts with an action accent (knife slash, zoom punch, whip…) every few gaps. Each added scene keeps the transition selected when it was added.")
    }

    /// Approving does double duty: the clip joins the reel, and the scene is
    /// promoted to the Curated Scenes folder with the user's trim saved as
    /// its range — curation work done here is never lost.
    private func approveAndCurate() {
        if let scene = model.currentScene {
            syncSceneCuration(scene)
        }
        model.approveCurrent()
    }

    private func finishEditingAndSync() {
        if let id = model.editingPickID, let pick = model.picks.first(where: { $0.id == id }) {
            syncSceneCuration(pick.scene)
        }
        model.finishEditingPick()
    }

    private func syncSceneCuration(_ scene: SceneRecord) {
        let rangeChanged = abs(model.editStart - scene.startTime) > 0.05
            || abs(model.editEnd - scene.endTime) > 0.05
        if rangeChanged {
            store.setSceneEditRange(scene, start: model.editStart, end: model.editEnd)
        }
        if !scene.curated {
            store.curateScene(scene, curated: true)
        }
    }

    // MARK: - Fight story (saved research)

    /// Saved fight research for the videos in this wizard's scene pool —
    /// run and edited from Analyze → Fight Research.
    private var poolResearch: [FightResearchRecord] {
        let videoIDs = Set(model.queue.map(\.videoID))
        return videoIDs.compactMap { store.fightResearch[$0] }
            .sorted { $0.fightLabel < $1.fightLabel }
    }

    /// Overlay-text candidates from every fight's research (hooks first).
    private var buzzOverlayLines: [String] {
        var lines: [String] = []
        for record in poolResearch {
            for line in record.overlayLines where !lines.contains(line) {
                lines.append(line)
            }
        }
        return lines
    }

    /// The reel so far as a vertical list in the right column: numbered
    /// rows, drag to reorder, click to re-edit a trim, context-menu to
    /// remove. Replaces the old bottom strip so the player keeps the height.
    private var reelListPane: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your Reel")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .help("Drag to reorder, click to re-trim")
            if model.picks.isEmpty {
                Text("Approved scenes land here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(model.picks.enumerated()), id: \.element.id) { index, pick in
                            reelRow(pick, number: index + 1)
                                .draggable(pick.id.uuidString)
                                .dropDestination(for: String.self) { items, _ in
                                    model.movePick(idString: items.first, before: pick.id)
                                }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
                // Dropping past the last row appends.
                .dropDestination(for: String.self) { items, _ in
                    model.movePick(idString: items.first, before: nil)
                }
            }
        }
        .frame(minHeight: 130)
    }

    private func reelRow(_ pick: CuratedWizardModel.Pick, number: Int) -> some View {
        let isEditing = model.editingPickID == pick.id
        return HStack(spacing: 8) {
            Text("\(number)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .trailing)
            VideoThumbnail(url: pick.scene.videoURL, time: pick.trimStart + 0.1)
                .frame(width: 56, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: "%.1fs", pick.duration))
                    .font(.caption.monospacedDigit())
                Text(pick.scene.videoFilename)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if pick.speed != 1 {
                SpeedBadge(speed: pick.speed, compact: true)
            }
        }
        .padding(4)
        .background(isEditing ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                              : AnyShapeStyle(.quinary),
                    in: RoundedRectangle(cornerRadius: 6))
        .onTapGesture { model.beginEditingPick(pick.id) }
        .contextMenu {
            Button("Re-trim") { model.beginEditingPick(pick.id) }
            Button("Remove from Reel", role: .destructive) { model.removePick(pick.id) }
        }
        .help(pick.scene.videoFilename)
    }

    // MARK: - Step 2: overlays

    @ViewBuilder
    private var overlaysStep: some View {
        HSplitView {
            pickList(subtitle: { pick in
                pick.overlayChoice == CuratedWizardModel.overlayNone
                    ? "No overlay" : "\(pick.overlayChoice): \(pick.overlayText)"
            })
            overlayEditor
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var overlayEditor: some View {
        if let index = model.selectedPickIndex {
            let templates = OverlayTemplateStore.list().map(\.name)
            HStack(alignment: .top, spacing: 16) {
                Form {
                    Picker("Overlay", selection: $model.picks[index].overlayChoice) {
                        Text("None").tag(CuratedWizardModel.overlayNone)
                        Section("Built-in styles") {
                            ForEach(WizardTextStyle.allCases, id: \.rawValue) { style in
                                Text(style.rawValue.capitalized).tag(style.rawValue)
                            }
                        }
                        if !templates.isEmpty {
                            Section("Your templates") {
                                ForEach(templates, id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                        }
                    }
                    if model.picks[index].overlayChoice != CuratedWizardModel.overlayNone {
                        TextField("Text", text: $model.picks[index].overlayText,
                                  prompt: Text("2-6 punchy ALL-CAPS words"))
                        if WizardTextStyle(rawValue: model.picks[index].overlayChoice) != nil {
                            TextField("Kicker", text: $model.picks[index].overlayKicker,
                                      prompt: Text("Optional small label, e.g. ROUND 2"))
                            Picker("Animation", selection: $model.picks[index].overlayAnimation) {
                                Text("Pop").tag("pop")
                                Text("Fade").tag("fade")
                                Text("Slide up").tag("slide_up")
                            }
                        } else {
                            Text("Template overlays render your saved design; the text above replaces its dynamic line.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !buzzOverlayLines.isEmpty {
                        Section {
                            ForEach(buzzOverlayLines, id: \.self) { line in
                                Button(line) {
                                    if model.picks[index].overlayChoice == CuratedWizardModel.overlayNone {
                                        model.picks[index].overlayChoice = WizardTextStyle.impact.rawValue
                                    }
                                    model.picks[index].overlayText = line
                                }
                            }
                        } header: {
                            Text("Fan buzz lines")
                        } footer: {
                            Text("From the Fight Story research on step 1 — click to use as this clip's overlay text.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        if index > 0 {
                            Button {
                                model.copyOverlay(from: index - 1, to: [index])
                            } label: {
                                Label("Copy from Previous", systemImage: "arrow.turn.left.down")
                            }
                            .help("Replace this clip's overlay with the previous clip's overlay, text, kicker, and animation")
                        }
                        if index < model.picks.count - 1 {
                            Button {
                                model.copyOverlay(from: index, to: [index + 1])
                            } label: {
                                Label("Copy to Next", systemImage: "arrow.turn.right.down")
                            }
                            .help("Apply this clip's overlay, text, kicker, and animation to the next clip")
                            Button {
                                model.copyOverlay(from: index,
                                                  to: Array((index + 1)..<model.picks.count))
                            } label: {
                                Label("Copy to All Remaining", systemImage: "square.on.square")
                            }
                            .help("Apply this clip's overlay, text, kicker, and animation to every clip after it")
                        }
                    } header: {
                        Text("Reuse this overlay")
                    } footer: {
                        Text("Copies the overlay style, text, kicker, and animation between clips — the list on the left shows the result immediately.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .frame(maxWidth: 380)

                // The clip plays on repeat with the chosen overlay drawn on
                // top — aspect-filled to approximate the final 9:16 crop. The
                // overlay rides the player's clock, so its enter/exit
                // animation replays with every loop of the clip.
                let pick = model.picks[index]
                let overlayComposition = previewOverlayComposition(for: pick)
                VStack(spacing: 8) {
                    ZStack {
                        if player != nil {
                            PlayerFillView(player: player)
                        } else {
                            VideoThumbnail(url: pick.scene.videoURL,
                                           time: pick.trimStart + 0.1,
                                           cornerRadius: 0)
                        }
                        if let overlayComposition {
                            SwiftUI.TimelineView(.animation) { context in
                                OverlayPreviewCanvas(composition: .constant(overlayComposition),
                                                     selection: .constant(nil),
                                                     time: overlayPreviewTime(for: pick,
                                                                              at: context.date),
                                                     backdrop: false)
                            }
                        }
                    }
                    .aspectRatio(9 / 16, contentMode: .fit)
                    .background(.black, in: RoundedRectangle(cornerRadius: 8))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(maxHeight: .infinity)
                    HStack {
                        previewControls
                        Spacer()
                    }
                }
                .padding(.vertical, 12)
            }
            .padding(.horizontal, 12)
        } else {
            ContentUnavailableView("Select a clip", systemImage: "textformat",
                                   description: Text("Pick a clip on the left to set its text overlay."))
        }
    }

    /// The pick's overlay with built-in style items stretched across the
    /// clip's window — the same timing `buildDocument` renders with — so the
    /// preview shows the real enter animation and end-of-clip fade instead of
    /// hiding the overlay once the item's default window ends.
    private func previewOverlayComposition(for pick: CuratedWizardModel.Pick) -> OverlayComposition? {
        guard var composition = pick.overlayComposition() else { return nil }
        if WizardTextStyle(rawValue: pick.overlayChoice) != nil {
            for index in composition.texts.indices {
                composition.texts[index].startTime = 0
                composition.texts[index].endTime = pick.duration
                composition.texts[index].unbounded = false
            }
        }
        return composition
    }

    /// Where the looping player is on the overlay composition's clock
    /// (0 = clip start, in SCREEN seconds — the player runs source time at
    /// the pick's rate, so elapsed source maps through the speed). Before
    /// the player exists, a wall-clock loop keeps the animation repeating
    /// over the thumbnail.
    private func overlayPreviewTime(for pick: CuratedWizardModel.Pick, at date: Date) -> Double {
        let duration = max(0.5, pick.duration)
        if let player, let range = model.currentLoopRange {
            let elapsed = (player.currentTime().seconds - range.lowerBound) / pick.speed
            return min(max(0, elapsed), duration - 0.01)
        }
        return date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: duration)
    }

    // MARK: - Step 3: music

    @ViewBuilder
    private var musicStep: some View {
        let tracks = WizardEngine.availableMusic().map(\.name)
        VStack(spacing: 0) {
            HStack {
                Menu("Set one soundtrack for the whole reel") {
                    ForEach(tracks, id: \.self) { name in
                        Button(name) { model.setSoundtrackForAll(name) }
                    }
                    Divider()
                    Button("No music anywhere") { model.setSoundtrackForAll(nil) }
                }
                .frame(maxWidth: 340)
                Spacer()
                Text("Or set music per clip below — “Continue previous” keeps the prior clip's track running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            List {
                ForEach($model.picks) { $pick in
                    HStack(spacing: 12) {
                        VideoThumbnail(url: pick.scene.videoURL, time: pick.trimStart + 0.1)
                            .frame(width: 40, height: 56)
                            .overlay(alignment: .bottomTrailing) {
                                if pick.speed != 1 {
                                    SpeedBadge(speed: pick.speed, compact: true)
                                        .padding(2)
                                }
                            }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pick.scene.videoFilename)
                                .lineLimit(1)
                            Text(String(format: "%.1fs", pick.duration))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("Music", selection: $pick.musicChoice) {
                            Text("Continue previous").tag(CuratedWizardModel.musicContinue)
                            Text("No music").tag(CuratedWizardModel.musicNone)
                            Divider()
                            ForEach(tracks, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 260)
                        Picker("Volume", selection: $pick.musicVolume) {
                            ForEach(1...5, id: \.self) { level in
                                Text("\(level)").tag(level)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 140)
                        .disabled(pick.musicChoice == CuratedWizardModel.musicNone)
                        .help("Music volume under this clip (1 quiet – 5 loud)")
                    }
                }
            }
        }
    }

    // MARK: - Step 4: outro

    @ViewBuilder
    private var outroStep: some View {
        let profile = store.activeProfile
        let hasBrandAssets = profile.logoURL != nil
            || !(profile.socials["instagram"]?.handle ?? "").isEmpty
        HSplitView {
            VStack(spacing: 16) {
                Toggle("Append the branded outro card", isOn: $model.includeOutro)
                    .toggleStyle(.switch)
                    .disabled(!hasBrandAssets)
                if hasBrandAssets {
                    if model.includeOutro {
                        OutroCardPreview(profile: profile)
                            .frame(maxHeight: 360)
                        Text("A 2.5s end card with the profile's logo, name, tagline, and follow CTA — faded in from black after the last clip.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("The reel ends on your last clip.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No brand assets set — add a logo or Instagram handle in Settings → Profile to get an outro card.")
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Final check before Generate: run the Exact Preview here and
            // watch precisely the file that Generate will save.
            reelPreviewPane
                .rememberedPaneWidth("pane.curatedWizard.outroPreview", min: 190, initial: 260, max: 320)
                .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Shared pick list (steps 2–3)

    private func pickList(subtitle: @escaping (CuratedWizardModel.Pick) -> String) -> some View {
        List(selection: $model.selectedPickID) {
            ForEach(model.picks) { pick in
                HStack(spacing: 10) {
                    VideoThumbnail(url: pick.scene.videoURL, time: pick.trimStart + 0.1)
                        .frame(width: 40, height: 56)
                        .overlay(alignment: .bottomTrailing) {
                            if pick.speed != 1 {
                                SpeedBadge(speed: pick.speed, compact: true)
                                    .padding(2)
                            }
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pick.scene.videoFilename)
                            .lineLimit(1)
                        Text(subtitle(pick))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .tag(pick.id)
            }
        }
        .rememberedPaneWidth("pane.curatedWizard.pickList", min: 240, initial: 280, max: 340)
    }

    // MARK: - Preview player

    /// Playback rate for the proposal/overlay preview: the live speed edit
    /// in step 1, the pick's saved speed in the overlay step.
    private var previewRate: Float {
        switch model.step {
        case .scenes: return Float(model.editSpeed)
        case .overlays: return Float(model.selectedPickIndex.map { model.picks[$0].speed } ?? 1)
        default: return 1
        }
    }

    /// Pause/mute buttons shown under every surface driven by the
    /// proposal/overlay preview player.
    private var previewControls: some View {
        HStack(spacing: 10) {
            Button {
                previewPlaying.toggle()
                if previewPlaying { player?.rate = previewRate } else { player?.pause() }
            } label: {
                Image(systemName: previewPlaying ? "pause.fill" : "play.fill")
            }
            .help(previewPlaying ? "Pause the preview" : "Play the preview")
            Button {
                previewMuted.toggle()
                player?.isMuted = previewMuted
            } label: {
                Image(systemName: previewMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .help(previewMuted ? "Unmute the preview" : "Mute the preview")
        }
    }

    /// (Re)load the player whenever the previewed scene changes, and keep
    /// playback looping inside the active range (the live trim in step 1,
    /// the pick's saved trim in the overlay step).
    private func syncPlayer() {
        teardownPlayer()
        guard let scene = model.previewScene, let range = model.currentLoopRange else { return }
        let newPlayer = AVPlayer(url: scene.videoURL)
        newPlayer.isMuted = previewMuted
        player = newPlayer
        newPlayer.seek(to: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                       toleranceBefore: .zero, toleranceAfter: .zero)
        if previewPlaying { newPlayer.rate = previewRate }
        // The observer reads the CURRENT bounds each tick, so dragging the
        // trim handles immediately re-scopes the loop.
        loopObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { time in
            Task { @MainActor in
                guard let player = self.player, !self.isScrubbing,
                      let range = model.currentLoopRange else { return }
                // Track native-control mute changes as they happen.
                if player.isMuted != self.previewMuted {
                    self.previewMuted = player.isMuted
                }
                let seconds = time.seconds
                if seconds >= range.upperBound || seconds < range.lowerBound - 0.5 {
                    player.seek(to: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                                toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        }
    }

    private func teardownPlayer() {
        // The proposal player shows native controls — pausing or muting
        // there bypasses our state, so read the player's actual state before
        // letting it go and the next video starts the same way.
        if let player {
            previewMuted = player.isMuted
            if !isScrubbing {
                previewPlaying = player.rate > 0
            }
        }
        scrubResumeTask?.cancel()
        scrubResumeTask = nil
        isScrubbing = false
        if let loopObserver, let player {
            player.removeTimeObserver(loopObserver)
        }
        loopObserver = nil
        player?.pause()
        player = nil
    }
}

/// Chrome-less aspect-FILL player layer: the wide source center-crops into
/// the 9:16 stage, approximating what the render's portrait crop shows —
/// AVPlayerView can only aspect-fit.
private struct PlayerFillView: NSViewRepresentable {
    let player: AVPlayer?

    final class LayerView: NSView {
        let playerLayer = AVPlayerLayer()

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspectFill
            layer = playerLayer
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("unavailable") }
    }

    func makeNSView(context: Context) -> LayerView { LayerView() }

    func updateNSView(_ view: LayerView, context: Context) {
        view.playerLayer.player = player
    }
}

/// The 1–4 step chips in the sheet header.
private struct StepIndicator: View {
    let current: CuratedWizardModel.Step

    var body: some View {
        HStack(spacing: 6) {
            ForEach(CuratedWizardModel.Step.allCases, id: \.self) { step in
                Text("\(step.number). \(step.title)")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(step == current ? AnyShapeStyle(Color.accentColor.opacity(0.2))
                                                : AnyShapeStyle(.quinary),
                                in: Capsule())
                    .foregroundStyle(step == current ? .primary : .secondary)
            }
        }
    }
}

/// Renders the profile's outro card PNG (same drawing the renderer burns)
/// for an honest preview.
private struct OutroCardPreview: View {
    let profile: BrandProfile
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.black)
                    .aspectRatio(9 / 16, contentMode: .fit)
                ProgressView()
            }
        }
        .task(id: profile.profileName) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("CuratedOutroPreview", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let url = BrandRenderer.outroCard(profile: profile, to: directory) {
                image = NSImage(contentsOf: url)
            }
        }
    }
}

// MARK: - Model

/// All curated-wizard state: the proposal queue, approved picks with their
/// edits, the current step, and the final TimelineDocument assembly.
@MainActor @Observable
final class CuratedWizardModel {
    enum Step: Int, CaseIterable {
        case scenes, overlays, music, outro

        var number: Int { rawValue + 1 }
        var title: String {
            switch self {
            case .scenes: return "Scenes"
            case .overlays: return "Overlays"
            case .music: return "Music"
            case .outro: return "Outro"
            }
        }
    }

    /// Sentinel music choices (real track names never collide with these).
    static let musicContinue = "\u{0}continue"
    static let musicNone = "\u{0}none"
    static let overlayNone = "\u{0}none"

    struct Pick: Identifiable, Equatable {
        let id = UUID()
        var scene: SceneRecord
        var trimStart: Double         // absolute source seconds
        var trimEnd: Double
        /// Playback speed (1 = normal): 0.5/0.75 slow motion, 1.5/2 speed-up.
        var speed: Double = 1
        var centerStage: Bool = false
        /// Transition INTO this clip — captured from the picker at approval
        /// time (cut | fade | action), so each add keeps what was selected.
        var transition: String = "cut"
        var overlayChoice: String = CuratedWizardModel.overlayNone
        var overlayText: String = ""
        var overlayKicker: String = ""
        var overlayAnimation: String = "pop"
        var musicChoice: String = CuratedWizardModel.musicContinue
        var musicVolume: Int = 3

        /// Source seconds this pick consumes.
        var sourceSpan: Double { trimEnd - trimStart }
        /// Screen seconds — slow motion stretches the source span, a
        /// speed-up shrinks it. All timeline math uses this.
        var duration: Double { sourceSpan / speed }

        /// The overlay this pick renders with, built the same way the AI
        /// wizard's planner output is turned into overlays. Nil = none.
        func overlayComposition() -> OverlayComposition? {
            guard overlayChoice != CuratedWizardModel.overlayNone else { return nil }
            let text = overlayText.trimmingCharacters(in: .whitespacesAndNewlines)
            if var composition = OverlayTemplateStore.composition(named: overlayChoice) {
                for index in composition.texts.indices {
                    composition.texts[index].uid = UUID()
                    if composition.texts[index].isDynamic, !text.isEmpty {
                        composition.texts[index].text = text
                    }
                }
                for index in composition.images.indices {
                    composition.images[index].uid = UUID()
                }
                return composition
            }
            guard let style = WizardTextStyle(rawValue: overlayChoice), !text.isEmpty else { return nil }
            let kicker = overlayKicker.trimmingCharacters(in: .whitespacesAndNewlines)
            var item = style.overlayItem(text: text, kicker: kicker.isEmpty ? nil : kicker)
            item.transIn = overlayAnimation
            item.transOut = "fade"
            return OverlayComposition(texts: [item])
        }
    }

    var targetDuration: Double
    var includeOutro: Bool
    var step: Step = .scenes
    /// The picker's live value — stamped onto each pick as it's approved.
    var transitionStyle = "cut"       // cut | fade | action

    private(set) var queue: [SceneRecord]
    private var position = 0
    /// Analyze batches present in the queue, in queue order. The proposal
    /// walk is scoped to `activeBatchID` when there's more than one; each
    /// batch remembers its own place.
    private let batchNames: [Int64: String]
    private(set) var batchIDs: [Int64] = []
    private(set) var activeBatchID: Int64?
    private var savedPositions: [Int64: Int] = [:]
    var picks: [Pick] = []
    /// Approved pick being re-trimmed from the timeline strip (nil = the
    /// queue proposal is showing).
    var editingPickID: UUID?
    var selectedPickID: UUID?

    // Live trim state for whatever the player is showing.
    var editStart: Double = 0
    var editEnd: Double = 0
    var editCenterStage = false
    var editSpeed: Double = 1

    init(queue: [SceneRecord], targetDuration: Double, includeOutro: Bool,
         batchNames: [Int64: String] = [:],
         selectedBatchIDs: [Int64] = []) {
        self.queue = queue
        self.targetDuration = max(3, targetDuration)
        self.includeOutro = includeOutro
        self.batchNames = batchNames
        // Every batch the user SELECTED stays listed — even ones the filters
        // emptied out, so they can see why nothing is proposed from them.
        var ids = selectedBatchIDs
        var seen = Set(ids)
        for scene in queue {
            if let runID = scene.runID, seen.insert(runID).inserted {
                ids.append(runID)
            }
        }
        batchIDs = ids
        if batchIDs.count > 1 {
            let populated = Set(queue.compactMap(\.runID))
            activeBatchID = batchIDs.first(where: populated.contains) ?? batchIDs.first
        } else {
            activeBatchID = nil
        }
        seedEditState()
    }

    // MARK: Batches

    /// The proposal source: the active batch's scenes, or everything when a
    /// single batch (or none) is in play.
    private var activeQueue: [SceneRecord] {
        guard let activeBatchID else { return queue }
        return queue.filter { $0.runID == activeBatchID }
    }

    func batchName(_ id: Int64) -> String {
        batchNames[id] ?? "Analyze Batch \(id)"
    }

    /// Whether the pool contains anything from this batch at all (false =
    /// the Source Selection filters matched none of its scenes).
    func batchHasProposals(_ id: Int64) -> Bool {
        queue.contains { $0.runID == id }
    }

    /// The active batch contributed nothing to the queue (as opposed to
    /// having been reviewed to the end).
    var activeBatchIsEmpty: Bool {
        activeQueue.isEmpty
    }

    func switchBatch(to id: Int64) {
        guard id != activeBatchID, batchIDs.contains(id) else { return }
        if let current = activeBatchID { savedPositions[current] = position }
        activeBatchID = id
        position = savedPositions[id] ?? 0
        editingPickID = nil
        advancePastPicked()
        seedEditState()
    }

    /// Next (+1) / previous (−1) batch, wrapping around.
    func cycleBatch(_ delta: Int) {
        guard batchIDs.count > 1, let current = activeBatchID,
              let index = batchIDs.firstIndex(of: current) else { return }
        let count = batchIDs.count
        switchBatch(to: batchIDs[(index + delta + count) % count])
    }

    // MARK: Proposal navigation

    private var pickedSceneIDs: Set<Int64> { Set(picks.map(\.scene.id)) }

    /// Merged picked source intervals per video — the footage the reel
    /// already contains, with overlapping trims collapsed.
    private var pickedIntervalsByVideo: [Int64: [(start: Double, end: Double)]] {
        var byVideo: [Int64: [(start: Double, end: Double)]] = [:]
        for pick in picks {
            byVideo[pick.scene.videoID, default: []].append((pick.trimStart, pick.trimEnd))
        }
        return byVideo.mapValues { intervals in
            var merged: [(start: Double, end: Double)] = []
            for interval in intervals.sorted(by: { $0.start < $1.start }) {
                if let last = merged.last, interval.start <= last.end {
                    merged[merged.count - 1].end = max(last.end, interval.end)
                } else {
                    merged.append(interval)
                }
            }
            return merged
        }
    }

    /// Whether a scene is off the proposal walk: approved itself, or its
    /// footage is already in the reel — at least half its range lies inside
    /// approved picks of the same video. That drops sub-scenes of a longer
    /// approved clip and re-offers of a moment whose trim was widened, and
    /// (being computed live) brings proposals back when a pick is removed.
    private func proposalExclusionTest() -> (SceneRecord) -> Bool {
        let picked = pickedSceneIDs
        let intervals = pickedIntervalsByVideo
        return { scene in
            if picked.contains(scene.id) { return true }
            guard let ranges = intervals[scene.videoID] else { return false }
            let duration = max(0.1, scene.endTime - scene.startTime)
            var covered = 0.0
            for range in ranges {
                covered += max(0, min(range.end, scene.endTime) - max(range.start, scene.startTime))
            }
            return covered / duration >= 0.5
        }
    }

    /// Unapproved scenes still on offer from the active batch, in queue
    /// order — the proposal carousel across the top of the scenes step.
    var proposalList: [SceneRecord] {
        let excluded = proposalExclusionTest()
        return activeQueue.filter { !excluded($0) }
    }

    /// Jump the proposal walk straight to a scene tapped in the carousel
    /// (finishing any pick re-edit first, so its trim isn't lost).
    func jumpToProposal(_ sceneID: Int64) {
        guard step == .scenes else { return }
        if editingPickID != nil { finishEditingPick() }
        let excluded = proposalExclusionTest()
        guard let index = activeQueue.firstIndex(where: { $0.id == sceneID }),
              let scene = activeQueue.first(where: { $0.id == sceneID }),
              !excluded(scene) else { return }
        position = index
        seedEditState()
    }

    /// The scene the player shows: an approved pick under re-edit, or the
    /// queue's current proposal.
    var currentScene: SceneRecord? {
        if let editingPickID, let pick = picks.first(where: { $0.id == editingPickID }) {
            return pick.scene
        }
        return proposal(at: position)
    }

    var currentRange: ClosedRange<Double>? {
        guard let scene = currentScene else { return nil }
        return scene.startTime...scene.endTime
    }

    /// Identity of what's previewed — drives player reloads.
    var previewKey: String {
        switch step {
        case .scenes:
            if let editingPickID { return "pick-\(editingPickID)" }
            return currentScene.map { "scene-\($0.id)" } ?? "none"
        case .overlays:
            return selectedPickID.map { "overlay-\($0)" } ?? "off"
        default:
            return "off"
        }
    }

    /// The scene the preview player shows: the step-1 proposal, or the pick
    /// selected in the overlay step (playing under its overlay).
    var previewScene: SceneRecord? {
        switch step {
        case .scenes: return currentScene
        case .overlays: return selectedPickIndex.map { picks[$0].scene }
        default: return nil
        }
    }

    /// Absolute source range the preview loops.
    var currentLoopRange: ClosedRange<Double>? {
        switch step {
        case .scenes:
            guard currentScene != nil else { return nil }
            return editStart...max(editEnd, editStart + 0.1)
        case .overlays:
            guard let index = selectedPickIndex else { return nil }
            let pick = picks[index]
            return pick.trimStart...max(pick.trimEnd, pick.trimStart + 0.1)
        default:
            return nil
        }
    }

    private func proposal(at index: Int) -> SceneRecord? {
        let list = activeQueue
        guard index >= 0, index < list.count else { return nil }
        let excluded = proposalExclusionTest()
        // Skip over scenes that were approved already or whose footage the
        // reel now covers.
        for scene in list[index...] where !excluded(scene) {
            return scene
        }
        return nil
    }

    var remainingProposals: Int {
        let list = activeQueue
        let excluded = proposalExclusionTest()
        guard position < list.count else { return 0 }
        return list[position...].count { !excluded($0) }
    }

    var hasPreviousProposal: Bool {
        let list = activeQueue
        let excluded = proposalExclusionTest()
        return list[..<min(position, list.count)].contains { !excluded($0) }
    }

    private func seedEditState() {
        guard let scene = currentScene else { return }
        if let editingPickID, let pick = picks.first(where: { $0.id == editingPickID }) {
            editStart = pick.trimStart
            editEnd = pick.trimEnd
            editCenterStage = pick.centerStage
            editSpeed = pick.speed
        } else {
            editStart = scene.startTime
            editEnd = scene.endTime
            // A scene's reviewed framing is its default. Users can still turn
            // it on here to compute a path for an unframed wide scene.
            editCenterStage = scene.wide && scene.centerStagePath != nil
            editSpeed = 1
        }
    }

    func skipCurrent() {
        guard editingPickID == nil else { return }
        position += 1
        advancePastPicked()
        seedEditState()
    }

    func goToPreviousProposal() {
        guard editingPickID == nil else { return }
        let list = activeQueue
        let excluded = proposalExclusionTest()
        var index = position - 1
        while index >= 0 {
            if index < list.count, !excluded(list[index]) { break }
            index -= 1
        }
        guard index >= 0 else { return }
        position = index
        seedEditState()
    }

    func approveCurrent() {
        guard editingPickID == nil, let scene = currentScene else { return }
        var pick = Pick(scene: scene, trimStart: editStart, trimEnd: editEnd)
        pick.speed = editSpeed
        pick.centerStage = editCenterStage && scene.wide
        pick.transition = transitionStyle
        picks.append(pick)
        advancePastPicked()
        seedEditState()
    }

    private func advancePastPicked() {
        let list = activeQueue
        let excluded = proposalExclusionTest()
        while position < list.count, excluded(list[position]) {
            position += 1
        }
    }

    // MARK: Approved-pick editing

    func beginEditingPick(_ id: UUID) {
        guard step == .scenes else { return }
        editingPickID = id
        seedEditState()
    }

    func finishEditingPick() {
        guard let id = editingPickID,
              let index = picks.firstIndex(where: { $0.id == id }) else {
            editingPickID = nil
            return
        }
        picks[index].trimStart = editStart
        picks[index].trimEnd = editEnd
        picks[index].speed = editSpeed
        picks[index].centerStage = editCenterStage && picks[index].scene.wide
        editingPickID = nil
        seedEditState()
    }

    func removePick(_ id: UUID) {
        picks.removeAll { $0.id == id }
        if editingPickID == id { editingPickID = nil }
        if selectedPickID == id { selectedPickID = nil }
        seedEditState()
    }

    func movePick(idString: String?, before targetID: UUID?) -> Bool {
        guard let idString, let id = UUID(uuidString: idString),
              let from = picks.firstIndex(where: { $0.id == id }) else { return false }
        let pick = picks.remove(at: from)
        if let targetID, let to = picks.firstIndex(where: { $0.id == targetID }) {
            picks.insert(pick, at: to)
        } else {
            picks.append(pick)
        }
        return true
    }

    var totalDuration: Double { picks.reduce(0) { $0 + $1.duration } }

    /// Copy one pick's overlay configuration (style, text, kicker,
    /// animation) onto other picks.
    func copyOverlay(from source: Int, to targets: [Int]) {
        guard picks.indices.contains(source) else { return }
        let template = picks[source]
        for target in targets where picks.indices.contains(target) && target != source {
            picks[target].overlayChoice = template.overlayChoice
            picks[target].overlayText = template.overlayText
            picks[target].overlayKicker = template.overlayKicker
            picks[target].overlayAnimation = template.overlayAnimation
        }
    }

    /// Music step convenience: first clip gets the track (or explicit "no
    /// music"), the rest continue it — one soundtrack across the reel.
    func setSoundtrackForAll(_ track: String?) {
        for index in picks.indices {
            picks[index].musicChoice = index == 0
                ? (track ?? Self.musicNone)
                : Self.musicContinue
        }
    }

    var selectedPickIndex: Int? {
        selectedPickID.flatMap { id in picks.firstIndex { $0.id == id } }
    }

    // MARK: Step navigation

    func goForward() {
        if step == .scenes, editingPickID != nil { finishEditingPick() }
        if let next = Step(rawValue: step.rawValue + 1) {
            step = next
            if selectedPickID == nil { selectedPickID = picks.first?.id }
        }
    }

    func goBack() {
        if let previous = Step(rawValue: step.rawValue - 1) {
            step = previous
        }
    }

    // MARK: Document assembly

    /// Every approved pick becomes a sequential Builder clip; overlays land
    /// as blocks/items in the clip's window; consecutive music choices merge
    /// into sound-track blocks. The outro card is appended at render time
    /// (AppStore) so this document stays portable.
    func buildDocument() -> TimelineDocument {
        var document = TimelineDocument()
        var cursor = 0.0
        let accents = ["zoom_punch", "knife_slash", "whip_left", "flash_white", "impact_shake"]
        var accentIndex = 0
        for (index, pick) in picks.enumerated() {
            var clip = TimelineClip()
            clip.sceneID = pick.scene.id
            clip.videoFile = pick.scene.videoPath
            clip.sourceStart = pick.trimStart
            clip.sourceEnd = pick.trimEnd
            clip.startTime = (cursor * 10).rounded() / 10
            clip.duration = (pick.duration * 10).rounded() / 10
            clip.speed = pick.speed == 1 ? nil : pick.speed
            clip.sceneFullDuration = (pick.scene.duration * 10).rounded() / 10
            clip.wide = pick.scene.wide
            // Wide clips always carry a crop: without one the Builder
            // renderer letterboxes them into a slot band, but the reel
            // preview shows a full-frame centered 9:16 crop — pin the
            // centered crop so the render matches the preview.
            clip.cropXFrac = pick.scene.cropXFrac ?? (pick.scene.wide ? 0.5 : nil)
            clip.centerStage = pick.centerStage
            if let json = pick.scene.freeCropsJSON, let data = json.data(using: .utf8),
               let crops = try? JSONDecoder().decode([FreeCrop].self, from: data), !crops.isEmpty {
                clip.freeCrops = crops
            }
            if index > 0 {
                switch pick.transition {
                case "fade":
                    clip.transIn = "fade"
                case "action" where index % 3 == 0:
                    clip.transIn = accents[accentIndex % accents.count]
                    accentIndex += 1
                default:
                    clip.transIn = nil
                }
            }
            document.videoTrack.append(clip)

            if let composition = pick.overlayComposition() {
                if OverlayTemplateStore.composition(named: pick.overlayChoice) != nil {
                    var block = OverlayBlockItem()
                    block.name = pick.overlayChoice
                    block.composition = composition
                    block.startTime = clip.startTime
                    block.duration = clip.duration
                    document.overlayBlocks.append(block)
                } else if var item = composition.texts.first {
                    item.startTime = clip.startTime
                    item.endTime = clip.startTime + clip.duration
                    item.unbounded = false
                    document.textOverlays.append(item)
                }
            }
            cursor += clip.duration
        }

        // Music: walk the picks resolving "continue previous", then merge
        // consecutive same-track same-volume stretches into single blocks.
        var soundCursor = 0.0
        var activeTrack: String?
        for pick in picks {
            switch pick.musicChoice {
            case Self.musicNone: activeTrack = nil
            case Self.musicContinue: break
            default: activeTrack = pick.musicChoice
            }
            let clipDuration = (pick.duration * 10).rounded() / 10
            if let track = activeTrack {
                if var last = document.soundTrack.last, last.name == track,
                   last.volume == pick.musicVolume,
                   abs(last.startTime + last.duration - soundCursor) < 0.05 {
                    last.duration += clipDuration
                    document.soundTrack[document.soundTrack.count - 1] = last
                } else {
                    document.soundTrack.append(SoundItem(name: track, volume: pick.musicVolume,
                                                         startTime: soundCursor,
                                                         duration: clipDuration))
                }
            }
            soundCursor += clipDuration
        }
        return document
    }
}
