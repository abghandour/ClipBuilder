import SwiftUI

/// Cover-frame picker: the AI samples frames across a rendered reel and
/// ranks the best thumbnail candidates; clicking one makes it the Library
/// card's cover.
struct CoverFrameSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let video: GeneratedVideoRecord

    @State private var isRunning = false
    @State private var statusLine = ""
    @State private var errorMessage: String?
    @State private var modelTag = ""
    @State private var availableProviders = Set(AICatalog.providers.map(\.key))
    @State private var candidates: [CoverFramePicker.Candidate]?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick a Cover Frame")
                .font(.title3.bold())
            Text("The AI samples frames across \(video.filename) and ranks the strongest thumbnails — sharp, expressive, readable at cover size. Click one to make it the card's cover.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let candidates {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(candidates) { candidate in
                        Button {
                            store.setCoverFrame(video, time: candidate.time)
                            dismiss()
                        } label: {
                            VStack(spacing: 6) {
                                VideoThumbnail(url: video.url, time: candidate.time)
                                    .aspectRatio(9 / 16, contentMode: .fit)
                                    .frame(width: 140)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(alignment: .bottomTrailing) {
                                        Text(candidate.time.timecode)
                                            .font(.caption2.monospacedDigit())
                                            .padding(3)
                                            .background(.black.opacity(0.6),
                                                        in: RoundedRectangle(cornerRadius: 4))
                                            .foregroundStyle(.white)
                                            .padding(4)
                                    }
                                Text(candidate.reason.isEmpty ? "Use This" : candidate.reason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 140)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Use this frame as the cover")
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack {
                    ModelPicker(title: "Model", task: "cover", selection: $modelTag,
                                availableProviders: availableProviders)
                        .fixedSize()
                    Spacer()
                }
            }

            if isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(statusLine.isEmpty ? "Ranking frames…" : statusLine)
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

            if candidates == nil {
                HStack {
                    Spacer()
                    Button(isRunning ? "Picking…" : "Propose Covers") { run() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isRunning)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 500)
        .modalCloseButton { dismiss() }
        .task {
            availableProviders = await ModelPicker.probeAvailability(ai: store.ai)
            if modelTag.isEmpty {
                modelTag = ModelPicker.bestAvailableTag(for: "cover",
                                                        available: availableProviders)
            }
        }
    }

    private func run() {
        let (provider, model) = ModelPicker.parse(modelTag)
        isRunning = true
        errorMessage = nil
        Task {
            do {
                candidates = try await store.proposeCoverFrames(
                    for: video, provider: provider, model: model) { message in
                    if let line = AIProgressLine.from(message) { Task { @MainActor in statusLine = line } }
                }
            } catch {
                errorMessage = error.userMessage
            }
            isRunning = false
        }
    }
}
