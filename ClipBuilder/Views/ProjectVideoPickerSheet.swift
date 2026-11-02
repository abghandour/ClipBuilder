import SwiftUI

struct ProjectVideoPickerSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [HomeVideoCandidate] = []
    @State private var selection: Set<Int64> = []
    @State private var isLoading = true
    @State private var loadedProjectID: Int64?
    @State private var loadedGeneration: Int?
    @State private var search = ""
    @State private var filter: HomeVideoFilter = .all

    private var projectName: String { store.activeProject?.name ?? "Project" }
    private var filtered: [HomeVideoCandidate] { HomeVideoFilter.apply(filter, search: search, to: candidates) }
    private var visibleIDs: Set<Int64> { Set(filtered.map(\.id)) }
    private var allVisibleSelected: Bool { !visibleIDs.isEmpty && visibleIDs.isSubset(of: selection) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.spaceS) {
                Text("Videos in this profile not yet in \(projectName)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search files", text: $search)
                        .textFieldStyle(.plain)
                }
                .padding(Theme.spaceS)
                .background(.quaternary, in: .rect(cornerRadius: Theme.mediaRadius))
                Picker("Filter videos", selection: $filter) {
                    ForEach(HomeVideoFilter.allCases) { filter in
                        Text(filter.rawValue).lineLimit(1).fixedSize().tag(filter)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(Theme.spaceM)
            if isLoading {
                ProgressView("Loading videos…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if candidates.isEmpty {
                ContentUnavailableView(
                    "No Videos to Add",
                    systemImage: "film.stack",
                    description: Text("Every Home video is already in this project.")
                )
            } else if filtered.isEmpty {
                ContentUnavailableView("No matching videos", systemImage: "magnifyingglass")
            } else {
                List(filtered, selection: $selection) { candidate in
                    let video = candidate.video
                    HStack {
                        VideoThumbnail(url: video.url, time: 0.5)
                            .frame(width: 64, height: 38)
                            .clipShape(.rect(cornerRadius: Theme.mediaRadius))
                        VStack(alignment: .leading) {
                            Text(video.filename)
                                .lineLimit(1)
                            HStack {
                                Text(video.createdDate, format: .dateTime.year().month(.twoDigits).day(.twoDigits))
                                    .help(video.createdDate.formatted(date: .complete, time: .standard))
                                Text(video.duration.timecode)
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1).fixedSize()
                            HStack(spacing: Theme.spaceXS) {
                                ForEach(Array(candidate.projectNames.prefix(3).enumerated()), id: \.offset) { _, name in
                                    Text(name)
                                        .lineLimit(1)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }
                                if candidate.projectNames.count > 3 {
                                    Text("+\(candidate.projectNames.count - 3)").lineLimit(1).fixedSize()
                                }
                            }
                            .font(.caption)
                            .help(candidate.projectNames.joined(separator: ", "))
                        }
                    }
                    .tag(video.id)
                }
            }

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .lineLimit(1).fixedSize()
                Button(allVisibleSelected ? "Deselect All" : "Select All") {
                    if allVisibleSelected { selection.subtract(visibleIDs) }
                    else { selection.formUnion(visibleIDs) }
                }
                .lineLimit(1).fixedSize()
                .disabled(isLoading || visibleIDs.isEmpty)
                Spacer()
                Button("Add \(selection.count) to \(projectName)", action: addSelection)
                    .lineLimit(1).fixedSize()
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading || selection.isEmpty || loadedProjectID != store.activeProjectID
                              || loadedGeneration != store.profileGeneration || store.isHomeProject)
            }
            .padding(Theme.spaceM)
        }
        .frame(minWidth: 640, minHeight: 480)
        .modalCloseButton { dismiss() }
        .navigationTitle("Add from Home")
        .task(id: store.activeProjectID) { await loadVideos() }
        .onChange(of: store.profileGeneration) { dismiss() }
    }

    private func loadVideos() async {
        isLoading = true
        loadedProjectID = nil
        loadedGeneration = nil
        selection = []
        candidates = []
        let projectID = store.activeProjectID
        let generation = store.profileGeneration
        let loaded = await store.availableVideosForProjectPicker()
        guard !Task.isCancelled, projectID == store.activeProjectID, generation == store.profileGeneration else { return }
        candidates = loaded
        loadedProjectID = projectID
        loadedGeneration = generation
        isLoading = false
    }

    private func addSelection() {
        guard !isLoading, !store.isHomeProject, let projectID = loadedProjectID,
              projectID == store.activeProjectID, loadedGeneration == store.profileGeneration else { return }
        store.addVideos(Array(selection), to: projectID)
        dismiss()
    }
}
