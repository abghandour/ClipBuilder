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
    /// Screen-crop layouts the planner may use (Use custom crops).
    @AppStorage(WizardOptions.useScreenCropsKey) private var useScreenCrops = false
    @AppStorage(WizardOptions.screenCropLayoutsKey) private var screenCropLayoutsRaw = ""
    /// Transitions the planner may use; empty raw = any.
    @AppStorage(WizardOptions.limitTransitionsKey) private var limitTransitions = false
    @AppStorage(WizardOptions.allowedTransitionsKey) private var allowedTransitionsRaw = ""
    @State private var availableLayouts: [ScreenCropLayout] = []
    @AppStorage("wizard.useFightResearch") private var useFightResearch = true
    @AppStorage("wizard.aiInstructions") private var aiInstructions = ""
    /// Hard duration for the generated reel, in seconds.
    @AppStorage("wizard.targetDuration") private var targetDuration = 10
    /// Reel recipe: custom / recap / compilation / interview.
    @AppStorage("wizard.formatPreset") private var formatPreset = "custom"
    /// "" = profile default, "none" = no taste, "cat:<key>" = a learned category.
    @AppStorage("wizard.tastePreset") private var tastePreset = ""
    @AppStorage("wizard.critiqueLoop") private var critiqueLoop = true
    @AppStorage("wizard.includeWatermark") private var includeWatermark = true
    @AppStorage("wizard.includeHeadline") private var includeHeadline = true
    @AppStorage("wizard.includeOutro") private var includeOutro = true
    @AppStorage("wizard.limitToSelection") private var limitToSelection = false
    @AppStorage("wizard.curatedOnly") private var curatedOnly = false
    /// Comma-joined analyze-batch IDs — AppStorage can't hold a Set directly.
    @AppStorage("wizard.selectedRunIDs") private var selectedRunIDsRaw = ""
    /// Comma-joined person keys the footage must feature (empty = everyone).
    @AppStorage("wizard.sourcePeople") private var sourcePeopleRaw = ""
    /// App-wide similar-scene grouping level — the pool collapses each
    /// stack of takes to its best one at this aggressiveness.
    @AppStorage(SceneStacks.levelKey) private var stackLevelRaw = SceneStackLevel.standard.rawValue
    @State private var musicCount = 0
    @State private var newLessonText = ""
    @State private var showTrainingGuide = false
    @State private var showGapReport = false
    @State private var showCuratedWizard = false
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
        store.sceneIndex.usableCount
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
        var tags = Set<String>()
        for runID in selectedRunIDs {
            tags.formUnion(store.sceneIndex.personTagsByRun[runID] ?? [])
        }
        return store.people.filter { tags.contains($0.tag) }
    }

    /// Distinct people recognized per analyze batch, via person: scene tags.
    private var batchPeopleCounts: [Int64: Int] {
        store.sceneIndex.personTagsByRun.mapValues(\.count)
    }

    var body: some View {
        HSplitView {
            configurationForm
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            WizardLogPanel()
                .rememberedPaneWidth("pane.wizard.log", min: 300, initial: 360, max: 480)
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("AI Wizard")
        .navigationSubtitle("\(analyzedSceneCount) scenes available")
        .toolbar {
            Button("Content Gaps", systemImage: "checklist") {
                showGapReport = true
            }
            .help("AI strategist's report over the whole pipeline: what to post next, what's sitting unused, what's blocking output")
            Button("Training Guide", systemImage: "questionmark.circle") {
                showTrainingGuide = true
            }
            .help("How to train the wizard for better results")
        }
        .sheet(isPresented: $showGapReport) {
            GapReportSheet()
        }
        .sheet(isPresented: $showTrainingGuide) {
            HelpSheet()
        }
        .sheet(item: $pendingDispatch) { pending in
            DispatchPlanSheet(operation: pending.operation, onStart: pending.run)
        }
        // A "Generate Video" request shows as a modal only while it's being
        // interpreted (or when interpretation failed); a successful parse
        // seeds the form below and the modal dismisses on its own.
        .sheet(isPresented: requestModalPresented) {
            generateRequestModal
        }
        // Loaded once instead of in the Form: availableMusic() lists a
        // directory synchronously, which doesn't belong in a body pass.
        .task {
            musicCount = WizardEngine.availableMusic().count
            availableLayouts = ScreenCropStore.all().filter { !$0.areas.isEmpty }
        }
        // Seed the form from a "Generate Video" request —
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
                // Clamp typed values on commit so the field always shows the
                // duration the run will actually use.
                .onChange(of: targetDuration) { _, value in
                    let clamped = min(180, max(3, value))
                    if clamped != value { targetDuration = clamped }
                }
            }

            if let handoff = store.pendingWizardTemplate {
                Section("Reference Template") {
                    HStack(spacing: 12) {
                        // Snapshot of the source reel, so it's obvious which
                        // video the wizard is replicating.
                        if let url = handoff.thumbnailURL {
                            CachedImage(url: url, maxPixel: 240)
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
                            Label("Remove Template", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .help("Remove the template — future generations won't use it")
                    }
                }
            }

            Section("Format & Branding") {
                Picker("Video type", selection: $formatPreset) {
                    Text("Custom").tag("custom")
                    Divider()
                    Text("MMA finish").tag("mma-finish")
                    Text("MMA submission sequence").tag("mma-submission")
                    Text("MMA exchange").tag("mma-exchange")
                    Text("MMA technique breakdown").tag("mma-technique")
                    Divider()
                    Text("Fight recap").tag("recap")
                    Text("Best-of compilation").tag("compilation")
                    Text("Interview clip").tag("interview")
                    if !store.activeProfile.tasteCategories.isEmpty {
                        Divider()
                        ForEach(store.activeProfile.tasteCategories) { category in
                            Text("\(category.label) — learned from \(category.studiedCount) reel(s)")
                                .tag("cat:\(category.key)")
                        }
                    }
                }
                .help("What kind of video to build. Built-in recipes the planner must follow, plus video types learned from your Instagram exemplars — a learned type injects its rubric and prefers scenes that matched it during analysis. Teach new types from the Instagram tab's Learn menu.")
                Picker("Taste", selection: $tastePreset) {
                    Text("Profile taste (default)").tag("")
                    Text("None").tag("none")
                    if !store.activeProfile.tasteCategories.isEmpty {
                        Divider()
                        ForEach(store.activeProfile.tasteCategories) { category in
                            Text(category.label).tag("cat:\(category.key)")
                        }
                    }
                }
                .help("Which taste steers scene picking for this video: the profile's main taste rubric (Settings → AI → Taste), one of your learned taste categories, or none at all. Picking the same category as the video type doesn't double it up.")
                Toggle("Use fight research (fan reactions)", isOn: $useFightResearch)
                    .help("Injects each fight's saved web research — crawled fan reactions distilled into a story — into planning and captions. Run and edit the research from Analyze → Fight Research.")
                if useFightResearch {
                    Text(store.fightResearch.isEmpty
                         ? "No fight research saved yet — run it from the Analyze page's Fight Research column."
                         : "\(store.fightResearch.count) fight(s) researched — research for the selected footage is injected automatically.")
                        .font(.caption)
                        .foregroundStyle(store.fightResearch.isEmpty ? .orange : .secondary)
                }
                Toggle("AI critique & auto-retry", isOn: $critiqueLoop)
                    .help("After each render, a critic model watches the finished reel and scores it against your taste. If it sees a clearly better version, the wizard re-plans with the critic's notes and renders again — up to 3 versions total, all kept in the Library with their reviews.")
                if critiqueLoop {
                    Text("Up to 3 versions per run — each extra version is a full plan + render cycle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Watermark (brand logo)", isOn: $includeWatermark)
                    .help("Burns the profile's logo into the top-left corner of every frame — set the logo in Settings → Profile")
                Toggle("Result headline lower-third", isOn: $includeHeadline)
                    .help("A branded full-video lower-third with the fight result (e.g. “X BEATS Y”), composed from the analyzer's extracted outcomes")
                Toggle("Branded outro card", isOn: $includeOutro)
                    .help("Appends a 2.5s end card: logo, brand name, tagline, and follow CTA from the profile's brand kit")
                if store.activeProfile.logoPath.isEmpty && (includeWatermark || includeOutro) {
                    Text("No brand logo set — add one in Settings → Profile to get the watermark and a full outro card.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Audio") {
                Toggle("Use background music", isOn: $useMusic)
                Toggle("Mute source audio (music only)", isOn: $muteSource)
                    .disabled(!useMusic)
                if !useMusic {
                    Text("Needs background music on — a fully silent video isn't offered.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                        Button("Refresh Track Count", systemImage: "arrow.clockwise") {
                            musicCount = WizardEngine.availableMusic().count
                        }
                        .labelStyle(.iconOnly)
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

            Section("Layouts & Effects") {
                Toggle("Use custom crops (screen-crop layouts)", isOn: $useScreenCrops)
                    .help("Lets the AI show several scenes at once: a layout splits the frame into areas, each area gets its own scene, and a tracking camera keeps the fighters inside it. Draw layouts in Assets → Screen Crop.")
                if useScreenCrops {
                    let picked = Set(screenCropLayoutsRaw.split(separator: ",").map(String.init))
                    ForEach(availableLayouts) { layout in
                        Toggle(isOn: Binding(
                            get: { picked.contains(layout.name) },
                            set: { on in
                                var set = picked
                                if on { set.insert(layout.name) } else { set.remove(layout.name) }
                                screenCropLayoutsRaw = set.sorted().joined(separator: ",")
                            })) {
                            HStack(spacing: 6) {
                                Text(layout.name)
                                Text(layout.areas.map(\.name).joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if ScreenCropStore.isBuiltIn(layout.name) {
                                    Text("built-in")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    Text(picked.isEmpty
                         ? "Nothing picked — the AI may use any of the layouts above."
                         : "The AI may use the picked layouts freely (1–3 blocks per reel).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Limit transitions", isOn: $limitTransitions)
                    .help("Off: the AI picks any transition it thinks looks best. On: only the checked effects are offered (hard cuts are always allowed). Preview them in Assets → Effects.")
                if limitTransitions {
                    let allowed = Set(allowedTransitionsRaw.split(separator: ",").map(String.init))
                    ForEach(TransitionEffect.Category.allCases.filter { $0 != .cut }, id: \.self) { category in
                        let members = TransitionCatalog.all.filter { $0.category == category }
                        DisclosureGroup {
                            ForEach(members) { effect in
                                Toggle(isOn: Binding(
                                    get: { allowed.contains(effect.name) },
                                    set: { on in setTransitions([effect.name], allowed: on) })) {
                                    HStack {
                                        Text(effect.title)
                                        Text(effect.name)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text("\(category.title) (\(members.count { allowed.contains($0.name) })/\(members.count))")
                                Spacer()
                                Button("All") { setTransitions(members.map(\.name), allowed: true) }
                                    .controlSize(.mini)
                                Button("None") { setTransitions(members.map(\.name), allowed: false) }
                                    .controlSize(.mini)
                            }
                        }
                    }
                    Text(allowed.isEmpty
                         ? "Nothing checked — every gap will be a hard cut."
                         : "\(allowed.count) transition\(allowed.count == 1 ? "" : "s") allowed, plus hard cuts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Source Selection") {
                let curatedCount = store.scenes.count(where: { $0.curated && !$0.excluded && !$0.ignored })
                Toggle("Use curated scenes only", isOn: $curatedOnly)
                    .help("Pick footage only from scenes you promoted to Curated Scenes — trimmed, framed, and marked good to go")
                if curatedOnly {
                    Text(curatedCount == 0
                         ? "No curated scenes yet — promote scenes from Raw Scenes (or the Curated Scenes screen) first, or turn this off."
                         : "\(curatedCount) curated scene(s) available.")
                        .font(.caption)
                        .foregroundStyle(curatedCount == 0 ? .orange : .secondary)
                }
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
                        Text("Only scenes featuring the picked people are used — combined with the analyze batch filter above. Center Stage tracks them in wide footage.")
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

        }
        .formStyle(.grouped)
        // The primary action stays on screen no matter how long the form
        // grows — pinned under the scroll instead of being its last section.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            generationBar
        }
        .sheet(isPresented: $showCuratedWizard) {
            CuratedWizardSheet(scenes: curatedWizardPool,
                               targetDuration: min(180, max(3, targetDuration)),
                               includeOutro: includeOutro,
                               centerStageDefault: centerStageWide,
                               batchNames: Dictionary(uniqueKeysWithValues:
                                   store.analysisRuns.map { ($0.id, $0.name) }),
                               selectedBatchIDs: limitToSelection
                                   ? store.analysisRuns.map(\.id).filter(selectedRunIDs.contains)
                                   : [])
        }
    }

    /// Pinned action bar under the configuration form: the wizard's primary
    /// action (Generate/Stop) plus the hand-picked alternative, always
    /// visible at any window size.
    private var generationBar: some View {
        VStack(spacing: 8) {
            if analyzedSceneCount == 0 {
                Text("Analyze some videos first — the wizard picks from analyzed scenes.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Button {
                    showCuratedWizard = true
                } label: {
                    Label("Generate Curated Video", systemImage: "checklist")
                }
                .disabled(analyzedSceneCount == 0 || store.isCuratedRendering)
                .help("Hand-pick the reel yourself: the app proposes scenes one by one (respecting the Source Selection above) — preview, trim, approve, then overlays, music, and outro. No AI planning involved.")

                Spacer()

                if store.isWizardRunning {
                    Button(role: .destructive) {
                        store.cancelWizard()
                    } label: {
                        Label("Stop Generating", systemImage: "stop.fill")
                    }
                    .controlSize(.large)
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        startGeneration()
                    } label: {
                        Label("Generate Video", systemImage: "wand.and.stars")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(analyzedSceneCount == 0)
                    .help("Plan and render a reel from the settings above (⌘⏎)")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// The scene queue the Curated wizard proposes from: the same pool the
    /// AI wizard would draw on (curated-only, batch, and people filters from
    /// Source Selection), walked in video order — each approval/skip moves
    /// on to the next moment later in the timeline until the footage runs
    /// out.
    ///
    /// Proposals are individual MOMENTS, never whole-video sequences: a
    /// person filter that matches a sequence pulls in its breakdown beats
    /// (the beats don't carry person tags themselves), and any sequence
    /// whose beats are in the pool is dropped in favor of those beats.
    private var curatedWizardPool: [SceneRecord] {
        var pool = store.scenes.filter { !$0.excluded && !$0.ignored }
        if curatedOnly {
            pool = pool.filter(\.curated)
        }
        if limitToSelection, !selectedRunIDs.isEmpty {
            let runIDs = selectedRunIDs
            pool = pool.filter { $0.runID.map(runIDs.contains) ?? false }
        }
        let personTags = Set(store.people.filter { selectedSourcePeople.contains($0.key) }.map(\.tag))
        if !personTags.isEmpty {
            // Person tags often land only on the whole-fight sequence scene,
            // not on the atomic beats cut from it — a beat sitting inside a
            // person-matched scene's time range features that person too.
            let matched = pool.filter { !personTags.isDisjoint(with: $0.tags) }
            let matchedIDs = Set(matched.map(\.id))
            pool = pool.filter { scene in
                if matchedIDs.contains(scene.id) { return true }
                if scene.parentSceneID.map(matchedIDs.contains) ?? false { return true }
                return matched.contains { container in
                    container.videoID == scene.videoID
                        && scene.startTime >= container.startTime - 0.5
                        && scene.endTime <= container.endTime + 0.5
                }
            }
        }
        // Propose atoms, not containers: a scene that wraps other pool scenes
        // (by time, the same relation containmentNotes feeds the planner) is
        // a sequence — its beats represent it. The 1s slack keeps two
        // near-identical detections from knocking each other out.
        let byVideo = Dictionary(grouping: pool, by: \.videoID)
        pool = pool.filter { scene in
            guard let group = byVideo[scene.videoID] else { return true }
            return !group.contains {
                $0.id != scene.id
                    && $0.startTime >= scene.startTime - 0.25
                    && $0.endTime <= scene.endTime + 0.25
                    && $0.duration <= scene.duration - 1.0
            }
        }
        // Stacked takes of one moment collapse to their best one (the
        // user's remembered pick when made, otherwise the AI's) — siblings
        // would only re-propose the same moment and eat the shortlist
        // budget. Follows the app-wide grouping level.
        pool = SceneStacks.tops(pool, level: .from(stackLevelRaw))
        // Center Stage on: skip wide moments the analyzer flagged as
        // portrait-fit:poor — the people are spread out and the tracked crop
        // WILL cut someone out of frame.
        if centerStageWide {
            pool = pool.filter { !($0.wide && $0.tags.contains("portrait-fit:poor")) }
        }
        // The scoring model picks the queue: rank by entertainment score
        // (crowd excitement as fallback, taste-highlight boost) and keep the
        // strongest until the shortlist comfortably overfills the target.
        // No signals at all → propose everything rather than picking blind.
        func rank(_ scene: SceneRecord) -> Double {
            var value = scene.score ?? scene.excitement.map { $0 * 10 } ?? -1
            if scene.tags.contains(where: { $0.hasPrefix("highlight") }) { value += 5 }
            return value
        }
        if pool.contains(where: { rank($0) >= 0 }) {
            // Rank WITHIN each batch — a global cut would let one strong
            // batch crowd every other selected batch out of the queue.
            let groups = Dictionary(grouping: pool) { $0.runID ?? -1 }
            let batchCount = max(1, groups.count)
            let totalBudget = max(Double(min(180, max(3, targetDuration))) * 4, 60)
            let perBatchBudget = max(totalBudget / Double(batchCount), 30)
            let perBatchMinimum = max(12 / batchCount, 6)
            var shortlist: [SceneRecord] = []
            for scenes in groups.values {
                var total = 0.0
                var kept = 0
                for scene in scenes.sorted(by: { rank($0) > rank($1) }) {
                    if total >= perBatchBudget, kept >= perBatchMinimum { break }
                    shortlist.append(scene)
                    total += scene.duration
                    kept += 1
                }
            }
            pool = shortlist
        }
        return pool.sorted {
            if $0.videoID != $1.videoID { return $0.videoID < $1.videoID }
            return $0.startTime < $1.startTime
        }
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

    /// Fill the form from a "Generate Video" request. Only fields the user
    /// actually specified are touched; before/without an AI interpretation
    /// the raw description rides as instructions so nothing is lost. Overlay
    /// choices aren't form fields — runWizard() reads them straight from the
    /// handoff, and the request card shows them.
    /// Shown while a request is in flight (statusMessage set) or after a
    /// failed interpretation; closing it mid-flight cancels the request.
    private var requestModalPresented: Binding<Bool> {
        Binding(
            get: {
                guard let handoff = store.pendingWizardPrompt else { return false }
                return handoff.statusMessage != nil || handoff.parseFailed
            },
            set: { presented in
                if !presented { store.pendingWizardPrompt = nil }
            })
    }

    private var generateRequestModal: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Generate Video Request", systemImage: "wand.and.stars")
                .font(.headline)
            Text("“\(store.pendingWizardPrompt?.description ?? "")”")
            if let status = store.pendingWizardPrompt?.statusMessage {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(status)
                        .foregroundStyle(.secondary)
                }
            } else if store.pendingWizardPrompt?.parseFailed == true {
                Label("Couldn't interpret the request with AI — it was placed in AI Instructions as-is.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(20)
        .frame(width: 440)
        // Closing drops the request — nothing is applied to the form.
        .modalCloseButton { store.pendingWizardPrompt = nil }
    }

    private func applyPromptHandoff(_ handoff: WizardPromptHandoff) {
        if !handoff.runIDs.isEmpty {
            // Scenes/People hand off the exact batches their displayed
            // scenes came from.
            setSelectedRunIDs(handoff.runIDs)
            limitToSelection = true
        } else if !handoff.videoIDs.isEmpty {
            // Re-resolved on every handoff update, so batches created by the
            // "analyze first" step are picked up once analysis finishes.
            setSelectedRunIDs(latestRunIDs(forVideoIDs: handoff.videoIDs))
            limitToSelection = true
        }
        if !handoff.personKeys.isEmpty {
            sourcePeopleRaw = handoff.personKeys.sorted().joined(separator: ",")
        }
        guard let parsed = handoff.parsed else {
            aiInstructions = ([tagFilterLine(handoff.tags), handoff.description]
                .compactMap { $0 }).joined(separator: "\n")
            return
        }
        if let duration = parsed.targetDurationSeconds { targetDuration = duration }
        if let value = parsed.useMusic { useMusic = value }
        if let value = parsed.addCaptions { addCaptions = value }
        if let value = parsed.enableTextOverlays { enableTextOverlays = value }
        var lines: [String] = []
        let contentTags = handoff.tags + parsed.contentTags.filter { !handoff.tags.contains($0) }
        if let tagLine = tagFilterLine(contentTags) {
            lines.append(tagLine)
        }
        if !parsed.residualInstructions.isEmpty {
            lines.append(parsed.residualInstructions)
        }
        aiInstructions = lines.joined(separator: "\n")
    }

    /// The instruction line that keeps a hand-off's tag filter in force.
    private func tagFilterLine(_ tags: [String]) -> String? {
        tags.isEmpty ? nil
            : "Only use footage tagged: \(tags.joined(separator: ", ")). Skip everything else."
    }

    private func setTransitions(_ names: [String], allowed: Bool) {
        var set = Set(allowedTransitionsRaw.split(separator: ",").map(String.init))
        for name in names {
            if allowed { set.insert(name) } else { set.remove(name) }
        }
        allowedTransitionsRaw = set.sorted().joined(separator: ",")
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
        options.screenCropLayouts = WizardOptions.screenCropLayoutsFromDefaults()
        options.allowedTransitions = WizardOptions.allowedTransitionsFromDefaults()
        options.useFightResearch = useFightResearch
        options.aiInstructions = aiInstructions
        options.targetDurationSeconds = min(180, max(3, targetDuration))
        options.formatPreset = formatPreset
        options.critiqueLoop = critiqueLoop
        options.tastePreset = tastePreset.isEmpty ? nil : tastePreset
        options.includeWatermark = includeWatermark
        options.includeHeadline = includeHeadline
        options.includeOutro = includeOutro
        options.selectedRunIDs = limitToSelection ? selectedRunIDs : []
        options.curatedOnly = curatedOnly
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
                Label(lesson.pinned ? "Unpin Lesson" : "Pin Lesson",
                      systemImage: lesson.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(lesson.pinned ? .orange : .secondary)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(lesson.pinned ? "Pinned: permanent hard constraint. Click to unpin."
                                : "Click to pin — the distiller never replaces pinned lessons")

            VStack(alignment: .leading, spacing: 2) {
                TextField("Lesson", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        store.updateLesson(lesson, text: text)
                    }
                if !lesson.evidence.isEmpty || lesson.provenance != nil {
                    HStack(spacing: 4) {
                        if let provenance = lesson.provenance {
                            ProvenanceBadge(provenance: provenance, role: "Distilled by", size: 11)
                        }
                        if !lesson.evidence.isEmpty {
                            Text(lesson.evidence)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Spacer()

            Button {
                store.deleteLesson(lesson)
            } label: {
                Label("Delete Lesson", systemImage: "trash")
                    .foregroundStyle(.secondary)
            }
            .labelStyle(.iconOnly)
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
                LogActions(lines: store.wizardLog) { store.wizardLog = [] }
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

            // A failed run gets a banner with a way forward, not just a red
            // line buried in the scrollback.
            if let failure = store.wizardFailureMessage {
                failureCard(failure)
                    .padding(.horizontal)
            }

            if store.wizardLog.isEmpty {
                ContentUnavailableView(
                    "Ready",
                    systemImage: "wand.and.stars",
                    description: Text("The wizard researches best practices, plans a reel from your analyzed scenes and feedback, and renders it to the Library."))
                    // Fill the remaining pane height — without this the
                    // whole panel (header included) centers vertically.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            let log = store.wizardLog
                            ForEach(log.indices, id: \.self) { index in
                                logLine(log[index])
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

    /// What went wrong and what to do next, shown until dismissed or retried.
    private func failureCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Generation failed", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Button("Try Again") {
                    store.wizardFailureMessage = nil
                    store.retryWizard()
                }
                .controlSize(.small)
                .help("Re-run the generation with the same settings")
                Spacer()
                Button("Dismiss") {
                    store.wizardFailureMessage = nil
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private static func elapsedString(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s"
    }
}
