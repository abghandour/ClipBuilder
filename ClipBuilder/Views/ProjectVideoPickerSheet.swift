import SwiftUI

struct ProjectVideoPickerSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var videos: [VideoRecord] = []
    @State private var selection: Set<Int64> = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView("Loading videos…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if videos.isEmpty {
                ContentUnavailableView(
                    "No Videos to Add",
                    systemImage: "film.stack",
                    description: Text("Every profile video is already in this project.")
                )
            } else {
                List(videos, selection: $selection) { video in
                    HStack {
                        VideoThumbnail(url: video.url, time: 0.5)
                            .frame(width: 64, height: 38)
                            .clipShape(.rect(cornerRadius: Theme.mediaRadius))
                        VStack(alignment: .leading) {
                            Text(video.filename)
                                .lineLimit(1)
                            Text(video.duration.timecode)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(video.id)
                }
            }

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Add \(selection.count) to Project", action: addSelection)
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.isEmpty || store.activeProjectID == nil)
            }
            .padding(Theme.spaceM)
        }
        .frame(minWidth: 560, minHeight: 420)
        .navigationTitle("Add Existing Videos")
        .task { await loadVideos() }
    }

    private func loadVideos() async {
        videos = await store.availableVideosForProjectPicker()
        isLoading = false
    }

    private func addSelection() {
        guard let projectID = store.activeProjectID else { return }
        store.addVideos(Array(selection), to: projectID)
        dismiss()
    }
}
