import AVKit
import SwiftUI

/// Presented when a wizard run finishes: every video it produced, playable
/// side by side, with quick thumbs (saved as reviews the wizard trains on),
/// a jump into the full review flow, and a one-click retry of the same run.
struct WizardResultsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let results: WizardRunResults

    @State private var players: [Int64: AVPlayer] = [:]
    @State private var verdicts: [Int64: Int] = [:]
    @State private var reviewTarget: GeneratedVideoRecord?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text(results.videos.count == 1
                     ? "Your reel is ready"
                     : "\(results.videos.count) reels are ready")
                    .font(.headline)
                Text("Watch and rate — every rating trains the wizard. Not what you wanted? Retry runs the same settings again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(results.videos) { video in
                        videoCard(video)
                    }
                }
                .padding(.horizontal)
            }

            HStack {
                Button {
                    store.retryWizard()
                    dismiss()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .help("Generate again with the same settings — a new plan, new videos")

                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 480)
        .onAppear {
            for video in results.videos {
                players[video.id] = AVPlayer(url: video.url)
            }
        }
        .onDisappear {
            for player in players.values { player.pause() }
        }
        .sheet(item: $reviewTarget) { video in
            ReviewSheet(video: video)
        }
    }

    @ViewBuilder
    private func videoCard(_ video: GeneratedVideoRecord) -> some View {
        VStack(spacing: 8) {
            PlayerView(player: players[video.id])
                .frame(width: 210, height: 373)
                .background(.black, in: RoundedRectangle(cornerRadius: 8))

            Text("\(video.filename) · \(video.duration.timecode)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let rationale = video.rationale, !rationale.isEmpty {
                Text(rationale)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(width: 210)
            }

            HStack(spacing: 12) {
                ThumbsToggle(value: Binding(
                    get: { verdicts[video.id] ?? 0 },
                    set: { verdict in
                        verdicts[video.id] = verdict
                        saveQuickVerdict(verdict, for: video)
                    }))

                Button("Full Review…") {
                    reviewTarget = video
                }
                .controlSize(.small)
            }
        }
    }

    /// A thumbs tap is a review with just the overall verdict — the full
    /// ReviewSheet loads and extends it if the user goes deeper.
    private func saveQuickVerdict(_ verdict: Int, for video: GeneratedVideoRecord) {
        store.saveReview(GenerationReview(generatedVideoID: video.id,
                                          verdict: verdict,
                                          dimensions: [:],
                                          note: "",
                                          createdAt: nil),
                         clips: [])
    }
}
