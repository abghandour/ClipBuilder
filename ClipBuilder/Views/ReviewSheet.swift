import AVKit
import SwiftUI

/// Structured review of one generated reel: overall verdict, per-dimension
/// thumbs, and a per-clip strip with reason chips — ten seconds of clicking
/// that the wizard reads as training signal on every future run.
struct ReviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let video: GeneratedVideoRecord

    @State private var verdict = 0
    @State private var dimensions: [String: Int] = [:]
    @State private var clipVerdicts: [Int: Int] = [:]
    @State private var clipReasons: [Int: Set<String>] = [:]
    @State private var note = ""
    @State private var player: AVPlayer?

    private var clips: [ReviewableClip] { video.reviewableClips }

    private static let dimensionLabels: [(key: String, label: String)] = [
        ("hook", "Hook"), ("pacing", "Pacing"), ("music", "Music"), ("scenes", "Scene choice"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Review \(video.filename)")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
            }
            .padding()

            HStack(alignment: .top, spacing: 16) {
                PlayerView(player: player)
                    .frame(width: 236, height: 420)
                    .background(.black, in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 14) {
                    LabeledContent("Overall") {
                        ThumbsToggle(value: $verdict)
                    }
                    Divider()
                    ForEach(Self.dimensionLabels, id: \.key) { dimension in
                        LabeledContent(dimension.label) {
                            ThumbsToggle(value: binding(for: dimension.key))
                        }
                    }
                    Divider()
                    Text("Anything else?")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $note)
                        .font(.body)
                        .frame(minHeight: 60)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal)

            if !clips.isEmpty {
                Text("Clips — rate the picks the wizard made")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding([.top, .horizontal])
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(clips) { clip in
                            clipCell(clip)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Review") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasContent)
            }
            .padding([.top, .horizontal])
        }
        .padding(.bottom)
        .frame(width: 720)
        .task {
            let player = AVPlayer(url: video.url)
            self.player = player
            if let existing = await store.loadReview(for: video) {
                verdict = existing.review.verdict
                dimensions = existing.review.dimensions
                note = existing.review.note
                for clip in existing.clips {
                    clipVerdicts[clip.clipIndex] = clip.verdict
                    clipReasons[clip.clipIndex] = Set(clip.reasons)
                }
            }
        }
    }

    private var hasContent: Bool {
        verdict != 0 || !dimensions.values.filter { $0 != 0 }.isEmpty
            || !clipVerdicts.values.filter { $0 != 0 }.isEmpty
            || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func binding(for key: String) -> Binding<Int> {
        Binding(get: { dimensions[key] ?? 0 }, set: { dimensions[key] = $0 })
    }

    @ViewBuilder
    private func clipCell(_ clip: ReviewableClip) -> some View {
        let verdict = clipVerdicts[clip.index] ?? 0
        VStack(spacing: 6) {
            Button {
                // Jump the player to this clip's start within the reel.
                let offset = clips.prefix(clip.index).reduce(0) { $0 + $1.duration }
                player?.seek(to: CMTime(seconds: offset, preferredTimescale: 600))
                player?.play()
            } label: {
                VideoThumbnail(url: clip.url, time: (clip.start + clip.end) / 2)
                    .frame(width: 76, height: 135)
            }
            .buttonStyle(.plain)
            .help("Play this clip in the preview")

            Text("Clip \(clip.index + 1) · \(String(format: "%.1fs", clip.duration))"
                 + (clip.speed == 1 ? "" : String(format: " · %g× slow", clip.speed)))
                .font(.caption2)
                .foregroundStyle(clip.speed == 1 ? .secondary : Color.orange)

            ThumbsToggle(value: Binding(
                get: { clipVerdicts[clip.index] ?? 0 },
                set: { clipVerdicts[clip.index] = $0 }))

            if verdict < 0 {
                Menu {
                    ForEach(ClipReview.negativeReasons, id: \.self) { reason in
                        Toggle(reason, isOn: Binding(
                            get: { clipReasons[clip.index]?.contains(reason) ?? false },
                            set: { on in
                                var set = clipReasons[clip.index] ?? []
                                if on { set.insert(reason) } else { set.remove(reason) }
                                clipReasons[clip.index] = set
                            }))
                    }
                } label: {
                    let count = clipReasons[clip.index]?.count ?? 0
                    Text(count == 0 ? "Why?" : "\(count) reason\(count == 1 ? "" : "s")")
                        .font(.caption2)
                }
                .controlSize(.small)
                .frame(width: 84)
            }
        }
    }

    private func save() {
        let review = GenerationReview(generatedVideoID: video.id,
                                      verdict: verdict,
                                      dimensions: dimensions.filter { $0.value != 0 },
                                      note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                                      createdAt: nil)
        let clipReviewList = clipVerdicts.filter { $0.value != 0 }.map { index, verdict in
            ClipReview(clipIndex: index,
                       sceneID: clips.first { $0.index == index }?.sceneID,
                       verdict: verdict,
                       reasons: verdict < 0 ? (clipReasons[index] ?? []).sorted() : [])
        }.sorted { $0.clipIndex < $1.clipIndex }
        store.saveReview(review, clips: clipReviewList)
        dismiss()
    }
}

/// 👍/👎 pair where tapping the active side clears it (back to 0).
struct ThumbsToggle: View {
    @Binding var value: Int

    var body: some View {
        HStack(spacing: 4) {
            Button {
                value = value == 1 ? 0 : 1
            } label: {
                Image(systemName: value == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .foregroundStyle(value == 1 ? .green : .secondary)
            }
            Button {
                value = value == -1 ? 0 : -1
            } label: {
                Image(systemName: value == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .foregroundStyle(value == -1 ? .red : .secondary)
            }
        }
        .buttonStyle(.borderless)
    }
}
