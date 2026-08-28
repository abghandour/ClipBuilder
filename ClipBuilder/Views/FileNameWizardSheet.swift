import SwiftUI

/// File Name Wizard: build a descriptive filename for each selected video
/// from the metadata already on record — people detected, video type, fight
/// result/research, scene stories, transcript — then review and edit every
/// proposal before it's applied. Renaming moves the file on disk and
/// rebuilds derived analyze-batch labels; scene titles join the videos
/// table, so they follow on their own.
struct FileNameWizardSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let videos: [VideoRecord]

    @State private var isRunning = false
    @State private var statusLine = ""
    @State private var errorMessage: String?
    // Model choice, dispatcher-style: configured task routing is the seed.
    @State private var modelTag = ""
    @State private var availableProviders = Set(AICatalog.providers.map(\.key))
    /// Proposals from the finished run — flips the sheet into review mode.
    @State private var suggestions: [RenameSuggestion]?

    var body: some View {
        Group {
            if let suggestions {
                review(suggestions)
            } else {
                setup
            }
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 280, idealHeight: 340)
        // Closing keeps the current filenames — nothing is renamed.
        .modalCloseButton { dismiss() }
        .task {
            availableProviders = await ModelPicker.probeAvailability(ai: store.ai)
            if modelTag.isEmpty {
                modelTag = ModelPicker.bestAvailableTag(for: "naming",
                                                        available: availableProviders)
            }
        }
    }

    // MARK: - Setup phase

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

            if isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(statusLine.isEmpty ? "Reading the metadata…" : statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(isRunning ? "Naming…" : "Suggest Names") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(videos.isEmpty || isRunning)
            }
        }
        .padding(20)
    }

    // MARK: - Review phase

    private func review(_ suggestions: [RenameSuggestion]) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text(suggestions.count == 1
                         ? "Rename suggestion"
                         : "\(suggestions.count) rename suggestions")
                        .font(.headline)
                    if let provenance = suggestions.first?.provenance {
                        ProvenanceBadge(provenance: provenance, style: .full, role: "Named by")
                    }
                }
                Text("Edit any name, uncheck files you want to keep as they are, then Rename.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()

            RenameSuggestionEditor(suggestions: suggestions,
                                   onApplied: { dismiss() })
        }
    }

    private func run() {
        let (provider, model) = ModelPicker.parse(modelTag)
        isRunning = true
        errorMessage = nil
        Task {
            do {
                let results = try await store.suggestFileNames(
                    for: videos, provider: provider, model: model) { message in
                    if let line = AIProgressLine.from(message) { Task { @MainActor in statusLine = line } }
                }
                if results.isEmpty {
                    errorMessage = "No renames to propose — the current names already match the content."
                } else {
                    suggestions = results
                }
            } catch {
                errorMessage = error.userMessage
            }
            isRunning = false
        }
    }
}
