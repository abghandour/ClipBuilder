import AVKit
import Speech
import SwiftUI

/// Which user action a dispatch plan gates.
enum DispatchOperation: String {
    case analyze
    case generate

    var title: String {
        switch self {
        case .analyze: return "Model plan for analysis"
        case .generate: return "Model plan for generation"
        }
    }

    /// AI-dispatched stages, in pipeline order.
    var aiTasks: [String] {
        switch self {
        case .analyze: return ["analysis"]
        case .generate: return ["research", "wizard", "captions", "parse"]
        }
    }

    /// Stages that run on-device — shown for transparency, nothing to pick.
    /// (Analysis transcription has its own toggle + pickers in the sheet.)
    var localStages: [(label: String, detail: String)] {
        switch self {
        case .analyze:
            return [("Scene detection", "derived from the analysis tags — local")]
        case .generate:
            return [("Video assembly", "ffmpeg — runs on this Mac")]
        }
    }
}

/// An operation waiting for its model plan to be confirmed.
struct PendingDispatch: Identifiable {
    let id = UUID()
    var operation: DispatchOperation
    /// The videos an analysis run targets — drives the per-video notes panel.
    var videos: [VideoRecord] = []
    var run: () -> Void
}

/// The smart dispatcher's pre-flight sheet: which model handles each stage
/// of the operation, editable, with a "remember" checkbox that mutes the
/// prompt for this operation type (reset from Settings → AI).
struct DispatchPlanSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let operation: DispatchOperation
    var videos: [VideoRecord] = []
    let onStart: () -> Void

    private var showsNotesPanel: Bool { operation == .analyze && !videos.isEmpty }

    /// task → "provider|model" (Picker-friendly composite tag).
    @State private var choices: [String: String] = [:]
    @State private var remember = false
    // Optimistic until the async CLI check lands, so the sheet never blocks.
    @State private var availableProviders = Set(AICatalog.providers.map(\.key))

    /// Analyze runs in stages: teach identities first, then tag scenes, then
    /// (for footage that isn't already 9:16) frame them for portrait output.
    enum AnalyzeTab {
        case people
        case tags
        case framing
    }

    @State private var analyzeTab: AnalyzeTab = .people

    // Analysis-only options; persisted so muted runs keep the last values.
    @AppStorage("analysis.instructions") private var instructions = ""
    @AppStorage("analysis.sampleInterval") private var sampleInterval = 0.0   // 0 = automatic
    @AppStorage("analysis.autoBreakdown") private var autoBreakdown = false
    /// Comma-joined tags whose scenes get the breakdown pass — AppStorage
    /// can't hold a Set directly.
    @AppStorage("analysis.breakdownTags") private var breakdownTagsRaw = ""
    @AppStorage("analysis.includeTranscript") private var includeTranscript = false
    // Framing pass options: one static rect per scene by default, framed:
    // people tags on, unframed scenes letterboxed (no auto-zoom).
    @AppStorage("analysis.framingCamera") private var framingCamera = FramingService.staticCamera
    @AppStorage("analysis.framingTagPeople") private var framingTagPeople = true
    @AppStorage("analysis.autoZoomUnframed") private var autoZoomUnframed = false
    // One engine today; persisted so future engines slot in without a rekey.
    @AppStorage("analysis.transcribeEngine") private var transcribeEngine = "apple"
    @State private var transcriptionLocales: [Locale] = []
    @State private var savedPrompts: [SavedPrompt] = []
    @State private var showSavePrompt = false
    @State private var showManagePrompts = false
    @State private var savePromptName = ""
    // Per-run trim (single video only) — deliberately NOT persisted: a
    // leftover range must never silently apply to another video.
    @State private var trimStart = 0.0
    @State private var trimEnd = 0.0
    // Roster selection (single video only) — also per-run, like the trim:
    // checked people can become a hard "must all be present" scene filter.
    @State private var selectedPeopleKeys: Set<String> = []
    @State private var requirePeople = false
    // Shared with the notes panel: it owns playback and draws the marker
    // boxes; the People column hosts Add Person and the marker list.
    @State private var panelVideoIndex = 0
    @State private var panelPlayer: AVPlayer?
    @State private var panelMarkers: [PersonMarker] = []
    @State private var pendingNewPersonMarker: PersonMarker?
    @State private var newPersonName = ""

    private static let markerColors: [Color] = [.yellow, .green, .cyan, .orange,
                                                .pink, .purple, .red, .mint]

    private static let samplingChoices: [(label: String, value: Double)] = [
        ("Automatic (1–3s by length)", 0),
        ("Every 0.5s", 0.5), ("Every 1s", 1), ("Every 2s", 2),
        ("Every 3s", 3), ("Every 5s", 5), ("Every 10s", 10),
    ]

    /// The gate: every targeted video must have had people detection before
    /// tag detection may run. Read from the live store so a just-finished
    /// detect run counts immediately.
    private func peopleDone(_ video: VideoRecord) -> Bool {
        (store.videos.first { $0.id == video.id } ?? video).peopleDetectedAt != nil
    }

    private var peopleGateSatisfied: Bool {
        videos.allSatisfy(peopleDone)
    }

    /// Framing only applies to footage that isn't already 9:16 — vertical
    /// video needs no crop window.
    private var framingApplies: Bool {
        guard let video = videos.first, video.width > 0, video.height > 0 else { return false }
        let aspect = Double(video.width) / Double(video.height)
        let vertical = 9.0 / 16.0
        return abs(aspect - vertical) / vertical > 0.02
    }

    /// Framing operates on detected scenes — tag detection must have run.
    private var framingScenes: [SceneRecord] {
        guard let video = videos.first else { return [] }
        return store.scenes.filter { $0.videoID == video.id && !$0.excluded }
    }

    /// The video the notes panel is showing — marker controls target it.
    private var panelVideo: VideoRecord? {
        videos.isEmpty ? nil : videos[min(panelVideoIndex, videos.count - 1)]
    }

    /// The picker's LIVE model choice for the shared "analysis" task — the
    /// people pass honors it immediately (Start persists it for tagging).
    private var analysisChoice: (provider: String?, model: String?) {
        let tag = choices["analysis"] ?? recommendedTag(for: "analysis")
        let parts = tag.split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else { return (nil, nil) }
        return (String(parts[0]), String(parts[1]))
    }

    private func markerColor(_ marker: PersonMarker) -> Color {
        if marker.ignored { return .gray }
        let index = panelMarkers.firstIndex(where: { $0.id == marker.id }) ?? 0
        return Self.markerColors[index % Self.markerColors.count]
    }

    private func markerPersonName(_ marker: PersonMarker) -> String? {
        if marker.ignored { return "Ignored" }
        return marker.personID.flatMap { id in store.people.first { $0.id == id }?.displayName }
    }

    var body: some View {
        VStack(spacing: 0) {
            if operation == .analyze {
                Picker("Mode", selection: $analyzeTab) {
                    Text("People Detection").tag(AnalyzeTab.people)
                    Text("Tag Detection").tag(AnalyzeTab.tags)
                    if framingApplies {
                        Text("Framing Detection").tag(AnalyzeTab.framing)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: framingApplies ? 520 : 380)
                .padding(.top, 12)
            }
            HStack(alignment: .top, spacing: 0) {
                if operation == .analyze && analyzeTab == .people {
                    peopleColumn
                        .frame(width: 460)
                } else if operation == .analyze && analyzeTab == .framing {
                    framingColumn
                        .frame(width: 460)
                } else {
                    planColumn
                        .frame(width: 460)
                }
                if showsNotesPanel {
                    Divider()
                    VideoNotesPanel(videos: videos,
                                    mode: analyzeTab == .people ? .people
                                        : analyzeTab == .framing ? .framing : .tags,
                                    trimStart: $trimStart, trimEnd: $trimEnd,
                                    selectedPeopleKeys: $selectedPeopleKeys,
                                    requirePeople: $requirePeople,
                                    selectedIndex: $panelVideoIndex,
                                    player: $panelPlayer,
                                    markers: $panelMarkers)
                        .frame(width: 520)
                }
            }
        }
        .task {
            var available = Set<String>()
            for provider in AICatalog.providers {
                if await store.ai.isProviderAvailable(provider.key) {
                    available.insert(provider.key)
                }
            }
            availableProviders = available
            seedChoices()
            if operation == .analyze {
                let locales = await SpeechTranscriber.supportedLocales
                transcriptionLocales = locales.sorted {
                    localeDisplayName($0).localizedCaseInsensitiveCompare(localeDisplayName($1)) == .orderedAscending
                }
            }
        }
        .onAppear {
            seedChoices()
            savedPrompts = PromptStore.load()
            // Land on the tab with work left: identities first, tags once
            // every video has them.
            if operation == .analyze {
                analyzeTab = peopleGateSatisfied ? .tags : .people
            }
        }
        .alert("Save Prompt", isPresented: $showSavePrompt) {
            TextField("Name", text: $savePromptName)
            Button("Save") {
                let name = savePromptName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                savedPrompts = PromptStore.upsert(name: name, text: instructions)
                savePromptName = ""
            }
            Button("Cancel", role: .cancel) { savePromptName = "" }
        } message: {
            Text("Saving with an existing prompt's name updates that prompt.")
        }
        .sheet(isPresented: $showManagePrompts) {
            ManagePromptsSheet(prompts: $savedPrompts) { instructions = $0 }
        }
        .alert("New Person", isPresented: Binding(
            get: { pendingNewPersonMarker != nil },
            set: { if !$0 { pendingNewPersonMarker = nil; newPersonName = "" } })
        ) {
            TextField("Name", text: $newPersonName)
            Button("Create") {
                let name = newPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
                if var marker = pendingNewPersonMarker, !name.isEmpty {
                    Task {
                        if let person = await store.createPerson(named: name) {
                            marker.personID = person.id
                            panelMarkers = await store.updatePersonMarker(marker)
                        }
                    }
                }
                pendingNewPersonMarker = nil
                newPersonName = ""
            }
            Button("Cancel", role: .cancel) {
                pendingNewPersonMarker = nil
                newPersonName = ""
            }
        } message: {
            Text("The person is added to the People section and this marker teaches the analyzer their face.")
        }
    }

    /// Drop a fresh box at the paused moment, centered-ish so it's easy to
    /// grab and fit around a person over the player on the right.
    private func addPersonMarker() {
        guard let panelPlayer, let video = panelVideo else { return }
        panelPlayer.pause()
        let seconds = panelPlayer.currentTime().seconds
        let atTime = seconds.isFinite ? max(0, (seconds * 10).rounded() / 10) : 0
        Task {
            panelMarkers = await store.addPersonMarker(videoID: video.id, at: atTime,
                                                       x: 0.35, y: 0.2, width: 0.3, height: 0.55)
        }
    }

    /// One marker: color swatch, seek-to timecode, person dropdown, delete.
    @ViewBuilder
    private func markerRow(_ marker: PersonMarker) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(markerColor(marker))
                .frame(width: 10, height: 10)
            Button {
                panelPlayer?.pause()
                panelPlayer?.seek(to: CMTime(seconds: marker.atTime, preferredTimescale: 600))
            } label: {
                Text(marker.atTime.timecode)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.borderless)
            .help("Jump the player to this marker's moment")

            Menu(markerPersonName(marker) ?? "Who is this?") {
                ForEach(store.people) { person in
                    Button(person.displayName) {
                        var updated = marker
                        updated.personID = person.id
                        let wasIgnored = updated.ignored
                        updated.ignored = false
                        Task {
                            panelMarkers = await store.updatePersonMarker(updated)
                            if wasIgnored, let video = panelVideo {
                                store.markerIgnoreChanged(videoID: video.id)
                            }
                        }
                    }
                }
                if !store.people.isEmpty { Divider() }
                Button("New Person…") {
                    pendingNewPersonMarker = marker
                }
                Divider()
                Button(marker.ignored ? "Stop Ignoring" : "Ignore — exclude from the whole video") {
                    var updated = marker
                    updated.ignored = !marker.ignored
                    if updated.ignored { updated.personID = nil }
                    Task {
                        panelMarkers = await store.updatePersonMarker(updated)
                        if let video = panelVideo {
                            store.markerIgnoreChanged(videoID: video.id)
                        }
                    }
                }
                .help("The boxed person (e.g. a referee) is never framed by Center Stage and never registered or tagged by analysis — applied to this entire video")
            }
            .controlSize(.small)
            .fixedSize()

            Spacer()

            Button {
                Task { panelMarkers = await store.deletePersonMarker(marker) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    /// People Detection tab: per-video status + run buttons. Tagging stays
    /// locked until every targeted video has been through this.
    private var peopleColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("People detection")
                    .font(.headline)
                Text("Teach the system who is who: box and name people on the right, then run detection. Tag detection unlocks once every video here has been through it — scene tags always carry the people present.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Form {
                // Same "analysis" model task as tag detection — one picker
                // choice powers both passes; runs here honor it immediately.
                Picker(AICatalog.taskLabels["analysis"] ?? "analysis",
                       selection: binding(for: "analysis")) {
                    ForEach(options(for: "analysis"), id: \.tag) { option in
                        Text(option.label).tag(option.tag)
                    }
                }
                ForEach(videos) { video in
                    let done = peopleDone(video)
                    HStack {
                        Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(done ? Color.green : Color.secondary)
                        Text(video.filename)
                            .lineLimit(1)
                        Spacer()
                        Button(done ? "Re-run" : "Detect") {
                            let choice = analysisChoice
                            Task {
                                _ = await store.detectPeopleInVideo(video,
                                                                    provider: choice.provider,
                                                                    model: choice.model)
                            }
                        }
                        .controlSize(.small)
                        .disabled(store.isDetectingPeople)
                    }
                }
                if store.isDetectingPeople {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Detecting people…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: CGFloat(videos.count + 2) * 44 + 40)

            // Marker controls for the video showing on the right: the boxes
            // themselves are drawn (and dragged) over the player there.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button {
                        addPersonMarker()
                    } label: {
                        Label("Add Person", systemImage: "person.crop.rectangle.badge.plus")
                    }
                    .help("Pauses the video and drops a colored box at this moment — drag and resize it around one person on the right, then name them here. Markers are ground truth for people recognition.")
                    Spacer()
                }
                if panelMarkers.isEmpty {
                    Text("No markers yet — pause on someone and click Add Person.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(panelMarkers) { marker in
                                markerRow(marker)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Continue to Tag Detection") { analyzeTab = .tags }
                    .buttonStyle(.borderedProminent)
                    .disabled(!peopleGateSatisfied)
            }
            .padding()
        }
    }

    /// Everything Center Stage: how scenes get their 9:16 framing (static
    /// rect or moving camera), and whether the people inside the framing are
    /// tagged for later filtering. Local passes only — no AI cost.
    private var framingColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Framing detection")
                    .font(.headline)
                Text("Give each detected scene its 9:16 framing — the window, the zoom, and who is inside it. Pause the video on the right and adjust the rectangle to pin the framing at that moment; pins are hard hints the pass obeys exactly. Scenes without framing show with black bars.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Form {
                Picker("Camera", selection: $framingCamera) {
                    Text("Static (one rect per scene)").tag(FramingService.staticCamera)
                    Text("Smooth").tag("smooth")
                    Text("Balanced").tag("balanced")
                    Text("Fast action").tag("fast")
                }
                .help("Static picks one fixed 9:16 rectangle per scene. The other presets track the people and move the camera through the scene.")
                Toggle("Tag people inside the framing", isOn: $framingTagPeople)
                    .help("Adds framed:<person> tags per person: each is identity-matched against their marker portraits and must sit mostly inside the framing — filter the Scenes screen by who is actually in frame, not just in the scene. Local check, no AI cost.")
                Toggle("Auto-zoom scenes without framing", isOn: $autoZoomUnframed)
                    .help("Applies to tag-detection runs: scenes get a centered people crop even before framing runs. Off (default), unframed scenes stay letterboxed with black bars.")

                LabeledContent("Scenes") {
                    if framingScenes.isEmpty {
                        Text("none yet — run tag detection first")
                            .foregroundStyle(.orange)
                    } else {
                        let framed = framingScenes.count(where: { $0.centerStagePathJSON != nil })
                        Text("\(framed) of \(framingScenes.count) framed")
                            .foregroundStyle(.secondary)
                    }
                }
                if store.isDetectingFraming {
                    HStack(spacing: 6) {
                        ProgressView(value: store.framingProgress)
                        Text("Framing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(framingScenes.contains(where: { $0.centerStagePathJSON != nil })
                       ? "Re-run Framing" : "Detect Framing") {
                    guard let video = videos.first else { return }
                    let camera = framingCamera
                    let tagPeople = framingTagPeople
                    Task {
                        await store.detectFraming(video: video, camera: camera,
                                                  tagFramedPeople: tagPeople)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isDetectingFraming || framingScenes.isEmpty)
            }
            .padding()
        }
    }

    private var planColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(operation.title)
                    .font(.headline)
                Text("The dispatcher picked the best available model for each step. Adjust if you like — if a model fails mid-run, the next best available takes over automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Form {
                ForEach(operation.aiTasks, id: \.self) { task in
                    Picker(AICatalog.taskLabels[task] ?? task, selection: binding(for: task)) {
                        ForEach(options(for: task), id: \.tag) { option in
                            Text(option.label).tag(option.tag)
                        }
                    }
                }
                if operation == .analyze {
                    if analysisChoice.provider == "gemini" {
                        Text("Gemini watches the video natively (motion + audio) when the file is under 300 MB and no section is trimmed; otherwise sampled frames are sent.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Frame sampling", selection: $sampleInterval) {
                        ForEach(Self.samplingChoices, id: \.value) { choice in
                            Text(choice.label).tag(choice.value)
                        }
                    }
                    .help("How often a frame is sent to the model. Denser sampling catches short moments but costs more (capped at 60 frames).")
                    Toggle("Break down tagged scenes into sub-scenes", isOn: $autoBreakdown)
                        .help("Scenes carrying one of the tags picked below get a second, frame-dense AI pass that splits them into their individual actions — each combo or exchange becomes its own scene. Costs one extra AI call per broken-down scene.")
                    if autoBreakdown {
                        breakdownTagRows
                    }
                    transcriptionRows
                }
                ForEach(operation.localStages, id: \.label) { stage in
                    LabeledContent(stage.label) {
                        Text(stage.detail)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: CGFloat(operation.aiTasks.count + operation.localStages.count) * 44 + 60
                   + (operation == .analyze
                      ? (includeTranscript ? 176 : 88) + (autoBreakdown ? 160 : 0)
                      : 0))

            if operation == .analyze {
                instructionsSection
                    .padding(.horizontal)
            }

            VStack(alignment: .leading, spacing: 10) {
                // Analysis always shows this plan — remembering applies to
                // generation only.
                if operation == .generate {
                    Toggle("Remember these choices and don't ask again", isOn: $remember)
                    Text("You can reset the dispatcher's choices and re-enable this prompt in Settings → AI.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if operation == .analyze && !peopleGateSatisfied {
                    Label("Run people detection first — every video needs it before tag detection.",
                          systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                    Button("Start") { start() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(operation == .analyze && !peopleGateSatisfied)
                }
            }
            .padding()
        }
    }

    /// The trim range to hand to the run; nil when the handles still span
    /// the whole video (= no trim).
    private var trimRange: (start: Double, end: Double)? {
        guard let video = videos.first, trimEnd > trimStart else { return nil }
        if trimStart <= 0.05, trimEnd >= video.duration - 0.05 { return nil }
        return (max(0, trimStart), min(video.duration, trimEnd))
    }

    private var selectedBreakdownTags: Set<String> {
        Set(breakdownTagsRaw.split(separator: ",").map(String.init))
    }

    private func breakdownBinding(for tag: String) -> Binding<Bool> {
        Binding(get: { selectedBreakdownTags.contains(tag) },
                set: { on in
                    var tags = selectedBreakdownTags
                    if on { tags.insert(tag) } else { tags.remove(tag) }
                    breakdownTagsRaw = tags.sorted().joined(separator: ",")
                })
    }

    /// Which tags mark a scene for the breakdown pass, from the profile's
    /// tag vocabulary. The picks persist between runs.
    @ViewBuilder
    private var breakdownTagRows: some View {
        let vocabulary = Array(Set(store.activeProfile.effectiveTags.values.flatMap { $0 })).sorted()
        if vocabulary.isEmpty {
            Text("This profile has no tag vocabulary yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(vocabulary, id: \.self) { tag in
                        Toggle(tag, isOn: breakdownBinding(for: tag))
                            .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
            Text("Scenes at least \(Int(Analyzer.minBreakdownDuration))s long carrying any checked tag are broken down into their individual actions.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Optional per-run transcription: one engine today (Apple's on-device
    /// SpeechAnalyzer), plus which language it should listen for. The
    /// language is the same setting as Settings → Transcription.
    @ViewBuilder
    private var transcriptionRows: some View {
        Toggle("Include transcript", isOn: $includeTranscript)
            .help("Transcribe each video's audio after tagging. Videos that already have a transcript reuse it.")
        if includeTranscript {
            Picker("Transcription model", selection: $transcribeEngine) {
                Text("Apple SpeechAnalyzer — runs on this Mac").tag("apple")
            }
            Picker("Language", selection: transcribeLanguageBinding) {
                Text("Auto-detect").tag("")
                ForEach(transcriptionLocales, id: \.identifier) { locale in
                    Text(localeDisplayName(locale)).tag(locale.identifier)
                }
                // Keep a hand-typed Settings value selectable even if it
                // doesn't match a listed locale identifier.
                if !currentLanguageIsListed {
                    Text(store.settings.transcribeLanguage).tag(store.settings.transcribeLanguage)
                }
            }
        }
    }

    private var transcribeLanguageBinding: Binding<String> {
        Binding(get: { store.settings.transcribeLanguage },
                set: { store.settings.transcribeLanguage = $0 })
    }

    private var currentLanguageIsListed: Bool {
        let current = store.settings.transcribeLanguage
        return current.isEmpty || transcriptionLocales.contains { $0.identifier == current }
    }

    private func localeDisplayName(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// Named people from the registry — quick-insert hard filters into
    /// the instructions without retyping names.
    private var namedPeople: [PersonRecord] {
        store.people.filter { !$0.name.isEmpty }
    }

    private func appendInstruction(_ line: String) {
        instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? line
            : instructions.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + line
    }

    /// Optional footage context injected into the analysis prompt as
    /// highest-priority guidance, with a named history for reuse.
    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Generic instructions — apply to every video (optional)")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if !namedPeople.isEmpty {
                    Menu("People") {
                        ForEach(namedPeople) { person in
                            Menu(person.name) {
                                Button("Only include scenes with \(person.name)") {
                                    appendInstruction("Only include scenes featuring \"\(person.name)\" — omit every range where they are not clearly present.")
                                }
                                Button("Focus on \(person.name)") {
                                    appendInstruction("Focus on \"\(person.name)\" — prioritize moments where they are the main action.")
                                }
                            }
                        }
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .help("Insert an instruction referencing a person from the People section")
                }
                Menu("History") {
                    ForEach(savedPrompts) { prompt in
                        Button(prompt.name) { instructions = prompt.text }
                    }
                    if !savedPrompts.isEmpty { Divider() }
                    Button("Save Current As…") { showSavePrompt = true }
                        .disabled(instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Manage Prompts…") { showManagePrompts = true }
                        .disabled(savedPrompts.isEmpty)
                }
                .controlSize(.small)
                .fixedSize()
            }
            TextEditor(text: $instructions)
                .font(.body)
                .frame(height: 64)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            Text("Context the model can't see — e.g. “focus on the athlete in black”, “this is a seminar recording; tag technique demos”. Applies to every analysis run until cleared.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Choices

    private func binding(for task: String) -> Binding<String> {
        Binding(get: { choices[task] ?? recommendedTag(for: task) },
                set: { choices[task] = $0 })
    }

    /// The catalog's true top pick for the task — flagged in the picker
    /// even when its provider isn't installed, so the user knows what the
    /// ideal setup would be.
    private func topRecommendedTag(for task: String) -> String {
        if let entry = AICatalog.recommendedChains[task]?.first {
            return "\(entry.provider)|\(entry.model)"
        }
        let key = AICatalog.taskDefaults[task] ?? "claude"
        return "\(key)|\(AICatalog.provider(key)?.defaultModel ?? "")"
    }

    /// First recommended chain entry whose CLI is installed, else the
    /// task default provider with its default model — what actually gets
    /// pre-selected and run.
    private func recommendedTag(for task: String) -> String {
        for entry in AICatalog.recommendedChains[task] ?? []
        where availableProviders.contains(entry.provider) {
            return "\(entry.provider)|\(entry.model)"
        }
        let key = AICatalog.taskDefaults[task] ?? "claude"
        return "\(key)|\(AICatalog.provider(key)?.defaultModel ?? "")"
    }

    /// Current effective choice: the user's saved routing when present,
    /// otherwise the recommendation.
    private func seedChoices() {
        guard choices.isEmpty else { return }
        for task in operation.aiTasks {
            if let provider = store.settings.ai.tasks[task] {
                let model = store.settings.ai.taskModels[task]
                    ?? store.settings.ai.providers[provider]?.model
                    ?? AICatalog.provider(provider)?.defaultModel ?? ""
                choices[task] = "\(provider)|\(model)"
            } else {
                choices[task] = recommendedTag(for: task)
            }
        }
    }

    private func options(for task: String) -> [(tag: String, label: String)] {
        // The catalog's true best is always flagged (installed or not);
        // when it's missing, the best of what IS installed gets its own
        // flag so the effective default is legible too.
        let top = topRecommendedTag(for: task)
        let bestAvailable = recommendedTag(for: task)
        var result: [(String, String)] = []
        for provider in AICatalog.providers {
            let installed = availableProviders.contains(provider.key)
            for model in provider.models {
                let tag = "\(provider.key)|\(model)"
                var label = "\(provider.label) — \(model)"
                if tag == top {
                    label += "  ★ recommended"
                } else if tag == bestAvailable, bestAvailable != top {
                    label += "  ★ best available"
                }
                if !installed { label += "  (not installed)" }
                result.append((tag, label))
            }
        }
        // Keep whatever is currently chosen selectable even if it's custom.
        if let current = choices[task], !result.contains(where: { $0.0 == current }) {
            result.append((current, current.replacingOccurrences(of: "|", with: " — ")))
        }
        return result
    }

    private func start() {
        // One-shot hand-off: the analyze run consumes and clears these.
        if let range = trimRange {
            UserDefaults.standard.set(range.start, forKey: "analysis.trimStart")
            UserDefaults.standard.set(range.end, forKey: "analysis.trimEnd")
        } else {
            UserDefaults.standard.removeObject(forKey: "analysis.trimStart")
            UserDefaults.standard.removeObject(forKey: "analysis.trimEnd")
        }
        if requirePeople, !selectedPeopleKeys.isEmpty {
            UserDefaults.standard.set(selectedPeopleKeys.sorted().joined(separator: ","),
                                      forKey: "analysis.requiredPeople")
        } else {
            UserDefaults.standard.removeObject(forKey: "analysis.requiredPeople")
        }
        for task in operation.aiTasks {
            let tag = choices[task] ?? recommendedTag(for: task)
            let parts = tag.split(separator: "|", maxSplits: 1)
            guard parts.count == 2 else { continue }
            store.settings.ai.tasks[task] = String(parts[0])
            store.settings.ai.taskModels[task] = String(parts[1])
        }
        if remember, !store.settings.ai.mutedDispatchPlans.contains(operation.rawValue) {
            store.settings.ai.mutedDispatchPlans.append(operation.rawValue)
        }
        store.saveSettings()
        dismiss()
        onStart()
    }
}

/// Edit the saved analysis prompts: rename inline, load one into the
/// editor, or delete. Changes persist immediately.
private struct ManagePromptsSheet: View {
    @Binding var prompts: [SavedPrompt]
    let onLoad: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Saved Prompts")
                .font(.headline)
                .padding()
            List {
                ForEach($prompts) { $prompt in
                    HStack {
                        TextField("Name", text: $prompt.name)
                            .textFieldStyle(.plain)
                            .onSubmit { PromptStore.save(prompts) }
                        Spacer()
                        Button("Load") {
                            onLoad(prompt.text)
                            dismiss()
                        }
                        .controlSize(.small)
                        Button {
                            prompts.removeAll { $0.id == prompt.id }
                            PromptStore.save(prompts)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                    .help(prompt.text)
                }
            }
            .frame(minHeight: 180)
            HStack {
                Spacer()
                Button("Done") {
                    PromptStore.save(prompts)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 380)
    }
}

/// Per-video, timestamped notes: scrub the footage, pause anywhere, and
/// note what the analyzer should know about that moment. Notes persist on
/// the video until deleted and are injected into its analysis prompt.
private struct VideoNotesPanel: View {
    /// Which analyze tab drives the panel: People (markers + roster), Tags
    /// (section trim, required people, notes), or Framing (the adjustable
    /// 9:16 camera rectangle + pinned hints).
    enum PanelMode {
        case people
        case tags
        case framing
    }

    @Environment(AppStore.self) private var store
    let videos: [VideoRecord]
    var mode: PanelMode = .tags
    /// Section-to-analyze trim selector, rendered under the video so
    /// scrubbing it drives this panel's player. Defaults to the full video.
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    /// Roster checks + the "everyone checked must be in every scene" flag.
    @Binding var selectedPeopleKeys: Set<String>
    @Binding var requirePeople: Bool
    // Shared with the sheet's People column, which hosts the Add Person
    // button and marker list while this panel draws the boxes.
    @Binding var selectedIndex: Int
    @Binding var player: AVPlayer?
    @Binding var markers: [PersonMarker]

    @State private var notes: [VideoNote] = []
    @State private var noteText = ""
    @State private var currentTime = 0.0
    @State private var timeObserver: Any?
    @State private var sectionEndObserver: Any?
    @State private var isPlayingSection = false
    @State private var videoPeople: [VideoPersonRecord] = []
    @State private var loudness: [Double] = []
    // Framing mode: pinned hints plus the live computed suggestion for the
    // paused frame — dragging either pins a hard hint at that moment.
    @State private var framingHints: [CameraHint] = []
    @State private var suggestionCrop: CGRect?
    @State private var suggestionDraft: CGRect?
    @State private var focusPortraits: [Data] = []
    @State private var avoidPortraits: [Data] = []

    /// One distinct color per marker, cycling a fixed palette.
    private static let markerColors: [Color] = [.yellow, .green, .cyan, .orange,
                                                .pink, .purple, .red, .mint]

    private var video: VideoRecord {
        videos[min(selectedIndex, videos.count - 1)]
    }

    private func markerColor(_ marker: PersonMarker) -> Color {
        if marker.ignored { return .gray }
        let index = markers.firstIndex(where: { $0.id == marker.id }) ?? 0
        return Self.markerColors[index % Self.markerColors.count]
    }

    private func markerPersonName(_ marker: PersonMarker) -> String? {
        if marker.ignored { return "Ignored" }
        return marker.personID.flatMap { id in store.people.first { $0.id == id }?.displayName }
    }

    /// Markers anchored near the current playback moment — the ones drawn
    /// over the video and editable right now.
    private var visibleMarkers: [PersonMarker] {
        markers.filter { abs($0.atTime - currentTime) < 0.5 }
    }

    private var modeCaption: String {
        switch mode {
        case .people:
            "Scrub the video, pause on someone, and box them with Add Person — name them (or mark them Ignored). These identities are ground truth for detection and tagging."
        case .tags:
            "Pause anywhere and describe what matters at that moment — each note is anchored to the paused timestamp and guides this video's analysis. Notes stay on the video until you delete them."
        case .framing:
            "Pause anywhere — the rectangle shows the 9:16 framing Center Stage would pick for that frame. Drag or resize it to pin the framing there; pins are hard hints the framing pass obeys exactly."
        }
    }

    /// Normalized width per unit height that keeps a crop 9:16 in pixels.
    private var widthPerHeight: Double {
        (9.0 / 16.0) * Double(max(1, video.height)) / Double(max(1, video.width))
    }

    /// Suggestion recompute key: paused moment (rounded), hint edits, video.
    private var suggestionKey: String {
        "\(video.id)|\((currentTime * 2).rounded())|\(framingHints.count)|\(mode == .framing)"
    }

    // MARK: - People roster (people-only pass)

    /// Everyone the people pass found in this video. People mode shows the
    /// roster with a run/re-run button; tags mode turns the avatars into
    /// check toggles feeding the "everyone must be present" scene filter.
    @ViewBuilder
    private var peopleRoster: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("People in this video")
                    .font(.caption.weight(.medium))
                Spacer()
                if mode == .people, store.isDetectingPeople {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if videoPeople.isEmpty {
                Text(mode == .people
                     ? "Run Detect on the left to build this video's roster."
                     : "No roster yet — run detection on the People Detection tab first.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(videoPeople) { entry in
                            personChip(entry)
                        }
                    }
                    .padding(.vertical, 2)
                }
                if mode == .tags {
                    Toggle("Only keep scenes where every checked person is present (>50% of their body visible)",
                           isOn: $requirePeople)
                        .font(.caption)
                        .disabled(selectedPeopleKeys.isEmpty)
                        .help("A hard filter for this run: the analysis omits every time range where any checked person is absent or mostly hidden")
                }
            }
        }
    }

    private func personChip(_ entry: VideoPersonRecord) -> some View {
        let isSelected = mode == .tags && selectedPeopleKeys.contains(entry.key)
        return Button {
            guard mode == .tags else { return }
            if isSelected {
                selectedPeopleKeys.remove(entry.key)
            } else {
                selectedPeopleKeys.insert(entry.key)
            }
        } label: {
            VStack(spacing: 3) {
                VideoPersonAvatar(record: entry, videoURL: video.url, size: 44)
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
                Text(entry.displayName)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .frame(width: 58)
        }
        .buttonStyle(.plain)
        .help(entry.descriptor.isEmpty ? entry.displayName : "\(entry.displayName) — \(entry.descriptor)")
    }

    // MARK: - Section trim playback

    /// Dragging a trim handle parks the player on that anchor's frame. A
    /// small tolerance keeps mid-drag seeks cheap (near-keyframe) — exact
    /// seeks per drag tick stutter on long-GOP sources.
    private func scrub(to time: Double) {
        guard let player else { return }
        if isPlayingSection {
            stopSectionPlayback()
        } else {
            player.pause()
        }
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                    toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    /// Play exactly [trimStart, trimEnd] in the panel's player, stopping on
    /// the end boundary.
    private func playSection() {
        guard let player, trimEnd > trimStart else { return }
        stopSectionPlayback()
        sectionEndObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: trimEnd, preferredTimescale: 600))],
            queue: .main) {
            Task { @MainActor in stopSectionPlayback() }
        }
        player.seek(to: CMTime(seconds: trimStart, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            player.play()
        }
        isPlayingSection = true
    }

    private func stopSectionPlayback() {
        if let sectionEndObserver, let player {
            player.removeTimeObserver(sectionEndObserver)
        }
        sectionEndObserver = nil
        if isPlayingSection {
            player?.pause()
            isPlayingSection = false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mode == .people ? "Who is who" : "Video notes")
                .font(.headline)
            Text(modeCaption)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(video.filename)
                .font(.caption.weight(.medium))
                .lineLimit(1)

            PlayerView(player: player)
                .frame(maxWidth: .infinity)
                .frame(height: 380)
                .background(.black, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    // Identity boxes near the current moment, drawn in the
                    // video's letterboxed display rect and editable in place.
                    if mode == .people {
                        GeometryReader { geo in
                            let videoRect = AVMakeRect(
                                aspectRatio: CGSize(width: max(1, video.width), height: max(1, video.height)),
                                insideRect: CGRect(origin: .zero, size: geo.size))
                            ForEach(visibleMarkers) { marker in
                                PersonMarkerBox(marker: marker,
                                                color: markerColor(marker),
                                                name: markerPersonName(marker),
                                                videoRect: videoRect) { updated in
                                    if let index = markers.firstIndex(where: { $0.id == updated.id }) {
                                        markers[index] = updated
                                    }
                                } onCommit: { updated in
                                    Task { markers = await store.updatePersonMarker(updated) }
                                }
                            }
                        }
                    }
                    // The framing rectangle at the paused moment: a nearby
                    // pinned hint (editable) or the live suggestion — drag
                    // either to pin the framing as a hard hint.
                    if mode == .framing {
                        GeometryReader { geo in
                            let videoRect = AVMakeRect(
                                aspectRatio: CGSize(width: max(1, video.width), height: max(1, video.height)),
                                insideRect: CGRect(origin: .zero, size: geo.size))
                            if let hint = framingHints.first(where: { abs($0.atTime - currentTime) < 0.5 }) {
                                CameraFrameBox(rect: CGRect(x: hint.x, y: hint.y,
                                                            width: hint.width, height: hint.height),
                                               color: .orange, label: "Pinned framing",
                                               videoRect: videoRect,
                                               widthPerHeight: widthPerHeight) { updated in
                                    if let index = framingHints.firstIndex(where: { $0.id == hint.id }) {
                                        framingHints[index].x = updated.minX
                                        framingHints[index].y = updated.minY
                                        framingHints[index].width = updated.width
                                        framingHints[index].height = updated.height
                                    }
                                } onCommit: { updated in
                                    var changed = hint
                                    changed.x = updated.minX
                                    changed.y = updated.minY
                                    changed.width = updated.width
                                    changed.height = updated.height
                                    Task { framingHints = await store.updateCameraHint(changed) }
                                }
                            } else if let crop = suggestionDraft ?? suggestionCrop {
                                CameraFrameBox(rect: crop, color: .cyan,
                                               label: "Framing — drag to pin",
                                               videoRect: videoRect,
                                               widthPerHeight: widthPerHeight) { updated in
                                    suggestionDraft = updated
                                } onCommit: { updated in
                                    let time = currentTime
                                    suggestionDraft = nil
                                    Task {
                                        framingHints = await store.addCameraHint(videoID: video.id,
                                                                                 at: time, rect: updated)
                                    }
                                }
                            }
                        }
                    }
                }

            if mode == .tags {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Section to analyze")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Button {
                            if isPlayingSection {
                                stopSectionPlayback()
                            } else {
                                playSection()
                            }
                        } label: {
                            Label(isPlayingSection ? "Stop" : "Play Section",
                                  systemImage: isPlayingSection ? "stop.fill" : "play.fill")
                        }
                        .controlSize(.small)
                        .help("Play just the selected section in the player above")
                    }
                    VideoTrimSlider(url: video.url, duration: video.duration,
                                    start: $trimStart, end: $trimEnd,
                                    loudness: loudness) { time in
                        scrub(to: time)
                    }
                }
                .onAppear {
                    if trimEnd <= trimStart {
                        trimStart = 0
                        trimEnd = video.duration
                    }
                }
                .task(id: "\(video.id)|loudness") {
                    guard loudness.isEmpty else { return }
                    loudness = await Analyzer.loudnessCurve(url: video.url)
                }
            }

            peopleRoster

            if mode == .people {
                Text(visibleMarkers.isEmpty && !markers.isEmpty
                     ? "\(markers.count) marker(s) on this video — use the list on the left to jump to one."
                     : "Drag a box around one person; resize from the corner dot. Add and manage markers on the left.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if mode == .tags {
                HStack {
                    TextField("Note for the current moment…", text: $noteText)
                        .onSubmit(addNote)
                    Button("Add", action: addNote)
                        .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Pauses the video and saves the note anchored at the current playback time")
                }
            }

            if mode == .framing {
                if framingHints.isEmpty {
                    Text("No pinned framings yet — pause and drag the rectangle to pin one.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(framingHints) { hint in
                                HStack(spacing: 6) {
                                    Button {
                                        player?.seek(to: CMTime(seconds: hint.atTime,
                                                                preferredTimescale: 600))
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "camera.viewfinder")
                                                .foregroundStyle(.orange)
                                            Text(hint.atTime.timecode)
                                                .font(.caption.monospacedDigit())
                                            Spacer(minLength: 0)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Jump the player to this pinned framing")
                                    Button {
                                        Task { framingHints = await store.deleteCameraHint(hint) }
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
            } else if mode == .people {
                EmptyView()
            } else if notes.isEmpty {
                Text("No notes for this video yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(notes) { note in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                // The whole row is the seek target; only the
                                // trash can is a separate control.
                                Button {
                                    player?.seek(to: CMTime(seconds: note.atTime,
                                                            preferredTimescale: 600))
                                } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(note.atTime.timecode)
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.tint)
                                        Text(note.note)
                                            .font(.caption)
                                            .multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                                .help("Jump the player to this note's moment")
                                Button {
                                    Task { notes = await store.deleteVideoNote(note) }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .task(id: video.id) {
            if let timeObserver, let player {
                player.removeTimeObserver(timeObserver)
                self.timeObserver = nil
            }
            stopSectionPlayback()
            player?.pause()
            let newPlayer = AVPlayer(url: video.url)
            player = newPlayer
            currentTime = 0
            timeObserver = newPlayer.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
                queue: .main) { time in
                Task { @MainActor in currentTime = time.seconds }
            }
            notes = await store.videoNotes(for: video.id)
            markers = await store.personMarkers(for: video.id)
            videoPeople = await store.videoPeople(for: video.id)
            selectedPeopleKeys = []
            loudness = []
            framingHints = await store.centerStageHints(for: video.id)
            await reloadFramingPortraits()
        }
        // Live framing suggestion for the paused frame — same tracker the
        // pass uses, so what's shown is what a run would pick.
        .task(id: suggestionKey) {
            suggestionDraft = nil
            guard mode == .framing, (player?.rate ?? 0) == 0 else {
                suggestionCrop = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            suggestionCrop = await CenterStageService.stillFrameCrop(
                source: video.url, at: currentTime,
                focusPortraits: focusPortraits,
                avoidPortraits: avoidPortraits)
        }
        // The People tab's detect run rebuilt the roster — pick it up when
        // switching to the Tags tab.
        .task(id: mode == .tags) {
            videoPeople = await store.videoPeople(for: video.id)
        }
        // A detect run kicked off from the sheet's People column finished —
        // refresh this video's roster.
        .onChange(of: store.isDetectingPeople) { _, running in
            if !running {
                Task { videoPeople = await store.videoPeople(for: video.id) }
            }
        }
        .onDisappear {
            if let timeObserver, let player {
                player.removeTimeObserver(timeObserver)
                self.timeObserver = nil
            }
            stopSectionPlayback()
            player?.pause()
        }
    }

    private func addNote() {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let player else { return }
        player.pause()
        let seconds = player.currentTime().seconds
        let atTime = seconds.isFinite ? max(0, (seconds * 10).rounded() / 10) : 0
        noteText = ""
        Task { notes = await store.addVideoNote(videoID: video.id, at: atTime, text: text) }
    }

    /// Person-marker portraits make the framing suggestion identity-aware —
    /// the rectangle frames the named people, never referees or staff.
    private func reloadFramingPortraits() async {
        let markers = await store.personMarkers(for: video.id)
        let named = markers.filter { $0.personID != nil && !$0.ignored }
        let ignored = markers.filter(\.ignored)
        focusPortraits = named.isEmpty ? []
            : await Analyzer.markerPortraits(url: video.url, markers: named,
                                             duration: video.duration)
        avoidPortraits = ignored.isEmpty ? []
            : await Analyzer.markerPortraits(url: video.url, markers: ignored,
                                             duration: video.duration)
    }
}

/// One editable identity box over the video: drag the body to move, drag the
/// bottom-right dot to resize. Coordinates stay normalized to the video's
/// display rect, so they survive any player size.
/// Round avatar for a roster entry, cropped from the portrait box the
/// people pass picked for them. Falls back to initials.
struct VideoPersonAvatar: View {
    let record: VideoPersonRecord
    let videoURL: URL
    var size: CGFloat = 44

    @State private var image: NSImage?
    @State private var loadedID: Int64?

    private var initials: String {
        record.displayName.split(separator: " ").prefix(2)
            .compactMap(\.first).map(String.init).joined()
    }

    var body: some View {
        ZStack {
            if let image {
                Color.clear
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
            } else {
                Circle()
                    .fill(.quaternary)
                Text(initials.isEmpty ? "?" : initials)
                    .font(.system(size: size * 0.36, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: record.personID) {
            guard loadedID != record.personID else { return }
            loadedID = record.personID
            image = nil
            guard let box = record.portraitBox,
                  let frame = await ThumbnailService.jpegFrame(url: videoURL,
                                                               at: record.portraitAt,
                                                               maxDimension: 720) else { return }
            let marker = PersonMarker(id: 0, videoID: record.videoID,
                                      atTime: record.portraitAt,
                                      x: box.x, y: box.y, width: box.w, height: box.h)
            if let portrait = Analyzer.markerPortrait(from: frame, marker: marker),
               let cropped = NSImage(data: portrait) {
                image = cropped
            }
        }
    }
}

/// Draggable, corner-resizable camera-framing rectangle over the video
/// (9:16 locked): shows where Center Stage points at this moment; adjusting
/// it pins the framing as a hard hint.
struct CameraFrameBox: View {
    var rect: CGRect          // normalized top-left display coords
    let color: Color
    let label: String
    let videoRect: CGRect
    /// Normalized width per unit height that keeps the crop 9:16 in pixels.
    let widthPerHeight: Double
    let onChange: (CGRect) -> Void
    let onCommit: (CGRect) -> Void

    /// Rect at gesture start — deltas apply against this.
    @State private var gestureStart: CGRect?

    private var boxRect: CGRect {
        CGRect(x: videoRect.minX + rect.minX * videoRect.width,
               y: videoRect.minY + rect.minY * videoRect.height,
               width: rect.width * videoRect.width,
               height: rect.height * videoRect.height)
    }

    var body: some View {
        let box = boxRect
        ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .strokeBorder(color, lineWidth: 3)
                .background(color.opacity(0.22))
                .contentShape(Rectangle())
                .gesture(moveGesture)
            Circle()
                .fill(color)
                .frame(width: 13, height: 13)
                .contentShape(Circle().inset(by: -8))
                .gesture(resizeGesture)
                .offset(x: 5, y: 5)
        }
        .overlay(alignment: .topLeading) {
            Text(label)
                .font(.caption2.bold())
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(color, in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.black)
                .offset(y: -16)
        }
        .frame(width: box.width, height: box.height)
        .position(x: box.midX, y: box.midY)
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                let start = gestureStart ?? rect
                gestureStart = start
                var updated = start
                updated.origin.x = min(max(0, start.minX + value.translation.width / videoRect.width),
                                       1 - start.width)
                updated.origin.y = min(max(0, start.minY + value.translation.height / videoRect.height),
                                       1 - start.height)
                onChange(updated)
            }
            .onEnded { _ in
                gestureStart = nil
                onCommit(rect)
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                let start = gestureStart ?? rect
                gestureStart = start
                // Corner resize, 9:16 locked: height drives width.
                let maxHeight = min(1.0, 1.0 / max(0.0001, widthPerHeight))
                let height = min(max(0.12, start.height + value.translation.height / videoRect.height),
                                 maxHeight)
                let width = height * widthPerHeight
                var updated = CGRect(x: start.minX, y: start.minY, width: width, height: height)
                updated.origin.x = min(max(0, updated.minX), 1 - width)
                updated.origin.y = min(max(0, updated.minY), 1 - height)
                onChange(updated)
            }
            .onEnded { _ in
                gestureStart = nil
                onCommit(rect)
            }
    }
}

private struct PersonMarkerBox: View {
    let marker: PersonMarker
    let color: Color
    let name: String?
    let videoRect: CGRect
    let onChange: (PersonMarker) -> Void
    let onCommit: (PersonMarker) -> Void

    /// Marker state at gesture start — deltas apply against this.
    @State private var gestureStart: PersonMarker?

    private var boxRect: CGRect {
        CGRect(x: videoRect.minX + marker.x * videoRect.width,
               y: videoRect.minY + marker.y * videoRect.height,
               width: marker.width * videoRect.width,
               height: marker.height * videoRect.height)
    }

    var body: some View {
        let rect = boxRect
        ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .strokeBorder(color, lineWidth: 2.5)
                .background(color.opacity(0.12))
                .contentShape(Rectangle())
                .gesture(moveGesture)
            Circle()
                .fill(color)
                .frame(width: 13, height: 13)
                .contentShape(Circle().inset(by: -8))
                .gesture(resizeGesture)
                .offset(x: 5, y: 5)
        }
        .overlay(alignment: .topLeading) {
            Text(name ?? "who?")
                .font(.caption2.bold())
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(color, in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.black)
                .offset(y: -16)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                let start = gestureStart ?? marker
                gestureStart = start
                var updated = start
                updated.x = min(max(0, start.x + value.translation.width / videoRect.width),
                                1 - start.width)
                updated.y = min(max(0, start.y + value.translation.height / videoRect.height),
                                1 - start.height)
                onChange(updated)
            }
            .onEnded { _ in
                gestureStart = nil
                onCommit(marker)
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                let start = gestureStart ?? marker
                gestureStart = start
                var updated = start
                updated.width = min(max(0.04, start.width + value.translation.width / videoRect.width),
                                    1 - start.x)
                updated.height = min(max(0.04, start.height + value.translation.height / videoRect.height),
                                     1 - start.y)
                onChange(updated)
            }
            .onEnded { _ in
                gestureStart = nil
                onCommit(marker)
            }
    }
}

/// iPhone-Photos-style trim scrubber: a thumbnail filmstrip with draggable
/// start/end handles bounding the section to analyze. Dragging the middle
/// slides the whole selection; `onScrub` reports the anchor being dragged
/// so a player can follow it. Times ride under the strip and update live.
struct VideoTrimSlider: View {
    let url: URL
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    /// Per-second crowd loudness (dB) — drawn as a sparkline so the loud
    /// moments are findable while trimming. Empty = no sparkline.
    var loudness: [Double] = []
    var onScrub: ((Double) -> Void)?

    /// Selection start + span captured when a middle drag begins.
    @State private var moveAnchor: (start: Double, span: Double)?

    private static let handleWidth: CGFloat = 14
    private static let stripHeight: CGFloat = 44
    private static let minimumSpan = 1.0
    private static let thumbnailCount = 8
    /// Gestures measure in this fixed strip space — measuring in the moving
    /// handles' own space feeds the drag back into itself and jitters.
    private static let stripSpace = "videoTrimStrip"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let startX = x(for: start, width: width)
                let endX = x(for: end, width: width)
                ZStack(alignment: .topLeading) {
                    filmstrip(width: width)
                    // Dim what's outside the selection.
                    Rectangle()
                        .fill(.black.opacity(0.55))
                        .frame(width: max(0, startX), height: Self.stripHeight)
                    Rectangle()
                        .fill(.black.opacity(0.55))
                        .frame(width: max(0, width - endX), height: Self.stripHeight)
                        .offset(x: endX)
                    // Selection frame.
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(.yellow, lineWidth: 3)
                        .frame(width: max(endX - startX, Self.handleWidth * 2),
                               height: Self.stripHeight)
                        .offset(x: startX)
                        .allowsHitTesting(false)
                    // Middle drag: slide the whole selection, span unchanged.
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .frame(width: max(0, endX - startX - Self.handleWidth * 2),
                               height: Self.stripHeight)
                        .offset(x: startX + Self.handleWidth)
                        .gesture(DragGesture(coordinateSpace: .named(Self.stripSpace))
                            .onChanged { value in
                                let anchor = moveAnchor ?? (start, end - start)
                                moveAnchor = anchor
                                let shift = duration > 0 && width > 0
                                    ? Double(value.translation.width / width) * duration : 0
                                let newStart = min(max(0, anchor.start + shift),
                                                   max(0, duration - anchor.span))
                                start = newStart
                                end = newStart + anchor.span
                                onScrub?(newStart)
                            }
                            .onEnded { _ in moveAnchor = nil })
                    handle(icon: "chevron.compact.left")
                        .offset(x: startX)
                        .gesture(DragGesture(minimumDistance: 0,
                                             coordinateSpace: .named(Self.stripSpace))
                            .onChanged { value in
                                let t = time(forX: value.location.x, width: width)
                                start = min(max(0, t), end - Self.minimumSpan)
                                onScrub?(start)
                            })
                    handle(icon: "chevron.compact.right")
                        .offset(x: endX - Self.handleWidth)
                        .gesture(DragGesture(minimumDistance: 0,
                                             coordinateSpace: .named(Self.stripSpace))
                            .onChanged { value in
                                let t = time(forX: value.location.x, width: width)
                                end = max(min(duration, t), start + Self.minimumSpan)
                                onScrub?(end)
                            })
                }
                .coordinateSpace(name: Self.stripSpace)
            }
            .frame(height: Self.stripHeight)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            if loudness.count > 4 {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    let sorted = loudness.sorted()
                    let low = sorted[sorted.count / 2]
                    let high = max(sorted.last ?? low + 6, low + 6)
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 12))
                        for (index, value) in loudness.enumerated() {
                            let x = width * CGFloat(index) / CGFloat(max(1, loudness.count - 1))
                            let normalized = max(0, min(1, (value - low) / (high - low)))
                            path.addLine(to: CGPoint(x: x, y: 12 * (1 - CGFloat(normalized))))
                        }
                    }
                    .stroke(.orange.opacity(0.8), lineWidth: 1)
                }
                .frame(height: 12)
                .help("Crowd loudness — the spikes are where the arena reacted")
            }
            HStack {
                Text(start.timecode)
                Spacer()
                Text(String(format: "%.1fs selected", max(0, end - start)))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(end.timecode)
            }
            .font(.caption.monospacedDigit())
        }
    }

    private func x(for time: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(0, time / duration), 1)) * width
    }

    private func time(forX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(0, x / width), 1)) * duration
    }

    private func filmstrip(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<Self.thumbnailCount, id: \.self) { index in
                VideoThumbnail(url: url,
                               time: duration * (Double(index) + 0.5) / Double(Self.thumbnailCount),
                               cornerRadius: 0)
                    .frame(width: width / CGFloat(Self.thumbnailCount),
                           height: Self.stripHeight)
                    .clipped()
            }
        }
    }

    private func handle(icon: String) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: icon.hasSuffix("left") ? 4 : 0,
                               bottomLeadingRadius: icon.hasSuffix("left") ? 4 : 0,
                               bottomTrailingRadius: icon.hasSuffix("left") ? 0 : 4,
                               topTrailingRadius: icon.hasSuffix("left") ? 0 : 4)
            .fill(.yellow)
            .frame(width: Self.handleWidth, height: Self.stripHeight)
            .overlay {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black)
            }
            .contentShape(Rectangle().inset(by: -8))
    }
}
