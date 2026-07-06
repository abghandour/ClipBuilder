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

    private var analyzedSceneCount: Int {
        store.scenes.filter { !$0.excluded && !$0.ignored }.count
    }

    var body: some View {
        HSplitView {
            configurationForm
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            logPanel
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 480, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("AI Wizard")
        .navigationSubtitle("\(analyzedSceneCount) scenes available")
    }

    private var configurationForm: some View {
        Form {
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
                    let count = WizardEngine.availableMusic().count
                    HStack {
                        Text("\(count) tracks")
                            .foregroundStyle(count == 0 ? .orange : .secondary)
                        Button("Open Folder") {
                            try? FileManager.default.createDirectory(at: WizardEngine.musicDirectory,
                                                                     withIntermediateDirectories: true)
                            NSWorkspace.shared.open(WizardEngine.musicDirectory)
                        }
                        .controlSize(.small)
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

            Section {
                Button {
                    runWizard()
                } label: {
                    Label(store.isWizardRunning ? "Generating…" : "Generate Reels",
                          systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(store.isWizardRunning || analyzedSceneCount == 0)

                if analyzedSceneCount == 0 {
                    Text("Analyze some videos first — the wizard picks from analyzed scenes.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
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
        store.runWizard(options: options)
    }

    private var logPanel: some View {
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
