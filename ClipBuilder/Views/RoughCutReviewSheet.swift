import AVKit
import SwiftUI

/// The rough cut job's result: a player per cut, so framing and focus can be
/// checked in motion, beside the framing controls the cut was made with.
/// Preview opens it with the cuts prepared but not rendered: a still of the
/// settings covers each picture and Play renders. Likewise
/// once a setting changes, a still with the new settings covers the picture
/// at the playhead and Play renders the same takes again with the edited
/// framing, effect and transition, swaps the new cuts into this same sheet
/// and plays the one asked for. Apply hands the framing to the page it came
/// from, Discard changes nothing. The cuts are small and plain by design
/// (docs/Rough-Cut-Plan.md); nothing is saved. From Express the controls
/// have a second tab, Overlays, with the page's own overlay rows bound to
/// a copy of its settings: the still over each picture shows them, their
/// handles can be dragged there, Play renders them and Apply hands them to
/// the page with the framing (docs/Rough-Cut-Overlays-Plan.md).
struct RoughCutReviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// The job whose result is on screen; a render from Play moves it to the new job.
    @State private var jobID: UUID
    @State private var review: RoughCutReview
    @State private var framing: Framing
    /// Effect and transition for the next render; none unless chosen here.
    @State private var extras: RoughCutExtras
    /// Effect presets the local ffmpeg can render; every preset until probed.
    @State private var availableLookIDs: Set<String>?
    @State private var players: [String: AVPlayer] = [:]
    @State private var aspects: [String: CGFloat] = [:]
    @State private var loadingTask: Task<Void, Never>?
    @State private var posterTasks: [Task<Void, Never>] = []
    @State private var isVisible = false
    /// The render job this sheet is waiting for, started by Play on a stale cut.
    @State private var pendingJobID: UUID?
    /// Which take Play asked for; a failed take must not play its neighbour.
    @State private var playAfterRender: Int64?
    /// Picture or Overlays, remembered across sheets.
    @AppStorage("roughCut.settings.tab") private var tabRaw = WizardSettingsTab.picture.rawValue

    /// Wide enough for the framing rows' label column, a segmented picker
    /// and a short detail; the rows never spill past the sheet.
    private static let controlsWidth: CGFloat = 480
    /// The Overlays tab's speaker rows (name, position, style) need more.
    private static let controlsWidthWithOverlays: CGFloat = 720
    private var controlsWidth: CGFloat { hasOverlays ? Self.controlsWidthWithOverlays : Self.controlsWidth }
    /// Under each player: its transport and speed rows, its caption and the grid's spacing.
    private static let playerChromeHeight: CGFloat = 100

    init(jobID: UUID, review: RoughCutReview) {
        _jobID = State(initialValue: jobID)
        _review = State(initialValue: review)
        _framing = State(initialValue: review.framing)
        _extras = State(initialValue: review.extras)
    }

    /// The request's options as the rough cut renders them, with the
    /// sheet's framing and effect: what the still over a stale cut shows.
    private var previewOptions: WizardOptions? {
        guard var options = store.roughCutRequests[review.requestID]?.options else { return nil }
        options.framing = framing
        return WizardRoughCut.options(options, extras: extras)
    }

    private var idealSize: CGSize {
        let players = WizardResultsLayout.idealSize(count: review.cuts.count,
            cardSize: CGSize(width: WizardResultsLayout.minCardWidth, height: 720),
            screen: NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900))
        return CGSize(width: players.width + controlsWidth, height: players.height)
    }
    private var framingChanged: Bool { framing != review.framing || extras != review.extras }
    /// The picture does not show the settings: not rendered yet, or rendered with other settings.
    private var stale: Bool { framingChanged || !review.isRendered }
    /// Express's cut carries its Overlays tab; the full wizard's stays plain.
    private var hasOverlays: Bool { review.namespace == WizardAssistant.expressNamespace && extras.overlays != nil }
    private var tabs: [WizardSettingsTab] { hasOverlays ? [.picture, .overlays] : [.picture] }
    private var tab: WizardSettingsTab { (WizardSettingsTab(rawValue: tabRaw) ?? .picture).effective(in: tabs) }
    /// The Overlays tab edits in the picture: the still covers the cut and its handles are live.
    private var editsOverlays: Bool { hasOverlays && tab == .overlays && !busy && pendingJob == nil }
    /// The Picture tab places the focus frame in the picture: the still
    /// covers the paused cut with the frame's handle live. The wizard pages
    /// only play the recording, so this is where the frame is drawn.
    private var editsFocus: Bool {
        tab == .picture && framing.subject != .layout && !busy && pendingJob == nil
    }
    /// The Overlays tab's settings; a plain cut never reads this.
    private var overlaySettings: Binding<MiniWizardSettings> {
        Binding(get: { extras.overlays?.settings ?? MiniWizardSettings() },
                set: { extras.overlays?.settings = $0 })
    }
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
                Text(hasOverlays
                    ? "Framing, focus and overlays, small. Left out: \(WizardRoughCut.leftOut(overlays: true)). Change the settings and press play to see them in motion; Apply puts the framing and the overlays on the page."
                    : "Framing and focus only, small and plain. Left out: \(WizardRoughCut.leftOut). Change the settings and press play to see them in motion; Apply puts the framing on the page.")
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
                                    ScrubbingPlayerView(player: players[cut.id], aspect: size.width / max(1, size.height),
                                                        stale: stale, onPlayStale: { render(thenPlay: cut.takeID) },
                                                        hidesOverlayWhilePlaying: true,
                                                        pictureOverlay: { time in still(for: cut, at: time) },
                                                        pictureChrome: safeAreaShading(in: size))
                                        .frame(width: size.width)
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
                    .frame(width: controlsWidth)
            }

            HStack {
                if pendingJob != nil {
                    Text("Rendering the rough cut again with the settings on the right.")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                } else if !review.isRendered {
                    Text("Press play to render the rough cut with the settings on the right; Apply keeps \(kept).")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                } else if framingChanged {
                    Text("Settings changed. Press play to render a cut with them; Apply keeps \(kept).")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                } else if editsOverlays {
                    Text("Drag a caption, name tag or overlay item on the picture to place it.")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                } else if editsFocus {
                    Text("Drag the focus frame on the picture to move it, or a grip to resize it.")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer()
                Button("Discard") { finish() }
                    .keyboardShortcut(.cancelAction)
                    .help(hasOverlays ? "Close without changing the page's framing or overlays" : "Close without changing the page's framing")
                Button("Apply") {
                    send(WizardAssistant.applyFramingAction)
                }
                .keyboardShortcut(.defaultAction)
                .help(hasOverlays ? "Make the framing and overlays on the right the page's" : "Make the framing on the right the page's framing")
            }
            .padding()
        }
        .frame(minWidth: 420 + controlsWidth, idealWidth: idealSize.width, maxWidth: .infinity,
               minHeight: 480, idealHeight: idealSize.height, maxHeight: .infinity)
        .presentationSizing(.fitted)
        .modalCloseButton { finish() }
        .onAppear {
            isVisible = true
            loadingTask = Task { await loadPlayers() }
        }
        .onChange(of: pendingJob) { _, job in
            guard isVisible else { return }
            // Gone from the list (an empty result is removed at once) or finished.
            guard let job else { pendingJobID = nil; playAfterRender = nil; return }
            guard job.status != .running else { return }
            pendingJobID = nil
            // A failed or stopped run reports through the status bar; the
            // sheet keeps the cuts it has.
            guard job.status == .done, case .roughCut(let next)? = job.result else { playAfterRender = nil; return }
            adopt(next, from: job.id)
        }
        .onDisappear {
            isVisible = false
            stopPlayers()
        }
        .onChange(of: store.profileGeneration) { _, _ in finish() }
    }

    /// Play on a stale cut: render every cut again with the settings on
    /// the right, then play the one asked for. The job reports through the
    /// status bar as well; a second press while it runs changes nothing.
    private func render(thenPlay takeID: Int64?) {
        guard pendingJobID == nil else { return }
        guard !busy else {
            store.presentNotice("Rough cut", "The Wizard is already working on this project.")
            return
        }
        for player in players.values { player.pause() }
        playAfterRender = takeID
        pendingJobID = store.rerunRoughCut(requestID: review.requestID, framing: framing, extras: extras)
        if pendingJobID == nil { playAfterRender = nil }
    }

    /// Over a stale cut's picture: the kept footage at the playhead with the
    /// settings on the right, so a change shows before the cut is rendered.
    /// On the Overlays tab it covers the paused picture whatever the cut's
    /// state, with the page's drag handles live, so captions, name tags and
    /// the overlay's items can be placed on the cut itself; it lifts while
    /// the cut plays.
    @ViewBuilder
    private func still(for cut: RoughCut, at time: Double) -> some View {
        if stale || editsOverlays || editsFocus, let previewOptions, let takeID = cut.takeID,
           let moment = WizardPreviewClips.moment(in: WizardPreviewClips.clips(review.previewClips, ofTake: takeID), at: time) {
            pinnedStill(options: previewOptions, moment: moment)
        }
    }

    /// The unsafe platform zones over the player's picture whenever the
    /// overlays' Safe area only is on: on the picture itself, not in the
    /// still, so it stays while the cut plays and when the still is not shown.
    private func safeAreaShading(in playerSize: CGSize) -> AnyView? {
        guard hasOverlays, let previewOptions, previewOptions.safeAreaOnly == true,
              let safeArea = previewOptions.resolvedSafeArea else { return nil }
        // The player frame can be taller than the letterboxed picture inside
        // it, so the zones are fitted to the canvas aspect; the overlay
        // centres them on the picture.
        let aspect = max(0.01, previewOptions.renderSettings.aspectRatio)
        let fitted = playerSize.width / max(1, playerSize.height) > aspect
            ? CGSize(width: playerSize.height * aspect, height: playerSize.height)
            : CGSize(width: playerSize.width, height: playerSize.width / aspect)
        return AnyView(PlatformChromeLayer(size: fitted,
                                           safeAreaSettings: previewOptions.renderSettings.platformSafeArea,
                                           safeAreaOnly: safeArea))
    }

    private func pinnedStill(options: WizardOptions, moment: WizardPreviewMoment) -> some View {
        let editing = editsOverlays || editsFocus
        var onMove: ((PreviewElement, CustomPosition) -> Void)?
        var onPlaceOverlay: ((OverlayComponent, CGRect) -> Void)?
        var onPlaceFocusFrame: ((FreeCropRect?) -> Void)?
        if editsOverlays {
            onMove = { element, position in moveOverlayElement(element, position) }
            onPlaceOverlay = { component, box in placeOverlayComponent(component, box) }
        }
        if editsFocus {
            onPlaceFocusFrame = { frame in framing.focusFrame = frame }
        }
        let label: String = editsOverlays ? "Preview of the settings at this moment; drag a caption, name tag or overlay item to place it"
            : editsFocus ? "Preview of the framing at this moment; drag the focus frame to move it, or a grip to resize it"
            : "Preview of the changed settings at this moment"
        return WizardPreviewColumn(scenes: review.previewClips.map(\.scene), clips: review.previewClips,
                                   options: options, profile: store.activeProfile,
                                   thumbnails: store.thumbnails, onMove: onMove, onPlaceOverlay: onPlaceOverlay,
                                   onPlaceFocusFrame: onPlaceFocusFrame, pinned: moment)
            .clipShape(RoundedRectangle(cornerRadius: Theme.mediaRadius))
            .allowsHitTesting(editing)
            .accessibilityLabel(label)
    }

    /// An overlay text or image moved or resized on the still.
    private func placeOverlayComponent(_ component: OverlayComponent, _ box: CGRect) {
        var settings = overlaySettings.wrappedValue
        settings.overlayEdits.place(component, at: box)
        overlaySettings.wrappedValue = settings
    }

    /// A caption or name tag dropped on the still, as on the Express page.
    private func moveOverlayElement(_ element: PreviewElement, _ position: CustomPosition) {
        var settings = overlaySettings.wrappedValue
        switch element {
        case .caption(let slot):
            if let slot {
                var positions = settings.speakerCaptionPositions ?? [:]
                positions[slot] = position.string
                settings.speakerCaptionPositions = positions
            } else { settings.captionPosition = position.string }
        case .nameTag(let person): store.setPersonTagPosition(person, position.string)
        }
        overlaySettings.wrappedValue = settings
    }

    /// What Apply keeps, for the footer.
    private var kept: String { hasOverlays ? "the framing and overlays" : "the framing" }

    /// Over the players while Play renders: progress, the job's
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
        stopPlayers()
        store.jobs.markReviewed(jobID)
        jobID = newJobID
        review = next
        let playTakeID = framingChanged ? nil : playAfterRender
        playAfterRender = nil
        loadingTask = Task { await loadPlayers(playTakeID: playTakeID) }
    }

    private func stopPlayers() {
        loadingTask?.cancel()
        loadingTask = nil
        for task in posterTasks { task.cancel() }
        posterTasks = []
        for player in players.values { player.pause() }
        players = [:]
        aspects = [:]
    }

    private func loadPlayers(playTakeID: Int64? = nil) async {
        let cuts = review.cuts
        let playCut = playTakeID.flatMap { review.cut(forTake: $0) }
        for cut in cuts {
            guard !Task.isCancelled, isVisible, review.cuts == cuts else { return }
            guard let url = cut.url else { continue }
            let asset = AVURLAsset(url: url)
            let aspect = try? await Self.aspect(of: asset)
            guard !Task.isCancelled, isVisible, review.cuts == cuts else { return }
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.setReviewSpeed(PlaybackSpeed.stored())
            players[cut.id] = player
            if let aspect { aspects[cut.id] = aspect }
            if cut.id == playCut?.id, !framingChanged {
                // Play on a stale cut: the new cut plays as soon as it can.
                player.play()
            } else {
                // A paused player that never played shows nothing; once the item
                // is ready, a muted play-and-pause puts the first frame on screen.
                posterTasks.append(Task { await showPoster(of: player, item: item, cuts: cuts) })
            }
        }
    }

    /// The page's framing rows bound to the sheet's own copy, and the
    /// effect and transition for the next render; from Express, under a
    /// Picture tab beside the Overlays tab with the page's overlay rows.
    private var controls: some View {
        ScrollView {
            Group {
                if hasOverlays {
                    PageTabs(tabs: tabs, selection: Binding(get: { tab }, set: { tabRaw = $0.rawValue }),
                             label: \.label, rowSpacing: Theme.spaceM) { tab in
                        switch tab {
                        case .overlays:
                            if let overlays = extras.overlays {
                                MiniOverlayRows(settings: overlaySettings, videoIDs: review.videoIDs,
                                                showsNameTags: overlays.showsNameTags,
                                                showsCaptionLanguage: overlays.showsCaptionLanguage)
                            }
                        default: pictureRows
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: Theme.spaceM) { pictureRows }
                }
            }
            .padding()
            // The rows size to the column, never past it.
            .frame(width: controlsWidth)
        }
        .environment(\.formCaptionIndent, SettingsRowMetrics.labelWidth + Theme.spaceM)
        .environment(\.settingsDetailBelow, true)
        .environment(\.settingsRowDividers, false)
        .disabled(busy || pendingJob != nil)
        .task { availableLookIDs = await EffectControls.availablePresetIDs() }
    }

    /// Effect, transition and the framing rows.
    @ViewBuilder
    private var pictureRows: some View {
        SettingsRow("Effect", detail: "A look over the picture; none unless chosen. The still shows it at once, the cut once it plays again.") {
            lookPicker
        }
        SettingsRow("Transition", detail: "At every cut in the rough cut; hard cuts unless chosen. Shown once the cut plays again.") {
            transitionPicker
        }
        FramingRows(framing: $framing, type: review.sourceType, videoIDs: review.videoIDs,
                    canvasAspect: review.canvasAspect)
    }

    /// None, then the Looks and film-stock presets the local ffmpeg can render.
    private var lookPicker: some View {
        let available = EffectCatalog.presets.filter { preset in
            preset.id != "none" && (availableLookIDs?.contains(preset.id) ?? true)
        }
        let groups: [(title: String, presets: [EffectCatalog.Preset])] = [
            ("Effects", available.filter { $0.group == "looks" }),
            ("Film stocks", available.filter { $0.group == "film" }),
        ].filter { !$0.presets.isEmpty }
        return Picker("Effect", selection: Binding(get: { extras.look ?? "" },
                                                   set: { extras.look = $0.isEmpty ? nil : $0 })) {
            Text("None").lineLimit(1).fixedSize().tag("")
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.presets, id: \.id) { preset in
                        Text(preset.name).lineLimit(1).fixedSize().tag(preset.id)
                    }
                }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel("Effect")
    }

    /// None (hard cuts), Random, then every transition grouped by family.
    private var transitionPicker: some View {
        let groups: [(title: String, effects: [TransitionEffect])] = TransitionEffect.Category.allCases
            .filter { $0 != .cut }
            .map { category in (category.title, TransitionCatalog.all.filter { $0.category == category }) }
        return Picker("Transition", selection: Binding(get: { extras.transition ?? "" },
                                                       set: { extras.transition = $0.isEmpty ? nil : $0 })) {
            Text("None").lineLimit(1).fixedSize().tag("")
            Text("Random").lineLimit(1).fixedSize().tag(WizardPlanRules.randomTransitionChoice)
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.effects) { effect in
                        Text(effect.title).lineLimit(1).fixedSize().tag(effect.name)
                    }
                }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel("Transition")
    }

    /// The command is consumed by the page that made the cut, so bring that
    /// page back first: its project, the Wizard page and its mode. The
    /// pending command waits for it to mount.
    private func send(_ actionID: String) {
        _ = store.selectProject(review.projectID)
        store.isShowingProjectsHome = false
        store.selectedSection = .wizard
        store.wizardMode = review.namespace == WizardAssistant.expressNamespace ? .express : .full
        store.assistant.sendCommand(actionID, text: framing.joined, expressOverlays: hasOverlays ? extras.overlays?.settings : nil,
                                    namespace: review.namespace)
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
    private func showPoster(of player: AVPlayer, item: AVPlayerItem, cuts: [RoughCut]) async {
        for _ in 0..<100 where item.status == .unknown {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            guard !Task.isCancelled, isVisible, review.cuts == cuts else { return }
        }
        guard !Task.isCancelled, isVisible, review.cuts == cuts,
              item.status == .readyToPlay, player.rate == 0, item.currentTime() == .zero else { return }
        let muted = player.isMuted
        defer {
            if Task.isCancelled || !isVisible || review.cuts != cuts { player.pause() }
            player.isMuted = muted
        }
        player.isMuted = true
        player.play()
        for _ in 0..<40 where item.currentTime().seconds < 0.03 {
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            guard !Task.isCancelled, isVisible, review.cuts == cuts else { return }
        }
        if player.currentItem === item, item.currentTime().seconds < 0.5 { player.pause() }
    }

    nonisolated private static func aspect(of asset: AVAsset) async throws -> CGFloat? {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let size = CGRect(origin: .zero, size: natural).applying(transform).size
        guard size.width > 0, size.height > 0 else { return nil }
        return abs(size.width) / abs(size.height)
    }
}
