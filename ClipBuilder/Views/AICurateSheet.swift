import SwiftUI

/// AI Curator: judge the offered uncurated scenes against the taste rubric
/// and the user's own grading history, then review the proposed promotions —
/// each with a thumbnail and the model's reason — before any scene joins the
/// Curated set.
struct AICurateSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Uncurated scenes to judge (stack tops only — takes of the same moment
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
            Text("AI Curator")
                .font(.title3.bold())
            Text("Judges the \(candidates.count) uncurated scene\(candidates.count == 1 ? "" : "s") in view against your taste rubric — using your own grades and existing Curated picks as worked examples — and proposes the keepers. You review every pick before it joins Curated.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                ModelPicker(title: "Model", task: "curate", selection: $modelTag,
                            availableProviders: availableProviders)
                    .fixedSize()
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
                Button(isRunning ? "Judging…" : "Judge Scenes") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(candidates.isEmpty || isRunning)
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
                        ProvenanceBadge(provenance: provenance, style: .full, role: "Curated by")
                    }
                }
                Text("Uncheck any you disagree with, then Curate. Everything else stays as it is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(proposals) { proposal in
                        if let scene = scenesByID[proposal.sceneID] {
                            HStack(spacing: 10) {
                                Toggle("", isOn: Binding(
                                    get: { included[proposal.sceneID] ?? true },
                                    set: { included[proposal.sceneID] = $0 }
                                ))
                                .labelsHidden()
                                .toggleStyle(.checkbox)
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
                let count = proposals.count { included[$0.sceneID] ?? true }
                Button(count == 1 ? "Curate 1 Scene" : "Curate \(count) Scenes") {
                    store.applyCuration(sceneIDs: proposals
                        .filter { included[$0.sceneID] ?? true }
                        .map(\.sceneID), provenance: provenance)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(count == 0)
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
                let results = try await store.proposeCuration(
                    for: candidates, provider: provider, model: model) { message in
                    if let line = AIProgressLine.from(message) { Task { @MainActor in statusLine = line } }
                }
                if results.value.isEmpty {
                    errorMessage = "The curator promoted nothing — none of these scenes clearly met the rubric."
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
