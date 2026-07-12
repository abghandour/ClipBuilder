import SwiftUI

/// Analyze tab: source-video inventory with analysis/transcription status,
/// batch AI tagging, and a live progress log.
struct AnalyzeView: View {
    @Environment(AppStore.self) private var store

    @State private var selection: Set<Int64> = []
    @State private var provider: String = ""
    @State private var model: String = ""

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

                Button("Scan Folder", systemImage: "arrow.clockwise") {
                    store.scanSourceFolder()
                }
                .help("Re-scan the profile's Input folder for new videos")
            }
        }
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
        }
    }

    private func hasTranscript(_ video: VideoRecord) -> Bool {
        // Cheap proxy: speech attribution column is stamped by transcription.
        video.speechAnalyzerProvider != nil
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
