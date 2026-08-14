import SwiftUI

/// AI Wizard: configure a generation run, watch the live log, and find the
/// results in the Library.
struct WizardView: View {
    @Environment(AppStore.self) private var store

    @State private var numberOfVideos = 1
    @State private var variationsPerVideo = 1
    @State private var useMusic = true
    @State private var muteSource = false
    @State private var addCaptions = false
    @State private var autoCropWide = true
    @State private var enableTextOverlays = false
    @State private var aiInstructions = ""
    @State private var selectedVideoIDs: Set<Int64> = []
    @State private var limitToSelection = false
    @State private var musicCount = 0
    @State private var newLessonText = ""
    @State private var showTrainingGuide = false

    private var analyzedSceneCount: Int {
        store.scenes.filter { !$0.excluded && !$0.ignored }.count
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

            Section("Output") {
                Stepper("Videos: \(numberOfVideos)", value: $numberOfVideos, in: 1...5)
                Stepper("Variations per video: \(variationsPerVideo)", value: $variationsPerVideo, in: 1...5)
                if variationsPerVideo > 1 {
                    Text("Each variation uses a different creative approach.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                Toggle("Auto-crop wide footage to portrait", isOn: $autoCropWide)
                Toggle("AI text overlays", isOn: $enableTextOverlays)
            }

            Section("Source Selection") {
                Toggle("Limit to selected videos", isOn: $limitToSelection)
                if limitToSelection {
                    List(store.videos, selection: $selectedVideoIDs) { video in
                        Text(video.filename)
                            .tag(video.id)
                    }
                    .frame(height: 140)
                }
            }

            Section("AI Instructions (highest priority)") {
                TextEditor(text: $aiInstructions)
                    .font(.body)
                    .frame(minHeight: 70)
                Text("Hard requirements that override research and feedback — e.g. “always open with a knockout”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                        runWizard()
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

    private func addLesson() {
        store.addLesson(text: newLessonText)
        newLessonText = ""
    }

    /// Fill the form from an Analyze request. Only fields the user actually
    /// specified are touched; before/without an AI interpretation the raw
    /// description rides as instructions so nothing is lost. Duration and
    /// overlay choices aren't form fields — runWizard() reads them straight
    /// from the handoff, and the request card shows them.
    private func applyPromptHandoff(_ handoff: WizardPromptHandoff) {
        if !handoff.videoIDs.isEmpty {
            selectedVideoIDs = handoff.videoIDs
            limitToSelection = true
        }
        guard let parsed = handoff.parsed else {
            aiInstructions = handoff.description
            return
        }
        if let count = parsed.numberOfVideos { numberOfVideos = count }
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
        if let count = parsed.numberOfVideos { parts.append("\(count) video(s)") }
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
        options.numberOfVideos = numberOfVideos
        options.variationsPerVideo = variationsPerVideo
        options.useMusic = useMusic
        options.muteSource = muteSource && useMusic
        options.addCaptions = addCaptions
        options.autoCropWide = autoCropWide
        options.enableTextOverlays = enableTextOverlays
        options.aiInstructions = aiInstructions
        options.selectedVideoIDs = limitToSelection ? selectedVideoIDs : []
        // The template persists across runs; the card's X removes it.
        if let handoff = store.pendingWizardTemplate {
            options.templateJSON = handoff.templateJSON
            options.templateLabel = handoff.label
        }
        // Same for a sample-video request: its duration/overlay constraints
        // apply until the request card is dismissed.
        if let parsed = store.pendingWizardPrompt?.parsed {
            options.targetDurationSeconds = parsed.targetDurationSeconds
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Generation Log")
                    .font(.headline)
                Spacer()
                if store.isWizardRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding([.top, .horizontal])

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
                                Text(line)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(line.hasPrefix("DONE:error") || line.hasPrefix("Error") ? .red : .secondary)
                                    .textSelection(.enabled)
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
}
