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
    @FocusState private var renameFocused: Bool

    /// Exactly one selected video → the preview pane shows it.
    private var previewVideo: VideoRecord? {
        guard selection.count == 1 else { return nil }
        return store.videos.first { selection.contains($0.id) }
    }

    private var selectedVideos: [VideoRecord] {
        store.videos.filter { selection.contains($0.id) }
    }

    var body: some View {
        VSplitView {
            HSplitView {
                table
                    .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                if let video = previewVideo {
                    VideoPreviewPane(video: video)
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
                // Explicit text + icon content: the toolbar renders plain
                // Label buttons icon-only regardless of labelStyle.
                Button {
                    startAnalysis(of: selectedVideos)
                } label: {
                    ToolbarBubbleLabel(text: "Analyze", systemImage: "sparkles")
                }
                .disabled(selection.isEmpty || store.isAnalyzing)
                .help("Runs a fresh analysis. Each run lands in its own analyze batch on the Scenes screen — earlier batches stay until you delete them there.")

                Button {
                    showGenerateSheet = true
                } label: {
                    ToolbarBubbleLabel(text: "Generate Video", systemImage: "wand.and.stars")
                }
                .disabled(selection.isEmpty || store.isAnalyzing)
                .help("Describe a video to create from the selected footage — the AI Wizard is set up from your description")
            }
        }
        .sheet(isPresented: $showGenerateSheet) {
            GenerateVideoSheet(source: .videos(selectedVideos))
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

    /// The model plan always shows for analysis — it carries the options
    /// (model, sampling, instructions, notes, people detection) for the run.
    private func withDispatchPlan(videos: [VideoRecord], _ run: @escaping () -> Void) {
        pendingDispatch = PendingDispatch(operation: .analyze, videos: videos, run: run)
    }

    private func startAnalysis(of videos: [VideoRecord]) {
        withDispatchPlan(videos: videos) { store.analyze(videos: videos) }
    }

    /// "16:9"-style label: snap to the common ratios, else reduce by GCD.
    static func aspectRatioLabel(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "—" }
        let value = Double(width) / Double(height)
        let common: [(String, Double)] = [
            ("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("4:3", 4.0 / 3), ("3:4", 3.0 / 4),
            ("1:1", 1), ("21:9", 21.0 / 9), ("2:3", 2.0 / 3), ("3:2", 3.0 / 2),
        ]
        if let match = common.first(where: { abs($0.1 - value) / $0.1 < 0.02 }) {
            return match.0
        }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let divisor = gcd(width, height)
        let w = width / divisor, h = height / divisor
        return w <= 50 && h <= 50 ? "\(w):\(h)" : String(format: "%.2f:1", value)
    }

    private var table: some View {
        // One pass over scenes/batches instead of an O(n) filter per table row.
        let sceneCounts = store.scenes.reduce(into: [Int64: Int]()) { $0[$1.videoID, default: 0] += 1 }
        let batchCounts = store.analysisRuns.reduce(into: [Int64: Int]()) { $0[$1.videoID, default: 0] += 1 }
        let transcriptCounts = store.analysisRuns.reduce(into: [Int64: Int]()) {
            if $1.hasTranscript { $0[$1.videoID, default: 0] += 1 }
        }
        // Distinct people recognized per video, via person: tags on scenes.
        let peopleCounts = store.scenes.reduce(into: [Int64: Set<String>]()) { acc, scene in
            for tag in scene.tags where tag.hasPrefix("person:") {
                acc[scene.videoID, default: []].insert(tag)
            }
        }
        return Table(store.videos, selection: $selection) {
            TableColumn("File") { video in
                HStack {
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

            TableColumn("Ratio") { video in
                Text(Self.aspectRatioLabel(width: video.width, height: video.height))
                    .foregroundStyle(.secondary)
            }
            .width(55)

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

            TableColumn("People") { video in
                countText(peopleCounts[video.id]?.count ?? 0)
                    .help("Distinct people recognized in this video — see the People section")
            }
            .width(55)

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
            Button("Generate Video…") {
                selection = ids
                showGenerateSheet = true
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
