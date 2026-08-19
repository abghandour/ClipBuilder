import AppKit
import SwiftUI

/// AI Wizard: configure a generation run, watch the live log, and find the
/// results in the Library.
struct WizardView: View {
    @Environment(AppStore.self) private var store

    // Persisted so the form survives section switches and app restarts.
    @AppStorage("wizard.useMusic") private var useMusic = true
    @AppStorage("wizard.muteSource") private var muteSource = false
    @AppStorage("wizard.addCaptions") private var addCaptions = false
    @AppStorage("wizard.autoCropWide") private var autoCropWide = true
    @AppStorage("wizard.centerStageWide") private var centerStageWide = false
    /// Center Stage camera preset: "smooth", "balanced", or "fast".
    @AppStorage("wizard.centerStageCamera") private var centerStageCamera = "balanced"
    @AppStorage("wizard.allowWideSplit") private var allowWideSplit = false
    @AppStorage("wizard.enableTextOverlays") private var enableTextOverlays = false
    @AppStorage("wizard.aiInstructions") private var aiInstructions = ""
    /// Hard duration for the generated reel, in seconds.
    @AppStorage("wizard.targetDuration") private var targetDuration = 10
    @AppStorage("wizard.limitToSelection") private var limitToSelection = false
    /// Comma-joined analyze-batch IDs — AppStorage can't hold a Set directly.
    @AppStorage("wizard.selectedRunIDs") private var selectedRunIDsRaw = ""
    /// Comma-joined person keys the footage must feature (empty = everyone).
    @AppStorage("wizard.sourcePeople") private var sourcePeopleRaw = ""
    @State private var musicCount = 0
    @State private var newLessonText = ""
    @State private var showTrainingGuide = false
    @State private var pendingDispatch: PendingDispatch?

    private var selectedRunIDs: Set<Int64> {
        Set(selectedRunIDsRaw.split(separator: ",").compactMap { Int64($0) })
    }

    private func setSelectedRunIDs(_ ids: Set<Int64>) {
        selectedRunIDsRaw = ids.sorted().map(String.init).joined(separator: ",")
    }

    private var selectionBinding: Binding<Set<Int64>> {
        Binding(get: { selectedRunIDs }, set: { setSelectedRunIDs($0) })
    }

    /// The latest analyze batch of each given video — how an Analyze-tab
    /// video selection translates into batch selection.
    private func latestRunIDs(forVideoIDs videoIDs: Set<Int64>) -> Set<Int64> {
        var latest: [Int64: AnalysisRun] = [:]
        for run in store.analysisRuns where videoIDs.contains(run.videoID) {
            let current = latest[run.videoID]
            if current == nil || (run.createdAt ?? "") > (current?.createdAt ?? "") {
                latest[run.videoID] = run
            }
        }
        return Set(latest.values.map(\.id))
    }

    private var analyzedSceneCount: Int {
        store.scenes.filter { !$0.excluded && !$0.ignored }.count
    }

    /// Captions can only burn transcripts that already exist — the wizard
    /// never transcribes. True when the current source selection contains at
    /// least one analyze batch that produced a transcript.
    private var transcriptsAvailable: Bool {
        let runs = limitToSelection && !selectedRunIDs.isEmpty
            ? store.analysisRuns.filter { selectedRunIDs.contains($0.id) }
            : store.analysisRuns
        return runs.contains(where: \.hasTranscript)
    }

    private var selectedSourcePeople: Set<String> {
        Set(sourcePeopleRaw.split(separator: ",").map(String.init))
    }

    /// People eligible under the current batch selection: with batches
    /// picked, only those appearing in the selected batches' scenes.
    private var eligibleSourcePeople: [PersonRecord] {
        guard limitToSelection, !selectedRunIDs.isEmpty else { return store.people }
        let runIDs = selectedRunIDs
        var tags = Set<String>()
        for scene in store.scenes where scene.runID.map(runIDs.contains) ?? false {
            for tag in scene.tags where tag.hasPrefix("person:") {
                tags.insert(tag)
            }
        }
        return store.people.filter { tags.contains($0.tag) }
    }

    /// Distinct people recognized per analyze batch, via person: scene tags.
    private var batchPeopleCounts: [Int64: Int] {
        store.scenes.reduce(into: [Int64: Set<String>]()) { acc, scene in
            guard let runID = scene.runID else { return }
            for tag in scene.tags where tag.hasPrefix("person:") {
                acc[runID, default: []].insert(tag)
            }
        }.mapValues(\.count)
    }

    var body: some View {
        HSplitView {
            configurationForm
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            WizardLogPanel()
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 480, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("AI Wizard")
        .navigationSubtitle("\(analyzedSceneCount) scenes available")
        .toolbar {
            Button("Training Guide", systemImage: "questionmark.circle") {
                showTrainingGuide = true
            }
            .help("How to train the wizard for better results")
        }
        .sheet(isPresented: $showTrainingGuide) {
            HelpSheet()
        }
        .sheet(item: $pendingDispatch) { pending in
            DispatchPlanSheet(operation: pending.operation, onStart: pending.run)
        }
        // Loaded once instead of in the Form: availableMusic() lists a
        // directory synchronously, which doesn't belong in a body pass.
        .task { musicCount = WizardEngine.availableMusic().count }
        // Seed the form from an Analyze "Generate Sample Video" request —
        // on arrival, and again in place when its AI interpretation lands.
        .task {
            if let handoff = store.pendingWizardPrompt { applyPromptHandoff(handoff) }
        }
        .onChange(of: store.pendingWizardPrompt) { _, handoff in
            if let handoff { applyPromptHandoff(handoff) }
        }
    }

    private var configurationForm: some View {
        Form {
            Section("AI Instructions (highest priority)") {
                TextEditor(text: $aiInstructions)
                    .font(.body)
                    .frame(minHeight: 70)
                Text("Hard requirements that override research and feedback — e.g. “always open with a knockout” or “only include scenes with Person A fighting in the cage, keep Person A centered”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Target duration")
                    Spacer()
                    TextField("Target duration", value: $targetDuration, format: .number)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                    Stepper("Target duration", value: $targetDuration, in: 3...180)
                        .labelsHidden()
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }
                .help("The generated reel is planned to this length (3–180s)")
            }

            if let handoff = store.pendingWizardPrompt {
                Section("Sample Video Request") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("“\(handoff.description)”")
                            Spacer()
                            Button {
                                store.pendingWizardPrompt = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove the request — the settings it filled in stay editable below")
                        }
                        if let status = handoff.statusMessage {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(status)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else if handoff.parseFailed {
                            Text("Couldn't interpret the request with AI — it was placed in AI Instructions as-is.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else if let parsed = handoff.parsed {
                            Text(parsedSummary(parsed))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let handoff = store.pendingWizardTemplate {
                Section("Reference Template") {
                    HStack(spacing: 12) {
                        // Snapshot of the source reel, so it's obvious which
                        // video the wizard is replicating.
                        if let url = handoff.thumbnailURL, let image = NSImage(contentsOf: url) {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 44, height: 78)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.quaternary)
                                .frame(width: 44, height: 78)
                                .overlay {
                                    Image(systemName: "play.rectangle.on.rectangle")
                                        .foregroundStyle(.secondary)
                                }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(handoff.label)
                            Text("The wizard will replicate this reel's hook, pacing, structure, and text style with your scenes — until you remove it here.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            store.pendingWizardTemplate = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove the template — future generations won't use it")
                    }
                }
            }

            Section("Audio") {
                Toggle("Use background music", isOn: $useMusic)
                Toggle("Mute source audio (music only)", isOn: $muteSource)
                    .disabled(!useMusic)
                LabeledContent("Music library") {
                    HStack {
                        Text("\(musicCount) tracks")
                            .foregroundStyle(musicCount == 0 ? .orange : .secondary)
                        Button("Open Folder") {
                            try? FileManager.default.createDirectory(at: WizardEngine.musicDirectory,
                                                                     withIntermediateDirectories: true)
                            NSWorkspace.shared.open(WizardEngine.musicDirectory)
                        }
                        .controlSize(.small)
                        Button {
                            musicCount = WizardEngine.availableMusic().count
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .controlSize(.small)
                        .help("Re-count tracks after adding music")
                    }
                }
            }

            Section("Visuals") {
                Toggle("Burn transcript captions", isOn: $addCaptions)
                    .disabled(!transcriptsAvailable)
                    .help("Burns spoken-word subtitles from transcripts that already exist — the wizard never transcribes")
                if !transcriptsAvailable {
                    Text("No transcript in the selected sources. Captions only burn transcripts produced during analysis — the wizard doesn't transcribe.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Auto-crop wide footage to portrait", isOn: $autoCropWide)
                Toggle("Center Stage: track people in wide footage", isOn: $centerStageWide)
                    .help("Wide scenes get a virtual camera that pans and zooms to keep the people centered, instead of a static crop")
                if centerStageWide {
                    Picker("Camera", selection: $centerStageCamera) {
                        Text("Smooth").tag("smooth")
                        Text("Balanced").tag("balanced")
                        Text("Fast action").tag("fast")
                    }
                    .pickerStyle(.segmented)
                    .help("How eagerly the tracking camera chases the people: Smooth drifts cinematically, Fast action reacts hard and zooms out so fighters stay in frame")
                    Text(selectedSourcePeople.isEmpty
                         ? "Tracks everyone on screen. Pick people under Source Selection to focus the camera on them."
                         : "Tracks the people picked under Source Selection; wide scenes without them auto-crop.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Allow split-screen for wide footage", isOn: $allowWideSplit)
                    .help("Lets the AI stack a wide scene's left/right halves top and bottom. Off = wide footage always zooms to fill the frame instead.")
                Toggle("AI text overlays", isOn: $enableTextOverlays)
            }

            Section("Source Selection") {
                Toggle("Limit to selected analyze batches", isOn: $limitToSelection)
                if limitToSelection {
                    let peopleCounts = batchPeopleCounts
                    List(store.analysisRuns, selection: selectionBinding) { run in
                        HStack {
                            Text(run.name)
                                .lineLimit(1)
                            Spacer()
                            let people = peopleCounts[run.id] ?? 0
                            Text("\(run.sceneCount) scenes"
                                 + (people > 0 ? " · \(people) \(people == 1 ? "person" : "people")" : ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(run.id)
                    }
                    .frame(height: 140)
                }
                let eligiblePeople = eligibleSourcePeople
                if !eligiblePeople.isEmpty {
                    // People outside the selected batches are hidden; their
                    // stale selections are ignored, not silently applied.
                    let selected = selectedSourcePeople
                        .intersection(Set(eligiblePeople.map(\.key)))
                    // Messages-style pinned-contact row: tap a face to toggle
                    // that person; nobody picked = use anyone's scenes.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            personChoice(label: "Anyone", isSelected: selected.isEmpty,
                                         help: "Use scenes regardless of who is in them") {
                                sourcePeopleRaw = ""
                            } avatar: {
                                Circle()
                                    .fill(.quaternary)
                                    .overlay {
                                        Image(systemName: "person.2.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(width: 44, height: 44)
                            }
                            ForEach(eligiblePeople) { person in
                                personChoice(label: person.displayName,
                                             isSelected: selected.contains(person.key),
                                             help: "Only use scenes featuring \(person.displayName) — Center Stage tracks them too") {
                                    var keys = selected
                                    if keys.contains(person.key) {
                                        keys.remove(person.key)
                                    } else {
                                        keys.insert(person.key)
                                    }
                                    sourcePeopleRaw = keys.sorted().joined(separator: ",")
                                } avatar: {
                                    PersonFaceAvatar(person: person, size: 44)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    if !selected.isEmpty {
                        Text("Only scenes featuring the picked people are used — combined with the batch filter above. Center Stage tracks them in wide footage.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Learned Lessons") {
                if store.lessons.isEmpty {
                    Text("Nothing learned yet. Review generated reels in the Library (👍/👎 per clip), then distill those reviews into rules the wizard follows every run.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.lessons) { lesson in
                    LessonRow(lesson: lesson)
                }
                HStack {
                    TextField("Add your own rule — saved as pinned", text: $newLessonText)
                        .onSubmit(addLesson)
                    Button("Add", action: addLesson)
                        .disabled(newLessonText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack {
                    Button {
                        store.distillLessons()
                    } label: {
                        Label("Distill Lessons from Reviews", systemImage: "sparkles")
                    }
                    .disabled(store.isDistillingLessons)
                    if store.isDistillingLessons {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                }
                Text("Distilling replaces unpinned lessons with rules summarized from your reviews, A/B picks, and notes. Pin a lesson (📌) to make it a permanent hard constraint the distiller never touches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if store.isWizardRunning {
                    Button(role: .destructive) {
                        store.cancelWizard()
                    } label: {
                        Label("Stop Generating", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        startGeneration()
                    } label: {
                        Label("Generate Reels", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(analyzedSceneCount == 0)
                }

                if analyzedSceneCount == 0 {
                    Text("Analyze some videos first — the wizard picks from analyzed scenes.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// One item in the source-people row: avatar with a selection ring and
    /// checkmark badge, name underneath.
    private func personChoice(label: String, isSelected: Bool, help: String,
                              action: @escaping () -> Void,
                              @ViewBuilder avatar: () -> some View) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                avatar()
                    .overlay {
                        Circle()
                            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .background(Circle().fill(.background))
                        }
                    }
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .frame(width: 58)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func addLesson() {
        store.addLesson(text: newLessonText)
        newLessonText = ""
    }

    private func appendInstruction(_ line: String) {
        let trimmed = aiInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        aiInstructions = trimmed.isEmpty ? line : trimmed + "\n" + line
    }

    /// Show the smart dispatcher's model plan first (unless muted for
    /// generation), then kick off the run.
    private func startGeneration() {
        if store.settings.ai.mutedDispatchPlans.contains(DispatchOperation.generate.rawValue) {
            runWizard()
            // runWizard() has already reset the log by the time this appends.
            store.wizardLog.append("Model-plan prompt is muted — Reset Smart Dispatcher in Settings → AI to bring it back.")
        } else {
            pendingDispatch = PendingDispatch(operation: .generate) {
                runWizard()
            }
        }
    }

    /// Fill the form from an Analyze request. Only fields the user actually
    /// specified are touched; before/without an AI interpretation the raw
    /// description rides as instructions so nothing is lost. Overlay choices
    /// aren't form fields — runWizard() reads them straight from the
    /// handoff, and the request card shows them.
    private func applyPromptHandoff(_ handoff: WizardPromptHandoff) {
        if !handoff.videoIDs.isEmpty {
            // Re-resolved on every handoff update, so batches created by the
            // "analyze first" step are picked up once analysis finishes.
            setSelectedRunIDs(latestRunIDs(forVideoIDs: handoff.videoIDs))
            limitToSelection = true
        }
        guard let parsed = handoff.parsed else {
            aiInstructions = handoff.description
            return
        }
        if let duration = parsed.targetDurationSeconds { targetDuration = duration }
        if let value = parsed.useMusic { useMusic = value }
        if let value = parsed.addCaptions { addCaptions = value }
        if let value = parsed.enableTextOverlays { enableTextOverlays = value }
        var lines: [String] = []
        if !parsed.contentTags.isEmpty {
            lines.append("Only use footage tagged: \(parsed.contentTags.joined(separator: ", ")). Skip everything else.")
        }
        if !parsed.residualInstructions.isEmpty {
            lines.append(parsed.residualInstructions)
        }
        aiInstructions = lines.joined(separator: "\n")
    }

    private func parsedSummary(_ parsed: ParsedWizardRequest) -> String {
        var parts: [String] = []
        if let duration = parsed.targetDurationSeconds { parts.append("~\(duration)s") }
        if !parsed.contentTags.isEmpty {
            parts.append("footage: \(parsed.contentTags.joined(separator: ", "))")
        }
        if let template = parsed.overlayTemplate { parts.append("overlay: \(template)") }
        if let text = parsed.overlayText { parts.append("text: “\(text)”") }
        if parsed.useMusic == false { parts.append("no music") }
        if parsed.addCaptions == true { parts.append("captions") }
        guard !parts.isEmpty else {
            return "No specific settings detected — the description rides as AI instructions."
        }
        return "Applied: " + parts.joined(separator: " · ")
    }

    private func runWizard() {
        var options = WizardOptions()
        options.useMusic = useMusic
        options.muteSource = muteSource && useMusic
        options.addCaptions = addCaptions && transcriptsAvailable
        options.autoCropWide = autoCropWide
        options.centerStageWide = centerStageWide
        options.centerStageCamera = centerStageCamera
        options.allowWideSplit = allowWideSplit
        options.enableTextOverlays = enableTextOverlays
        options.aiInstructions = aiInstructions
        options.targetDurationSeconds = min(180, max(3, targetDuration))
        options.selectedRunIDs = limitToSelection ? selectedRunIDs : []
        // People hidden by the batch selection don't filter — only visible
        // picks apply.
        let eligibleKeys = Set(eligibleSourcePeople.map(\.key))
        options.sourcePeople = sourcePeopleRaw.split(separator: ",").map(String.init)
            .filter(eligibleKeys.contains)
        // The source-people filter doubles as the Center Stage focus: the
        // camera tracks the picked people (everyone when nobody is picked).
        options.centerStagePeople = options.sourcePeople
        // The template persists across runs; the card's X removes it.
        if let handoff = store.pendingWizardTemplate {
            options.templateJSON = handoff.templateJSON
            options.templateLabel = handoff.label
        }
        // Same for a sample-video request: its overlay constraints apply
        // until the request card is dismissed. (Its duration lands in the
        // form's target-duration field via applyPromptHandoff.)
        if let parsed = store.pendingWizardPrompt?.parsed {
            options.pinnedOverlayTemplate = parsed.overlayTemplate
            options.pinnedOverlayText = parsed.overlayText
        }
        store.runWizard(options: options)
    }

}

/// One editable lesson: pin toggle (pinned = permanent hard constraint the
/// distiller never replaces), inline text editing, evidence, delete.
private struct LessonRow: View {
    @Environment(AppStore.self) private var store
    let lesson: WizardLesson

    @State private var text: String = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                store.updateLesson(lesson, pinned: !lesson.pinned)
            } label: {
                Image(systemName: lesson.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(lesson.pinned ? .orange : .secondary)
            }
            .buttonStyle(.borderless)
            .help(lesson.pinned ? "Pinned: permanent hard constraint. Click to unpin."
                                : "Click to pin — the distiller never replaces pinned lessons")

            VStack(alignment: .leading, spacing: 2) {
                TextField("Lesson", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        store.updateLesson(lesson, text: text)
                    }
                if !lesson.evidence.isEmpty {
                    Text(lesson.evidence)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Button {
                store.deleteLesson(lesson)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Delete this lesson")
        }
        .onAppear { text = lesson.text }
        .onChange(of: lesson.text) { _, newValue in text = newValue }
    }
}

/// Isolated so per-line log appends don't re-evaluate the whole wizard
/// screen (and its Form) while a generation runs.
private struct WizardLogPanel: View {
    @Environment(AppStore.self) private var store
    @AppStorage("log.verbose") private var verboseLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Generation Log")
                    .font(.headline)
                Toggle("Verbose", isOn: $verboseLog)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Log the full prompt sent to the AI for every call")
                Spacer()
                if store.isWizardRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding([.top, .horizontal])

            if let status = store.wizardStatus {
                progressCard(status)
                    .padding(.horizontal)
            }

            if store.wizardLog.isEmpty {
                ContentUnavailableView(
                    "Ready",
                    systemImage: "wand.and.stars",
                    description: Text("The wizard researches best practices, plans a reel from your analyzed scenes and feedback, and renders it to the Library."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(store.wizardLog.enumerated()), id: \.offset) { index, line in
                                logLine(line)
                                    .id(index)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                    }
                    .onChange(of: store.wizardLog.count) {
                        proxy.scrollTo(store.wizardLog.count - 1, anchor: .bottom)
                    }
                }
            }
        }
    }

    /// One log line. The engine's "VIDEO:<file>:<duration>" marker renders
    /// as a link that opens the rendered file; everything else is plain text.
    @ViewBuilder
    private func logLine(_ line: String) -> some View {
        if let video = Self.videoReference(from: line) {
            Button {
                if let url = store.generatedVideoURL(named: video.name) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("\(video.name) · \(video.duration)s — click to watch",
                      systemImage: "play.rectangle.fill")
                    .font(.caption.monospaced())
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Open the generated video")
        } else {
            Text(line)
                .font(.caption.monospaced())
                .foregroundStyle(line.hasPrefix("DONE:error") || line.hasPrefix("Error") ? .red : .secondary)
                .textSelection(.enabled)
        }
    }

    /// "VIDEO:wiz-43-2.mp4:38.7" → (name, duration).
    private static func videoReference(from line: String) -> (name: String, duration: String)? {
        guard line.hasPrefix("VIDEO:") else { return nil }
        let parts = line.dropFirst("VIDEO:".count).split(separator: ":")
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// Friendly stage + overall progress + a per-stage elapsed clock, so a
    /// multi-minute AI call reads as "working" instead of "stuck".
    @ViewBuilder
    private func progressCard(_ status: WizardRunStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(status.stage)
                    .font(.subheadline.weight(.medium))
                Spacer()
                // SwiftUI-qualified: the Builder's timeline editor is also
                // named TimelineView.
                SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.elapsedString(from: status.stageChangedAt, to: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: status.fraction)
            if !status.detail.isEmpty {
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }

    private static func elapsedString(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s"
    }
}
