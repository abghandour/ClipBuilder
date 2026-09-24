import SwiftUI

struct DuplicateReviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let jobID: UUID
    let videos: [VideoRecord]
    let groups: [DuplicateFinder.Group]
    let provenance: AIProvenance?
    private var videosByID: [Int64: VideoRecord] {
        Dictionary(uniqueKeysWithValues: videos.map { ($0.id, $0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            report(groups)
            HStack {
                Spacer()
                Button("Done") { store.jobs.markReviewed(jobID); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .help("Close the report and clear it from the status bar")
            }
            .padding()
        }
        .frame(minWidth: 520, idealWidth: 580, minHeight: 300, idealHeight: 440)
        .modalCloseButton { dismiss() }
    }

    @ViewBuilder
    private func report(_ groups: [DuplicateFinder.Group]) -> some View {
        if groups.isEmpty {
            ContentUnavailableView("No duplicates found",
                                   systemImage: "checkmark.circle",
                                   description: Text("Every video in the library looks like distinct footage."))
                .padding()
        } else {
            VStack(spacing: 0) {
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        Text("\(groups.count) duplicate group\(groups.count == 1 ? "" : "s")")
                            .font(.headline)
                        if let provenance {
                            AIInfoButton(provenance: provenance, style: .full, role: "Compared by")
                        }
                    }
                    Text("KEEP marks the recommended copy. Nothing is deleted — reveal a lesser copy in Finder to clean up yourself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()

                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                if !group.reason.isEmpty {
                                    Text(group.reason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(group.videoIDs, id: \.self) { videoID in
                                    if let video = videosByID[videoID] {
                                        HStack(spacing: 10) {
                                            VideoThumbnail(url: video.url, time: video.duration / 2)
                                                .frame(width: 72, height: 40)
                                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(video.filename)
                                                    .font(.caption)
                                                    .lineLimit(1)
                                                Text("\(video.width)×\(video.height) · \(video.duration.timecode)")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            if videoID == group.keepID {
                                                Text("KEEP")
                                                    .font(.caption2.bold())
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(.green.opacity(0.2),
                                                                in: Capsule())
                                                    .foregroundStyle(.green)
                                            }
                                            Button("Reveal", systemImage: "folder") {
                                                NSWorkspace.shared.activateFileViewerSelecting([video.url])
                                            }
                                            .labelStyle(.iconOnly)
                                            .buttonStyle(.borderless)
                                            .help("Show this file in Finder")
                                        }
                                    }
                                }
                            }
                            .padding(10)
                            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

}
