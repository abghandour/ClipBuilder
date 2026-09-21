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

    @State private var folders: [OutputFolder] = []
    @State private var selectedFolder: String? = "all"
    @State private var driveSelection: Set<Int64> = []
    @State private var playing: GeneratedVideoRecord?
    @State private var deleting: GeneratedVideoRecord?
    @State private var reviewTarget: GeneratedVideoRecord?
    @State private var builderTarget: GeneratedVideoRecord?
    @State private var publishTarget: GeneratedVideoRecord?
    @State private var coverTarget: GeneratedVideoRecord?
    @State private var formatExportTarget: GeneratedVideoRecord?

    private var sorted: [GeneratedVideoRecord] {
        let membership = OutputFolders.membership(for: selectedFolder, in: folders)
        let videos = store.generatedVideos.filter { membership.contains($0.id) }
        switch SortOrder(rawValue: store.outputsSort) ?? .newest {
        case .newest: return videos
        case .longest: return videos.sorted { $0.duration > $1.duration }
        case .shortest: return videos.sorted { $0.duration < $1.duration }
        }
    }

    var body: some View {
        HSplitView {
            OutputFolderList(folders: folders, selection: $selectedFolder)
                .rememberedPaneWidth("pane.outputs.folders", min: 190, initial: 240, max: 340)
                .frame(maxHeight: .infinity)
            outputGrid
                .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: store.generatedVideos, initial: true) { rebuildFolders() }
        .onChange(of: store.scenesVersion) { rebuildFolders() }
        .onChange(of: store.timelines) { rebuildFolders() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in rebuildFolders() }
        .onChange(of: selectedFolder) {
            UserDefaults.standard.set(selectedFolder ?? "all", forKey: folderStorageKey)
            driveSelection = []
            store.outputsScrollID = nil
        }
        .screenTitle("Outputs", subtitle: "\(sorted.count) of \(store.generatedVideos.count) videos")
        .toolbar {
            ToolbarItem {
                DriveMediaMenu(media: sorted.filter { driveSelection.contains($0.id) }.map(\.driveMedia))
                    .disabled(driveSelection.isEmpty)
                    .help("Select outputs using More or the context menu, then upload the selection.")
            }
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
        .onChange(of: store.activeProjectID) {
            driveSelection = []
            restoreFolder()
        }
        .onChange(of: store.profileGeneration) {
            driveSelection = []
            restoreFolder()
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
            restoreFolder()
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

    private var folderStorageKey: String { "outputs.folder.\(store.activeProfile.profileName)" }

    private func restoreFolder() {
        selectedFolder = UserDefaults.standard.string(forKey: folderStorageKey) ?? "all"
        rebuildFolders()
    }

    private func rebuildFolders() {
        folders = OutputFolders.build(records: store.generatedVideos, scenes: store.scenes, timelines: store.timelines)
        selectedFolder = OutputFolders.resolvedSelection(selectedFolder, in: folders)
    }

    @ViewBuilder private var outputGrid: some View {
        if store.generatedVideos.isEmpty {
            ContentUnavailableView("No Generated Videos", systemImage: "film.stack",
                description: Text("Finished videos from the AI Wizard and Builder will appear here."))
        } else if sorted.isEmpty {
            ContentUnavailableView("No videos in this folder", systemImage: "folder",
                description: Text(selectedFolder == "favorites" ? "Use the heart on a video to add it to Favorites." : "Choose another folder to browse your outputs."))
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Theme.spaceM, alignment: .top)], spacing: Theme.spaceM) {
                    ForEach(sorted) { video in card(for: video).id(video.id) }
                }
                .padding(Theme.spaceM)
                .scrollTargetLayout()
            }
            .scrollPosition(id: Binding(get: { store.outputsScrollID }, set: { store.outputsScrollID = $0 }))
        }
    }

    /// Opening in the Builder replaces whatever is on its timeline — confirm
    /// first unless the timeline is empty.
    /// Share the rendered file through the system share sheet; the caption
    /// rides along as the message body where the target shows one.
    @ViewBuilder
    private func shareLink(_ video: GeneratedVideoRecord) -> some View {
        if video.caption.isEmpty {
            ShareLink(item: video.url) { Label("Share", systemImage: "square.and.arrow.up") }
        } else {
            ShareLink(item: video.url, message: Text(video.caption)) { Label("Share", systemImage: "square.and.arrow.up") }
        }
    }

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

            // Name on the left, the AI details button at the far right of
            // the same line.
            HStack(alignment: .firstTextBaseline, spacing: Theme.spaceS) {
                Text(video.filename)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(video.favorite ? "Remove from Favorites" : "Add to Favorites",
                       systemImage: video.favorite ? "heart.fill" : "heart") {
                    store.setGeneratedVideoFavorite(video, favorite: !video.favorite)
                }
                .labelStyle(.iconOnly).buttonStyle(.plain)
                .foregroundStyle(video.favorite ? Color.accentColor : Color.secondary)
                .help(video.favorite ? "Remove from Favorites" : "Add to Favorites")
                AIInfoButton(output: video)
            }

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
                // The macOS share sheet: Messages, AirDrop, Mail and any
                // share extension, with the caption as the message text.
                shareLink(video)
                    .disabled(!FileManager.default.fileExists(atPath: video.path))
                    .help(FileManager.default.fileExists(atPath: video.path)
                          ? "Send the rendered video with Messages, AirDrop, Mail or another app"
                          : "The file is not on this Mac — download it from the Drive menu to share it")
                Menu("More", systemImage: "ellipsis") {
                    driveSelectionAction(video)
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
                    shareLink(video)
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        deleting = video
                    }
                }
                .controlSize(.small)
                Spacer()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if video.driveFileID != nil {
                DriveMediaMenu(media: [video.driveMedia])
                    .padding(.horizontal, 8).padding(.bottom, 8)
            }
        }
        .padding(Theme.cardPadding)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay {
            if driveSelection.contains(video.id) {
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityAddTraits(driveSelection.contains(video.id) ? .isSelected : [])
        .contextMenu {
            driveSelectionAction(video)
            if video.driveFileID != nil { DriveMediaMenu(media: [video.driveMedia]) }
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

    private func driveSelectionAction(_ video: GeneratedVideoRecord) -> some View {
        Button(driveSelection.contains(video.id) ? "Remove from Drive Selection" : "Select for Drive Actions") {
            if driveSelection.contains(video.id) { driveSelection.remove(video.id) }
            else { driveSelection.insert(video.id) }
        }
    }

}
