import SwiftUI

/// The three Mini steps share the full Wizard’s saved selections and renderer.
struct MiniWizardView: View {
    @Environment(AppStore.self) private var store
    let profileName: String

    @AppStorage private var videoPath: String
    @AppStorage private var footageKind: MiniWizardFlow.FootageKind
    @AppStorage private var length: MiniWizardFlow.Length
    @FocusState private var instructionsFocused: Bool
    @State private var instructionsDirty = false
    @State private var videos: [VideoRecord] = []
    @State private var projectHasVideos = false
    @State private var podcastVideoIDs: Set<Int64> = []
    @State private var loadedProjectID: Int64?
    @State private var loadedGeneration: Int?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var reloadID = 0
    @State private var miniSettings = MiniWizardSettings()
    @State private var settingsProfile: String?
    @State private var transcriptLanguage: String?

    init(profileName: String) {
        self.profileName = profileName
        _videoPath = AppStorage(wrappedValue: "", MiniWizardMemory.key(for: .videoPath, profileName: profileName))
        _footageKind = AppStorage(wrappedValue: .highlights, MiniWizardMemory.key(for: .footageKind, profileName: profileName))
        _length = AppStorage(wrappedValue: .automatic, MiniWizardMemory.key(for: .length, profileName: profileName))
    }

    private struct SourceKey: Equatable {
        var generation: Int
        var projectID: Int64?
        var videosVersion: Int
        var scenesVersion: Int
        var reloadID: Int
    }

    private var sourceKey: SourceKey {
        SourceKey(generation: store.profileGeneration, projectID: store.activeProjectID,
                  videosVersion: store.videosVersion, scenesVersion: store.scenesVersion, reloadID: reloadID)
    }

    private var projectVideos: [VideoRecord] {
        guard loadedProjectID == store.activeProjectID, loadedGeneration == store.profileGeneration else { return [] }
        return videos
    }

    private var selectedVideo: VideoRecord? { projectVideos.first { $0.path == videoPath } }

    private var currentRun: MiniWizardRun? {
        guard let run = store.miniRun, run.projectID == store.activeProjectID,
              run.video.path == selectedVideo?.path, (run.footageKind == .qa || run.length == length),
              run.footageKind == (podcastVideoIDs.contains(run.video.id) || run.video.type == .podcast || run.video.type == .interview
                  ? footageKind : .highlights) else { return nil }
        return run
    }

    private var flow: MiniWizardFlow {
        MiniWizardFlow(video: selectedVideo,
                       hasPodcastExchangeScenes: selectedVideo.map { podcastVideoIDs.contains($0.id) } ?? false,
                       footageKind: footageKind, length: length,
                       captionsEnabled: miniSettings.captions, transcriptLanguage: transcriptLanguage,
                       hasFootage: currentRun?.hasFootage == true,
                       hasKeptFootage: (currentRun?.keptCount ?? 0) > 0,
                       requestedCard: currentRun?.requestedCard ?? .source, outputMode: miniSettings.outputMode)
    }

    private var instructions: Binding<String> {
        Binding(
            get: { store.activeProfile.profileName == profileName ? store.activeProfile.miniInstructions ?? "" : "" },
            set: { text in
                guard store.activeProfile.profileName == profileName else { return }
                store.activeProfile.miniInstructions = text.isEmpty ? nil : text
                instructionsDirty = true
            }
        )
    }

    var body: some View {
        GeometryReader { page in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spaceL) {
                    MiniCard(number: 1, title: "Source", summary: flow.summary(for: .source),
                             isOpen: !flow.isCollapsed(.source)) {
                        if flow.isCollapsed(.source) {
                            Button { store.miniRun?.requestedCard = .source } label: {
                                Text("Change source").lineLimit(1).fixedSize()
                            }
                        } else {
                            sourceControls.disabled(store.isWizardRunning)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    MiniCard(number: 2, title: "Footage",
                             summary: currentRun?.summary ?? flow.summary(for: .footage),
                             isOpen: currentRun != nil && !flow.isCollapsed(.footage)) {
                        if let run = currentRun, !flow.isCollapsed(.footage) {
                            MiniFootageCard(run: run, pageHeight: page.size.height)
                        } else if flow.canExpand(.footage) {
                            Button { store.miniRun?.requestedCard = .footage } label: {
                                Text("Review footage").lineLimit(1).fixedSize()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    MiniCard(number: 3, title: "Settings",
                        summary: flow.canExpand(.settings)
                            ? flow.settingsSummary(miniSettings.effective(for: flow,
                                introAvailable: store.bumpers.contains { $0.placements.contains(.intro) },
                                outroAvailable: store.bumpers.contains { $0.placements.contains(.outro) }))
                            : flow.summary(for: .settings),
                        isOpen: currentRun != nil && flow.openCard == .settings && settingsProfile == profileName) {
                        if let run = currentRun, flow.openCard == .settings, settingsProfile == profileName {
                            MiniSettingsCard(settings: $miniSettings, flow: flow, run: run)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(Theme.spaceXL)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .screenTitle("AI Wizard Mini")
        .task(id: sourceKey) { await loadSources() }
        .onAppear(perform: restoreAnswers)
        .onChange(of: store.profileGeneration) { _, _ in restoreAnswers() }
        .onChange(of: miniSettings) { _, value in
            guard settingsProfile == profileName, store.activeProfile.profileName == profileName else { return }
            value.remember(profileName: profileName)
        }
        .task(id: transcriptKey) { await loadTranscriptLanguage() }
        .onChange(of: store.scenesVersion) { _, _ in store.refreshMiniQASections() }
        .onChange(of: instructionsFocused) { _, focused in
            if !focused { saveInstructions() }
        }
        .onDisappear { saveInstructions() }
    }

    @ViewBuilder
    private var sourceControls: some View {
        sourceGrid
        if flow.showsFootageKind {
            MiniRow("Footage") {
                Picker("Footage", selection: $footageKind) {
                    ForEach(flow.footageKinds, id: \.self) { kind in
                        Text(kind.label).lineLimit(1).fixedSize().tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Footage")
            }
        }
        if flow.showsLength {
            MiniRow("Length") {
                Picker("Length", selection: $length) {
                    ForEach(flow.lengthOptions, id: \.self) { option in
                        Text(option.label).lineLimit(1).fixedSize().tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Length")
            }
        }
        // Only Highlights asks a model, so only Highlights has instructions
        // and a model to choose. Q&A lists the exchanges analysis found.
        let usesAI = flow.effectiveFootageKind == .highlights
        if usesAI {
            FormGroupHeader("Instructions for the AI")
            TextEditor(text: instructions)
                .font(.body)
                .frame(minHeight: 80, idealHeight: 100)
                .focused($instructionsFocused)
                .accessibilityLabel("Instructions for the AI")
                .onSubmit { saveInstructions() }
            FormCaption("Optional. Saved with this profile and shared by its projects.")
        } else {
            FormCaption("Q&A lists the question-and-answer exchanges found when this video was analyzed. No AI model runs for this step, so there is nothing to instruct or choose.")
        }
        HStack(spacing: Theme.spaceS) {
            Button {
                instructionsFocused = false
                saveInstructions()
                store.generateMiniFootage(flow: flow)
            } label: {
                Text(usesAI ? "Generate footage" : "Show Q&A exchanges").lineLimit(1).fixedSize()
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedVideo == nil || store.isWizardRunning)
            if usesAI {
                MiniModelButton(tasks: [flow.isPodcastOrInterview ? "highlights" : "wizard"])
            }
        }
    }

    @ViewBuilder
    private var sourceGrid: some View {
        if let loadError {
            FormCaption(loadError, tone: .warning)
            Button { reloadID += 1 } label: {
                Text("Reload sources").lineLimit(1).fixedSize()
            }
        } else if isLoading && projectVideos.isEmpty {
            ProgressView("Loading analyzed videos…")
        } else if projectVideos.isEmpty {
            FormCaption("No analyzed videos in this project")
            Button { store.requestedSection = .sources } label: {
                Text("Open Sources").lineLimit(1).fixedSize()
            }
            if projectHasVideos {
                FormCaption("Analyze a video first")
                Button { store.requestedSection = .analyze } label: {
                    Text("Open Analyze").lineLimit(1).fixedSize()
                }
            }
        } else {
            FormCaption("Choose one analyzed video.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: Theme.spaceM,
                                        alignment: .top)], spacing: Theme.spaceM) {
                ForEach(projectVideos) { video in
                    sourceCell(video)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sourceCell(_ video: VideoRecord) -> some View {
        let selected = selectedVideo?.id == video.id
        return Button {
            instructionsFocused = false
            videoPath = video.path
        } label: {
            VStack(alignment: .leading, spacing: Theme.spaceXS) {
                VideoThumbnail(url: video.url, time: min(1, video.duration / 2), cornerRadius: Theme.mediaRadius)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.mediaRadius)
                            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
                    }
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(Theme.spaceXS)
                        }
                    }
                Text(video.filename)
                    .font(.caption)
                    .lineLimit(1).fixedSize(horizontal: false, vertical: true)
                    .truncationMode(.middle)
                Text("\(video.type?.label ?? "Unknown type") · \(video.duration.timecode)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(video.filename), \(video.type?.label ?? "Unknown type"), \(video.duration.timecode)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("Choose \(video.filename)")
    }

    private func loadSources() async {
        let key = sourceKey
        guard let database = store.database, let projectID = key.projectID else {
            videos = []
            podcastVideoIDs = []
            projectHasVideos = false
            isLoading = false
            return
        }
        isLoading = true
        loadError = nil
        do {
            let fetchedVideos = try await database.fetchVideos(projectID: projectID)
            let scenes = try await database.fetchScenes(projectID: projectID)
            guard !Task.isCancelled, key == sourceKey, store.activeProfile.profileName == profileName else { return }
            let analyzedIDs = Set(scenes.map(\.videoID))
            videos = fetchedVideos.filter { $0.analyzedAt != nil && analyzedIDs.contains($0.id) }
            projectHasVideos = !fetchedVideos.isEmpty
            let validated = MiniWizardMemory.validatedVideoPath(videoPath, videos: videos)
            if validated != videoPath {
                if store.miniRun?.projectID == projectID, store.miniRun?.video.path == videoPath {
                    store.miniRun = nil
                }
                videoPath = validated
            }
            podcastVideoIDs = Set(scenes.filter { $0.tags.contains("podcast-exchange") }.map(\.videoID))
            loadedProjectID = projectID
            loadedGeneration = key.generation
            isLoading = false
        } catch {
            guard !Task.isCancelled, key == sourceKey, store.activeProfile.profileName == profileName else { return }
            videos = []
            podcastVideoIDs = []
            loadError = "Could not load analyzed videos: \(error.localizedDescription)"
            isLoading = false
        }
    }

    private var transcriptKey: String {
        "\(store.profileGeneration):\(selectedVideo?.id ?? -1):\(store.videosVersion):\(store.scenesVersion)"
    }

    private func loadTranscriptLanguage() async {
        transcriptLanguage = nil
        let key = transcriptKey
        guard let video = selectedVideo, let database = store.database else { return }
        // Original segments carry the language; translated English rows must not hide this choice.
        let language = try? await database.originalTranscriptLanguage(videoID: video.id)
        guard !Task.isCancelled, key == transcriptKey else { return }
        transcriptLanguage = language
    }

    private func restoreAnswers() {
        guard store.activeProfile.profileName == profileName else { return }
        // Source answers use profile-keyed AppStorage; Settings restores from the same key catalog.
        miniSettings = MiniWizardSettings.remembered(profile: store.activeProfile)
        settingsProfile = profileName
        store.refreshMiniQASections()
    }

    private func saveInstructions() {
        guard instructionsDirty, store.activeProfile.profileName == profileName else { return }
        store.saveActiveProfile()
        instructionsDirty = false
    }
}
