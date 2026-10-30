import SwiftUI

struct MiniBRollScenePicker: View {
    let items: [MiniBRollLibrary.Item]
    let usedSceneIDs: Set<Int64>
    let onPick: (SceneRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var filtered: [MiniBRollLibrary.Item] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            HStack {
                Text("Pick Scene").font(.headline).lineLimit(1).fixedSize()
                Spacer()
                Button("Cancel") { dismiss() }.lineLimit(1).fixedSize()
            }
            TextField("Search scenes, tags, people or file names", text: $query)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Search project scenes")
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220))], spacing: Theme.spaceM) {
                    ForEach(filtered) { item in
                        Button {
                            onPick(item.scene)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: Theme.spaceXS) {
                                VideoThumbnail(url: item.scene.videoURL, time: item.scene.startTime,
                                               cornerRadius: Theme.mediaRadius)
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                    .overlay(alignment: .topTrailing) {
                                        if usedSceneIDs.contains(item.id) {
                                            Label("Used", systemImage: "checkmark.circle.fill")
                                                .font(.caption).lineLimit(1).fixedSize()
                                                .padding(4).background(.regularMaterial, in: .capsule)
                                        }
                                    }
                                Text(item.name).font(.caption).lineLimit(1).fixedSize(horizontal: false, vertical: true)
                                Text(item.scene.videoFilename).font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).fixedSize(horizontal: false, vertical: true)
                                Text(item.scene.duration.timecode).font(.caption2).lineLimit(1).fixedSize()
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Pick \(item.name)" + (usedSceneIDs.contains(item.id) ? ", already used" : ""))
                    }
                }
                if filtered.isEmpty { FormCaption("No scenes match this search.") }
            }
        }
        .padding(Theme.spaceL)
        .frame(minWidth: 520, idealWidth: 650, minHeight: 420, idealHeight: 560)
        .modalCloseButton { dismiss() }
        .task(id: query) {
            let result = await MiniBRollLibrary.search(items, query: query)
            guard !Task.isCancelled else { return }
            filtered = result
        }
    }
}
