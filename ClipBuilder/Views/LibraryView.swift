import SwiftUI

/// Generated-videos library: browse, play, copy captions, leave wizard
/// feedback, delete.
struct LibraryView: View {
    @Environment(AppStore.self) private var store

    private enum SortOrder: String, CaseIterable {
        case newest = "Newest"
        case longest = "Longest"
        case shortest = "Shortest"
    }

    @State private var sortOrder: SortOrder = .newest
    @State private var playing: GeneratedVideoRecord?
    @State private var deleting: GeneratedVideoRecord?
    @State private var reviewTarget: GeneratedVideoRecord?
    @State private var builderTarget: GeneratedVideoRecord?
    @State private var publishTarget: GeneratedVideoRecord?
    @State private var coverTarget: GeneratedVideoRecord?

    private var sorted: [GeneratedVideoRecord] {
        switch sortOrder {
        case .newest: return store.generatedVideos
        case .longest: return store.generatedVideos.sorted { $0.duration > $1.duration }
        case .shortest: return store.generatedVideos.sorted { $0.duration < $1.duration }
        }
    }

    var body: some View {
        Group {
            if store.generatedVideos.isEmpty {
                ContentUnavailableView(
                    "No Generated Videos",
                    systemImage: "film.stack",
                    description: Text("Videos created by the AI Wizard will appear here."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16, alignment: .top)], spacing: 16) {
                        ForEach(sorted) { video in
                            card(for: video)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Library")
        .navigationSubtitle("\(store.generatedVideos.count) videos")
        .toolbar {
            ToolbarItem {
                // A named menu instead of a bare Picker — the toolbar showed
                // only the selected value ("Newest") with nothing saying what
                // the control was.
                Menu {
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(SortOrder.allCases, id: \.self) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    ToolbarBubbleLabel(text: "Sort: \(sortOrder.rawValue)",
                                       systemImage: "arrow.up.arrow.down")
                }
                .help("Order the library's videos")
            }
        }
        .sheet(item: $playing) { video in
            PlayerSheet(url: video.url, title: video.filename)
        }
        .sheet(item: $reviewTarget) { video in
            ReviewSheet(video: video)
        }
        .sheet(item: $publishTarget) { video in
            InstagramPublishSheet(video: video)
        }
        .sheet(item: $coverTarget) { video in
            CoverFrameSheet(video: video)
        }
        // Hook for scripts/capture_help_screenshots.sh: accessibility-tree
        // clicking is too flaky to reach the review sheet, so screenshot
        // captures launch the app with this argument instead.
        .onAppear {
            if CommandLine.arguments.contains("--auto-open-review"), reviewTarget == nil {
                reviewTarget = store.generatedVideos.first
            }
        }
        .confirmationDialog(
            "Delete \(deleting?.filename ?? "video")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Remove from Library and Delete File", role: .destructive) {
                if let deleting { store.deleteGeneratedVideo(deleting, removeFile: true) }
                deleting = nil
            }
            Button("Remove from Library Only") {
                if let deleting { store.deleteGeneratedVideo(deleting, removeFile: false) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        }
        .confirmationDialog(
            "Replace the current timeline?",
            isPresented: Binding(get: { builderTarget != nil }, set: { if !$0 { builderTarget = nil } })
        ) {
            Button("Replace Timeline") {
                if let builderTarget { store.openInBuilder(builderTarget) }
                builderTarget = nil
            }
            Button("Cancel", role: .cancel) { builderTarget = nil }
        } message: {
            Text("The Builder already has clips on its timeline. Opening \(builderTarget?.filename ?? "this video") replaces them. You can undo this with ⌘Z.")
        }
    }

    /// Opening in the Builder replaces whatever is on its timeline — confirm
    /// first unless the timeline is empty.
    private func openInBuilder(_ video: GeneratedVideoRecord) {
        if store.builder.document.videoTrack.isEmpty {
            store.openInBuilder(video)
        } else {
            builderTarget = video
        }
    }

    @ViewBuilder
    private func card(for video: GeneratedVideoRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                playing = video
            } label: {
                VideoThumbnail(url: video.url,
                               time: video.coverTime ?? min(0.5, video.duration / 2))
                    .accessibilityLabel("Play \(video.filename)")
                    .aspectRatio(9 / 16, contentMode: .fit)
                    .overlay {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.white.opacity(0.85))
                            .shadow(radius: 4)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        DurationBadge(seconds: video.duration)
                    }
            }
            .buttonStyle(.plain)

            Text(video.filename)
                .font(.callout.weight(.medium))
                .lineLimit(1)

            if let generatedAt = video.generatedAt {
                Text(generatedAt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Every model that touched this reel: planner, caption writer,
            // critic, cover picker — one badge per distinct model.
            ProvenanceRow(entries: [("Planned by", video.planProvenance),
                                    ("Caption by", video.captionProvenance),
                                    ("Critiqued by", video.critiqueProvenance),
                                    ("Cover picked by", video.coverProvenance)])

            if let quality = video.qualityReport {
                // "Review required" is an instruction — clicking it opens the
                // review instead of leaving the details buried in a tooltip.
                Button {
                    reviewTarget = video
                } label: {
                    Label(quality.summary, systemImage: quality.verdict == .publishable
                          ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(quality.verdict == .publishable ? .green : .orange)
                }
                .buttonStyle(.plain)
                .help("Quality gate: "
                      + ((quality.failures + quality.warnings).joined(separator: "\n").isEmpty
                          ? quality.summary
                          : (quality.failures + quality.warnings).joined(separator: "\n"))
                      + "\nClick to review the reel.")
            }
            if let critique = video.critique {
                Label("\(critique.shortLabel)\(critique.summary.isEmpty ? "" : " · \(critique.summary)")",
                      systemImage: "checkmark.seal.text")
                    .font(.caption2)
                    .foregroundStyle(critique.score >= 85 ? .green
                                     : critique.score >= 70 ? .secondary : .orange)
                    .lineLimit(1)
                    .help(([critique.summary]
                           + critique.issues.map { "• \($0)" }).joined(separator: "\n"))
            }
            if let percentile = video.audiencePercentile {
                Label("Audience: beat \(percentile)% of the account's reels"
                      + (video.audienceScore.map { String(format: " · quality %.1f", $0) } ?? ""),
                      systemImage: "person.3")
                    .font(.caption2)
                    .foregroundStyle(percentile >= 75 ? .green : percentile >= 40 ? .secondary : .orange)
                    .lineLimit(1)
                    .help("How this published reel performed among the account's reels (saves/shares/comments/likes normalized by reach) — compare with the critic's forecast")
            }
            if let stats = video.instagramStats {
                Text(ReelPerformance.label(stats, duration: video.duration))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !video.caption.isEmpty {
                Text(video.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack {
                if !video.caption.isEmpty {
                    Button("Copy Caption", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(video.caption, forType: .string)
                    }
                    .labelStyle(.iconOnly)
                    .help("Copy the Instagram caption")
                }
                Button("Review", systemImage: "hand.thumbsup") {
                    reviewTarget = video
                }
                .labelStyle(.iconOnly)
                .help("Rate this reel and its clips — the wizard trains on your review")

                Button("Publish to Instagram", systemImage: "paperplane") {
                    publishTarget = video
                }
                .labelStyle(.iconOnly)
                .help("Publish this video to the connected Instagram account as a Reel")

                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([video.url])
                }
                .labelStyle(.iconOnly)
                .help("Show the video file in Finder")

                Spacer()

                Button("Delete", systemImage: "trash", role: .destructive) {
                    deleting = video
                }
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(Theme.cardPadding)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .contextMenu {
            Button("Open in Builder") {
                openInBuilder(video)
            }
            Button("Pick Cover Frame…") {
                coverTarget = video
            }
            Button("Publish to Instagram…") {
                publishTarget = video
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([video.url])
            }
        }
    }

}
