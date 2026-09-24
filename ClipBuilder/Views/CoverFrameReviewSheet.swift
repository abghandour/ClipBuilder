import SwiftUI

struct CoverFrameReviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let jobID: UUID
    let video: GeneratedVideoRecord
    let candidates: [CoverFramePicker.Candidate]
    let provenance: AIProvenance?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Choose a Cover Frame").font(.headline)
                if let provenance { AIInfoButton(provenance: provenance, style: .full, role: "Ranked by") }
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(candidates) { candidate in
                    Button {
                        store.setCoverFrame(video, time: candidate.time, provenance: provenance)
                        store.jobs.markReviewed(jobID)
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
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 500)
        .modalCloseButton { dismiss() }
    }
}
