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
                Picker("Sort", selection: $sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .sheet(item: $playing) { video in
            PlayerSheet(url: video.url, title: video.filename)
        }
        .sheet(item: $reviewTarget) { video in
            ReviewSheet(video: video)
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
                VideoThumbnail(url: video.url, time: min(0.5, video.duration / 2))
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

                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([video.url])
                }
                .labelStyle(.iconOnly)

                Spacer()

                Button("Delete", systemImage: "trash", role: .destructive) {
                    deleting = video
                }
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            Button("Open in Builder") {
                openInBuilder(video)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([video.url])
            }
        }
    }

}
