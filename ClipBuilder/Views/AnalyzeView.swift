import AVKit
import SwiftUI

/// Analyze tab: source-video inventory with analysis/transcription status,
/// batch AI tagging, and a live progress log.
struct AnalyzeView: View {
    @Environment(AppStore.self) private var store

    @State private var selection: Set<Int64> = []
    @State private var isDropTargeted = false
    @State private var showGenerateSheet = false
    @State private var showNameWizard = false
    @State private var pendingDispatch: PendingDispatch?
    @State private var renamingID: Int64?
    @State private var renameText = ""
    @State private var fightResearchTarget: VideoRecord?
    @State private var soundbiteVideo: VideoRecord?
    @State private var showDuplicateScan = false
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
                    // Research opens through this view's top-level sheet — a
                    // presentation modifier inside the split child re-reports
                    // its min size mid-layout and trips AppKit's
                    // constraint-loop guard (crash).
                    VideoPreviewPane(video: video,
                                     onResearch: { fightResearchTarget = video })
                        .rememberedPaneWidth("pane.analyze.preview", min: 240, initial: 320, max: 440)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
            AnalysisLogPanel()
                .rememberedPaneHeight("pane.analyze.log", min: 120, initial: 160)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Raw Videos")
        .navigationSubtitle("\(store.videos.count) source videos")
        .toolbar {
            ToolbarItemGroup {
                // Explicit text + icon content: the toolbar renders plain
                // Label buttons icon-only regardless of labelStyle.
                Button {
                    let videos = selectedVideos
                    if !videos.isEmpty { startAnalysis(of: videos) }
                } label: {
                    ToolbarBubbleLabel(text: selection.count > 1 ? "Analyze \(selection.count)" : "Analyze",
                                       systemImage: "sparkles")
                }
                .disabled(selection.isEmpty || store.isAnalyzing)
                .help(selection.count > 1
                      ? "Analyzes the \(selection.count) selected videos back to back with the same plan — each lands in its own analyze batch on the Scenes screen"
                      : "Runs a fresh analysis of the selected video. Each run lands in its own analyze batch on the Scenes screen — earlier batches stay until you delete them there.")

                Button {
                    showNameWizard = true
                } label: {
                    ToolbarBubbleLabel(text: selection.count > 1 ? "Name \(selection.count) Files" : "Name File",
                                       systemImage: "textformat")
                }
                .disabled(selection.isEmpty || store.isAnalyzing)
                .help("File Name Wizard: builds a descriptive name for each selected file from what's on record — people detected, video type, fight research, scene stories — and shows every proposal for review before renaming. Analyze-batch names derived from a file update with it.")

                Button {
                    showGenerateSheet = true
                } label: {
                    ToolbarBubbleLabel(text: "Generate Video", systemImage: "wand.and.stars")
                }
                .disabled(selection.isEmpty || store.isAnalyzing)
                .help("Describe a video to create from the selected footage — the AI Wizard is set up from your description")
            }
        }
        .sheet(item: $fightResearchTarget) { video in
            FightResearchSheet(video: video)
        }
        .sheet(isPresented: $showGenerateSheet) {
            GenerateVideoSheet(source: .videos(selectedVideos))
        }
        .sheet(isPresented: $showNameWizard) {
            FileNameWizardSheet(videos: selectedVideos)
        }
        .sheet(item: $soundbiteVideo) { video in
            SoundbiteSheet(video: video)
        }
        .sheet(isPresented: $showDuplicateScan) {
            DuplicateReportSheet()
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
        startAnalysis(of: [video])
    }

    /// The model plan always shows for analysis — it carries the options
    /// (model, sampling, instructions, notes, people detection) for the run.
    /// A multi-selection runs back to back under one plan, one analyze batch
    /// per video; fine-trim only applies to single-video runs.
    private func startAnalysis(of videos: [VideoRecord]) {
        pendingDispatch = PendingDispatch(operation: .analyze, videos: videos,
                                          run: { store.analyze(videos: videos) })
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
                                // An emptied field cancels instead of saving
                                // a nameless file.
                                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    store.renameVideo(video, to: trimmed)
                                }
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

            TableColumn("Format") { video in
                Text("\(video.width)×\(video.height) · \(Self.aspectRatioLabel(width: video.width, height: video.height))")
                    .foregroundStyle(.secondary)
            }
            .width(130)

            TableColumn("Type") { video in
                // Display-only — the editable picker lives in the preview
                // pane so the grid stays a plain overview.
                if let type = video.type {
                    Text(type.label)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(80)

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
                    ProgressView()
                        .controlSize(.small)
                        .help("Transcribing — stop it from the preview pane")
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

            TableColumn("Fight Research") { video in
                // Status only — run/view/refresh live in the preview pane.
                HStack(spacing: 4) {
                    if video.type?.supportsFightFeatures != true {
                        Text("—")
                            .foregroundStyle(.secondary)
                            .help("Fight research applies to fight videos — set the type (in the preview pane) to Fight to enable it")
                    } else if store.fightResearchInFlight.contains(video.id) {
                        ProgressView().controlSize(.small)
                        Text("Researching…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if store.fightResearch[video.id] != nil {
                        Label("Researched", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .help("Fan-reaction research is saved — view or refresh it from the preview pane")
                    } else {
                        Text("Not researched")
                            .foregroundStyle(.tertiary)
                            .help("Run fight research from the preview pane")
                    }
                }
            }
            .width(110)
        }
        // The empty-row stripes render as detached gray bars on this macOS,
        // reading as debris under a short table — rows separate fine without
        // them.
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: Int64.self) { ids in
            let videos = store.videos.filter { ids.contains($0.id) }
            if !videos.isEmpty {
                Button(videos.count == 1 ? "Analyze" : "Analyze \(videos.count) Videos") {
                    startAnalysis(of: videos)
                }
            }
            if ids.count == 1, let video = videos.first {
                Button("Rename…") {
                    renameText = video.filename
                    renamingID = video.id
                    renameFocused = true
                }
            }
            if !videos.isEmpty {
                Button("File Name Wizard…") {
                    selection = ids
                    showNameWizard = true
                }
            }
            if ids.count == 1, let video = videos.first {
                Button("Find Soundbites…") {
                    soundbiteVideo = video
                }
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
            Divider()
            Button("Scan for Duplicates…") {
                showDuplicateScan = true
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
    /// Opens the fight-research sheet — presented by the parent view, not
    /// here: a .sheet inside this split-view child crashes AppKit layout.
    let onResearch: () -> Void

    @State private var player: AVPlayer?
    @State private var roster: [VideoPersonRecord] = []

    var body: some View {
        VStack(spacing: 8) {
            PlayerView(player: player)
                // Bounded height so the info sections below keep their room —
                // an unbounded player splits the pane 50/50 with the scroll
                // area and pushes the sections under the fold.
                .frame(maxWidth: .infinity, minHeight: 140, idealHeight: 230, maxHeight: 260)
                .background(.black, in: RoundedRectangle(cornerRadius: 8))
            VStack(spacing: 2) {
                Text(video.filename)
                    .font(.caption)
                    .lineLimit(1)
                Text("\(video.duration.timecode) · \(video.width)×\(video.height)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Video type — the grid's Type column is display-only; this is
            // the one editable control for it.
            HStack {
                Text("Type")
                    .font(.caption.weight(.medium))
                Spacer()
                Picker("Type", selection: Binding(
                    get: { video.videoType ?? "" },
                    set: { store.setVideoType(video, type: VideoType(rawValue: $0)) }
                )) {
                    Text("—").tag("")
                    ForEach(VideoType.allCases, id: \.rawValue) { type in
                        Text(type.label).tag(type.rawValue)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("What this footage is — inferred during analysis, editable here. Non-fight types skip fight scoring and fight research, and the AI Wizard sees the type when planning.")
            }

            // Transcription in flight: the grid only shows a spinner; the
            // stop control lives here.
            if store.transcribingVideoIDs.contains(video.id) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Transcribing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop", systemImage: "stop.circle") {
                        store.cancelTranscription(videoID: video.id)
                    }
                    .controlSize(.small)
                    .help("Stop transcribing this video")
                }
            }

            // The info sections live in a scroll view so the pane never
            // demands more minimum height than the split view can give —
            // fixed-height sections here made the pane's min size oscillate
            // against the player during layout, tripping AppKit's
            // constraint-loop guard (uncaught NSGenericException crash).
            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    // Fight action graph: per-fighter activity from the scoring
                    // pass — click to seek the player to a moment. Fight footage
                    // only: untyped videos don't show it either (set the Type
                    // column to Fight to enable).
                    if video.type?.supportsFightFeatures == true {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Fight Action")
                                    .font(.caption.weight(.medium))
                                Spacer()
                                if store.fightScoringInFlight.contains(video.id) {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Button(store.fightEvents[video.id]?.isEmpty == false ? "Re-score" : "Score") {
                                    store.scoreFightAction(video: video)
                                }
                                .controlSize(.small)
                                .disabled(store.fightScoringInFlight.contains(video.id))
                                .help("AI pass over the fight scenes logging strikes, takedowns, and submission attempts per fighter — runs automatically after analysis; progress shows in the analysis log")
                            }
                            if let events = store.fightEvents[video.id], !events.isEmpty {
                                FightGraphView(events: events,
                                               range: 0...max(1, video.duration),
                                               people: store.people,
                                               height: 64) { time in
                                    player?.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                                                 toleranceBefore: .zero, toleranceAfter: .zero)
                                }
                            } else {
                                Text("Not scored yet — analyzed fight footage scores automatically; use Score to run it now.")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // The video's people roster: build it here, ahead of any run —
                    // the analyze window then only asks which of them to require.
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("People")
                                .font(.caption.weight(.medium))
                            Spacer()
                            if store.isDetectingPeople {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Button(roster.isEmpty ? "Detect" : "Re-run") {
                                Task { roster = await store.detectPeopleInVideo(video) }
                            }
                            .controlSize(.small)
                            .disabled(store.isDetectingPeople)
                            .help("People-only AI pass: identifies everyone in this video (honoring markers) without a full analysis")
                        }
                        if roster.isEmpty {
                            Text("Nobody detected yet.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 8) {
                                    ForEach(roster) { entry in
                                        VStack(spacing: 2) {
                                            VideoPersonAvatar(record: entry, videoURL: video.url,
                                                              size: 36)
                                            Text(entry.displayName)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        .frame(width: 48)
                                        .help(entry.descriptor)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                }
            }

            // Fight research: the same view/refresh/run controls as the
            // table's Fight Research column, pinned at the pane's bottom
            // (outside the scroll — its fixed height is small enough not to
            // re-trip the split view's constraint-loop crash). Fight
            // footage only.
            if video.type?.supportsFightFeatures == true {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Fight Research")
                            .font(.caption.weight(.medium))
                        Spacer()
                        if store.fightResearchInFlight.contains(video.id) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Researching…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if store.fightResearch[video.id] != nil {
                            Button("View") {
                                onResearch()
                            }
                            .controlSize(.small)
                            .help("Fan-reaction research is saved for this fight — click to read and edit it")
                            Button("Refresh Research", systemImage: "arrow.clockwise") {
                                store.refreshFightResearch(video: video)
                            }
                            .labelStyle(.iconOnly)
                            .controlSize(.small)
                            .help("Re-crawl the web with the saved fight identity (progress in the analysis log)")
                        } else {
                            Button("Research…") {
                                onResearch()
                            }
                            .controlSize(.small)
                            .help("Identify this video's fight and crawl the web for fan reactions — the wizards can build the reel's story from it")
                        }
                    }
                    if let record = store.fightResearch[video.id] {
                        Text(record.fightLabel
                             + (record.event.isEmpty ? "" : " — \(record.event)"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if !store.fightResearchInFlight.contains(video.id) {
                        Text("Not researched yet.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .task(id: video.id) {
            player?.pause()
            player = AVPlayer(url: video.url)
            roster = await store.videoPeople(for: video.id)
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
                LogActions(lines: store.analysisLog) { store.analysisLog = [] }
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
