import SwiftUI

/// Analyze tab: source-video inventory with analysis/transcription status,
/// batch AI tagging, and a live progress log.
struct AnalyzeView: View {
    @Environment(AppStore.self) private var store

    @State private var selection: Set<Int64> = []
    @State private var provider: String = ""
    @State private var model: String = ""
    @State private var isDropTargeted = false
    @State private var showGenerateSheet = false

    private var selectedVideos: [VideoRecord] {
        store.videos.filter { selection.contains($0.id) }
    }

    private var pendingVideos: [VideoRecord] {
        store.videos.filter { $0.visualAnalyzedAt == nil }
    }

    var body: some View {
        VSplitView {
            table
                .frame(maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
            AnalysisLogPanel()
                .frame(maxWidth: .infinity, minHeight: 120, idealHeight: 160)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Analyze")
        .navigationSubtitle("\(store.videos.count) source videos")
        .toolbar {
            ToolbarItemGroup {
                Menu("Provider: \(providerLabel)") {
                    providerMenu
                }
                Button("Analyze Selected", systemImage: "sparkles") {
                    store.analyze(videos: selectedVideos,
                                  provider: provider.isEmpty ? nil : provider,
                                  model: model.isEmpty ? nil : model)
                }
                .disabled(selection.isEmpty || store.isAnalyzing)

                Button("Analyze All Pending", systemImage: "sparkles.rectangle.stack") {
                    store.analyze(videos: pendingVideos,
                                  provider: provider.isEmpty ? nil : provider,
                                  model: model.isEmpty ? nil : model)
                }
                .disabled(pendingVideos.isEmpty || store.isAnalyzing)

                Button("Generate Sample Video", systemImage: "wand.and.stars") {
                    showGenerateSheet = true
                }
                .disabled(selection.isEmpty || store.isAnalyzing)
                .help("Describe a video to create from the selected footage — the AI Wizard is set up from your description")
            }
        }
        .sheet(isPresented: $showGenerateSheet) {
            GenerateSampleSheet(videos: selectedVideos)
        }
        // The folder watcher keeps the table current while the app runs;
        // this catches anything from before this view existed.
        .task { store.scanSourceFolder() }
    }

    private var providerLabel: String {
        provider.isEmpty ? "default" : provider
    }

    @ViewBuilder
    private var providerMenu: some View {
        Button("Use Settings Default") {
            provider = ""
            model = ""
        }
        ForEach(AICatalog.providers, id: \.key) { entry in
            Menu(entry.label) {
                ForEach(entry.models, id: \.self) { modelName in
                    Button(modelName) {
                        provider = entry.key
                        model = modelName
                    }
                }
            }
        }
    }

    private var table: some View {
        // One pass over scenes instead of an O(scenes) filter per table row.
        let sceneCounts = store.scenes.reduce(into: [Int64: Int]()) { $0[$1.videoID, default: 0] += 1 }
        return Table(store.videos, selection: $selection) {
            TableColumn("File") { video in
                HStack {
                    Image(systemName: video.wide ? "rectangle" : "rectangle.portrait")
                        .foregroundStyle(.secondary)
                    Text(video.filename)
                }
            }
            .width(min: 200, ideal: 320)

            TableColumn("Duration") { video in
                Text(video.duration.timecode)
                    .monospacedDigit()
            }
            .width(70)

            TableColumn("Size") { video in
                Text("\(video.width)×\(video.height)")
                    .foregroundStyle(.secondary)
            }
            .width(90)

            TableColumn("Analyzed") { video in
                if store.isAnalyzing && selection.contains(video.id) {
                    ProgressView()
                        .controlSize(.small)
                } else if video.visualAnalyzedAt != nil {
                    Label(video.visualAnalyzerProvider ?? "done", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .help(video.visualAnalyzerModel ?? "")
                } else {
                    Text("—")
                        .foregroundStyle(.secondary)
                }
            }
            .width(110)

            TableColumn("Transcript") { video in
                if store.transcribingVideoIDs.contains(video.id) {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.small)
                        Button {
                            store.cancelTranscription(videoID: video.id)
                        } label: {
                            Image(systemName: "stop.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Stop transcribing")
                    }
                } else if video.speechAnalyzedAt != nil || hasTranscript(video) {
                    Image(systemName: "text.quote")
                        .foregroundStyle(.green)
                } else {
                    Button("Transcribe") {
                        store.transcribe(video: video)
                    }
                    .controlSize(.small)
                }
            }
            .width(100)

            TableColumn("Scenes") { video in
                Text("\(sceneCounts[video.id] ?? 0)")
                    .foregroundStyle(.secondary)
            }
            .width(60)
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            Button("Analyze") {
                store.analyze(videos: store.videos.filter { ids.contains($0.id) })
            }
            Button("Transcribe") {
                for video in store.videos.filter({ ids.contains($0.id) }) {
                    store.transcribe(video: video)
                }
            }
            Button("Generate Sample Video…") {
                selection = ids
                showGenerateSheet = true
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.importVideos(urls)
            return urls.contains { Analyzer.videoExtensions.contains($0.pathExtension.lowercased()) }
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .allowsHitTesting(false)
            } else if store.videos.isEmpty {
                ContentUnavailableView("No source videos", systemImage: "film",
                                       description: Text("Drop video files here — they're copied into the profile's Input folder."))
                    .allowsHitTesting(false)
            }
        }
    }

    private func hasTranscript(_ video: VideoRecord) -> Bool {
        // Cheap proxy: speech attribution column is stamped by transcription.
        video.speechAnalyzerProvider != nil
    }

}

/// One question — "what should the sample video be?" — everything else is
/// interpreted from the answer and lands as editable settings in the Wizard.
private struct GenerateSampleSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let videos: [VideoRecord]

    @State private var requestText = ""

    private var unanalyzedCount: Int {
        videos.count(where: { $0.visualAnalyzedAt == nil })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generate Sample Video")
                .font(.title3.bold())
            Text("Describe what to create from the \(videos.count) selected video(s). Mention duration, content, overlays, music — the AI Wizard is filled in from your description, ready to review and run.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $requestText)
                .font(.body)
                .frame(minHeight: 90)
                .overlay(alignment: .topLeading) {
                    if requestText.isEmpty {
                        Text("e.g. “generate an action-packed 15s video with fight footage only and use the text overlay ‘Sample 1’ with the caption ‘Porrada day!’”")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.quaternary)
                }

            if unanalyzedCount > 0 {
                Label("\(unanalyzedCount) selected video(s) haven't been analyzed — they'll be analyzed first so their footage can be used.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Generate") {
                    store.generateSampleVideo(description: requestText, videos: videos)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(requestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Isolated so per-tick progress/log updates don't re-evaluate the whole
/// Analyze screen (including the videos table) on every appended line.
private struct AnalysisLogPanel: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Activity")
                    .font(.headline)
                Spacer()
                if store.isAnalyzing {
                    Text(store.analysisStage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(value: store.analysisProgress)
                        .frame(width: 180)
                    Button("Stop", systemImage: "stop.circle") {
                        store.cancelAnalysis()
                    }
                    .controlSize(.small)
                    .help("Stop the analysis")
                }
            }
            ActivityLogView(lines: \.analysisLog)
        }
        .padding()
    }
}
