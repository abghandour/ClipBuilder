import SwiftUI

struct FileNameWizardSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let videos: [VideoRecord]
    @State private var modelTag = ""
    @State private var availableProviders = Set(AICatalog.providers.map(\.key))

    var body: some View {
        setup
        .frame(minWidth: 520, idealWidth: 560, minHeight: 280)
        .appJobSetupPresentation()
        .modalCloseButton { dismiss() }
        .task {
            availableProviders = await ModelPicker.probeAvailability(ai: store.ai)
            if modelTag.isEmpty {
                modelTag = ModelPicker.bestAvailableTag(for: "naming",
                                                        available: availableProviders)
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("File Name Wizard")
                .font(.title3.bold())
            Text("Builds a descriptive name for each selected file from what's already on record — people detected, video type, fight result and research, scene stories, transcript. You review and edit every proposal before anything is renamed; analyze-batch names derived from a file update with it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(videos) { video in
                            Text(video.filename)
                                .font(.caption)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 110)
            } label: {
                Text(videos.count == 1 ? "1 file" : "\(videos.count) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                ModelPicker(title: "Model", task: "naming", selection: $modelTag,
                            availableProviders: availableProviders)
                    .fixedSize()
                Spacer()
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Suggest Names") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(videos.isEmpty)
            }
        }
        .padding(20)
    }

    private func run() {
        let store = store
        let videos = videos
        let (provider, model) = ModelPicker.parse(modelTag)
        store.jobs.start(.fileNames, title: "File Names — \(videos.count) videos",
                         project: store.activeProject, profileGeneration: store.profileGeneration) { log in
            let suggestions = try await store.suggestFileNames(for: videos, provider: provider, model: model, log: log)
            guard !suggestions.isEmpty else {
                throw AppJobEmptyResult(message: "No renames to propose — the current names already match the content.")
            }
            return .fileNames(suggestions)
        }
        dismiss()
    }
}
