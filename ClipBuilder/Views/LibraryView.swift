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

    @State private var playing: GeneratedVideoRecord?
    @State private var deleting: GeneratedVideoRecord?
    @State private var reviewTarget: GeneratedVideoRecord?
    @State private var builderTarget: GeneratedVideoRecord?
    @State private var publishTarget: GeneratedVideoRecord?
    @State private var coverTarget: GeneratedVideoRecord?
    @State private var formatExportTarget: GeneratedVideoRecord?

    private var sorted: [GeneratedVideoRecord] {
        switch SortOrder(rawValue: store.outputsSort) ?? .newest {
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
                    description: Text("Finished videos from the AI Wizard and Builder will appear here."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16, alignment: .top)], spacing: 16) {
                        ForEach(sorted) { video in
                            card(for: video)
                                .id(video.id)
                        }
                    }
                    .padding()
                    .scrollTargetLayout()
                }
                .scrollPosition(id: Binding(
                    get: { store.outputsScrollID },
                    set: { store.outputsScrollID = $0 }
                ))
            }
        }
        .screenTitle("Outputs", subtitle: "\(store.generatedVideos.count) videos")
        .toolbar {
            ToolbarItem {
                // A named menu instead of a bare Picker — the toolbar showed
                // only the selected value ("Newest") with nothing saying what
                // the control was.
                Menu {
                    Picker("Sort", selection: Binding(
                        get: { SortOrder(rawValue: store.outputsSort) ?? .newest },
                        set: {
                            store.outputsSort = $0.rawValue
                            store.persistActiveProjectState()
                        }
                    )) {
                        ForEach(SortOrder.allCases, id: \.self) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    ToolbarBubbleLabel(text: "Sort: \((SortOrder(rawValue: store.outputsSort) ?? .newest).rawValue)",
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
        .sheet(item: $formatExportTarget) { video in
            SocialFormatExportSheet(video: video)
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
            if let quality = video.qualityReport {
                Label(quality.summary, systemImage: quality.verdict == .publishable
                      ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(quality.verdict == .publishable ? .green : .orange)
                    .lineLimit(1)
            } else if let stats = video.instagramStats {
                Text(ReelPerformance.label(stats, duration: video.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !video.caption.isEmpty {
                Text(video.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: Theme.spaceS) {
                if let quality = video.qualityReport, quality.verdict != .publishable {
                    Button("Review", systemImage: "hand.thumbsup") {
                        reviewTarget = video
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Publish", systemImage: "paperplane") {
                        publishTarget = video
                    }
                    .buttonStyle(.borderedProminent)
                }
                Menu("More", systemImage: "ellipsis") {
                    Button("Open in Builder", systemImage: "timeline.selection") {
                        openInBuilder(video)
                    }
                    Button("Pick Cover Frame…", systemImage: "rectangle.on.rectangle") {
                        coverTarget = video
                    }
                    Button("Review", systemImage: "hand.thumbsup") {
                        reviewTarget = video
                    }
                    Button("Publish to Instagram…", systemImage: "paperplane") {
                        publishTarget = video
                    }
                    Button("Export Story, Feed or Carousel…", systemImage: "rectangle.stack") {
                        formatExportTarget = video
                    }
                    if !video.caption.isEmpty {
                        Button("Copy Caption", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(video.caption, forType: .string)
                        }
                    }
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([video.url])
                    }
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        deleting = video
                    }
                }
                .controlSize(.small)
                Spacer()
            }
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
            Button("Export Story, Feed or Carousel…") {
                formatExportTarget = video
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([video.url])
            }
        }
    }

}
