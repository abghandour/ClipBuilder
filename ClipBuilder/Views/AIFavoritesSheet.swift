import SwiftUI

/// AI Favorites: judge the offered non-favorite scenes against the taste rubric
/// and the user's own grading history, then review the proposed promotions —
/// each with a thumbnail and the model's reason — before any scene joins the
/// Favorites.
struct AIFavoritesSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Non-favorite scenes to judge (stack tops only — takes of the same moment
    /// would just be judged twice).
    let candidates: [SceneRecord]

    @State private var isRunning = false
    @State private var statusLine = ""
    @State private var errorMessage: String?
    @State private var modelTag = ""
    @State private var availableProviders = Set(AICatalog.providers.map(\.key))
    /// Proposals from the finished run — flips the sheet into review mode.
    @State private var proposals: [SceneCurator.Proposal]?
    /// The curator that made the proposals — stamped on every applied pick.
    @State private var provenance: AIProvenance?
    @State private var included: [Int64: Bool] = [:]

    private var scenesByID: [Int64: SceneRecord] {
        Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
    }

    var body: some View {
        Group {
            if let proposals {
                review(proposals)
            } else {
                setup
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 300, idealHeight: 420)
        .modalCloseButton { dismiss() }
        .task {
            availableProviders = await ModelPicker.probeAvailability(ai: store.ai)
            if modelTag.isEmpty {
                modelTag = ModelPicker.bestAvailableTag(for: "curate",
                                                        available: availableProviders)
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI Favorites")
                .font(.title3.bold())
            Text("Judges the \(candidates.count) non-favorite scene\(candidates.count == 1 ? "" : "s") in view against your taste rubric — using your own grades and existing Favorite picks as worked examples — and proposes the keepers. You review every pick before it joins Favorites.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                ModelPicker(title: "Model", task: "curate", selection: $modelTag,
                            availableProviders: availableProviders)
                    .fixedSize()
                    .help("Choose the AI provider and model that will propose favorites")
                Spacer()
            }

            if isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(statusLine.isEmpty ? "Judging scenes…" : statusLine)
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
                Button("Cancel") { dismiss() }
                Button(isRunning ? "Judging…" : "Judge Scenes") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(candidates.isEmpty || isRunning)
                    .help("Ask AI Favorites to propose scenes for your review")
            }
        }
        .padding(20)
    }

    private func review(_ proposals: [SceneCurator.Proposal]) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text("\(proposals.count) proposed promotion\(proposals.count == 1 ? "" : "s")")
                        .font(.headline)
                    if let provenance {
                        AIInfoButton(provenance: provenance, style: .full, role: "Favorited by")
                    }
                }
                Text("Uncheck any you disagree with, then Favorite. Everything else stays as it is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(proposals) { proposal in
                        if let scene = scenesByID[proposal.sceneID] {
                            HStack(spacing: 10) {
                                Toggle("Favorite this scene", isOn: Binding(
                                    get: { included[proposal.sceneID] ?? true },
                                    set: { included[proposal.sceneID] = $0 }
                                ))
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                                .help("Include this scene when applying the proposed favorites")
                                VideoThumbnail(url: scene.videoURL,
                                               time: (scene.startTime + scene.endTime) / 2)
                                    .frame(width: 72, height: 40)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(scene.videoFilename)  \(scene.startTime.timecode)–\(scene.endTime.timecode)")
                                        .font(.caption)
                                        .lineLimit(1)
                                    HStack(spacing: 6) {
                                        if let score = scene.score {
                                            Text(String(format: "score %.1f", score))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(proposal.reason)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(8)
                            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding(.horizontal)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                let count = proposals.count { included[$0.sceneID] ?? true }
                Button(count == 1 ? "Favorite 1 Scene" : "Favorite \(count) Scenes") {
                    store.applyFavorites(sceneIDs: proposals
                        .filter { included[$0.sceneID] ?? true }
                        .map(\.sceneID), provenance: provenance)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(count == 0)
                .help("Save the checked scenes as favorites with the proposing AI recorded")
            }
            .padding()
        }
    }

    private func run() {
        let (provider, model) = ModelPicker.parse(modelTag)
        isRunning = true
        errorMessage = nil
        Task {
            do {
                let results = try await store.proposeFavorites(
                    for: candidates, provider: provider, model: model) { message in
                    if let line = AIProgressLine.from(message) { Task { @MainActor in statusLine = line } }
                }
                if results.value.isEmpty {
                    errorMessage = "AI Favorites selected nothing — none of these scenes clearly met the rubric."
                } else {
                    proposals = results.value
                    provenance = results.provenance
                }
            } catch {
                errorMessage = error.userMessage
            }
            isRunning = false
        }
    }
}
