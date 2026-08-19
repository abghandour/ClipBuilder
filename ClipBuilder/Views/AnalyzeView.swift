import AVKit
import SwiftUI

/// Analyze tab: source-video inventory with analysis/transcription status,
/// batch AI tagging, and a live progress log.
struct AnalyzeView: View {
    @Environment(AppStore.self) private var store

    @State private var selection: Set<Int64> = []
    @State private var isDropTargeted = false
    @State private var showGenerateSheet = false
    @State private var pendingDispatch: PendingDispatch?
    @State private var renamingID: Int64?
    @State private var renameText = ""
    @State private var markupVideo: VideoRecord?
    @FocusState private var renameFocused: Bool

    /// Exactly one selected video → the preview pane shows it.
    private var previewVideo: VideoRecord? {
        guard selection.count == 1 else { return nil }
        return store.videos.first { selection.contains($0.id) }
    }

    private var selectedVideos: [VideoRecord] {
        store.videos.filter { selection.contains($0.id) }
    }

    private var pendingVideos: [VideoRecord] {
        store.videos.filter { $0.visualAnalyzedAt == nil }
    }

    var body: some View {
        VSplitView {
            HSplitView {
                table
                    .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                if let video = previewVideo {
                    VideoPreviewPane(video: video) { markupVideo = video }
                        .frame(minWidth: 240, idealWidth: 320, maxWidth: 440, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
            AnalysisLogPanel()
                .frame(maxWidth: .infinity, minHeight: 120, idealHeight: 160)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Analyze")
        .navigationSubtitle("\(store.videos.count) source videos")
        .toolbar {
            ToolbarItemGroup {
                // Visible mute state for the dispatcher's plan prompt — when
                // this is off, Analyze starts immediately with saved choices.
                Toggle("Ask for model plan", isOn: askBeforeAnalyze)
                    .toggleStyle(.checkbox)
                    .help("Show the model plan (model, sampling, instructions) before each analysis. Unchecked = start immediately with the remembered choices.")

                // Explicit text + icon content: the toolbar renders plain
                // Label buttons icon-only regardless of labelStyle.
                Button {
                    startAnalysis(of: selectedVideos)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text("Analyze Selected")
                    }
                }
                .disabled(selection.isEmpty || store.isAnalyzing)
                .help("Runs a fresh analysis. Each run lands in its own analyze batch on the Scenes screen — earlier batches stay until you delete them there.")

                Button {
                    startAnalysis(of: pendingVideos)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles.rectangle.stack")
                        Text("Analyze All Pending")
                    }
                }
                .disabled(pendingVideos.isEmpty || store.isAnalyzing)

                Button {
                    showGenerateSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                        Text("Generate Sample Video")
                    }
                }
                .disabled(selection.isEmpty || store.isAnalyzing)
                .help("Describe a video to create from the selected footage — the AI Wizard is set up from your description")
            }
        }
        .sheet(isPresented: $showGenerateSheet) {
            GenerateSampleSheet(videos: selectedVideos)
        }
        .sheet(item: $markupVideo) { video in
            SubjectMarkupSheet(video: video)
        }
        .sheet(item: $pendingDispatch) { pending in
            DispatchPlanSheet(operation: pending.operation, videos: pending.videos,
                              onStart: pending.run)
        }
        // The folder watcher keeps the table current while the app runs;
        // this catches anything from before this view existed.
        .task { store.scanSourceFolder() }
        // A "re-run this batch" hand-off from the Scenes screen: select the
        // video and open the plan sheet with the batch's options loaded.
        .task {
            if let video = store.pendingAnalyzeSetup { presentPrefilledPlan(for: video) }
        }
        .onChange(of: store.pendingAnalyzeSetup) { _, video in
            if let video { presentPrefilledPlan(for: video) }
        }
    }

    /// The point is editing the options, so the sheet opens even when the
    /// model-plan prompt is muted.
    private func presentPrefilledPlan(for video: VideoRecord) {
        store.pendingAnalyzeSetup = nil
        selection = [video.id]
        pendingDispatch = PendingDispatch(operation: .analyze, videos: [video],
                                          run: { store.analyze(videos: [video]) })
    }

    /// Inverse of the dispatcher's "analyze" mute, editable from the toolbar.
    private var askBeforeAnalyze: Binding<Bool> {
        Binding(
            get: { !store.settings.ai.mutedDispatchPlans.contains(DispatchOperation.analyze.rawValue) },
            set: { ask in
                var muted = store.settings.ai.mutedDispatchPlans
                muted.removeAll { $0 == DispatchOperation.analyze.rawValue }
                if !ask { muted.append(DispatchOperation.analyze.rawValue) }
                store.settings.ai.mutedDispatchPlans = muted
                store.saveSettings()
            })
    }

    /// Show the smart dispatcher's model plan first (unless muted for
    /// analysis), then run. Replaces the old per-run provider menu.
    private func withDispatchPlan(videos: [VideoRecord], _ run: @escaping () -> Void) {
        if store.settings.ai.mutedDispatchPlans.contains(DispatchOperation.analyze.rawValue) {
            run()
            // analyze() has already reset the log by the time this appends.
            store.analysisLog.append("Model-plan prompt is muted — Reset Smart Dispatcher in Settings → AI to bring it back.")
        } else {
            pendingDispatch = PendingDispatch(operation: .analyze, videos: videos, run: run)
        }
    }

    private func startAnalysis(of videos: [VideoRecord]) {
        withDispatchPlan(videos: videos) { store.analyze(videos: videos) }
    }

    private var table: some View {
        // One pass over scenes/batches instead of an O(n) filter per table row.
        let sceneCounts = store.scenes.reduce(into: [Int64: Int]()) { $0[$1.videoID, default: 0] += 1 }
        let batchCounts = store.analysisRuns.reduce(into: [Int64: Int]()) { $0[$1.videoID, default: 0] += 1 }
        let transcriptCounts = store.analysisRuns.reduce(into: [Int64: Int]()) {
            if $1.hasTranscript { $0[$1.videoID, default: 0] += 1 }
        }
        return Table(store.videos, selection: $selection) {
            TableColumn("File") { video in
                HStack {
                    Image(systemName: video.wide ? "rectangle" : "rectangle.portrait")
                        .foregroundStyle(.secondary)
                    if renamingID == video.id {
                        TextField("Name", text: $renameText)
                            .textFieldStyle(.roundedBorder)
                            .focused($renameFocused)
                            .onSubmit {
                                store.renameVideo(video, to: renameText)
                                renamingID = nil
                            }
                            .onExitCommand { renamingID = nil }
                    } else {
                        Text(video.filename)
                            .onTapGesture(count: 2) {
                                renameText = video.filename
                                renamingID = video.id
                                renameFocused = true
                            }
                            .help("Double-click to rename")
                    }
                }
            }
            .width(min: 200, ideal: 320)

            TableColumn("Duration") { video in
                Text(video.duration.timecode)
                    .monospacedDigit()
            }
            .width(70)

            TableColumn("Size") { video in
                Text("\(video.width)×\(video.height)")
                    .foregroundStyle(.secondary)
            }
            .width(90)

            TableColumn("Analysis") { video in
                if store.isAnalyzing && selection.contains(video.id) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    countText(batchCounts[video.id] ?? 0)
                        .help("Analyze batches for this video — manage them on the Scenes screen")
                }
            }
            .width(70)

            TableColumn("Transcripts") { video in
                if store.transcribingVideoIDs.contains(video.id) {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.small)
                        Button {
                            store.cancelTranscription(videoID: video.id)
                        } label: {
                            Image(systemName: "stop.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Stop transcribing")
                    }
                } else {
                    countText(transcriptCounts[video.id] ?? 0)
                        .help("Analyze batches that include a transcript")
                }
            }
            .width(80)

            TableColumn("Scenes") { video in
                Text("\(sceneCounts[video.id] ?? 0)")
                    .foregroundStyle(.secondary)
            }
            .width(60)
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            Button("Analyze") {
                startAnalysis(of: store.videos.filter { ids.contains($0.id) })
            }
            Button("Transcribe") {
                for video in store.videos.filter({ ids.contains($0.id) }) {
                    store.transcribe(video: video)
                }
            }
            Button("Generate Sample Video…") {
                selection = ids
                showGenerateSheet = true
            }
            if ids.count == 1, let video = store.videos.first(where: { ids.contains($0.id) }) {
                Button("VIP Subjects…") {
                    markupVideo = video
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.importVideos(urls)
            return urls.contains { Analyzer.videoExtensions.contains($0.pathExtension.lowercased()) }
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .allowsHitTesting(false)
            } else if store.videos.isEmpty {
                ContentUnavailableView("No source videos", systemImage: "film",
                                       description: Text("Drop video files here — they're copied into the profile's Input folder."))
                    .allowsHitTesting(false)
            }
        }
    }

    /// Batch-count cell: a dash reads quieter than a zero in a mostly-empty
    /// column.
    private func countText(_ count: Int) -> Text {
        count == 0
            ? Text("—").foregroundStyle(.secondary)
            : Text("\(count)")
    }

}

/// Inline player for the single selected source video — watch the footage
/// before deciding to analyze (or re-analyze) it.
private struct VideoPreviewPane: View {
    @Environment(AppStore.self) private var store
    let video: VideoRecord
    let onMarkSubjects: () -> Void

    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 8) {
            PlayerView(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black, in: RoundedRectangle(cornerRadius: 8))
            VStack(spacing: 2) {
                Text(video.filename)
                    .font(.caption)
                    .lineLimit(1)
                Text("\(video.duration.timecode) · \(video.width)×\(video.height)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(store.subjects(for: video.id)) { subject in
                    HStack(spacing: 3) {
                        Circle()
                            .fill(subject.color)
                            .frame(width: 8, height: 8)
                        Text(subject.name)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
                Button("VIP Subjects…", action: onMarkSubjects)
                    .controlSize(.small)
                    .help("Draw colored boxes around important people so analysis can tag their scenes")
            }
        }
        .padding(10)
        .task(id: video.id) {
            player?.pause()
            player = AVPlayer(url: video.url)
        }
        .onDisappear {
            player?.pause()
        }
    }
}

/// One question — "what should the sample video be?" — everything else is
/// interpreted from the answer and lands as editable settings in the Wizard.
private struct GenerateSampleSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let videos: [VideoRecord]

    @State private var requestText = ""

    private var unanalyzedCount: Int {
        videos.count(where: { $0.visualAnalyzedAt == nil })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generate Sample Video")
                .font(.title3.bold())
            Text("Describe what to create from the \(videos.count) selected video(s). Mention duration, content, overlays, music — the AI Wizard is filled in from your description, ready to review and run.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $requestText)
                .font(.body)
                .frame(minHeight: 90)
                .overlay(alignment: .topLeading) {
                    if requestText.isEmpty {
                        Text("e.g. “generate an action-packed 15s video with fight footage only and use the text overlay ‘Sample 1’ with the caption ‘Porrada day!’”")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.quaternary)
                }

            if unanalyzedCount > 0 {
                Label("\(unanalyzedCount) selected video(s) haven't been analyzed — they'll be analyzed first so their footage can be used.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Generate") {
                    store.generateSampleVideo(description: requestText, videos: videos)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(requestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Isolated so per-tick progress/log updates don't re-evaluate the whole
/// Analyze screen (including the videos table) on every appended line.
private struct AnalysisLogPanel: View {
    @Environment(AppStore.self) private var store
    @AppStorage("log.verbose") private var verboseLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Activity")
                    .font(.headline)
                Toggle("Verbose", isOn: $verboseLog)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Log the full prompt sent to the AI for every call")
                Spacer()
                if store.isAnalyzing {
                    Text(store.analysisStage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(value: store.analysisProgress)
                        .frame(width: 180)
                    Button("Stop", systemImage: "stop.circle") {
                        store.cancelAnalysis()
                    }
                    .controlSize(.small)
                    .help("Stop the analysis")
                }
            }
            ActivityLogView(lines: \.analysisLog)
        }
        .padding()
    }
}
