import AVKit
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var showAnalyzeWizard = false
    @State private var showingImporter = false
    @AppStorage("analyze.activity.expanded") private var activityExpanded = false
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
        VStack(spacing: 0) {
            HSplitView {
                table
                    .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                if let video = previewVideo {
                    // Research opens through this view's top-level sheet — a
                    // presentation modifier inside the split child re-reports
                    // its min size mid-layout and trips AppKit's
                    // constraint-loop guard (crash).
                    VideoPreviewPane(video: video,
                                     onResearch: { fightResearchTarget = video },
                                     onNameWizard: { showNameWizard = true })
                        .rememberedPaneWidth("pane.analyze.preview", min: 240, initial: 320, max: 440)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
            Divider()
            AnalysisActivityBar(isExpanded: $activityExpanded)
            if activityExpanded {
                AnalysisLogPanel()
                    .frame(minHeight: 140, maxHeight: 260)
                Divider()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Raw Videos")
        .navigationSubtitle("\(store.videos.count) source videos")
        .toolbar {
            ToolbarItemGroup {
                Button("Add Videos", systemImage: "plus") {
                    showingImporter = true
                }
                .help("Add source videos to this profile")

                Button {
                    let videos = selectedVideos
                    if !videos.isEmpty { startAnalysis(of: videos) }
                } label: {
                    Label(selection.count > 1 ? "Analyze \(selection.count)" : "Analyze",
                          systemImage: "sparkles")
                }
                .disabled(selection.isEmpty || store.isAnalyzing)
                .help(selection.count > 1
                      ? "Analyzes the \(selection.count) selected videos back to back with the same plan — each lands in its own analyze batch on the Scenes screen"
                      : "Runs a fresh analysis of the selected video. Each run lands in its own analyze batch on the Scenes screen — earlier batches stay until you delete them there.")

                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Run Full Pipeline", systemImage: "wand.and.rays") {
                        showAnalyzeWizard = true
                    }
                    .disabled(selection.isEmpty || store.isPipelineRunning)
                    Divider()
                    Button("Generate Video…", systemImage: "wand.and.stars") {
                        showGenerateSheet = true
                    }
                    .disabled(selection.isEmpty || store.isAnalyzing)
                    Button("Scan for Duplicates…", systemImage: "rectangle.on.rectangle") {
                        showDuplicateScan = true
                    }
                }
                .help("Open less-frequent video actions")
            }
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                store.importVideos(urls)
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
        .sheet(isPresented: $showAnalyzeWizard) {
            AnalyzeWizardSheet(videos: selectedVideos)
        }
        .sheet(item: $pendingDispatch) { pending in
            DispatchPlanSheet(operation: pending.operation, videos: pending.videos,
                              onStart: pending.run)
        }
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
        let sceneCounts = store.sceneIndex.countsByVideo
        let batchCounts = store.analysisRuns.reduce(into: [Int64: Int]()) { $0[$1.videoID, default: 0] += 1 }
        let transcriptCounts = store.analysisRuns.reduce(into: [Int64: Int]()) {
            if $1.hasTranscript { $0[$1.videoID, default: 0] += 1 }
        }
        // Distinct people tagged across a video's batches.
        let personTagsByRun = store.sceneIndex.personTagsByRun
        let peopleCounts = store.analysisRuns.reduce(into: [Int64: Set<String>]()) { result, run in
            if let tags = personTagsByRun[run.id] { result[run.videoID, default: []].formUnion(tags) }
        }.mapValues(\.count)
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
                        if let provenance = video.namingProvenance {
                            ProvenanceBadge(provenance: provenance, role: "Named by", size: 11)
                        }
                    }
                }
            }
            .width(min: 200, ideal: 320)

            TableColumn("Duration") { video in
                Text(video.duration.timecode)
                    .monospacedDigit()
            }
            .width(70)

            TableColumn("Type") { video in
                Text(video.type?.label ?? "—")
                    .foregroundStyle(video.type == nil ? .tertiary : .secondary)
                    .help(video.type == nil ? "Not classified yet — analysis infers the footage type"
                                            : "Footage type; change it in the detail pane")
            }
            .width(min: 70, ideal: 90)

            TableColumn("Status") { video in
                if store.isAnalyzing && selection.contains(video.id) {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Analyzing")
                    }
                    .foregroundStyle(.secondary)
                } else {
                    let batches = batchCounts[video.id] ?? 0
                    let scenes = sceneCounts[video.id] ?? 0
                    let people = peopleCounts[video.id] ?? 0
                    let hasTranscript = (transcriptCounts[video.id] ?? 0) > 0
                    // One line of glyphs: analyzed check + scene count, then
                    // a transcript mark and a people count, each only when
                    // the video actually has them.
                    // Fixed slots so the marks line up as columns down
                    // the table; empty slots keep their width.
                    HStack(spacing: 6) {
                        if batches > 0 {
                            Label("\(scenes)", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .monospacedDigit()
                                .frame(width: 58, alignment: .leading)
                                .help("Analyzed — \(scenes) scene\(scenes == 1 ? "" : "s") ready")
                                .accessibilityLabel("Analyzed, \(scenes) scenes")
                        } else {
                            Label("Needs analysis", systemImage: "circle.dashed")
                                .foregroundStyle(.secondary)
                        }
                        if batches > 0 {
                            Group {
                                if hasTranscript {
                                    Image(systemName: "text.quote")
                                        .foregroundStyle(.secondary)
                                        .help("Transcript ready")
                                        .accessibilityLabel("Transcript ready")
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(width: 18, alignment: .center)
                            Group {
                                if people > 0 {
                                    Label("\(people)", systemImage: "person.2.fill")
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                        .help("\(people) \(people == 1 ? "person" : "people") found")
                                        .accessibilityLabel("\(people) people found")
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(width: 44, alignment: .leading)
                        }
                    }
                }
            }
            .width(min: 130, ideal: 160)
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
                ContentUnavailableView {
                    Label("Add your first source video", systemImage: "film")
                } description: {
                    Text("Drop video files here, or add them from Finder. They are copied into this profile’s Input folder.")
                } actions: {
                    Button("Add Videos…") { showingImporter = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

}

/// A compact activity summary leaves the footage table useful until a person
/// actively needs the detailed log.
private struct AnalysisActivityBar: View {
    @Environment(AppStore.self) private var store
    @Binding var isExpanded: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button {
                isExpanded.toggle()
            } label: {
                Label(isExpanded ? "Hide Activity" : "Show Activity",
                      systemImage: isExpanded ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.plain)

            if store.isAnalyzing {
                ProgressView(value: store.analysisProgress)
                    .frame(width: 110)
                Text(store.analysisStage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Stop", systemImage: "stop.circle") {
                    store.cancelAnalysis()
                }
                .controlSize(.small)
            } else if let last = store.analysisLog.last, !last.isEmpty {
                Text(last)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Select videos, then choose Analyze.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
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
    /// Opens the File Name Wizard for this video — same parent-presented
    /// sheet rule.
    let onNameWizard: () -> Void

    @State private var player: AVPlayer?
    @State private var roster: [VideoPersonRecord] = []
    /// Whether any transcript rows exist for this video — shows the editor.
    @State private var hasTranscript = false
    @State private var showTranscript = false

    var body: some View {
        VStack(spacing: 8) {
            PlayerView(player: player)
                // Bounded height so the info sections below keep their room —
                // an unbounded player splits the pane 50/50 with the scroll
                // area and pushes the sections under the fold.
                .frame(maxWidth: .infinity, minHeight: 140, idealHeight: 230, maxHeight: 260)
                .background(.black, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if player == nil {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Text(video.filename)
                        .font(.caption)
                        .lineLimit(1)
                    Button(action: onNameWizard) {
                        Image(systemName: "wand.and.sparkles")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .help("File Name Wizard: builds a descriptive name for this file from what's on record — people, type, fight research, scene stories — reviewed before renaming")
                }
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
            } else if hasTranscript {
                // The whole transcript, editable segment by segment.
                HStack {
                    Text("Transcript")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Button("Edit Transcript…", systemImage: "text.quote") {
                        showTranscript = true
                    }
                    .controlSize(.small)
                    .help("Open the full transcript of this file and edit any segment's text")
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
            // Drop the old player right away so the pane follows the selection
            // instantly, then open the file off the main thread: creating the
            // player synchronously probes the file and stalled the click.
            player?.pause()
            player = nil
            roster = []
            let asset = AVURLAsset(url: video.url)
            _ = try? await asset.load(.isPlayable, .duration, .preferredTransform)
            guard !Task.isCancelled else { return }
            player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            roster = await store.videoPeople(for: video.id)
        }
        // Re-check when a transcription for this video finishes.
        .task(id: "\(video.id)|\(store.transcribingVideoIDs.contains(video.id))") {
            guard let database = store.database else { return }
            hasTranscript = ((try? await database.fetchTranscripts(videoID: video.id)) ?? []).isEmpty == false
        }
        .sheet(isPresented: $showTranscript) {
            TranscriptSheet(video: video)
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
