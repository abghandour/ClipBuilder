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

    // Analysis-only options; persisted so muted runs keep the last values.
    @AppStorage("analysis.instructions") private var instructions = ""
    @AppStorage("analysis.sampleInterval") private var sampleInterval = 0.0   // 0 = automatic
    @AppStorage("analysis.detectPeople") private var detectPeople = true
    @AppStorage("analysis.portraitOnly") private var portraitOnly = false
    @AppStorage("analysis.autoBreakdown") private var autoBreakdown = false
    @AppStorage("analysis.centerStagePaths") private var centerStagePaths = false
    /// Camera preset the stored paths are computed with: "smooth",
    /// "balanced", or "fast" — same values as the Wizard's Center Stage.
    @AppStorage("analysis.centerStageCamera") private var centerStageCamera = "balanced"
    /// Comma-joined tags whose scenes get the breakdown pass — AppStorage
    /// can't hold a Set directly.
    @AppStorage("analysis.breakdownTags") private var breakdownTagsRaw = ""
    @AppStorage("analysis.includeTranscript") private var includeTranscript = false
    // One engine today; persisted so future engines slot in without a rekey.
    @AppStorage("analysis.transcribeEngine") private var transcribeEngine = "apple"
    @State private var transcriptionLocales: [Locale] = []
    @State private var savedPrompts: [SavedPrompt] = []
    @State private var showSavePrompt = false
    @State private var showManagePrompts = false
    @State private var savePromptName = ""
    // Per-run trim (single video only) — deliberately NOT persisted: a
    // leftover range must never silently apply to another video.
    @State private var trimEnabled = false
    @State private var trimStart = 0.0
    @State private var trimEnd = 0.0
    // Roster selection (single video only) — also per-run, like the trim:
    // checked people can become a hard "must all be present" scene filter.
    @State private var selectedPeopleKeys: Set<String> = []
    @State private var requirePeople = false

    private static let samplingChoices: [(label: String, value: Double)] = [
        ("Automatic (1–3s by length)", 0),
        ("Every 0.5s", 0.5), ("Every 1s", 1), ("Every 2s", 2),
        ("Every 3s", 3), ("Every 5s", 5), ("Every 10s", 10),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            planColumn
                .frame(width: 460)
            if showsNotesPanel {
                Divider()
                VideoNotesPanel(videos: videos,
                                trimEnabled: $trimEnabled,
                                trimStart: $trimStart, trimEnd: $trimEnd,
                                selectedPeopleKeys: $selectedPeopleKeys,
                                requirePeople: $requirePeople)
                    .frame(width: 520)
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
                    Picker("Frame sampling", selection: $sampleInterval) {
                        ForEach(Self.samplingChoices, id: \.value) { choice in
                            Text(choice.label).tag(choice.value)
                        }
                    }
                    .help("How often a frame is sent to the model. Denser sampling catches short moments but costs more (capped at 60 frames).")
                    if videos.count == 1 {
                        Toggle("Analyze only a section", isOn: $trimEnabled)
                            .help("Restrict this run to a time range: frames are sampled and scenes detected only inside it. The section selector appears under the video preview on the right. Applies to this run only — it is not remembered.")
                    }
                    Toggle("Detect people (build the People registry)", isOn: $detectPeople)
                        .help("Identify each distinct person, tag their scenes, and keep their identity across videos — see the People section")
                    Toggle("Only keep scenes that crop to 9:16 with people in frame", isOn: $portraitOnly)
                        .help("After tagging, each scene is checked locally (no AI cost): scenes whose people are spread too wide for a full-height 9:16 crop — or with nobody visible — are auto-hidden. Bring them back anytime with Show Hidden on the Scenes screen.")
                    Toggle("Break down tagged scenes into sub-scenes", isOn: $autoBreakdown)
                        .help("Scenes carrying one of the tags picked below get a second, frame-dense AI pass that splits them into their individual actions — each combo or exchange becomes its own scene. Costs one extra AI call per broken-down scene.")
                    if autoBreakdown {
                        breakdownTagRows
                    }
                    Toggle("Compute Center Stage camera paths", isOn: $centerStagePaths)
                        .help("Tracks the people in each wide scene locally (no AI cost) and stores the virtual camera's pan/zoom path. Scene previews then play the real moving crop, and generation reuses the path instead of re-tracking. With this on, the video preview also shows the camera's framing for the paused moment — drag or resize that rectangle to pin your preferred framing as a hard hint. Adds local processing time per scene.")
                    if centerStagePaths {
                        Picker("Camera", selection: $centerStageCamera) {
                            Text("Smooth").tag("smooth")
                            Text("Balanced").tag("balanced")
                            Text("Fast action").tag("fast")
                        }
                        .pickerStyle(.segmented)
                        .help("How eagerly the tracking camera chases the people — the same presets as the Wizard's Center Stage. Generation reuses a stored path only when its preset matches.")
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
                      ? (includeTranscript ? 308 : 220) + (autoBreakdown ? 160 : 0)
                        + (centerStagePaths ? 44 : 0)
                        + (videos.count == 1 ? 44 : 0)
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
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                    Button("Start") { start() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
    }

    /// The trim range to hand to the run; nil when trimming is off or the
    /// handles still span the whole video (= no trim).
    private var trimRange: (start: Double, end: Double)? {
        guard trimEnabled, videos.count == 1, let video = videos.first,
              trimEnd > trimStart else { return nil }
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

    /// First recommended chain entry whose CLI is installed, else the
    /// task default provider with its default model.
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
        let recommended = recommendedTag(for: task)
        var result: [(String, String)] = []
        for provider in AICatalog.providers {
            let installed = availableProviders.contains(provider.key)
            for model in provider.models {
                let tag = "\(provider.key)|\(model)"
                var label = "\(provider.label) — \(model)"
                if tag == recommended { label += "  ★ recommended" }
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
    @Environment(AppStore.self) private var store
    let videos: [VideoRecord]
    /// "Analyze only a section": the trim selector renders under the video
    /// so scrubbing it drives this panel's player.
    @Binding var trimEnabled: Bool
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    /// Roster checks + the "everyone checked must be in every scene" flag.
    @Binding var selectedPeopleKeys: Set<String>
    @Binding var requirePeople: Bool

    @State private var selectedIndex = 0
    @State private var notes: [VideoNote] = []
    @State private var noteText = ""
    @State private var player: AVPlayer?
    @State private var markers: [PersonMarker] = []
    @State private var currentTime = 0.0
    @State private var timeObserver: Any?
    @State private var sectionEndObserver: Any?
    @State private var isPlayingSection = false
    @State private var pendingNewPersonMarker: PersonMarker?
    @State private var newPersonName = ""
    // Center Stage framing: the computed crop for the paused frame, shown
    // as an adjustable rectangle; adjusting pins a hard camera hint.
    @AppStorage("analysis.centerStagePaths") private var centerStagePaths = false
    @AppStorage("analysis.centerStageCamera") private var centerStageCamera = "balanced"
    @State private var hints: [CameraHint] = []
    @State private var suggestionCrop: CGRect?
    @State private var suggestionDraft: CGRect?
    @State private var focusPortraits: [Data] = []
    @State private var avoidPortraits: [Data] = []
    // The real camera path for the trimmed section, computed on Play
    // Section and animated over the playing video. Cached per section.
    @State private var sectionPath: [CameraPathKeyframe]?
    @State private var sectionPathKey = ""
    @State private var isComputingSectionPath = false
    @State private var videoPeople: [VideoPersonRecord] = []

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

    /// Recompute the framing suggestion when the paused moment (rounded to
    /// half-seconds), the video, the hint set, or the marker roster changes.
    private var suggestionKey: String {
        "\(video.id)|\(centerStagePaths)|\((currentTime * 2).rounded())|\(hints.count)"
            + "|\(markers.filter(\.ignored).count)|\(markers.count(where: { $0.personID != nil }))"
    }

    /// Positive (named) and negative (ignored) identity references for the
    /// framing suggestion, from this video's markers.
    private func reloadPortraits() async {
        let named = markers.filter { $0.personID != nil && !$0.ignored }
        let ignored = markers.filter(\.ignored)
        focusPortraits = named.isEmpty ? []
            : await Analyzer.markerPortraits(url: video.url, markers: named,
                                             duration: video.duration)
        avoidPortraits = ignored.isEmpty ? []
            : await Analyzer.markerPortraits(url: video.url, markers: ignored,
                                             duration: video.duration)
    }

    // MARK: - People roster (people-only pass)

    /// Everyone the people pass found in this video: avatars with check
    /// toggles, a run/re-run button, and the "everyone must be present"
    /// scene filter for the checked set.
    @ViewBuilder
    private var peopleRoster: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("People in this video")
                    .font(.caption.weight(.medium))
                Spacer()
                if store.isDetectingPeople {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(videoPeople.isEmpty ? "Detect People" : "Re-run") {
                    Task { videoPeople = await store.detectPeopleInVideo(video) }
                }
                .controlSize(.small)
                .disabled(store.isDetectingPeople)
                .help("A people-only AI pass: identifies everyone in this video (honoring your markers) and builds the roster below — without running the full scene analysis")
            }
            if videoPeople.isEmpty {
                Text("Run Detect People to see everyone in this video and optionally require them in every scene.")
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
                Toggle("Only keep scenes where every checked person is present (>50% of their body visible)",
                       isOn: $requirePeople)
                    .font(.caption)
                    .disabled(selectedPeopleKeys.isEmpty)
                    .help("A hard filter for this run: the analysis omits every time range where any checked person is absent or mostly hidden")
            }
        }
    }

    private func personChip(_ entry: VideoPersonRecord) -> some View {
        let isSelected = selectedPeopleKeys.contains(entry.key)
        return Button {
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

    /// The cached section path is valid only for this exact section, camera,
    /// and marker/hint state.
    private var sectionPathCacheKey: String {
        "\(video.id)|\(trimStart)|\(trimEnd)|\(centerStageCamera)|\(markers.hashValue)|\(hints.hashValue)"
    }

    /// Run the real tracking pass for the trimmed section so the framing
    /// overlay can follow it during playback. Cached until the section, the
    /// camera preset, a marker, or a hint changes.
    private func prepareSectionPath() {
        let key = sectionPathCacheKey
        guard key != sectionPathKey || sectionPath == nil else { return }
        sectionPathKey = key
        sectionPath = nil
        isComputingSectionPath = true
        let start = trimStart
        let end = trimEnd
        let focus = focusPortraits
        let avoid = avoidPortraits
        let sectionHints = hints
            .filter { $0.atTime >= start - 0.25 && $0.atTime <= end + 0.25 }
            .map { hint in
                (time: min(max(0, hint.atTime - start), end - start),
                 crop: CGRect(x: hint.x, y: hint.y, width: hint.width, height: hint.height))
            }
        let url = video.url
        let camera = centerStageCamera
        Task {
            let centerStage = CenterStageService()
            let result = try? await centerStage.cameraPath(
                source: url, start: start, duration: end - start,
                focusPortraits: focus, avoidPortraits: avoid,
                hints: sectionHints, tuning: .named(camera))
            guard sectionPathKey == key else { return }
            sectionPath = result?.keyframes
            isComputingSectionPath = false
        }
    }

    /// Play exactly [trimStart, trimEnd] in the panel's player, stopping on
    /// the end boundary.
    private func playSection() {
        guard let player, trimEnd > trimStart else { return }
        stopSectionPlayback()
        if centerStagePaths, video.wide {
            prepareSectionPath()
        }
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
            Text("Video notes")
                .font(.headline)
            Text("Pause anywhere and describe what matters at that moment — each note is anchored to the paused timestamp and guides this video's analysis. Notes stay on the video until you delete them.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if videos.count > 1 {
                Picker("Video", selection: $selectedIndex) {
                    ForEach(videos.indices, id: \.self) { index in
                        Text(videos[index].filename).tag(index)
                    }
                }
                .labelsHidden()
            } else {
                Text(video.filename)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }

            PlayerView(player: player)
                .frame(maxWidth: .infinity)
                .frame(height: 380)
                .background(.black, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    // Identity boxes near the current moment, drawn in the
                    // video's letterboxed display rect and editable in place.
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
                        // While the section plays, the REAL camera path
                        // rides over the video: the framing rectangle moves
                        // in real time and everything outside it dims.
                        if isPlayingSection, centerStagePaths, video.wide,
                           let path = sectionPath, let player {
                            SwiftUI.TimelineView(.animation) { _ in
                                let t = player.currentTime().seconds - trimStart
                                if let crop = CenterStageService.interpolated(path, at: t) {
                                    let rect = CGRect(
                                        x: videoRect.minX + crop.x * videoRect.width,
                                        y: videoRect.minY + crop.y * videoRect.height,
                                        width: crop.w * videoRect.width,
                                        height: crop.h * videoRect.height)
                                    ZStack(alignment: .topLeading) {
                                        // Dim what the crop would discard.
                                        Path { dim in
                                            dim.addRect(videoRect)
                                            dim.addRect(rect)
                                        }
                                        .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
                                        Rectangle()
                                            .strokeBorder(.yellow, lineWidth: 3)
                                            .frame(width: rect.width, height: rect.height)
                                            .position(x: rect.midX, y: rect.midY)
                                    }
                                }
                            }
                            .allowsHitTesting(false)
                        }
                        // Center Stage framing for this paused moment: a
                        // saved hint if one is anchored nearby, else the
                        // tracker's computed crop — drag either to pin the
                        // preferred framing as a hard hint.
                        if centerStagePaths, video.wide, video.height > 0, !isPlayingSection {
                            let widthPerHeight = (9.0 / 16.0)
                                * Double(video.height) / Double(max(1, video.width))
                            if let hint = hints.first(where: { abs($0.atTime - currentTime) < 0.5 }) {
                                CameraFrameBox(rect: CGRect(x: hint.x, y: hint.y,
                                                            width: hint.width, height: hint.height),
                                               color: .orange,
                                               label: "Camera hint",
                                               videoRect: videoRect,
                                               widthPerHeight: widthPerHeight) { updated in
                                    if let index = hints.firstIndex(where: { $0.id == hint.id }) {
                                        hints[index].x = updated.minX
                                        hints[index].y = updated.minY
                                        hints[index].width = updated.width
                                        hints[index].height = updated.height
                                    }
                                } onCommit: { updated in
                                    var changed = hint
                                    changed.x = updated.minX
                                    changed.y = updated.minY
                                    changed.width = updated.width
                                    changed.height = updated.height
                                    Task { hints = await store.updateCameraHint(changed) }
                                }
                            } else if let crop = suggestionDraft ?? suggestionCrop {
                                CameraFrameBox(rect: crop,
                                               color: .cyan,
                                               label: "Center Stage — drag to pin",
                                               videoRect: videoRect,
                                               widthPerHeight: widthPerHeight) { updated in
                                    suggestionDraft = updated
                                } onCommit: { updated in
                                    let time = currentTime
                                    suggestionDraft = nil
                                    Task {
                                        hints = await store.addCameraHint(videoID: video.id,
                                                                          at: time, rect: updated)
                                    }
                                }
                            }
                        }
                    }
                }

            if trimEnabled && videos.count == 1 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Section to analyze")
                            .font(.caption.weight(.medium))
                        Spacer()
                        if isPlayingSection && centerStagePaths && isComputingSectionPath {
                            ProgressView()
                                .controlSize(.small)
                            Text("Computing Center Stage…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
                        .help(centerStagePaths
                              ? "Play just the selected section — the Center Stage framing rides over the video in real time once its tracking pass finishes"
                              : "Play just the selected section in the player above")
                    }
                    VideoTrimSlider(url: video.url, duration: video.duration,
                                    start: $trimStart, end: $trimEnd) { time in
                        scrub(to: time)
                    }
                }
                .onAppear {
                    if trimEnd <= trimStart {
                        trimStart = 0
                        trimEnd = video.duration
                    }
                }
            }

            if videos.count == 1 {
                peopleRoster
            }

            HStack {
                Button {
                    addPersonMarker()
                } label: {
                    Label("Add Person", systemImage: "person.crop.rectangle.badge.plus")
                }
                .help("Pauses the video and drops a colored box at this moment — drag and resize it around one person, then name them. Markers are ground truth for people recognition.")
                Text(visibleMarkers.isEmpty && !markers.isEmpty
                     ? "\(markers.count) marker(s) on this video — click a row to jump to one."
                     : "Drag the box around one person; resize from the corner dot.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            if !markers.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(markers) { marker in
                            markerRow(marker)
                        }
                    }
                }
                .frame(maxHeight: 96)
            }

            if centerStagePaths, !hints.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(hints) { hint in
                            HStack(spacing: 6) {
                                Button {
                                    player?.pause()
                                    player?.seek(to: CMTime(seconds: hint.atTime,
                                                            preferredTimescale: 600),
                                                 toleranceBefore: .zero, toleranceAfter: .zero)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "camera.viewfinder")
                                            .foregroundStyle(.orange)
                                        Text(hint.atTime.timecode)
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.tint)
                                        Text("Camera framing hint")
                                            .font(.caption)
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                                .help("Jump to this hint's moment to see or adjust its framing")
                                Button {
                                    Task { hints = await store.deleteCameraHint(hint) }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .frame(maxHeight: 72)
            }

            HStack {
                TextField("Note for the current moment…", text: $noteText)
                    .onSubmit(addNote)
                Button("Add", action: addNote)
                    .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Pauses the video and saves the note anchored at the current playback time")
            }

            if notes.isEmpty {
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
            hints = await store.centerStageHints(for: video.id)
            videoPeople = await store.videoPeople(for: video.id)
            selectedPeopleKeys = []
            await reloadPortraits()
        }
        .onChange(of: markers) {
            Task { await reloadPortraits() }
        }
        // The paused frame's computed Center Stage crop — debounced so
        // scrubbing doesn't spawn a Vision call per tick.
        .task(id: suggestionKey) {
            suggestionDraft = nil
            guard centerStagePaths, video.wide, (player?.rate ?? 0) == 0 else {
                suggestionCrop = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            suggestionCrop = await CenterStageService.stillFrameCrop(
                source: video.url, at: currentTime,
                focusPortraits: focusPortraits,
                avoidPortraits: avoidPortraits,
                tuning: .named(centerStageCamera))
        }
        .onDisappear {
            if let timeObserver, let player {
                player.removeTimeObserver(timeObserver)
                self.timeObserver = nil
            }
            stopSectionPlayback()
            player?.pause()
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
                            markers = await store.updatePersonMarker(marker)
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

    /// One marker: color swatch, seek-to timecode, person dropdown, delete.
    @ViewBuilder
    private func markerRow(_ marker: PersonMarker) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(markerColor(marker))
                .frame(width: 10, height: 10)
            Button {
                player?.pause()
                player?.seek(to: CMTime(seconds: marker.atTime, preferredTimescale: 600))
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
                            markers = await store.updatePersonMarker(updated)
                            if wasIgnored { store.markerIgnoreChanged(videoID: video.id) }
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
                        markers = await store.updatePersonMarker(updated)
                        store.markerIgnoreChanged(videoID: video.id)
                    }
                }
                .help("The boxed person (e.g. a referee) is never framed by Center Stage and never registered or tagged by analysis — applied to this entire video")
            }
            .controlSize(.small)
            .fixedSize()

            Spacer()

            Button {
                Task { markers = await store.deletePersonMarker(marker) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    /// Drop a fresh box at the paused moment, centered-ish so it's easy to
    /// grab and fit around a person.
    private func addPersonMarker() {
        guard let player else { return }
        player.pause()
        let seconds = player.currentTime().seconds
        let atTime = seconds.isFinite ? max(0, (seconds * 10).rounded() / 10) : 0
        Task {
            markers = await store.addPersonMarker(videoID: video.id, at: atTime,
                                                  x: 0.35, y: 0.2, width: 0.3, height: 0.55)
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
}

/// One editable identity box over the video: drag the body to move, drag the
/// bottom-right dot to resize. Coordinates stay normalized to the video's
/// display rect, so they survive any player size.
/// Round avatar for a roster entry, cropped from the portrait box the
/// people pass picked for them. Falls back to initials.
private struct VideoPersonAvatar: View {
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
private struct CameraFrameBox: View {
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
