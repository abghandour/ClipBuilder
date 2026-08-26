import AVKit
import SwiftUI

/// Side-by-side A/B pick between the variations of one wizard run. The
/// choice is stored as preference pairs (winner vs. each other variation)
/// that future generations train on.
struct ComparisonSheet: View {
    @Environment(AppStore.self) private var store
    let batch: ComparisonBatch

    @State private var players: [Int64: AVPlayer] = [:]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text("Which variation is best?")
                    .font(.headline)
                Text("Your pick teaches the wizard which creative approach wins — the others stay in the Library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            HStack(alignment: .top, spacing: 16) {
                ForEach(Array(batch.videos.enumerated()), id: \.element.id) { index, video in
                    VStack(spacing: 8) {
                        PlayerView(player: players[video.id])
                            .frame(width: 210, height: 373)
                            .background(.black, in: RoundedRectangle(cornerRadius: 8))

                        Text("Variation \(index + 1) · \(video.duration.timecode)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let rationale = video.rationale, !rationale.isEmpty {
                            Text(rationale)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .frame(width: 210)
                        }

                        Button("Pick This One") {
                            store.resolveComparison(batch, winner: video)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(.horizontal)

            Button("Skip — don't record a preference") {
                store.resolveComparison(batch, winner: nil)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding()
        }
        .frame(minWidth: 480)
        // Closing without picking records nothing — same as Skip.
        .modalCloseButton { store.resolveComparison(batch, winner: nil) }
        .onAppear {
            for video in batch.videos {
                players[video.id] = AVPlayer(url: video.url)
            }
        }
        .onDisappear {
            for player in players.values { player.pause() }
        }
    }
}
