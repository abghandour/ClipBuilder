import SwiftUI

/// Shared persisted type control for the source detail pane and transcript sheet.
struct VideoTypePicker: View {
    @Environment(AppStore.self) private var store
    let video: VideoRecord
    var focusRequest: UUID? = nil
    @FocusState private var isFocused: Bool

    private var selection: Binding<String> {
        Binding(
            get: { (store.videos.first { $0.id == video.id } ?? video).videoType ?? "" },
            set: { store.setVideoType(video, type: VideoType(rawValue: $0)) }
        )
    }

    var body: some View {
        Picker("Type", selection: selection) {
            Text("—").tag("")
            ForEach(VideoType.allCases, id: \.rawValue) { type in
                Text(type.label).tag(type.rawValue)
            }
        }
        .focused($isFocused)
        .task(id: focusRequest) {
            if focusRequest != nil { isFocused = true }
        }
        .labelsHidden()
        .controlSize(.small)
        .lineLimit(1)
        .fixedSize()
        .help("What this footage is — inferred during analysis, editable here. Podcast and Interview use podcast exchanges; other types get visual analysis. Non-fight types skip fight scoring and fight research.")
    }
}
