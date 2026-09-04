import SwiftUI

/// The everyday reel-making surface. It intentionally asks for outcomes,
/// while source curation, framing, effects, branding defaults, and learned
/// rules live with the parts of the app that own those decisions.
struct WizardView: View {
    @Environment(AppStore.self) private var store

    @AppStorage("wizard.aiInstructions") private var aiInstructions = ""
    @AppStorage("wizard.formatPreset") private var formatPreset = "custom"
    @AppStorage("wizard.tastePreset") private var tastePreset = ""
    @AppStorage(WizardDefaults.durationModeKey) private var durationModeRaw = WizardDurationMode.automatic.rawValue
    @AppStorage(WizardDefaults.customDurationKey) private var customDuration = 20
    @AppStorage(WizardDefaults.audioModeKey) private var audioModeRaw = WizardAudioMode.mix.rawValue
    @AppStorage(WizardDefaults.textModeKey) private var textModeRaw = WizardTextMode.automatic.rawValue
    @AppStorage("wizard.critiqueLoop") private var critiqueLoop = true
    @AppStorage(WizardDefaults.layoutModeKey) private var layoutModeRaw = WizardLayoutMode.automatic.rawValue
    @AppStorage(WizardDefaults.brandingOverrideKey) private var brandingOverrideRaw = WizardBrandingOverride.savedDefault.rawValue
    @AppStorage("wizard.limitToSelection") private var limitToSelection = false
    @AppStorage("wizard.curatedOnly") private var curatedOnly = false
    /// Comma-joined Analyze batch IDs — AppStorage cannot persist a Set.
    @AppStorage("wizard.selectedRunIDs") private var selectedRunIDsRaw = ""
    /// Comma-joined person keys (empty means anyone in the selected scenes).
    @AppStorage("wizard.sourcePeople") private var sourcePeopleRaw = ""
    @AppStorage(SceneStacks.levelKey) private var stackLevelRaw = SceneStackLevel.standard.rawValue

    @State private var musicCount = 0
    @State private var showTrainingGuide = false
    @State private var showGapReport = false
    @State private var showSourcePicker = false
    @State private var showCuratedWizard = false
    @State private var pendingDispatch: PendingDispatch?

    private struct SourcePoolKey: Equatable {
        var scenesVersion: Int
        var curatedOnly: Bool
        var limitToSelection: Bool
        var selectedRunIDsRaw: String
        var personTags: Set<String>
    }
    @State private var sourcePoolMemo = MemoBox<SourcePoolKey, [SceneRecord]>()

    private var durationMode: WizardDurationMode {
        WizardDurationMode(rawValue: durationModeRaw) ?? .automatic
    }

    private var durationModeBinding: Binding<WizardDurationMode> {
        Binding(
            get: { durationMode },
            set: { durationModeRaw = $0.rawValue }
        )
    }

    private var audioMode: WizardAudioMode {
        WizardAudioMode(rawValue: audioModeRaw) ?? .mix
    }

    private var audioModeBinding: Binding<WizardAudioMode> {
        Binding(
            get: { audioMode },
            set: { audioModeRaw = $0.rawValue }
        )
    }

    private var textMode: WizardTextMode {
        WizardTextMode(rawValue: textModeRaw) ?? .automatic
    }

    private var textModeBinding: Binding<WizardTextMode> {
        Binding(
            get: { textMode },
            set: { textModeRaw = $0.rawValue }
        )
    }

    private var layoutMode: WizardLayoutMode {
        WizardLayoutMode(rawValue: layoutModeRaw) ?? .automatic
    }

    private var layoutModeBinding: Binding<WizardLayoutMode> {
        Binding(
            get: { layoutMode },
            set: { layoutModeRaw = $0.rawValue }
        )
    }

    private var brandingOverride: WizardBrandingOverride {
        WizardBrandingOverride(rawValue: brandingOverrideRaw) ?? .savedDefault
    }

    private var brandingOverrideBinding: Binding<WizardBrandingOverride> {
        Binding(
            get: { brandingOverride },
            set: { brandingOverrideRaw = $0.rawValue }
        )
    }

    private var resolvedBranding: WizardBrandingMode {
        brandingOverride.resolved()
    }

    private var selectedRunIDs: Set<Int64> {
        Set(selectedRunIDsRaw.split(separator: ",").compactMap { Int64($0) })
    }

    private func setSelectedRunIDs(_ ids: Set<Int64>) {
        selectedRunIDsRaw = ids.sorted().map(String.init).joined(separator: ",")
    }

    /// The latest Analyze batch of each handed-off video.
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

    private var selectedSourcePeople: Set<String> {
        Set(sourcePeopleRaw.split(separator: ",").map(String.init))
    }

    private var eligibleSourcePeople: [PersonRecord] {
        guard limitToSelection, !selectedRunIDs.isEmpty else { return store.people }
        var tags = Set<String>()
        for runID in selectedRunIDs {
            tags.formUnion(store.sceneIndex.personTagsByRun[runID] ?? [])
        }
        return store.people.filter { tags.contains($0.tag) }
    }

    /// Captions only use transcripts that have already been generated.
    private var transcriptsAvailable: Bool {
        let runs = limitToSelection && !selectedRunIDs.isEmpty
            ? store.analysisRuns.filter { selectedRunIDs.contains($0.id) }
            : store.analysisRuns
        return runs.contains(where: \.hasTranscript)
    }

    private var manualTargetDuration: Int {
        switch durationMode {
        case .custom:
            min(180, max(3, customDuration))
        default:
            durationMode.duration ?? 20
        }
    }

    private var canGenerate: Bool {
        analyzedSceneCount > 0 && (!limitToSelection || !selectedRunIDs.isEmpty)
    }

    var body: some View {
        HSplitView {
            configurationForm
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
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
            .help("See what to post next and what is blocking output")

            Menu {
                Button("Training Guide", systemImage: "questionmark.circle") {
                    showTrainingGuide = true
                }
                Button("Manage Learned Rules…", systemImage: "brain.head.profile") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            } label: {
                Label("Wizard tools", systemImage: "ellipsis.circle")
            }
        }
        .sheet(isPresented: $showGapReport) {
            GapReportSheet()
        }
        .sheet(isPresented: $showTrainingGuide) {
            HelpSheet()
        }
        .sheet(isPresented: $showSourcePicker) {
            WizardSourcePickerSheet(curatedOnly: $curatedOnly,
                                    limitToSelection: $limitToSelection,
                                    selectedRunIDsRaw: $selectedRunIDsRaw,
                                    sourcePeopleRaw: $sourcePeopleRaw)
                .environment(store)
        }
        .sheet(isPresented: $showCuratedWizard) {
            CuratedWizardSheet(
                scenes: curatedWizardPool,
                targetDuration: manualTargetDuration,
                includeOutro: resolvedBranding.includeOutro,
                batchNames: Dictionary(uniqueKeysWithValues: store.analysisRuns.map {
                    ($0.id, $0.name.isEmpty ? $0.videoFilename : $0.name)
                }),
                selectedBatchIDs: limitToSelection
                    ? store.analysisRuns.map(\.id).filter(selectedRunIDs.contains)
                    : []
            )
        }
        .sheet(item: $pendingDispatch) { pending in
            DispatchPlanSheet(operation: pending.operation, onStart: pending.run)
        }
        .sheet(isPresented: requestModalPresented) {
            generateRequestModal
        }
        .task {
            migrateLegacySelections()
            refreshMusicCount()
        }
        .task {
            if let handoff = store.pendingWizardPrompt {
                applyPromptHandoff(handoff)
            }
        }
        .onChange(of: store.pendingWizardPrompt) { _, handoff in
            if let handoff {
                applyPromptHandoff(handoff)
            }
        }
    }

    private var configurationForm: some View {
        Form {
            Section("What should we make?") {
                TextEditor(text: $aiInstructions)
                    .font(.body)
                    .frame(minHeight: 76)
                Text("Describe the outcome, hook, or must-have moments. Saved research and learned rules are applied automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Plan") {
                Picker("Recipe", selection: $formatPreset) {
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
                }

                Picker("Length", selection: durationModeBinding) {
                    ForEach(WizardDurationMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                if durationMode == .custom {
                    HStack {
                        Text("Custom length")
                        Spacer()
                        TextField("Seconds", value: $customDuration, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 58)
                        Stepper("Custom length", value: $customDuration, in: 3...180)
                            .labelsHidden()
                        Text("seconds")
                            .foregroundStyle(.secondary)
                    }
                    .onChange(of: customDuration) { _, value in
                        let clamped = min(180, max(3, value))
                        if clamped != value { customDuration = clamped }
                    }
                }

                LabeledContent("Sources") {
                    Button {
                        showSourcePicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(sourceSummary)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .buttonStyle(.borderless)
                }

                Text(framingStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Output") {
                Picker("Audio", selection: audioModeBinding) {
                    ForEach(WizardAudioMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                if audioMode.useMusic && musicCount == 0 {
                    HStack {
                        Label("No music has been added yet", systemImage: "music.note.list")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Music") {
                            store.requestedSection = .music
                        }
                        .controlSize(.small)
                    }
                }

                Picker("On-screen text", selection: textModeBinding) {
                    ForEach(WizardTextMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                if (textMode == .captions || textMode == .both), !transcriptsAvailable {
                    Text("No transcript is available in these sources, so captions will be skipped.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Picker("Quality", selection: $critiqueLoop) {
                    Text("Standard — one render").tag(false)
                    Text("Best — up to 3 versions").tag(true)
                }
                Text(critiqueLoop
                     ? "The critic can request up to two better alternatives; every version is kept in the Library."
                     : "Renders the first planned version only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let handoff = store.pendingWizardTemplate {
                Section("Reference template") {
                    referenceTemplateChip(handoff)
                }
            }

            DisclosureGroup("More options") {
                Picker("Style reference", selection: $tastePreset) {
                    Text("Profile taste").tag("")
                    Text("No style reference").tag("none")
                    if !store.activeProfile.tasteCategories.isEmpty {
                        Divider()
                        ForEach(store.activeProfile.tasteCategories) { category in
                            Text(category.label).tag("cat:\(category.key)")
                        }
                    }
                }

                Picker("Layouts", selection: layoutModeBinding) {
                    ForEach(WizardLayoutMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                HStack {
                    Text("Manage reusable layouts in Assets → Screen Crop.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open") { store.requestedSection = .screenCrops }
                        .controlSize(.small)
                }

                Picker("Branding", selection: brandingOverrideBinding) {
                    ForEach(WizardBrandingOverride.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                if store.activeProfile.logoPath.isEmpty,
                   resolvedBranding.includeWatermark || resolvedBranding.includeOutro {
                    Text("No brand logo is set. Add one in Settings → Profile to use the watermark or outro.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text("Saved scene framing, approved transition effects, fight research, and learned rules apply automatically. Manage them in Analyze, Assets, and Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            generationBar
        }
    }

    private func referenceTemplateChip(_ handoff: WizardTemplateHandoff) -> some View {
        HStack(spacing: 10) {
            if let url = handoff.thumbnailURL {
                CachedImage(url: url, maxPixel: 160)
                    .frame(width: 34, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.quaternary)
                    .frame(width: 34, height: 56)
                    .overlay {
                        Image(systemName: "play.rectangle")
                            .foregroundStyle(.secondary)
                    }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(handoff.label)
                Text("Hook, pacing, and text style will guide this reel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Remove Template", systemImage: "xmark.circle.fill") {
                store.pendingWizardTemplate = nil
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .help("Remove this reference template")
        }
    }

    private var generationBar: some View {
        VStack(spacing: 8) {
            if analyzedSceneCount == 0 {
                Text("Analyze footage first — the wizard builds from analyzed scenes.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if limitToSelection, selectedRunIDs.isEmpty {
                Text("Choose at least one Analyze batch in Sources before generating.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                if store.isWizardRunning {
                    Button(role: .destructive) {
                        store.cancelWizard()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .controlSize(.large)
                } else {
                    Button {
                        startGeneration()
                    } label: {
                        Label("Generate", systemImage: "wand.and.stars")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canGenerate)
                }

                Spacer()

                Menu {
                    Button("Build manually…", systemImage: "checklist") {
                        showCuratedWizard = true
                    }
                    .disabled(!canGenerate || store.isCuratedRendering)
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .help("Build this reel manually from the same source selection")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var sourceSummary: String {
        var summary: String
        if limitToSelection {
            summary = selectedRunIDs.isEmpty
                ? "Choose Analyze batches"
                : "\(selectedRunIDs.count) Analyze batch\(selectedRunIDs.count == 1 ? "" : "es")"
        } else if curatedOnly {
            summary = "Curated scenes"
        } else {
            summary = "All analyzed scenes"
        }

        let names = store.people
            .filter { selectedSourcePeople.contains($0.key) }
            .map(\.displayName)
        if !names.isEmpty {
            summary += " · " + names.prefix(2).joined(separator: ", ")
            if names.count > 2 { summary += " +\(names.count - 2)" }
        }
        return summary
    }

    private var framingStatus: String {
        let wideScenes = sourcePool.filter(\.wide)
        guard !wideScenes.isEmpty else {
            return "No wide scenes in this source selection."
        }
        let saved = wideScenes.filter { $0.centerStagePath != nil }.count
        if saved == wideScenes.count {
            return "Framing: all \(saved) wide scenes use their saved 9:16 framing."
        }
        return "Framing: \(saved) of \(wideScenes.count) wide scenes use saved 9:16 framing; the rest use an automatic crop."
    }

    /// Shared source policy for both AI planning and the manual alternative.
    /// Memoized: body reads it several times per evaluation and the person
    /// containment pass is quadratic in the pool.
    private var sourcePool: [SceneRecord] {
        let personTags = Set(store.people
            .filter { selectedSourcePeople.contains($0.key) }
            .map(\.tag))
        let key = SourcePoolKey(scenesVersion: store.scenesVersion,
                                curatedOnly: curatedOnly,
                                limitToSelection: limitToSelection,
                                selectedRunIDsRaw: selectedRunIDsRaw,
                                personTags: personTags)
        return sourcePoolMemo(key) { computeSourcePool(personTags: personTags) }
    }

    private func computeSourcePool(personTags: Set<String>) -> [SceneRecord] {
        var pool = store.scenes.filter { !$0.excluded && !$0.ignored }
        if curatedOnly {
            pool = pool.filter(\.curated)
        }
        if limitToSelection, !selectedRunIDs.isEmpty {
            let runIDs = selectedRunIDs
            pool = pool.filter { $0.runID.map(runIDs.contains) ?? false }
        }

        if !personTags.isEmpty {
            // Person tags are frequently on a parent sequence rather than
            // each of its component beats, so include contained beats too.
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
        return pool
    }

    /// The manual wizard proposes focused beats from the same source pool.
    private var curatedWizardPool: [SceneRecord] {
        var pool = sourcePool
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
        pool = SceneStacks.tops(pool, level: .from(stackLevelRaw))

        func rank(_ scene: SceneRecord) -> Double {
            var value = scene.score ?? scene.excitement.map { $0 * 10 } ?? -1
            if scene.tags.contains(where: { $0.hasPrefix("highlight") }) { value += 5 }
            return value
        }

        if pool.contains(where: { rank($0) >= 0 }) {
            let groups = Dictionary(grouping: pool) { $0.runID ?? -1 }
            let batchCount = max(1, groups.count)
            let totalBudget = max(Double(manualTargetDuration) * 4, 60)
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

    private func refreshMusicCount() {
        musicCount = WizardEngine.availableMusic().count
    }

    private func migrateLegacySelections() {
        let defaults = UserDefaults.standard
        WizardDefaults.migrateLegacy(defaults: defaults)
        audioModeRaw = WizardDefaults.audioMode(defaults: defaults).rawValue
        textModeRaw = WizardDefaults.textMode(defaults: defaults).rawValue
        durationModeRaw = WizardDefaults.durationMode(defaults: defaults).rawValue
        layoutModeRaw = WizardLayoutMode(rawValue: defaults.string(forKey: WizardDefaults.layoutModeKey) ?? "")?.rawValue
            ?? WizardLayoutMode.automatic.rawValue
        brandingOverrideRaw = WizardDefaults.brandingOverride(defaults: defaults).rawValue

        // Learned categories used to appear as recipes. Keep the person's
        // intent, but put it in the optional style reference where it belongs.
        if formatPreset.hasPrefix("cat:") {
            if tastePreset.isEmpty { tastePreset = formatPreset }
            formatPreset = "custom"
        }
    }

    private func startGeneration() {
        if store.settings.ai.mutedDispatchPlans.contains(DispatchOperation.generate.rawValue) {
            runWizard()
            store.wizardLog.append("Model-plan prompt is muted — reset Smart Dispatcher in Settings → AI to show it again.")
        } else {
            pendingDispatch = PendingDispatch(operation: .generate) {
                runWizard()
            }
        }
    }

    private var requestModalPresented: Binding<Bool> {
        Binding(
            get: {
                guard let handoff = store.pendingWizardPrompt else { return false }
                return handoff.statusMessage != nil || handoff.parseFailed
            },
            set: { presented in
                if !presented { store.pendingWizardPrompt = nil }
            }
        )
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
                Label("Couldn't interpret the request with AI — it was added to the brief as written.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(20)
        .frame(width: 440)
        .modalCloseButton { store.pendingWizardPrompt = nil }
    }

    private func applyPromptHandoff(_ handoff: WizardPromptHandoff) {
        if !handoff.runIDs.isEmpty {
            setSelectedRunIDs(handoff.runIDs)
            limitToSelection = true
            curatedOnly = false
        } else if !handoff.videoIDs.isEmpty {
            setSelectedRunIDs(latestRunIDs(forVideoIDs: handoff.videoIDs))
            limitToSelection = true
            curatedOnly = false
        }
        if !handoff.personKeys.isEmpty {
            sourcePeopleRaw = handoff.personKeys.sorted().joined(separator: ",")
        }

        guard let parsed = handoff.parsed else {
            aiInstructions = ([tagFilterLine(handoff.tags), handoff.description]
                .compactMap { $0 }).joined(separator: "\n")
            return
        }

        if let duration = parsed.targetDurationSeconds {
            customDuration = min(180, max(3, duration))
            durationModeRaw = WizardDurationMode.custom.rawValue
        }
        if let useMusic = parsed.useMusic {
            if useMusic, audioMode == .original {
                audioModeRaw = WizardAudioMode.mix.rawValue
            } else if !useMusic {
                audioModeRaw = WizardAudioMode.original.rawValue
            }
        }
        applyParsedTextOptions(captions: parsed.addCaptions,
                               headlines: parsed.enableTextOverlays)

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

    private func applyParsedTextOptions(captions: Bool?, headlines: Bool?) {
        switch (captions, headlines) {
        case let (.some(captions), .some(headlines)):
            switch (captions, headlines) {
            case (true, true): textModeRaw = WizardTextMode.both.rawValue
            case (true, false): textModeRaw = WizardTextMode.captions.rawValue
            case (false, true): textModeRaw = WizardTextMode.headlines.rawValue
            case (false, false): textModeRaw = WizardTextMode.none.rawValue
            }
        case (.some(true), nil):
            textModeRaw = WizardTextMode.captions.rawValue
        case (nil, .some(true)):
            textModeRaw = WizardTextMode.headlines.rawValue
        case (.some(false), nil), (nil, .some(false)), (nil, nil):
            break
        }
    }

    private func tagFilterLine(_ tags: [String]) -> String? {
        tags.isEmpty ? nil
            : "Only use footage tagged: \(tags.joined(separator: ", ")). Skip everything else."
    }

    private func runWizard() {
        guard canGenerate else { return }

        let musicAvailable = !WizardEngine.availableMusic().isEmpty
        let audio = audioMode
        let text = textMode.output(transcriptsAvailable: transcriptsAvailable, recipe: formatPreset)
        let branding = resolvedBranding
        var options = WizardOptions()
        options.useMusic = audio.useMusic && musicAvailable
        options.muteSource = audio.muteSource && options.useMusic
        options.addCaptions = text.captions
        options.enableTextOverlays = text.headlines
        options.framingCamera = WizardDefaults.fallbackFramingCamera
        options.screenCropLayouts = layoutMode == .automatic
            ? WizardOptions.screenCropLayoutsFromDefaults() : []
        options.allowedTransitions = WizardOptions.allowedTransitionsFromDefaults()
        options.useFightResearch = true
        options.aiInstructions = aiInstructions
        options.targetDurationSeconds = durationMode.duration
            ?? (durationMode == .custom ? min(180, max(3, customDuration)) : nil)
        options.formatPreset = formatPreset
        options.critiqueLoop = critiqueLoop
        options.tastePreset = tastePreset.isEmpty ? nil : tastePreset
        options.includeWatermark = branding.includeWatermark
        options.includeHeadline = branding.includeHeadline
        options.includeOutro = branding.includeOutro
        options.selectedRunIDs = limitToSelection ? selectedRunIDs : []
        options.curatedOnly = curatedOnly

        let eligibleKeys = Set(eligibleSourcePeople.map(\.key))
        options.sourcePeople = sourcePeopleRaw.split(separator: ",").map(String.init)
            .filter(eligibleKeys.contains)

        if let handoff = store.pendingWizardTemplate {
            options.templateJSON = handoff.templateJSON
            options.templateLabel = handoff.label
        }
        if let parsed = store.pendingWizardPrompt?.parsed {
            options.pinnedOverlayTemplate = parsed.overlayTemplate
            options.pinnedOverlayText = parsed.overlayText
        }
        store.runWizard(options: options)
    }
}
