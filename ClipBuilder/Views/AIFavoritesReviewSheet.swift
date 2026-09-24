import SwiftUI

struct AIFavoritesReviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let jobID: UUID
    let candidates: [SceneRecord]
    let proposals: [SceneCurator.Proposal]
    let provenance: AIProvenance?
    @State private var included: [Int64: Bool] = [:]
    private var scenesByID: [Int64: SceneRecord] {
        Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
    }

    var body: some View {
        review(proposals)
            .frame(minWidth: 520, idealWidth: 580, minHeight: 300, idealHeight: 440)
            .modalCloseButton { dismiss() }
    }

    @ViewBuilder
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
                    store.jobs.markReviewed(jobID)
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

}
