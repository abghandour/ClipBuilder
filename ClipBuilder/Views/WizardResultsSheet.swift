import AVKit
import SwiftUI

/// Presented when a wizard run finishes: every video it produced, playable
/// side by side, with quick thumbs (saved as reviews the wizard trains on),
/// a jump into the full review flow, and a one-click retry of the same run.
struct WizardResultsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let results: WizardRunResults

    @State private var players: [Int64: AVPlayer] = [:]
    /// Width / height of each rendered video, for players that keep its shape.
    @State private var aspects: [Int64: CGFloat] = [:]
    @State private var verdicts: [Int64: Int] = [:]
    @State private var reviewTarget: GeneratedVideoRecord?
    @State private var builderTarget: GeneratedVideoRecord?
    @State private var feedbackDrafts: [Int64: String] = [:]
    @State private var postTextNotes: [Int64: String] = [:]

    @State private var keepingTake: WizardSelectionSummary?
    @State private var keepingBest: GeneratedVideoRecord?
    @State private var removedVideoIDs: Set<Int64> = []

    private var visibleVideos: [GeneratedVideoRecord] {
        results.videos.filter { !removedVideoIDs.contains($0.id) }
    }

    private var bestCritiquedIDs: Set<Int64> {
        let videos = visibleVideos
        return Set(Set(videos.compactMap(\.batchID)).compactMap { batch -> Int64? in
            guard videos.filter({ $0.batchID == batch }).count > 1 else { return nil }
            return WizardBatchRanking.best(in: videos, batchID: batch)?.id
        })
    }

    private var idealSize: CGSize {
        WizardResultsLayout.idealSize(count: visibleVideos.count,
            cardSize: CGSize(width: WizardResultsLayout.minCardWidth, height: 680),
            screen: NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                HStack {
                    Spacer()
                    Text(visibleVideos.count == 1
                         ? "Your video is ready"
                         : "\(visibleVideos.count) videos are ready")
                        .font(.headline)
                        .lineLimit(1).fixedSize()
                    Spacer()
                    PlatformChromePicker().fixedSize()
                }
                Text(visibleVideos.count > 1 && !bestCritiquedIDs.isEmpty
                     ? "The critic’s highest-rated output in each batch is marked. Watch and rate; every rating trains the wizard."
                     : results.source == .express
                        ? "Watch and rate — every rating trains the wizard. Not what you wanted? Go back to change the picks or settings."
                        : "Watch and rate — every rating trains the wizard. Not what you wanted? Retry runs the same settings again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            // The cards follow the sheet: resize it and the players grow or
            // shrink with it, in each video's own shape.
            GeometryReader { geometry in
                let grid = WizardResultsLayout.grid(count: visibleVideos.count, available: geometry.size)
                let players = Dictionary(uniqueKeysWithValues: visibleVideos.map {
                    ($0.id, WizardResultsLayout.playerSize(in: grid, aspect: aspects[$0.id] ?? 9 / 16))
                })
                let cardWidth = WizardResultsLayout.cardWidth(
                    in: grid, playerWidth: players.values.map(\.width).max() ?? 0)
                ScrollView(.vertical) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: WizardResultsLayout.spacing, alignment: .top),
                                             count: grid.columns),
                              alignment: .center, spacing: WizardResultsLayout.spacing) {
                        ForEach(visibleVideos) { video in
                            videoCard(video, width: cardWidth, playerSize: players[video.id] ?? CGSize(width: 210, height: 373))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)
                }
            }

            HStack {
                if results.source == .express {
                    // Express rendered chosen picks: anything to change lives on its page.
                    Button {
                        dismiss()
                        store.miniRun?.requestedCard = .settings
                        store.requestedSection = .wizardMini
                    } label: {
                        Label("Back to Settings", systemImage: "slider.horizontal.3").lineLimit(1).fixedSize()
                    }
                    .help("Return to AI Wizard Express to change the picks or settings and generate again")
                } else {
                    Button {
                        store.retryWizard()
                        dismiss()
                    } label: {
                        Label("Generate Again", systemImage: "arrow.clockwise").lineLimit(1).fixedSize()
                    }
                    .help("Generate again with the same settings — a new plan, new videos")
                }

                DriveMediaMenu(media: visibleVideos.map(\.driveMedia))
                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 520, idealWidth: idealSize.width, maxWidth: .infinity,
               minHeight: 560, idealHeight: idealSize.height, maxHeight: .infinity)
        .presentationSizing(.fitted)
        .modalCloseButton { dismiss() }
        .task {
            await store.refreshWizardSelections()
            for video in results.videos {
                guard await DrivePlayback.prepare(video.url) else { continue }
                guard let asset = try? await DriveLocalAsset.make(video.url) else { continue }
                players[video.id] = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                if let aspect = try? await Self.aspect(of: asset) { aspects[video.id] = aspect }
            }
        }
        .onDisappear {
            for player in players.values { player.pause() }
            players = [:]
        }
        .onChange(of: store.profileGeneration) { _, _ in dismiss() }
        .onChange(of: store.activeProjectID) { _, _ in dismiss() }
        .confirmationDialog(
            "Keep the best version only?",
            isPresented: Binding(get: { keepingBest != nil }, set: { if !$0 { keepingBest = nil } })
        ) {
            Button("Remove from Library and Delete Files", role: .destructive) {
                discardOtherVersions(removeFiles: true)
            }
            Button("Remove from Library Only") { discardOtherVersions(removeFiles: false) }
            Button("Cancel", role: .cancel) { keepingBest = nil }
        } message: {
            Text("Keep \(keepingBest?.filename ?? "the best version") and remove the other versions from this run. No other batch is affected.")
        }
        .confirmationDialog("Keep the best take's preview only?", isPresented: Binding(
            get: { keepingTake != nil }, set: { if !$0 { keepingTake = nil } })
        ) {
            Button("Delete Other Take Previews", role: .destructive) {
                if let selection = keepingTake, let best = selection.bestTake {
                    store.keepBestWizardTakeProxy(selectionID: selection.id, takeID: best.id)
                }
                keepingTake = nil
            }
            Button("Cancel", role: .cancel) { keepingTake = nil }
        } message: {
            Text("Keep the best take's preview and the rendered reel. All takes, cuts and content scores remain in the selection.")
        }
        .sheet(item: $reviewTarget) { video in
            ReviewSheet(video: video)
        }
        // Mirrors the Library: opening in the Builder replaces its timeline,
        // so confirm when clips are already there.
        .confirmationDialog(
            "Replace the current timeline?",
            isPresented: Binding(get: { builderTarget != nil }, set: { if !$0 { builderTarget = nil } })
        ) {
            Button("Replace Timeline") {
                if let builderTarget {
                    dismiss()
                    store.openInBuilder(builderTarget)
                }
                builderTarget = nil
            }
            Button("Cancel", role: .cancel) { builderTarget = nil }
        } message: {
            Text("The Builder already has clips on its timeline. Opening \(builderTarget?.filename ?? "this video") replaces them. You can undo this with ⌘Z.")
        }
    }

    /// One result: the player, what it is, how to rate it, what to do next.
    /// Grouped top to bottom so each row has one job.
    private func videoCard(_ video: GeneratedVideoRecord, width cardWidth: CGFloat, playerSize: CGSize) -> some View {
        let take = takeInfo(for: video)
        let isBest = bestCritiquedIDs.contains(video.id)
        return VStack(alignment: .leading, spacing: Theme.spaceS) {
            ScrubbingPlayerView(player: players[video.id], aspect: playerSize.width / max(1, playerSize.height),
                                pictureOverlay: {
                PlatformChromeLayer(size: playerSize,
                                    safeAreaSettings: store.activeProfile.defaultRenderSettings.platformSafeArea)
            })
            .frame(width: playerSize.width)
            .frame(maxWidth: .infinity)

            // What it is.
            VStack(alignment: .leading, spacing: 2) {
                Text(cardTitle(video))
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(video.rationale ?? video.filename)
                Text("\(video.filename) · \(video.duration.timecode)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(video.filename)
            }

            if take != nil || video.critique != nil {
                HStack(spacing: Theme.spaceS) {
                    if let take {
                        Button("Take \(take.take.ordinal)" + (take.take.criticScore.map { " · content \($0)/100" } ?? "")) {
                            store.wizardResults = nil
                            dismiss()
                            store.openWizardSelection(take.selection.id, takeID: take.take.id)
                        }
                        .buttonStyle(.link).font(.caption)
                        .help("Open this take in the selection review")
                    }
                    if let critique = video.critique {
                        critiqueLine(critique, isBest: isBest)
                    }
                    Spacer(minLength: 0)
                    if let take, take.canKeepBestOnly {
                        Button("Keep best only") { keepingTake = take.selection }
                            .controlSize(.small)
                            .disabled(store.isWizardRunning)
                            .help("Delete other take previews; preserve the take history and scores")
                    } else if video.critique != nil, isBest {
                        Button("Keep best only") { keepingBest = video }
                            .controlSize(.small)
                    }
                }
                .lineLimit(1)
            }

            Divider()

            // Rate it.
            HStack(spacing: Theme.spaceS) {
                Text("Rate").font(.caption).foregroundStyle(.secondary)
                ThumbsToggle(value: Binding(
                    get: { verdicts[video.id] ?? 0 },
                    set: { verdict in
                        verdicts[video.id] = verdict
                        saveQuickVerdict(verdict, for: video)
                    }))
                Spacer(minLength: 0)
                Button("Full Review…") { reviewTarget = video }
                    .controlSize(.small)
                    .help("Rate each dimension and each clip")
            }
            .lineLimit(1)

            // Free-text note straight into the wizard's training signals —
            // for anything the thumbs and review dimensions can't say.
            HStack(spacing: 6) {
                TextField("Tell the wizard anything…", text: Binding(
                    get: { feedbackDrafts[video.id] ?? "" },
                    set: { feedbackDrafts[video.id] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { saveFeedback(for: video) }
                Button("Send") { saveFeedback(for: video) }
                    .controlSize(.small)
                    .disabled((feedbackDrafts[video.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Saved as a feedback note — the next runs and lesson distillation read it")
            }

            Divider()

            postTextRows(video)

            Divider()

            // What next.
            HStack(spacing: Theme.spaceS) {
                Button("Edit in Builder") {
                    if store.builder.document.videoTrack.isEmpty {
                        dismiss()
                        store.openInBuilder(video)
                    } else {
                        builderTarget = video
                    }
                }
                .help("Open this video's timeline in the Builder to tweak clips, overlays, and music")
                Button("Fix with Wizard…") {
                    store.openInBuilder(video, fixWithWizard: true)
                    dismiss()
                }
                .help("Open this result as a new timeline and preview fixes with Builder Wizard. Apply stays manual.")
                Spacer(minLength: 0)
                AIInfoButton(output: video)
                    .help("How the AI made this video")
            }
            .controlSize(.small)
            .lineLimit(1)
        }
        .padding(WizardResultsLayout.cardPadding)
        .frame(width: cardWidth, alignment: .top)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }

    /// Width over height of the first video track, after its transform.
    nonisolated private static func aspect(of asset: AVAsset) async throws -> CGFloat? {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let size = CGRect(origin: .zero, size: natural).applying(transform).size
        guard size.width > 0, size.height > 0 else { return nil }
        return abs(size.width) / abs(size.height)
    }

    /// The Instagram post text, written after the video so a discarded reel
    /// costs no model call: Write, then the text with Copy and Rewrite plus
    /// an optional steer. The gear picks the model.
    @ViewBuilder
    private func postTextRows(_ video: GeneratedVideoRecord) -> some View {
        let live = store.currentGeneratedVideo(video)
        let writing = store.isWritingPostText(for: video)
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            HStack(spacing: Theme.spaceS) {
                Text("Post text").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if writing {
                    ProgressView().controlSize(.small)
                    Text("Writing…").font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                } else if live.caption.isEmpty {
                    Button("Write Post Text") { store.writePostText(for: live) }
                        .controlSize(.small)
                        .help("Ask the model for the Instagram caption and hashtags for this video")
                } else {
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(live.caption, forType: .string)
                    }
                    .labelStyle(.iconOnly).controlSize(.small)
                    .help("Copy the post text")
                }
                MiniModelButton(tasks: ["captions"])
            }
            if !live.caption.isEmpty {
                Text(live.caption)
                    .font(.caption)
                    .lineLimit(4).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(live.caption)
                HStack(spacing: 6) {
                    TextField("Ask for a change (optional)…", text: Binding(
                        get: { postTextNotes[video.id] ?? "" },
                        set: { postTextNotes[video.id] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .onSubmit { rewritePostText(live) }
                    Button("Rewrite") { rewritePostText(live) }
                        .controlSize(.small)
                        .disabled(writing)
                        .help("Write a fresh caption; the note above steers it")
                }
            }
        }
        .lineLimit(1)
    }

    private func rewritePostText(_ video: GeneratedVideoRecord) {
        let note = (postTextNotes[video.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        store.writePostText(for: video, note: note.isEmpty ? nil : note)
        postTextNotes[video.id] = ""
    }

    /// The reel's headline when the planner wrote one, else its file name.
    private func cardTitle(_ video: GeneratedVideoRecord) -> String {
        if let rationale = video.rationale?.trimmingCharacters(in: .whitespacesAndNewlines), !rationale.isEmpty {
            return rationale
        }
        return (video.filename as NSString).deletingPathExtension
    }

    private struct TakeInfo {
        var selection: WizardSelectionSummary
        var take: WizardSelectionTake
        var canKeepBestOnly: Bool
    }

    private func takeInfo(for video: GeneratedVideoRecord) -> TakeInfo? {
        guard let takeID = video.selectionTakeID,
              let selection = store.wizardSelections.first(where: { $0.takes.contains { $0.id == takeID } }),
              let take = selection.takes.first(where: { $0.id == takeID }) else { return nil }
        let canKeep = selection.selection.bestTakeID == takeID
            && selection.takes.contains { $0.id != takeID && $0.proxyPath != nil }
        return TakeInfo(selection: selection, take: take, canKeepBestOnly: canKeep)
    }

    /// The critic's score (colored by band) and BEST mark; the summary and
    /// the full strengths/issues/notes are in the tooltip.
    private func critiqueLine(_ critique: ReelCritique, isBest: Bool) -> some View {
        HStack(spacing: 6) {
            Label(critique.shortLabel, systemImage: "checkmark.seal.text")
                .font(.caption.weight(.medium))
                .foregroundStyle(critique.score >= 85 ? .green
                                 : critique.score >= 70 ? .yellow : .orange)
            if isBest {
                Text("BEST")
                    .font(.badgeCompact)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.green.opacity(0.85), in: RoundedRectangle(cornerRadius: Theme.chipRadius))
                    .foregroundStyle(.black)
                    .accessibilityLabel("Critic's favorite version")
            }
        }
        .lineLimit(1)
        .help(critiqueTooltip(critique))
    }

    private func critiqueTooltip(_ critique: ReelCritique) -> String {
        var lines: [String] = critique.summary.isEmpty ? [] : [critique.summary]
        if !critique.strengths.isEmpty {
            lines.append("Strengths:")
            lines.append(contentsOf: critique.strengths.map { "  • \($0)" })
        }
        if !critique.issues.isEmpty {
            lines.append("Issues:")
            lines.append(contentsOf: critique.issues.map { "  • \($0)" })
        }
        if !critique.notes.isEmpty {
            lines.append("Review notes:")
            lines.append(contentsOf: critique.notes.map { "  • \($0)" })
        }
        if let judge = AIProvenance(provider: critique.provider, model: critique.model) {
            lines.append("Judged by \(judge.shortLabel)")
        }
        return lines.isEmpty ? critique.summary : lines.joined(separator: "\n")
    }

    private func discardOtherVersions(removeFiles: Bool) {
        guard let best = keepingBest else { return }
        let discards = WizardBatchRanking.discards(in: visibleVideos, keeping: best)
        for video in discards {
            players[video.id]?.pause()
            store.deleteGeneratedVideo(video, removeFile: removeFiles) {
                removedVideoIDs.insert(video.id)
                players[video.id] = nil
            }
        }
        keepingBest = nil
    }

    private func saveFeedback(for video: GeneratedVideoRecord) {
        let text = (feedbackDrafts[video.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.addFeedback(for: video, text: text)
        feedbackDrafts[video.id] = ""
    }

    /// A thumbs tap is a review with just the overall verdict — the full
    /// ReviewSheet loads and extends it if the user goes deeper.
    private func saveQuickVerdict(_ verdict: Int, for video: GeneratedVideoRecord) {
        store.saveReview(GenerationReview(generatedVideoID: video.id,
                                          verdict: verdict,
                                          dimensions: [:],
                                          note: "",
                                          createdAt: nil),
                         clips: [])
    }
}
