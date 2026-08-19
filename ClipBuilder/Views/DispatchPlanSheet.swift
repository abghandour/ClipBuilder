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
    @AppStorage("analysis.includeTranscript") private var includeTranscript = false
    // One engine today; persisted so future engines slot in without a rekey.
    @AppStorage("analysis.transcribeEngine") private var transcribeEngine = "apple"
    @State private var transcriptionLocales: [Locale] = []
    @State private var savedPrompts: [SavedPrompt] = []
    @State private var showSavePrompt = false
    @State private var savePromptName = ""
    @State private var showManagePrompts = false

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
                VideoNotesPanel(videos: videos)
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
                    Toggle("Detect people (build the People registry)", isOn: $detectPeople)
                        .help("Identify each distinct person, tag their scenes, and keep their identity across videos — see the People section")
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
                   + (operation == .analyze ? (includeTranscript ? 176 : 88) : 0))

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

    @State private var selectedIndex = 0
    @State private var notes: [VideoNote] = []
    @State private var noteText = ""
    @State private var player: AVPlayer?
    @State private var markers: [PersonMarker] = []
    @State private var currentTime = 0.0
    @State private var timeObserver: Any?
    @State private var pendingNewPersonMarker: PersonMarker?
    @State private var newPersonName = ""

    /// One distinct color per marker, cycling a fixed palette.
    private static let markerColors: [Color] = [.yellow, .green, .cyan, .orange,
                                                .pink, .purple, .red, .mint]

    private var video: VideoRecord {
        videos[min(selectedIndex, videos.count - 1)]
    }

    private func markerColor(_ marker: PersonMarker) -> Color {
        let index = markers.firstIndex(where: { $0.id == marker.id }) ?? 0
        return Self.markerColors[index % Self.markerColors.count]
    }

    private func markerPersonName(_ marker: PersonMarker) -> String? {
        marker.personID.flatMap { id in store.people.first { $0.id == id }?.displayName }
    }

    /// Markers anchored near the current playback moment — the ones drawn
    /// over the video and editable right now.
    private var visibleMarkers: [PersonMarker] {
        markers.filter { abs($0.atTime - currentTime) < 0.5 }
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
                    }
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
        }
        .onDisappear {
            if let timeObserver, let player {
                player.removeTimeObserver(timeObserver)
                self.timeObserver = nil
            }
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
                        Task { markers = await store.updatePersonMarker(updated) }
                    }
                }
                if !store.people.isEmpty { Divider() }
                Button("New Person…") {
                    pendingNewPersonMarker = marker
                }
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
