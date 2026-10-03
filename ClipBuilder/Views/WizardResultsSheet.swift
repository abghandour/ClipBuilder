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
    @State private var verdicts: [Int64: Int] = [:]
    @State private var reviewTarget: GeneratedVideoRecord?
    @State private var builderTarget: GeneratedVideoRecord?
    @State private var feedbackDrafts: [Int64: String] = [:]

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

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                HStack {
                    Spacer()
                    Text(visibleVideos.count == 1
                         ? "Your video is ready"
                         : "\(visibleVideos.count) videos are ready")
                        .font(.headline)
                    Spacer()
                    PlatformChromePicker().fixedSize()
                }
                Text(visibleVideos.count > 1 && !bestCritiquedIDs.isEmpty
                     ? "The critic’s highest-rated output in each batch is marked. Watch and rate; every rating trains the wizard."
                     : "Watch and rate — every rating trains the wizard. Not what you wanted? Retry runs the same settings again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(visibleVideos) { video in
                        videoCard(video)
                    }
                }
                .padding(.horizontal)
            }

            HStack {
                Button {
                    store.retryWizard()
                    dismiss()
                } label: {
                    Label("Generate Again", systemImage: "arrow.clockwise")
                }
                .help("Generate again with the same settings — a new plan, new videos")

                DriveMediaMenu(media: visibleVideos.map(\.driveMedia))
                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 480)
        .modalCloseButton { dismiss() }
        .task {
            await store.refreshWizardSelections()
            for video in results.videos {
                guard await DrivePlayback.prepare(video.url) else { continue }
                guard let asset = try? await DriveLocalAsset.make(video.url) else { continue }
                players[video.id] = AVPlayer(playerItem: AVPlayerItem(asset: asset))
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

    @ViewBuilder
    private func videoCard(_ video: GeneratedVideoRecord) -> some View {
        VStack(spacing: 8) {
            PlayerView(player: players[video.id])
                .frame(width: 210, height: 373)
                .background(.black, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    PlatformChromeLayer(size: CGSize(width: 210, height: 373),
                                        safeAreaSettings: store.activeProfile.defaultRenderSettings.platformSafeArea)
                }

            Text("\(video.filename) · \(video.duration.timecode)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let takeID = video.selectionTakeID,
               let selection = store.wizardSelections.first(where: { $0.takes.contains { $0.id == takeID } }),
               let take = selection.takes.first(where: { $0.id == takeID }) {
                Button("Take \(take.ordinal)" + (take.criticScore.map { " · content \($0)/100" } ?? "")) {
                    store.wizardResults = nil
                    dismiss()
                    store.openWizardSelection(selection.id, takeID: takeID)
                }
                .buttonStyle(.link).font(.caption).lineLimit(1).fixedSize()
                if selection.selection.bestTakeID == takeID,
                   selection.takes.contains(where: { $0.id != takeID && $0.proxyPath != nil }) {
                    Button("Keep best only") { keepingTake = selection }
                        .lineLimit(1).fixedSize().controlSize(.small)
                        .disabled(store.isWizardRunning)
                        .help("Delete other take previews; preserve the take history and scores")
                }
            }

            if let critique = video.critique {
                critiqueLine(critique, isBest: bestCritiquedIDs.contains(video.id))
                if bestCritiquedIDs.contains(video.id) {
                    Button("Keep best only") { keepingBest = video }
                        .lineLimit(1).fixedSize()
                        .controlSize(.small)
                }
            }

            if let rationale = video.rationale, !rationale.isEmpty {
                Text(rationale)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(width: 210)
            }

            HStack(spacing: 12) {
                ThumbsToggle(value: Binding(
                    get: { verdicts[video.id] ?? 0 },
                    set: { verdict in
                        verdicts[video.id] = verdict
                        saveQuickVerdict(verdict, for: video)
                    }))

                Button("Full Review…") {
                    reviewTarget = video
                }
                .controlSize(.small)
            }

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
            .frame(width: 210)

            Button("Fix with Wizard…", systemImage: "wand.and.stars") {
                store.openInBuilder(video, fixWithWizard: true)
                dismiss()
            }
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .help("Open this result as a new timeline and preview fixes with Builder Wizard. Apply stays manual.")
            AIInfoButton(output: video)
            Button {
                if store.builder.document.videoTrack.isEmpty {
                    dismiss()
                    store.openInBuilder(video)
                } else {
                    builderTarget = video
                }
            } label: {
                Label("Edit in Builder", systemImage: "slider.horizontal.below.rectangle")
            }
            .controlSize(.small)
            .help("Open this video's timeline in the Builder to tweak clips, overlays, and music")
        }
    }

    /// The critic's take on this version: score (colored by band), one-line
    /// summary, and the full strengths/issues/notes in the tooltip.
    @ViewBuilder
    private func critiqueLine(_ critique: ReelCritique, isBest: Bool) -> some View {
        VStack(spacing: 2) {
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
            if !critique.summary.isEmpty {
                Text(critique.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: 210)
        .help(critiqueTooltip(critique))
    }

    private func critiqueTooltip(_ critique: ReelCritique) -> String {
        var lines: [String] = []
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
