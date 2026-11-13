import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// Analyze tab: source-video inventory with analysis/transcription status,
/// batch AI tagging, and a live progress log.
struct AnalyzeView: View {
    @State private var showingDriveBrowser = false
    @State private var confirmingDriveUpload = false
    /// Videos queued for "Remove from Project"; non-empty shows the confirmation.
    @State private var pendingRemoval: Set<Int64> = []
    /// Sources awaiting the footer's remove confirmation.
    @State private var pendingSourceRemoval: [VideoRecord] = []
    /// Videos whose analyze batches are queued for removal; non-empty shows the confirmation.
    @State private var pendingBatchRemoval: Set<Int64> = []
    @State private var showingDriveUpload = false
    @State private var pendingDriveUploads: [DriveMedia] = []
    @State private var skippedDriveUploads = 0
    @State private var sortOrder: [KeyPathComparator<SourceRow>] = []
    /// The sort and the column order/visibility the user chose, kept on
    /// this Mac only (user defaults, not the profile).
    @AppStorage("sources.table.sort") private var storedSort = ""
    @AppStorage("sources.table.columns") private var columnCustomization = TableColumnCustomization<SourceRow>()
    /// Projects each source belongs to, for the inspector's Projects row.
    @State private var projectNames: [Int64: [String]] = [:]
    @State private var projectNamesVersion = 0
    @Environment(AppStore.self) private var store
    @Environment(\.workspacePageVisible) private var pageVisible

    @State private var selection: Set<Int64> = []
    @State private var typeFocusVideoID: Int64?
    @State private var typeFocusRequest: UUID?
    @State private var fightStatsFocusVideoID: Int64?
    @State private var fightStatsFocusRequest: UUID?
    @State private var isDropTargeted = false
    @State private var showGenerateSheet = false
    @State private var showNameWizard = false
    @State private var pendingDispatch: PendingDispatch?
    @State private var fightResearchTarget: VideoRecord?
    @State private var fightStoryTarget: VideoRecord?
    @State private var soundbiteVideo: VideoRecord?
    @State private var showDuplicateScan = false
    @State private var showAnalyzeWizard = false
    @State private var comparisonRevision = 0
    @State private var comparisonPlanKey: String?
    @State private var checkingAnalysis = false
    /// Analyze was pressed on videos whose last analysis did not finish:
    /// the prompt asks whether to resume or start over.
    @State private var resumePrompt: ResumePrompt?
    @State private var typePrompt: TypePrompt?
    /// Continue's work, held until the type prompt sheet has closed.
    @State private var afterTypePrompt: (() -> Void)?
    @State private var showingImporter = false
    @State private var showingProjectVideoPicker = false
    @State private var showingProjectFromSelection = false
    @State private var newProjectName = ""

    /// The video the preview pane shows — follows `selection` one run-loop
    /// turn behind it (see `syncPreview`).
    @State private var previewVideoID: Int64?
    /// Scene playing from the person popover (sheet owned here, not by the
    /// split-view child).
    @State private var batchComparison: ScenesView.CompareRequest?
    @State private var reassignPerson: PersonRecord?
    @State private var reassignVideo: VideoRecord?
    @State private var newPersonName = ""
    /// Exactly one selected video → the preview pane shows it.
    private var previewVideo: VideoRecord? {
        guard let previewVideoID else { return nil }
        return store.videos.first { $0.id == previewVideoID }
    }

    /// Rebuilding the pane (split view + player view + hosted sections)
    /// is real AppKit layout work. Done in the same transaction as the
    /// selection change, it lands before the table's new highlight can
    /// paint. Deferring one turn lets the highlight show first; the pane
    /// then swaps to its loading state and builds behind it.
    private func syncPreview(to selection: Set<Int64>) {
        let target: Int64? = selection.count == 1 ? selection.first : nil
        guard target != previewVideoID else { return }
        DispatchQueue.main.async {
            // Selection may have moved again in the meantime.
            previewVideoID = self.selection.count == 1 ? self.selection.first : nil
        }
    }

    /// Rename runs in an AppKit alert sheet rather than an inline field or
    /// a SwiftUI alert: swapping a row's Text for a TextField put the field
    /// in a different row on macOS 27 (Table row reuse), and SwiftUI's
    /// alert can't put focus in its text field or select its contents.
    /// Here the field is the initial first responder, so it opens focused
    /// with the whole name selected; Return renames, Escape cancels.
    private func beginRename(_ video: VideoRecord) {
        guard let window = NSApp.keyWindow else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Video"
        alert.informativeText = "Renames \(video.filename) on disk; scenes and batches follow the file."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: video.filename)
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        field.placeholderString = "File name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            commitRename(video, to: field.stringValue)
        }
    }

    /// An emptied or unchanged name cancels instead of saving.
    private func commitRename(_ video: VideoRecord, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != video.filename else { return }
        store.renameVideo(video, to: trimmed)
    }

    private var selectedVideos: [VideoRecord] {
        store.videos.filter { selection.contains($0.id) }
    }

    // MARK: - Ask AI

    /// What Ask AI reads from this page: the footer's missing-step counts,
    /// the selection and the sort (SourcesAssistant).
    private var assistantState: AssistantPageState {
        let missing = allMissingSteps
        var counts = ["missing.files": missing.count, "selected": selection.count]
        for step in AnalysisSteps.Step.allCases {
            counts["missing.\(step.rawValue)"] = missing.values.count { $0.contains(step) }
        }
        return AssistantPageState(
            counts: counts,
            flags: ["selected.fight": previewVideo?.type?.supportsFightFeatures == true],
            values: ["sort": sortOrder.isEmpty ? "default" : "custom"],
            selection: selectedVideos.map(\.filename))
    }

    /// Missing steps of every file, narrowed to `only` (all steps when nil),
    /// behind the footer's own busy guard, checked again now that the
    /// command runs.
    private func runMissingSteps(only step: AnalysisSteps.Step? = nil) {
        guard !store.isMissingStepsBatchBusy else {
            store.presentNotice("Ask AI", "Analysis is already running on this page. Try again when it finishes.")
            return
        }
        let missing = step.map { step in allMissingSteps.compactMapValues { $0.contains(step) ? [step] : nil } }
            ?? allMissingSteps
        guard !missing.isEmpty else { return }
        store.runMissingAnalysisSteps(missing, videos: store.videos, syncWhenDone: true)
    }

    private func runAssistantCommand(_ command: AssistantCommand) {
        switch command.actionID {
        case "sources.add": showingImporter = true
        case "sources.addFromHome":
            if !store.isHomeProject { showingProjectVideoPicker = true }
        case "sources.analyze.missing": runMissingSteps()
        case "sources.transcribe.missing": runMissingSteps(only: .transcript)
        case "sources.speakers.name": runMissingSteps(only: .speakerNames)
        case "sources.duplicates.scan": showDuplicateScan = true
        case "sources.names.suggest":
            if selection.isEmpty {
                selection = Set(store.videos.filter { SourcesAssistant.isCameraName($0.filename) }.map(\.id))
            }
            if !selection.isEmpty { showNameWizard = true }
        case "sources.wizard.open":
            if !selectedVideos.isEmpty { store.openWizard(with: selectedVideos) }
        case "sources.fight.research":
            if let video = previewVideo, video.type?.supportsFightFeatures == true { fightResearchTarget = video }
        case "sources.fight.story":
            if let video = previewVideo, video.type?.supportsFightFeatures == true { fightStoryTarget = video }
        case "sources.soundbites":
            if let video = previewVideo ?? selectedVideos.first { soundbiteVideo = video }
        default: break
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            LanguageReadinessBanner()
            HSplitView {
                VStack(spacing: 0) {
                    table
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if store.analysisStepBatch != nil || !allMissingSteps.isEmpty {
                        Divider()
                        missingStepsFooter
                    }
                }
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 0) {
                    if let video = previewVideo {
                        // Research opens through this view's top-level sheet — a
                        // presentation modifier inside the split child re-reports
                        // its min size mid-layout and trips AppKit's
                        // constraint-loop guard (crash).
                        VideoPreviewPane(video: video,
                                         projectNames: projectNames[video.id] ?? [],
                                         typeFocusRequest: typeFocusVideoID == video.id ? typeFocusRequest : nil,
                                         fightStatsFocusRequest: fightStatsFocusVideoID == video.id ? fightStatsFocusRequest : nil,
                                         onResearch: { fightResearchTarget = video },
                                         onStory: { fightStoryTarget = video },
                                         onNameWizard: { showNameWizard = true },
                                         onCompareBatches: { batchComparison = ScenesView.CompareRequest(runs: $0, video: video) },
                                         onSelectVideo: { selection = [$0.id] },
                                         onReassignNewPerson: { person, video, suggested in
                                             newPersonName = suggested
                                             reassignVideo = video
                                             reassignPerson = person
                                         },
                                         coverage: tableSummary.coverage[video.id],
                                         missingSteps: missingSteps,
                                         onAnalyze: { startAnalysis(of: [video]) },
                                         onRunSteps: { runSteps($0, video: video) })
                            .frame(maxHeight: .infinity)
                    } else {
                        SourcesPanePlaceholder(videoCount: store.videos.filter(\.isReachable).count, selectionCount: selection.count)
                            .frame(maxHeight: .infinity)
                    }
                    Divider()
                    selectionActionsFooter
                }
                .rememberedPaneWidth("pane.analyze.preview", min: 240, initial: 320, max: 440)
                .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingDriveBrowser) { GoogleDriveBrowserSheet() }
        .sheet(isPresented: $showingDriveUpload) { GoogleDriveBrowserSheet(uploadMedia: pendingDriveUploads) }
        .confirmationDialog(
            resumePrompt.map { $0.unfinished.count == 1 ? "Resume the analysis of \($0.unfinished[0].filename)?"
                                                        : "Resume \($0.unfinished.count) unfinished analyses?" } ?? "",
            isPresented: Binding(get: { resumePrompt != nil }, set: { if !$0 { resumePrompt = nil } }),
            titleVisibility: .visible,
            presenting: resumePrompt
        ) { prompt in
            Button("Resume") {
                store.analyze(videos: prompt.videos)
            }
            Button("Start Over", role: .destructive) {
                Task {
                    await store.discardAnalysisCheckpoints(videoIDs: prompt.unfinished.map(\.id))
                    presentPlan(for: prompt.videos)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            Text(resumeMessage(prompt))
        }
        .confirmationDialog("Upload selected videos to Google Drive?", isPresented: $confirmingDriveUpload) {
            Button("Choose Folder…") { showingDriveUpload = true }
        } message: {
            Text("\(pendingDriveUploads.count) videos will upload. \(skippedDriveUploads) skipped (already in Drive). Uploads continue in the background.")
        }
        .confirmationDialog(
            "Remove the analyze batches of \(pendingBatchRemoval.count == 1 ? "this video" : "\(pendingBatchRemoval.count) videos")?",
            isPresented: Binding(get: { !pendingBatchRemoval.isEmpty }, set: { if !$0 { pendingBatchRemoval = [] } }),
            titleVisibility: .visible
        ) {
            Button("Remove Analyze Batches", role: .destructive) {
                store.deleteAnalysisRuns(forVideos: pendingBatchRemoval)
                pendingBatchRemoval = []
            }
        } message: {
            Text(store.batchDeletionMessage(store.analysisRuns.filter { pendingBatchRemoval.contains($0.videoID) }))
        }
        .confirmationDialog(
            pendingRemoval.count == 1 ? "Remove this video from the project?"
                : "Remove \(pendingRemoval.count) videos from the project?",
            isPresented: Binding(get: { !pendingRemoval.isEmpty }, set: { if !$0 { pendingRemoval = [] } }),
            titleVisibility: .visible
        ) {
            Button("Remove from Project", role: .destructive) { removeFromProject(pendingRemoval) }
        } message: {
            Text("The video stays in Home and in any other project, with its scenes, transcripts and timelines. Only its place in this project is removed.")
        }
        .confirmationDialog(
            store.isTeamAttachedProfile
                ? (pendingSourceRemoval.count == 1 ? "Remove this source from this Mac?"
                                                   : "Remove \(pendingSourceRemoval.count) sources from this Mac?")
                : (pendingSourceRemoval.count == 1 ? "Remove this source?"
                                                   : "Remove \(pendingSourceRemoval.count) sources?"),
            isPresented: Binding(get: { !pendingSourceRemoval.isEmpty }, set: { if !$0 { pendingSourceRemoval = [] } }),
            titleVisibility: .visible
        ) {
            Button(store.isTeamAttachedProfile ? "Remove from this Mac" : "Remove", role: .destructive) {
                let videos = pendingSourceRemoval
                pendingSourceRemoval = []
                selection.subtract(videos.map(\.id))
                store.removeSources(videos)
            }
        } message: {
            if store.isTeamAttachedProfile {
                let offloadable = pendingSourceRemoval.filter { $0.driveFileID != nil && $0.isPresent }.count
                Text((offloadable > 0
                      ? "\(offloadable) local cop\(offloadable == 1 ? "y is" : "ies are") removed; Google Drive keeps the file. "
                      : "")
                     + "The sources disappear from this Mac's lists but stay on record for your team.")
            } else {
                Text((store.isHomeProject
                      ? "Removing from Home removes the source from every project. "
                      : "The source is removed from Home and from every project, not only this one. ")
                     + "Its scenes, transcripts and analyze batches are kept, so adding the same file again needs no new analysis. Files in the profile's source folder move to the Trash.")
            }
        }
        .screenTitle("Sources", subtitle: "\(store.videos.filter(\.isReachable).count) source videos")
        .askAI(SourcesAssistant(), pageState: assistantState)
        .onAssistantCommand("sources.") { runAssistantCommand($0) }
        .toolbar {
            if pageVisible {
                ToolbarItemGroup {
                    if store.isHomeProject {
                        Button {
                            showingImporter = true
                        } label: {
                            ToolbarBubbleLabel(text: "Add Videos", systemImage: "plus")
                        }
                        .help("Add source videos to this project")
                    } else {
                        Menu {
                            Button(store.homeVideosNotInProjectCount > 0
                                   ? "From Home… (\(store.homeVideosNotInProjectCount) available)"
                                   : "From Home… (none available)") { showingProjectVideoPicker = true }
                                .lineLimit(1).fixedSize()
                                .disabled(store.homeVideosNotInProjectCount == 0)
                            Button("From Finder…") { showingImporter = true }
                                .lineLimit(1).fixedSize()
                            Button("From Google Drive…") { showingDriveBrowser = true }
                                .lineLimit(1).fixedSize()
                        } label: {
                            ToolbarBubbleLabel(text: "Add Videos", systemImage: "plus")
                        } primaryAction: {
                            // A project draws on Home first; with nothing
                            // left there to add, the label opens Finder.
                            if store.homeVideosNotInProjectCount > 0 {
                                showingProjectVideoPicker = true
                            } else {
                                showingImporter = true
                            }
                        }
                        // The indicator is the only way to open the menu on a
                        // split button; the label itself runs the default.
                        .help(store.homeVideosNotInProjectCount > 0
                              ? "Add videos from Home, or open the menu to add new files from Finder or Google Drive"
                              : "Add new videos from Finder, or open the menu for Google Drive")
                    }
                    Button { showingDriveBrowser = true } label: { ToolbarBubbleLabel(text: "Add from Google Drive…", systemImage: "icloud.and.arrow.down") }
                        .help("Pick videos from Google Drive and add them to this project")
                    Button {
                        pendingDriveUploads = GoogleDriveTransfers.uploadCandidates(selectedVideos.map(\.driveMedia))
                        skippedDriveUploads = selectedVideos.count - pendingDriveUploads.count
                        confirmingDriveUpload = true
                    } label: {
                        ToolbarBubbleLabel(text: "Upload to Google Drive…", systemImage: "icloud.and.arrow.up")
                    }
                    .disabled(GoogleDriveTransfers.uploadCandidates(selectedVideos.map(\.driveMedia)).isEmpty)
                    .help("Upload the selected videos to Google Drive")
                    DriveMediaMenu(media: selectedVideos.filter { $0.driveFileID != nil }.map(\.driveMedia))
                        .disabled(!selectedVideos.contains { $0.driveFileID != nil })
                    // Last so they overflow first on a narrow window; the banner
                    // under the toolbar explains what they are for.
                    LanguageReadinessControls()
                }
            }
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                if let projectID = store.activeProjectID {
                    store.importVideos(urls, toProjectID: projectID)
                } else {
                    store.importVideos(urls)
                }
            }
        }
        .sheet(item: $reassignPerson, onDismiss: {
            reassignVideo = nil
            newPersonName = ""
        }) { person in
            VStack(alignment: .leading, spacing: Theme.spaceM) {
                Text("Move to a new person")
                    .font(.headline)
                Text("Move \(person.displayName)'s references in \(reassignVideo?.filename ?? "this video") to:")
                    .foregroundStyle(.secondary)
                TextField("Name", text: $newPersonName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { createReassignedPerson(from: person) }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { reassignPerson = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Create and Move") { createReassignedPerson(from: person) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(newPersonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.spaceL)
            .frame(width: 380)
        }
        .sheet(item: $batchComparison) { request in
            CompareBatchesSheet(runs: request.runs, video: request.video)
        }
        .sheet(item: $fightResearchTarget) { video in
            FightResearchSheet(video: video)
        }
        .sheet(item: $fightStoryTarget) { video in
            FightStorySheet(fightVideo: video)
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
        // What Continue starts may present its own dialog (the transcription
        // model question); it runs once this sheet has gone, or AppKit can
        // drop that presentation.
        .sheet(item: $typePrompt, onDismiss: {
            let run = afterTypePrompt
            afterTypePrompt = nil
            run?()
        }) { prompt in
            VideoTypePromptSheet(videos: prompt.untyped,
                                 onContinue: { confirmed in
                                     afterTypePrompt = { prompt.continue(confirmed) }
                                     typePrompt = nil
                                 },
                                 onCancel: { typePrompt = nil })
        }
        .sheet(isPresented: $showingProjectVideoPicker) {
            ProjectVideoPickerSheet()
        }
        .alert("New Project from Selection", isPresented: $showingProjectFromSelection) {
            TextField("Project name", text: $newProjectName)
            Button("Create", action: createProjectFromSelection)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected Home files will also appear in the new project.")
        }
        // A "re-run this batch" hand-off from the Scenes screen: select the
        // video and open the plan sheet with the batch's options loaded.
        .task {
            if let video = store.pendingAnalyzeSetup { presentPrefilledPlan(for: video) }
        }
        .onChange(of: store.pendingAnalyzeSetup) { _, video in
            if let video { presentPrefilledPlan(for: video) }
        }
        .task(id: comparisonRevision) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await store.refreshAnalysisComparisons()
        }
        .onChange(of: store.analysisRuns) { _, _ in comparisonRevision += 1 }
        .onChange(of: store.videos) { _, _ in comparisonRevision += 1 }
        .onChange(of: store.people) { _, _ in comparisonRevision += 1 }
        .onChange(of: store.restoredAnalysisRequests) { comparisonRevision += 1 }
        .onChange(of: store.transcriptCountsVersion) { comparisonRevision += 1 }
        .onChange(of: store.videoPeopleVersion) { comparisonRevision += 1 }
        .task(id: projectNamesKey) { await loadProjectNames() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            refreshComparisonPlanKey()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshComparisonPlanKey()
        }
        .onAppear {
            restoreProjectState()
            refreshComparisonPlanKey()
        }
        .onChange(of: store.projectStateVersion) { restoreProjectState() }
        .onChange(of: selection, initial: true) { old, new in
            // Mid-load the table's selection is the previous project's.
            if !store.isLoadingProject {
                if new.isEmpty { ensureSelection() }
                store.sourceSelection = selection
            }
            if old != new { UITiming.selectionChanged(screen: "Sources", count: new.count) }
            syncPreview(to: selection)
        }
        .onChange(of: store.videos.map(\.id)) { _, ids in
            guard !store.isLoadingProject else { return }
            selection.formIntersection(ids)
            ensureSelection()
        }
    }

    /// The point is editing the options, so the sheet opens even when the
    /// model-plan prompt is muted.
    private func presentPrefilledPlan(for video: VideoRecord) {
        store.pendingAnalyzeSetup = nil
        selection = [video.id]
        presentPlan(for: [video])
    }

    /// The model plan always shows for analysis — it carries the options
    /// (model, sampling, instructions, notes, people detection) for the run.
    private func refreshComparisonPlanKey() {
        let plan = AnalysisRequest.capturePlan(defaults: .standard, singleVideo: true,
            provider: nil, model: nil, includeFightScoring: true)
        let key = AnalysisComparisonMemo.planKey(plan)
        guard key != comparisonPlanKey else { return }
        comparisonPlanKey = key
        comparisonRevision += 1
    }

    /// A multi-selection runs back to back under one plan, one analyze batch
    /// per video; fine-trim only applies to single-video runs.
    private struct StepsKey: Equatable {
        var videoID: Int64?
        var type: String?
        var peopleDetectedAt: String?
        /// The transcript's usability depends on the chosen language.
        var language: String?
        var languageSource: String?
        var runsVersion: Int
        var scenesVersion: Int
        var transcriptCountsVersion: Int
        var peopleVersion: Int
        var speakerNamingVersion: Int
        var passes: [AnalysisPassRecord]
        var hasCheckpoint: Bool
        var previewed: Bool
    }
    @State private var stepsMemo = MemoBox<StepsKey, [AnalysisSteps.Step]>()

    private struct AllStepsKey: Equatable {
        var videos: [String]
        var runsVersion: Int
        var scenesVersion: Int
        var transcriptCountsVersion: Int
        var peopleVersion: Int
        var speakerNamingVersion: Int
        var passes: [AnalysisPassRecord]
        var checkpoints: Set<Int64>
        var previews: Set<Int64>
    }
    @State private var allStepsMemo = MemoBox<AllStepsKey, [Int64: [AnalysisSteps.Step]]>()

    /// Missing or outdated steps of every file on this Mac, behind the table
    /// footer's "N files · Analyze N steps" button.
    private var allMissingSteps: [Int64: [AnalysisSteps.Step]] {
        let present = store.videos.filter(\.isPresent)
        let key = AllStepsKey(videos: present.map {
            "\($0.id)|\($0.videoType ?? "")|\($0.peopleDetectedAt ?? "")|\($0.activeRunKey ?? "")|\($0.language ?? "")|\($0.languageSource ?? "")"
        },
                              runsVersion: store.analysisRunsVersion, scenesVersion: store.scenesVersion,
                              transcriptCountsVersion: store.transcriptCountsVersion, peopleVersion: store.videoPeopleVersion,
                              speakerNamingVersion: store.speakerNamingVersion,
                              passes: store.analysisPasses, checkpoints: Set(store.analysisCheckpoints.keys),
                              previews: Set(store.analysisRequestPreviews.keys))
        return allStepsMemo(key) {
            var result: [Int64: [AnalysisSteps.Step]] = [:]
            for video in present {
                let report = AnalysisCoverage.report(
                    video: video, activeRun: store.activeLayer(videoID: video.id).run,
                    scenes: store.scenes.filter { $0.videoID == video.id },
                    transcriptCount: store.transcriptCounts[video.id] ?? 0,
                    transcriptUsable: store.transcriptUsable(video),
                    transcriptKey: store.transcriptFacts[video.id]?.transcriptionKey,
                    passes: store.analysisPasses, hasCheckpoint: store.analysisCheckpoints[video.id] != nil,
                    duplicateOf: store.duplicateAnalysis(for: video))
                let steps = AnalysisSteps.missing(video: video, report: report,
                                                  peopleCount: store.videoPeopleCounts[video.id] ?? 0,
                                                  passes: store.analysisPasses,
                                                  speakerNaming: store.speakerNamingSummaries[video.id]?.verdict)
                if !steps.isEmpty { result[video.id] = steps }
            }
            return result
        }
    }

    /// Pinned under the table: one button for every missing step of every
    /// file, then a team sync so teammates get the results.
    private var missingStepsFooter: some View {
        let missing = allMissingSteps
        let summary = AnalysisSteps.summary(missing)
        let running = store.analysisStepBatch != nil
        let busy = store.isMissingStepsBatchBusy
        return HStack(spacing: Theme.spaceS) {
            if running {
                ProgressView().controlSize(.small)
                Text("Analyzing missing steps…").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
            } else if store.teamSync.attached {
                Text("Results sync with the team when done").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if summary.files > 0 {
                Button(AnalysisSteps.batchButtonTitle(files: summary.files, steps: summary.steps)) {
                    runAllMissingSteps()
                }
                .buttonStyle(.borderedProminent)
                .lineLimit(1).fixedSize()
                .disabled(busy)
                .help("Runs every missing or outdated analysis step of every file on this Mac, then syncs the results with the team")
            }
        }
        .padding(.horizontal, Theme.spaceS)
        .padding(.vertical, Theme.spaceXS)
    }

    /// The footer's batch, after the type question for files that have
    /// none: the missing steps are recomputed once the types are saved,
    /// since the type decides which steps a file expects.
    private func runAllMissingSteps() {
        let missing = allMissingSteps
        // A stopped run resumes with the type its request recorded, so
        // only files without one are asked.
        let untyped = store.videos.filter { $0.type == nil && missing[$0.id] != nil && store.analysisCheckpoints[$0.id] == nil }
        if !untyped.isEmpty {
            typePrompt = TypePrompt(untyped: untyped) { _ in
                let refreshed = allMissingSteps
                guard !refreshed.isEmpty else { return }
                store.runMissingAnalysisSteps(refreshed, videos: store.videos, syncWhenDone: true)
            }
            return
        }
        store.runMissingAnalysisSteps(missing, videos: store.videos, syncWhenDone: true)
    }

    /// Steps the previewed recording is still missing; empty hides the button.
    private var missingSteps: [AnalysisSteps.Step] {
        guard let video = previewVideo else { return [] }
        let key = StepsKey(videoID: video.id, type: video.videoType, peopleDetectedAt: video.peopleDetectedAt,
                           language: video.language, languageSource: video.languageSource,
                           runsVersion: store.analysisRunsVersion, scenesVersion: store.scenesVersion,
                           transcriptCountsVersion: store.transcriptCountsVersion, peopleVersion: store.videoPeopleVersion,
                           speakerNamingVersion: store.speakerNamingVersion,
                           passes: store.analysisPasses,
                           hasCheckpoint: store.analysisCheckpoints[video.id] != nil,
                           previewed: store.analysisRequestPreviews[video.id] != nil)
        return stepsMemo(key) {
            let report = AnalysisCoverage.report(
                video: video, activeRun: store.activeLayer(videoID: video.id).run,
                scenes: store.scenes.filter { $0.videoID == video.id },
                transcriptCount: store.transcriptCounts[video.id] ?? 0,
                transcriptUsable: store.transcriptUsable(video),
                transcriptKey: store.transcriptFacts[video.id]?.transcriptionKey,
                passes: store.analysisPasses, hasCheckpoint: store.analysisCheckpoints[video.id] != nil,
                duplicateOf: store.duplicateAnalysis(for: video))
            return AnalysisSteps.missing(video: video, report: report,
                                         peopleCount: store.videoPeopleCounts[video.id] ?? 0,
                                         passes: store.analysisPasses,
                                         speakerNaming: store.speakerNamingSummaries[video.id]?.verdict)
        }
    }

    private func stepsInFlight(_ video: VideoRecord) -> Bool {
        store.analyzingVideoIDs.contains(video.id) || store.transcribingVideoIDs.contains(video.id)
            || store.isDetectingPeople || store.fightScoringInFlight.contains(video.id)
            || store.speakerMappingVideoIDs.contains(video.id)
    }

    /// Selection actions pinned under the detail column: the missing-steps
    /// button keeps its text, the rest are icon-only with tooltips. Small
    /// bordered buttons that wrap; a short fixed height outside the pane's
    /// scroll is safe for the split view.
    private var selectionActionsFooter: some View {
        let videos = selectedVideos
        let absent = videos.contains { !$0.isPresent }
        let steps = missingSteps
        // Several files selected: only the actions that take a selection
        // of files stay (add to or remove from a project, remove), so the
        // per-file analysis and generation controls never act on a batch
        // by accident.
        let single = selection.count <= 1
        return FlowLayout(spacing: 6) {
            if let video = previewVideo {
                DriveUploadFooter(video: video)
            }
            if single, let video = previewVideo, !steps.isEmpty {
                let busy = stepsInFlight(video)
                Button(AnalysisSteps.buttonTitle(count: steps.count)) {
                    runSteps(steps, video: video)
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || store.isAnalyzing || !video.isPresent)
                .help(video.isPresent
                      ? "Runs the analysis steps this \(video.type?.label.lowercased() ?? "recording") is missing: "
                        + steps.map(\.title).joined(separator: ", ")
                      : VideoRecord.notPresentReason)
                if busy { ProgressView().controlSize(.small) }
            }
            if single {
                iconButton(videos.first.map { store.duplicateAnalysis(for: $0) != nil ? "Analyze again" : "Analyze" } ?? "Analyze",
                           systemImage: "sparkles",
                           help: absent ? VideoRecord.notPresentReason
                               : videos.first.map { store.analysisRequestHelp(for: $0) } ?? "Select a video to analyze.") {
                    if !videos.isEmpty { startAnalysis(of: videos) }
                }
                .disabled(selection.isEmpty || store.isAnalyzing || checkingAnalysis || absent)
                iconButton("Run full pipeline", systemImage: "arrow.triangle.turn.up.right.diamond",
                           help: "Analyze the selected video and generate reels from it in one run") {
                    showAnalyzeWizard = true
                }
                .disabled(selection.isEmpty || store.isPipelineRunning || absent)
                iconButton("Generate with AI Wizard", systemImage: "wand.and.stars",
                           help: absent ? VideoRecord.notPresentReason
                               : "Open the AI Wizard on the selected video's analysis to generate a video from it") {
                    store.openWizard(with: videos)
                }
                .disabled(selection.isEmpty || absent)
                iconButton("Build in AI Builder", systemImage: "hammer",
                           help: absent ? VideoRecord.notPresentReason
                               : "Create a timeline with the selected video and open it in the AI Builder") {
                    store.buildTimeline(from: videos)
                }
                .disabled(selection.isEmpty || absent)
            }
            if store.isHomeProject {
                Menu {
                    ForEach(store.projects.filter { !$0.isHome && !$0.archived }) { project in
                        Button(project.name) {
                            store.addVideos(Array(selection), to: project.id)
                        }
                    }
                    Divider()
                    Button("New Project from Selection…", systemImage: "plus") {
                        beginProjectFromSelection()
                    }
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .accessibilityLabel("Add to project")
                }
                .fixedSize()
                .disabled(selection.isEmpty)
                .help("Add the selected videos to a project")
            } else {
                if single {
                    iconButton("Add from Home", systemImage: "folder.badge.plus",
                               help: "Add videos already in this profile's Home project") {
                        showingProjectVideoPicker = true
                    }
                }
                iconButton("Remove from project", systemImage: "minus.circle",
                           help: "Take the selected videos out of this project; they stay in Home") {
                    pendingRemoval = selection
                }
                .disabled(selection.isEmpty)
            }
            if single {
                iconButton("Scan for duplicates", systemImage: "rectangle.on.rectangle",
                           help: "Find source videos that are copies of each other") {
                    showDuplicateScan = true
                }
            }
            iconButton(store.isTeamAttachedProfile ? "Remove from this Mac" : "Remove source",
                       systemImage: "trash",
                       help: store.isTeamAttachedProfile
                           ? "Remove the selected sources from this Mac: local copies are offloaded to Google Drive and the rows are hidden here; teammates keep them"
                           : "Remove the selected sources from every project; their analysis is kept and files in the profile's source folder go to the Trash") {
                pendingSourceRemoval = videos
            }
            .disabled(selection.isEmpty || store.isAnalyzing || store.isBuilderRendering
                      || store.isWizardRunning || store.isPipelineRunning)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    private func iconButton(_ title: String, systemImage: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .accessibilityLabel(title)
        }
        .help(help)
    }

    /// Runs steps of one file, after the type question when the file has
    /// no type and no stopped run: a short untyped recording would
    /// otherwise get the visual pass unasked. The steps are narrowed to
    /// what the chosen type expects; when none survive, every step the
    /// file is then missing runs.
    private func runSteps(_ steps: [AnalysisSteps.Step], video: VideoRecord) {
        guard video.type == nil, store.analysisCheckpoints[video.id] == nil else {
            store.runMissingAnalysisSteps(steps, video: video)
            return
        }
        typePrompt = TypePrompt(untyped: [video]) { confirmed in
            guard let updated = confirmed.first else { return }
            let expected = AnalysisSteps.expected(for: updated.type)
            let wanted = steps.filter { expected.contains($0) }
            store.runMissingAnalysisSteps(wanted.isEmpty ? (allMissingSteps[updated.id] ?? []) : wanted, video: updated)
        }
    }

    private func startAnalysis(of videos: [VideoRecord], typesConfirmed: Bool = false) {
        guard videos.allSatisfy(\.isPresent) else { store.presentError(VideoRecord.notPresentReason); return }
        // A recording with no type gets the wrong passes; ask before the
        // run, once, unless it is resuming where it stopped.
        let untyped = videos.filter { $0.type == nil && store.analysisCheckpoints[$0.id] == nil }
        if !typesConfirmed, !untyped.isEmpty {
            typePrompt = TypePrompt(untyped: untyped) { confirmed in
                let byID = Dictionary(uniqueKeysWithValues: confirmed.map { ($0.id, $0) })
                startAnalysis(of: videos.map { byID[$0.id] ?? $0 }, typesConfirmed: true)
            }
            return
        }
        let unfinished = videos.filter { store.analysisCheckpoints[$0.id] != nil }
        if unfinished.isEmpty {
            if videos.count == 1, let video = videos.first,
               store.analysisRuns.contains(where: { $0.videoID == video.id && $0.requestHash != nil }) {
                checkingAnalysis = true
                let generation = store.profileGeneration
                Task {
                    defer { checkingAnalysis = false }
                    do {
                        let plan = AnalysisRequest.capturePlan(defaults: .standard, singleVideo: true,
                            provider: nil, model: nil, includeFightScoring: true)
                        let request = try await store.captureAnalysisRequest(video: video, plan: plan, profile: store.activeProfile,
                            config: store.effectiveAIConfig, podcast: store.podcastEditingSettings, language: store.transcriptionLanguage())
                        guard generation == store.profileGeneration else { return }
                        store.analysisRequestPreviews[video.id] = request
                        if store.duplicateAnalysis(for: video) != nil {
                            store.analyze(videos: videos, capturedRequests: [video.id: request])
                        } else { presentPlan(for: videos) }
                    } catch { store.presentError("Could not check the analysis settings", error) }
                }
            } else { presentPlan(for: videos) }
        } else {
            resumePrompt = ResumePrompt(videos: videos, unfinished: unfinished)
        }
    }

    private func presentPlan(for videos: [VideoRecord]) {
        pendingDispatch = PendingDispatch(operation: .analyze, videos: videos,
                                          run: { store.analyze(videos: videos) })
    }

    struct ResumePrompt: Identifiable {
        let id = UUID()
        var videos: [VideoRecord]
        var unfinished: [VideoRecord]
    }

    /// The type question asked before a run; `continue` gets the videos
    /// with their chosen types saved.
    struct TypePrompt: Identifiable {
        let id = UUID()
        var untyped: [VideoRecord]
        var `continue`: ([VideoRecord]) -> Void
    }

    /// What the resume prompt says: where each unfinished run stopped.
    private func resumeMessage(_ prompt: ResumePrompt) -> String {
        let lines = prompt.unfinished.compactMap { video -> String? in
            guard let checkpoint = store.analysisCheckpoints[video.id] else { return nil }
            var line = "\(video.filename) stopped at \(checkpoint.percent)%"
            if !checkpoint.stage.isEmpty { line += " while \(checkpoint.stage)" }
            if let error = checkpoint.lastError { line += " — \(error)" }
            return line + "."
        }
        var message = lines.joined(separator: "\n")
        message += "\n\nResume keeps the settings of the stopped run and skips the work already done. Start Over discards that work and opens a fresh plan."
        if prompt.videos.count > prompt.unfinished.count {
            message += " The other selected videos run with the last-used plan."
        }
        return message
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

    /// A table-only projection keeps the sortable label out of persisted video records.
    private struct ProjectNamesKey: Equatable {
        var storeID: ObjectIdentifier
        var generation: Int
        var projectID: Int64?
        var videosVersion: Int
        var projects: [ProjectRecord]
    }

    private var projectNamesKey: ProjectNamesKey {
        ProjectNamesKey(storeID: ObjectIdentifier(store), generation: store.profileGeneration,
                        projectID: store.activeProjectID, videosVersion: store.videosVersion, projects: store.projects)
    }

    private func loadProjectNames() async {
        let key = projectNamesKey
        guard let database = store.database else {
            projectNames = [:]
            projectNamesVersion += 1
            return
        }
        do {
            let names = try await database.projectNames(forVideos: store.videos.map(\.id))
            guard !Task.isCancelled, key == projectNamesKey, store.database === database else { return }
            projectNames = names
            projectNamesVersion += 1
        } catch {
            guard !Task.isCancelled, key == projectNamesKey, store.database === database else { return }
            projectNames = [:]
            projectNamesVersion += 1
            store.presentError("Could not load source projects", error)
        }
    }

    private struct TableKey: Equatable {
        var storeID: ObjectIdentifier
        var videosVersion: Int
        var runsVersion: Int
        var scenesVersion: Int
        var peopleVersion: Int
        var transcriptCountsVersion: Int
        var passes: [AnalysisPassRecord]
        var unfinishedVideoIDs: Set<Int64>
        var sortOrder: [KeyPathComparator<SourceRow>]
        var projectNamesVersion: Int
        var isHomeProject: Bool
    }

    private struct TableSummary {
        var videos: [SourceRow]
        var sceneCounts: [Int64: Int]
        var batchCounts: [Int64: Int]
        var transcriptCounts: [Int64: Int]
        var peopleCounts: [Int64: Int]
        var qaCounts: [Int64: Int]
        var coverage: [Int64: AnalysisCoverage.Report]
    }

    @State private var tableMemo = MemoBox<TableKey, TableSummary>()

    private var tableSummary: TableSummary {
        let key = TableKey(storeID: ObjectIdentifier(store),
                           videosVersion: store.videosVersion, runsVersion: store.analysisRunsVersion,
                           scenesVersion: store.scenesVersion, peopleVersion: store.videoPeopleVersion,
                           transcriptCountsVersion: store.transcriptCountsVersion,
                           passes: store.analysisPasses, unfinishedVideoIDs: Set(store.analysisCheckpoints.keys),
                           sortOrder: sortOrder, projectNamesVersion: projectNamesVersion, isHomeProject: store.isHomeProject)
        return tableMemo(key) { computeTableSummary() }
    }

    private func computeTableSummary() -> TableSummary {
        // One pass over scenes/batches instead of an O(n) filter per table row.
        let sceneCounts = store.allSceneCountsByVideo
        let batchCounts = store.analysisRuns.reduce(into: [Int64: Int]()) { $0[$1.videoID, default: 0] += 1 }
        let transcriptCounts = store.transcriptCounts
        let scenesByVideo = Dictionary(grouping: store.scenes, by: \.videoID)
        let coverage = Dictionary(uniqueKeysWithValues: store.videos.map { video in
            (video.id, AnalysisCoverage.report(video: video, activeRun: store.activeLayer(videoID: video.id).run,
                                               scenes: scenesByVideo[video.id] ?? [],
                                               transcriptCount: transcriptCounts[video.id] ?? 0,
                                               transcriptUsable: store.transcriptUsable(video),
                                               transcriptKey: store.transcriptFacts[video.id]?.transcriptionKey,
                                               passes: store.analysisPasses, hasCheckpoint: store.analysisCheckpoints[video.id] != nil,
                                               duplicateOf: store.duplicateAnalysis(for: video)))
        })
        // Distinct people tagged across a video's batches, or the roster the
        // people pass built when that is all there is yet.
        let personTagsByRun = store.sceneIndex.personTagsByRun
        var peopleCounts = store.analysisRuns.reduce(into: [Int64: Set<String>]()) { result, run in
            if let tags = personTagsByRun[run.id] { result[run.videoID, default: []].formUnion(tags) }
        }.mapValues(\.count)
        for (video, roster) in store.videoPeopleCounts where roster > (peopleCounts[video] ?? 0) {
            peopleCounts[video] = roster
        }
        // A source that is neither on this Mac nor on Drive has nothing to
        // show or download, so the table leaves it out.
        let rows = store.videos.filter(\.isReachable).map { SourceRow(video: $0) }
        return TableSummary(videos: rows.sorted(using: sortOrder), sceneCounts: sceneCounts,
                            batchCounts: batchCounts, transcriptCounts: transcriptCounts,
                            peopleCounts: peopleCounts, qaCounts: store.sceneIndex.qaCountsByVideo,
                            coverage: coverage)
    }

    /// Steps in flight for a file, from the store's per-pass sets.
    private func runningSteps(_ video: VideoRecord) -> Set<AnalysisSteps.Step> {
        var running: Set<AnalysisSteps.Step> = []
        if store.analyzingVideoIDs.contains(video.id) { running.formUnion([.scenes, .exchanges]) }
        if store.detectingPeopleVideoID == video.id { running.insert(.people) }
        if store.transcribingVideoIDs.contains(video.id) { running.insert(.transcript) }
        if store.speakerMappingVideoIDs.contains(video.id) { running.insert(.speakerNames) }
        if store.fightScoringInFlight.contains(video.id) { running.insert(.fightScore) }
        return running
    }

    private func chipInputs(video: VideoRecord, summary: TableSummary) -> AnalysisStepPresentation.Inputs {
        let report = summary.coverage[video.id]
            ?? AnalysisCoverage.Report(qaCount: 0, hasTranscript: false, hasRun: false, latestPipeline: nil, state: .needsAnalysis)
        return AnalysisStepPresentation.Inputs(
            type: video.type, report: report,
            peopleCount: summary.peopleCounts[video.id] ?? 0, peopleDetectedAt: video.peopleDetectedAt,
            sceneCount: summary.sceneCounts[video.id] ?? 0, qaCount: summary.qaCounts[video.id] ?? 0,
            speakerNaming: store.speakerNamingSummaries[video.id]?.verdict,
            missing: allMissingSteps[video.id] ?? [], running: runningSteps(video))
    }

    @ViewBuilder
    private func coverageControl(video: VideoRecord, report: AnalysisCoverage.Report?) -> some View {
        if store.duplicateAnalysis(for: video) != nil {
            Label("Up to date, same settings", systemImage: "checkmark.circle")
                .lineLimit(1).fixedSize().foregroundStyle(.secondary)
        } else if video.type?.supportsFightFeatures == true {
            FightStatsCoverageCell(store: store, video: video) {
                selection = [video.id]
                fightStatsFocusVideoID = video.id
                fightStatsFocusRequest = UUID()
            }
        } else if let report, report.state == .untyped {
            // The step chips cover missing and outdated work; a run with no
            // type is the one state they cannot act on.
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Type unknown")
                Button(AnalysisCoverage.Action.setType.title) { performCoverageAction(.setType, video: video) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .lineLimit(1)
                    .fixedSize()
            }
            .help(AnalysisCoverage.message(for: report, type: video.type))
        } else if store.analysisCheckpoints[video.id] != nil, !stepsInFlight(video) {
            Button {
                startAnalysis(of: [video])
            } label: {
                Label("Unfinished", systemImage: "pause.circle")
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .lineLimit(1).fixedSize()
            .help("An analysis of this file stopped before it finished. Click to resume it or start over.")
        } else {
            Color.clear
        }
    }

    private func performCoverageAction(_ action: AnalysisCoverage.Action, video: VideoRecord) {
        switch action {
        case .runExchanges:
            store.rerun(.exchanges, video: video)
        case .analyze:
            selection = [video.id]
            startAnalysis(of: [video])
        case .setType:
            selection = [video.id]
            typeFocusVideoID = video.id
            typeFocusRequest = UUID()
        }
    }

    private var table: some View {
        let summary = tableSummary
        return Table(summary.videos, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columnCustomization) {
            TableColumn("File", value: \.filename) { row in
                let video = row.video
                HStack(spacing: Theme.spaceXS) {
                    // No gesture on the cell: a SwiftUI tap in a table cell
                    // makes AppKit apply the row selection only after mouse
                    // up, so the highlight lagged by the length of the click.
                    // Double-click rename comes from the table's primary action.
                    Text(video.filename)
                        .lineLimit(1)
                        .help("Double-click to rename")
                    if !video.isLocal {
                        Label("Not on this Mac", systemImage: "externaldrive.badge.questionmark")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }
                    Spacer(minLength: Theme.spaceXS)
                    // Badges keep one order at the column's right edge: cloud
                    // (with its transfer state), then the AI info stars.
                    DriveSourceProgress(media: video.driveMedia)
                    if video.driveFileID != nil {
                        DriveMediaBadge(media: video.driveMedia)
                        DriveFetchIndicator(media: video.driveMedia)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                // Table cells are hosted per row by AppKit. A recycled cell can
                // still receive an observation update (Drive job status) after
                // the host environment is gone, and its store-reading children
                // then trap on the missing Observable. Carry the store in the
                // cell's own tree so the lookup never depends on the host.
                .environment(store)
            }
            .width(min: 200, ideal: 320)
            .customizationID(SourcesTableSort.Column.file.rawValue)
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Created", value: \.createdDate) { row in
                let video = row.video
                Text(video.createdDate, format: .dateTime.year().month(.twoDigits).day(.twoDigits))
                    .help(video.createdDate.formatted(date: .complete, time: .standard))
            }
            .width(min: 85, ideal: 100)
            .customizationID(SourcesTableSort.Column.created.rawValue)

            TableColumn("Duration", value: \.duration) { row in
                Text(row.video.duration.timecode)
                    .monospacedDigit()
            }
            .width(70)
            .customizationID(SourcesTableSort.Column.duration.rawValue)

            TableColumn("Type", value: \.typeLabel) { row in
                let video = row.video
                Text(video.type?.label ?? "—")
                    .foregroundStyle(video.type == nil ? .tertiary : .secondary)
                    .help(video.type == nil ? "No type yet — Analyze asks for one, or set it in the detail pane"
                                            : "Footage type; change it in the detail pane")
            }
            .width(min: 70, ideal: 90)
            .customizationID(SourcesTableSort.Column.type.rawValue)

            // Two-letter code, or "?" when detection found nothing; the
            // language is changed in the detail pane.
            TableColumn("Lang", value: \.language) { row in
                LanguageBadge(video: row.video)
            }
            .width(min: 36, ideal: 40)
            .customizationID(SourcesTableSort.Column.lang.rawValue)

            TableColumn("Status") { row in
                let video = row.video
                let batches = summary.batchCounts[video.id] ?? 0
                // Batch picker, then one chip per step the type expects
                // (count when done, click to run when missing or outdated),
                // then the states the chips cannot act on.
                HStack(spacing: 6) {
                    AnalysisBatchControl(store: store, video: video, compact: true) { runs in
                        batchComparison = ScenesView.CompareRequest(runs: runs, video: video)
                    }
                    .foregroundStyle(batches > 0 ? Color.green : Color.secondary)
                    .frame(width: 58, alignment: .leading)
                    AnalysisStepChips(store: store, video: video,
                                      chips: AnalysisStepPresentation.chips(chipInputs(video: video, summary: summary)),
                                      missing: allMissingSteps[video.id] ?? [],
                                      run: { runSteps($0, video: video) })
                    coverageControl(video: video, report: summary.coverage[video.id])
                }
                .lineLimit(1)
                .fixedSize()
            }
            .width(min: 420, ideal: 480)
            .customizationID("status")
        }
        // Headers sort (click, click again to flip) and the sort is kept
        // across launches; columns reorder by dragging their headers and
        // show or hide from the header's context menu.
        .onAppear { if sortOrder.isEmpty { sortOrder = SourcesTableSort.decode(storedSort) } }
        .onChange(of: sortOrder) { _, order in storedSort = SourcesTableSort.encode(order) }
        // The empty-row stripes render as detached gray bars on this macOS,
        // reading as debris under a short table — rows separate fine without
        // them.
        .alternatingRowBackgrounds(.disabled)
        .scrollPosition(id: Binding(
            get: { store.sourceScrollID },
            set: { store.sourceScrollID = $0 }
        ))
        .contextMenu(forSelectionType: Int64.self) { ids in
            let videos = store.videos.filter { ids.contains($0.id) }
            if !videos.isEmpty {
                Button(videos.count == 1 ? "Analyze" : "Analyze \(videos.count) Videos") {
                    startAnalysis(of: videos)
                }
            }
            if ids.count == 1, let video = videos.first {
                Button("Rename…") {
                    beginRename(video)
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
                store.requestTranscription(videos: store.videos.filter { ids.contains($0.id) })
            }
            // Transcribe reuses a stored transcript; this makes a new set
            // and keeps the old one in the transcript's sets list.
            let transcribed = store.videos.filter { ids.contains($0.id) && (store.transcriptCounts[$0.id] ?? 0) > 0 }
            if !transcribed.isEmpty {
                Button("Re-transcribe") {
                    store.requestTranscription(videos: transcribed, force: true)
                }
                .disabled(transcribed.allSatisfy { store.transcribingVideoIDs.contains($0.id) })
            }
            Button("Generate Video…") {
                selection = ids
                showGenerateSheet = true
            }
            let batches = store.analysisRuns.filter { ids.contains($0.videoID) }.count
            if batches > 0 {
                Button(batches == 1 ? "Remove Analyze Batch" : "Remove \(batches) Analyze Batches", role: .destructive) {
                    store.prepareBatchDeletion { pendingBatchRemoval = ids }
                }
            }
            Divider()
            Button("Scan for Duplicates…") {
                showDuplicateScan = true
            }
            if store.isHomeProject {
                Menu("Add to Project…") {
                    ForEach(store.projects.filter { !$0.isHome && !$0.archived }) { project in
                        Button(project.name) { store.addVideos(Array(ids), to: project.id) }
                    }
                }
            }
            Divider()
            if !store.isHomeProject {
                Button("Remove from Project", role: .destructive) {
                    pendingRemoval = ids
                }
            }
            Button(store.isTeamAttachedProfile ? "Remove from this Mac…" : "Remove Source…", role: .destructive) {
                pendingSourceRemoval = store.videos.filter { ids.contains($0.id) }
            }
            .disabled(store.isAnalyzing || store.isBuilderRendering || store.isWizardRunning || store.isPipelineRunning)
        } primaryAction: { ids in
            // AppKit's own double-click, so single clicks select on mouse down.
            if ids.count == 1, let video = store.videos.first(where: { $0.id == ids.first }) {
                beginRename(video)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            if let projectID = store.activeProjectID {
                store.importVideos(urls, toProjectID: projectID)
            }
            return urls.contains { Analyzer.videoExtensions.contains($0.pathExtension.lowercased()) }
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Theme.mediaRadius)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .allowsHitTesting(false)
            } else if store.videos.isEmpty && !store.isHomeProject {
                ContentUnavailableView {
                    Label("No sources in \(store.activeProject?.name ?? "this project") yet", systemImage: "film")
                } description: {
                    Text(store.homeVideosNotInProjectCount > 0
                         ? "Add new files, or pick from the \(store.homeVideosNotInProjectCount) videos already in this profile's Home project."
                         : "Add new files; Home has no videos yet either.")
                } actions: {
                    if store.homeVideosNotInProjectCount > 0 {
                        Button("Add from Home…") { showingProjectVideoPicker = true }
                            .lineLimit(1).fixedSize()
                            .buttonStyle(.borderedProminent)
                        Button("Add Videos…") { showingImporter = true }
                            .lineLimit(1).fixedSize()
                            .buttonStyle(.bordered)
                    } else {
                        Button("Add Videos…") { showingImporter = true }
                            .lineLimit(1).fixedSize()
                            .buttonStyle(.borderedProminent)
                    }
                }
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

    private func restoreProjectState() {
        guard !store.isLoadingProject else { return }
        selection = store.sourceSelection.intersection(Set(store.videos.map(\.id)))
        syncPreview(to: selection)
        ensureSelection()
    }

    private func ensureSelection() {
        guard !store.isLoadingProject, selection.isEmpty else { return }
        let summary = tableSummary
        guard let first = summary.videos.first else { return }
        selection = [first.id]
    }

    private func createReassignedPerson(from person: PersonRecord) {
        let name = newPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let video = reassignVideo, !name.isEmpty else { return }
        store.reassignPerson(in: video, from: person, to: nil, newPersonName: name)
        reassignPerson = nil
    }

    private func removeFromProject(_ ids: Set<Int64>) {
        guard let projectID = store.activeProjectID, !ids.isEmpty else { return }
        store.removeVideos(Array(ids), from: projectID)
        selection.subtract(ids)
        pendingRemoval = []
    }

    private func beginProjectFromSelection() {
        guard let first = selectedVideos.first else { return }
        newProjectName = (first.filename as NSString).deletingPathExtension
        showingProjectFromSelection = true
    }

    private func createProjectFromSelection() {
        store.createProject(named: newProjectName, videoIDs: selectedVideos.map(\.id))
        showingProjectFromSelection = false
    }

}


private struct SourcesPanePlaceholder: View {
    var videoCount: Int
    var selectionCount: Int

    var body: some View {
        ContentUnavailableView {
            if videoCount == 0 {
                Label("No source videos", systemImage: "film")
            } else if selectionCount > 1 {
                Label("\(selectionCount) videos selected", systemImage: "rectangle.stack")
            } else {
                Label("Select a video", systemImage: "film")
            }
        } description: {
            if videoCount == 0 {
                Text("Add a video to see its preview, type, transcript and people here.")
            } else if selectionCount > 1 {
                Text("Select a single video to see its preview, type, transcript and people.")
            } else {
                Text("Click a row to see its preview, type, transcript and people.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Inline player for the single selected source video — watch the footage
/// before deciding to analyze (or re-analyze) it.
private struct VideoPreviewPane: View {
    @Environment(\.workspacePageVisible) private var pageVisible
    @Environment(AppStore.self) private var store
    let video: VideoRecord
    /// Projects this source belongs to; replaces the grid's Projects column.
    let projectNames: [String]
    let typeFocusRequest: UUID?
    /// A new value scrolls the info sections to Fight Action.
    let fightStatsFocusRequest: UUID?
    /// Which fighter's count is expanded into its frame list.
    private struct FightListPick: Equatable {
        var videoID: Int64
        var fighterKey: String
        var category: FightScoreDigest.Category
    }
    @State private var fightListPick: FightListPick?
    @State private var fightMarkerTime: Double?
    /// The action playing on repeat: its entry id and the player's time
    /// observer that rewinds it. Dropped with the player.
    @State private var fightLoopEntryID: Int64?
    @State private var fightLoopObserver: Any?

    private func stopFightLoop() {
        if let fightLoopObserver { player?.removeTimeObserver(fightLoopObserver) }
        fightLoopObserver = nil
        fightLoopEntryID = nil
    }

    /// Seek to the action's window and keep rewinding to its start.
    private func loopFightAction(_ entry: FightScoreDigest.Entry) {
        let wasLooping = fightLoopEntryID == entry.id
        stopFightLoop()
        fightMarkerTime = entry.time
        guard let player, !wasLooping else { player?.pause(); return }
        let range = entry.loopRange
        let start = CMTime(seconds: range.lowerBound, preferredTimescale: 600)
        player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        fightLoopEntryID = entry.id
        fightLoopObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak player] time in
            guard time.seconds >= range.upperBound else { return }
            player?.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }
    /// Opens the fight-research sheet — presented by the parent view, not
    /// here: a .sheet inside this split-view child crashes AppKit layout.
    let onResearch: () -> Void
    /// Opens the fight story sheet — same parent-presented sheet rule.
    var onStory: (() -> Void)? = nil
    /// Opens the File Name Wizard for this video — same parent-presented
    /// sheet rule.
    let onNameWizard: () -> Void
    let onCompareBatches: ([AnalysisRun]) -> Void
    /// Selects another video picked in the person popover.
    let onSelectVideo: (VideoRecord) -> Void
    /// Requests the name sheet from AnalyzeView, outside the split view.
    let onReassignNewPerson: (PersonRecord, VideoRecord, String) -> Void
    /// Coverage of the active run, for the reason lines under Type,
    /// Language and the active batch.
    var coverage: AnalysisCoverage.Report? = nil
    var missingSteps: [AnalysisSteps.Step] = []
    /// Starts a full analysis of this video (type prompt and plan included).
    var onAnalyze: () -> Void = {}
    /// Runs the given steps of this video (type prompt included).
    var onRunSteps: ([AnalysisSteps.Step]) -> Void = { _ in }

    /// A wrapped orange reason with its one action, under the control it
    /// explains.
    private func reasonLine(_ text: String, action: AnalysisCoverage.Action?,
                            perform: @escaping (AnalysisCoverage.Action) -> Void) -> some View {
        reasonLine(text, actionTitle: action?.title, help: action.map { "\($0.title) this recording" } ?? "") {
            if let action { perform(action) }
        }
        .disabled(store.isAnalyzing || !video.isPresent)
    }

    private func reasonLine(_ text: String, actionTitle: String?, help: String, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.spaceS) {
            Text(text)
                .font(.caption2).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let actionTitle {
                Button(actionTitle, action: perform)
                    .controlSize(.small)
                    .lineLimit(1).fixedSize()
                    .help(help)
            }
        }
    }

    /// What the player area shows while there is no player.
    private enum Availability { case loading, downloading, ready, unavailable }

    /// The registry record behind a roster entry (the popover reads the
    /// hand-picked avatar and hidden flag from it); a roster row whose
    /// person was deleted mid-session still opens on what the row knows.
    /// "Name  3 strikes  0/2 TD  1/1 sub": each count toggles its frame list.
    private func fightCountsRow(_ fighter: FightScoreDigest.Fighter, events: [FightEventRecord]) -> some View {
        let name = store.people.first { $0.key == fighter.key }?.displayName
            ?? (fighter.key.isEmpty ? "Unattributed" : fighter.key)
        return VStack(alignment: .leading, spacing: Theme.spaceXS) {
            Text(name)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
            HStack(spacing: 6) {
            ForEach(FightScoreDigest.Category.allCases, id: \.self) { category in
                let count = FightScoreDigest.count(fighter, category)
                if count > 0 || category == .strikes {
                    let picked = fightListPick == FightListPick(videoID: video.id, fighterKey: fighter.key, category: category)
                    Button {
                        stopFightLoop()
                        fightMarkerTime = nil
                        fightListPick = picked ? nil : FightListPick(videoID: video.id, fighterKey: fighter.key, category: category)
                    } label: {
                        Text(countLabel(fighter, category))
                            .font(.caption2.monospacedDigit())
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(picked ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(count == 0)
                    .help(count == 0 ? "No \(category.label.lowercased()) scored" : "Show the frames behind these \(category.label.lowercased())")
                }
            }
            Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func countLabel(_ fighter: FightScoreDigest.Fighter, _ category: FightScoreDigest.Category) -> String {
        switch category {
        case .strikes: "\(fighter.strikes) strike" + (fighter.strikes == 1 ? "" : "s")
        case .takedowns: "\(fighter.takedowns)/\(fighter.takedownAttempts) TD"
        case .submissions: "\(fighter.submissions)/\(fighter.submissionAttempts) sub"
        }
    }

    private func person(for entry: VideoPersonRecord) -> PersonRecord {
        store.people.first { $0.id == entry.personID }
            ?? PersonRecord(id: entry.personID, key: entry.key, name: entry.name, descriptor: entry.descriptor)
    }

    @State private var player: AVPlayer?
    @State private var availability = Availability.loading
    @State private var roster: [VideoPersonRecord] = []
    /// Roster member whose detail popover is open.
    @State private var detailPersonID: Int64?
    /// Whether any transcript rows exist for this video — shows the editor.
    @State private var hasTranscript = false
    @State private var transcriptSetLabel = ""
    @State private var transcriptPinMissing = false
    @State private var showTranscript = false

    var body: some View {
        VStack(spacing: 8) {
            PlayerView(player: player)
                // Bounded height so the info sections below keep their room —
                // an unbounded player splits the pane 50/50 with the scroll
                // area and pushes the sections under the fold.
                .frame(maxWidth: .infinity, minHeight: 140, idealHeight: 230, maxHeight: 260)
                .background(.black, in: RoundedRectangle(cornerRadius: Theme.mediaRadius))
                .overlay {
                    switch availability {
                    case .loading:
                        ProgressView()
                            .controlSize(.small)
                    case .downloading:
                        VStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Downloading from Drive…")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    case .unavailable:
                        VStack(spacing: 4) {
                            Label("Not on this Mac", systemImage: "video.slash")
                                .font(.caption)
                            if video.driveFileID != nil {
                                MissingFootageDownloadButton(video: video)
                            }
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Video not available")
                    case .ready:
                        EmptyView()
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                let active = store.activeLayer(videoID: video.id)
                Text("Active batch: \(active.run?.name ?? "None") (\(active.reason))")
                    .font(.caption).lineLimit(1)
                HStack {
                    AnalysisBatchControl(store: store, video: video, onCompare: onCompareBatches)
                    Spacer(minLength: 0)
                }
                if active.missingPin {
                    Text("pinned batch not on this Mac yet").font(.caption2).foregroundStyle(.orange)
                }
                if let coverage, coverage.state != .upToDate, coverage.state != .needsAnalysis,
                   coverage.state != .outdated(stage: AnalysisCoverage.typeChangedStage), coverage.sameAsActive != true {
                    reasonLine(AnalysisCoverage.message(for: coverage, type: video.type),
                               action: AnalysisCoverage.action(for: coverage.state)) { action in
                        switch action {
                        case .analyze: onAnalyze()
                        case .runExchanges: onRunSteps([.exchanges])
                        case .setType: break
                        }
                    }
                }
                if let verdict = store.speakerNamingSummaries[video.id]?.verdict, verdict.isSuspicious {
                    reasonLine(verdict.reason, actionTitle: "Name speakers again",
                               help: "Runs the speaker naming pass again on the current transcript and people") {
                        onRunSteps([.speakerNames])
                    }
                    .disabled(store.speakerMappingVideoIDs.contains(video.id) || !video.isPresent)
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
                    AIInfoButton(size: 12, video: video)
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
                VideoTypePicker(video: video, focusRequest: typeFocusRequest)
            }
            if let coverage, coverage.state == .outdated(stage: AnalysisCoverage.typeChangedStage) {
                reasonLine(AnalysisCoverage.typeChangedMessage(ran: coverage.ranAs, now: video.type),
                           actionTitle: "Analyze", help: "Redoes the analysis with the passes this type uses") { onAnalyze() }
                    .disabled(store.isAnalyzing || !video.isPresent)
            } else if video.type == nil {
                Text(Analyzer.minimumClassifiableDuration <= video.duration
                     ? "No type yet. Analysis guesses one from the first minutes, or choose it here."
                     : "No type yet, and the recording is too short to guess one. Choose it here before analyzing.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Language")
                    .font(.caption.weight(.medium))
                    .lineLimit(1).fixedSize()
                Spacer()
                VideoLanguagePicker(video: video)
            }
            if let coverage, coverage.hasTranscript, !coverage.transcriptUsable {
                let transcriptLanguage = store.transcriptFacts[video.id]?.language
                reasonLine("The transcript is in \(transcriptLanguage.map(VideoLanguage.name) ?? "another language"); this video is \(video.language.map(VideoLanguage.name) ?? "set to another language"). Transcribe again to match.",
                           actionTitle: "Transcribe again", help: "Transcribes the video again in its language") {
                    onRunSteps([.transcript])
                }
                .disabled(store.transcribingVideoIDs.contains(video.id) || !video.isPresent)
            } else if VideoLanguage.detectionFailed(language: video.language, source: video.languageSource) {
                Text(VideoLanguage.detectionFailedText)
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Projects")
                    .font(.caption.weight(.medium))
                    .lineLimit(1).fixedSize()
                Spacer()
                Text(projectNames.isEmpty ? "Not in any project" : projectNames.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(projectNames.isEmpty ? .secondary : .primary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(projectNames.isEmpty ? "Add this source to a project from the Projects menu below"
                          : "Projects that contain this source: " + projectNames.joined(separator: ", "))
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Transcript").font(.caption.weight(.medium))
                        Text(transcriptSetLabel).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).fixedSize()
                        if transcriptPinMissing {
                            Text("Pinned set not on this Mac yet").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Edit…", systemImage: "text.quote") {
                        showTranscript = true
                    }
                    .controlSize(.small)
                    .lineLimit(1).fixedSize()
                    .help("Choose the active transcript set or edit its text")
                }
            }

            // The info sections live in a scroll view so the pane never
            // demands more minimum height than the split view can give —
            // fixed-height sections here made the pane's min size oscillate
            // against the player during layout, tripping AppKit's
            // constraint-loop guard (uncaught NSGenericException crash).
            ScrollViewReader { proxy in
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
                                Button(store.fightEvents[video.id]?.isEmpty == false ? "Re-score v2" : "Score v2") {
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
                                               height: 64,
                                               onSeek: { time in
                                                   stopFightLoop()
                                                   fightMarkerTime = nil
                                                   player?.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                                                                toleranceBefore: .zero, toleranceAfter: .zero)
                                               },
                                               markerTime: fightListPick?.videoID == video.id ? fightMarkerTime : nil)
                            } else if let pass = store.analysisPasses.last(where: { $0.videoID == video.id && $0.pass == .fightScore && $0.status != .running }) {
                                Text(pass.status == .completed
                                     ? "Scored v\(pass.version): no scoring actions found (\(pass.note ?? "no detail")). Check the Fight Scoring job log in the status bar."
                                     : "Scoring \(pass.status.rawValue): \(pass.note ?? "no detail"). Check the Fight Scoring job log in the status bar.")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text("Not scored yet — analyzed fight footage scores automatically; use Score to run it now.")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            if let events = store.fightEvents[video.id], !events.isEmpty {
                                // Per-fighter totals behind the graph; the grid's
                                // stats badge lands here. Each count opens the
                                // frames behind it.
                                ForEach(FightScoreDigest.fighters(events: events)) { fighter in
                                    fightCountsRow(fighter, events: events)
                                }
                                if let pick = fightListPick, pick.videoID == video.id {
                                    FightActionListView(video: video, events: events, fighterKey: pick.fighterKey,
                                                        category: pick.category, looping: fightLoopEntryID) { entry in
                                        loopFightAction(entry)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("fightAction")
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
                            // Wraps to further rows when the pane is narrow; the top
                            // padding leaves room for the VIP star outside the circle.
                            FlowLayout(spacing: 8) {
                                    ForEach(roster) { entry in
                                        Button {
                                            detailPersonID = entry.personID
                                        } label: {
                                            VStack(spacing: 2) {
                                                VideoPersonAvatar(record: entry, videoURL: video.url,
                                                                  size: 54)
                                                    .padding(.top, 6)
                                                Text(entry.displayName)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                            .frame(width: 72)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu { VIPContextMenu(entry: entry) }
                                        .accessibilityLabel("Details for \(entry.displayName)")
                                        .help(entry.descriptor.isEmpty
                                              ? "Who this is, when they are on screen, and their videos and scenes"
                                              : entry.descriptor)
                                        .popover(isPresented: Binding(
                                            get: { detailPersonID == entry.personID },
                                            set: { if !$0 { detailPersonID = nil } }),
                                            arrowEdge: .bottom
                                        ) {
                                            PersonDetailPopover(
                                                person: person(for: entry), video: video, rosterEntry: entry,
                                                onSeek: { time in
                                                    player?.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                                                                 toleranceBefore: .zero, toleranceAfter: .zero)
                                                },
                                                onSelectVideo: onSelectVideo,
                                                onReassignNewPerson: onReassignNewPerson)
                                        }
                                    }
                                }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                }
            }
            .onChange(of: fightStatsFocusRequest) { _, request in
                guard request != nil else { return }
                withAnimation { proxy.scrollTo("fightAction", anchor: .top) }
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
                        if let onStory {
                            Button {
                                onStory()
                            } label: {
                                Text("Fight Story…").lineLimit(1).fixedSize()
                            }
                            .controlSize(.small)
                            .disabled(store.isBuildingFightStory(fightVideoID: video.id))
                            .help("Build one timeline from an interview claim, this fight's picked sequences and a result card")
                        }
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
        .task(id: "\(video.id)|\(video.path ?? "")|\(video.locallyDownloaded ?? false)|\(video.driveOffloaded)") {
            // Drop the old player right away so the pane follows the selection
            // instantly, then open the file off the main thread: creating the
            // player synchronously probes the file and stalled the click.
            stopFightLoop()
            player?.pause()
            player = nil
            roster = []
            availability = .loading
            roster = await store.videoPeople(for: video.id)
            // Let the pane's loading state paint before the file is touched.
            await Task.yield()
            // A file that is not on this Mac is reported, not spun on; a
            // download the user already started is joined and shown as such.
            // Selecting a row never starts a download by itself, Drive copy
            // or not: the Download button under the message does.
            if !video.isLocal {
                let fetching = video.driveFileID != nil
                    && store.googleDrive.activeFetchJob(for: video.driveMedia, profile: store.activeProfile.profileName) != nil
                guard fetching, video.path != nil else { availability = .unavailable; return }
                availability = .downloading
            }
            guard await DrivePlayback.prepare(video.url) else {
                if !Task.isCancelled { availability = .unavailable }
                return
            }
            guard let asset = try? await DriveLocalAsset.make(video.url),
                  let playable = try? await asset.load(.isPlayable), playable else {
                if !Task.isCancelled { availability = .unavailable }
                return
            }
            _ = try? await asset.load(.duration, .preferredTransform)
            guard !Task.isCancelled else { return }
            player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            availability = .ready
            UITiming.responseReady(screen: "Sources", what: "preview player")
            roster = await store.videoPeople(for: video.id)
        }
        // A detect run that started elsewhere (the analysis sheet) finished:
        // show the roster it built.
        .onChange(of: store.isDetectingPeople) { _, running in
            if !running { Task { roster = await store.videoPeople(for: video.id) } }
        }
        .task(id: "\(video.id)|\(store.videoPeopleVersion)") {
            let refreshed = await store.videoPeople(for: video.id)
            guard !Task.isCancelled else { return }
            roster = refreshed
        }
        // Re-check when a transcription for this video finishes.
        .task(id: "\(video.id)|\(store.transcribingVideoIDs.contains(video.id))|\(store.transcriptCountsVersion)|\(video.activeTranscriptionKey ?? "")|\(showTranscript)") {
            guard let database = store.database else { return }
            let sets = (try? await database.transcriptionSets(videoID: video.id)) ?? []
            let resolution = try? await database.activeTranscription(videoID: video.id)
            guard !Task.isCancelled else { return }
            hasTranscript = !sets.isEmpty || resolution?.missingPin == true
            transcriptPinMissing = resolution?.missingPin ?? false
            if let index = Array(sets.reversed()).firstIndex(where: { $0.isActive }) {
                let number = index + 1
                transcriptSetLabel = "Set \(number) of \(sets.count) (\(resolution?.reason ?? "newest"))"
            } else {
                transcriptSetLabel = "No local set"
            }
        }
        .sheet(isPresented: $showTranscript) {
            TranscriptSheet(video: video, focusSetsPicker: true)
        }
        .onChange(of: pageVisible) { _, visible in
            if !visible {
                stopFightLoop()
                player?.pause()
            }
        }
        .onDisappear {
            stopFightLoop()
            player?.pause()
            player = nil
        }
    }
}
