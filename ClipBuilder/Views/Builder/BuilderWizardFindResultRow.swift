import SwiftUI

struct BuilderWizardFindResultRow: View {
    let scene: SceneRecord
    let reason: String
    let add: () -> Void
    let openPicker: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            HStack(alignment: .top, spacing: Theme.spaceS) {
                VideoThumbnail(url: scene.videoURL, time: scene.startTime, cornerRadius: 4)
                    .frame(width: 64, height: 36)
                    .accessibilityLabel("Thumbnail for \(scene.videoFilename)")
                VStack(alignment: .leading, spacing: Theme.spaceXS) {
                    Text(scene.videoFilename).lineLimit(1).truncationMode(.middle)
                    Text("\(scene.startTime.timecode)–\(scene.endTime.timecode)")
                        .font(.caption).foregroundStyle(.secondary)
                    if let score = scene.score, score.isFinite {
                        Text("Score: \(score.formatted(.number.precision(.fractionLength(1))))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !scene.tags.isEmpty {
                Text(scene.tags.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .help(scene.tags.joined(separator: ", "))
            }
            Text(reason).font(.caption).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: Theme.spaceXS) {
                Button("Add as B-roll", action: add)
                    .help("Preview this scene as B-roll at the current playhead on the focused track. Apply is required.")
                Button("Open in B-roll picker", action: openPicker)
                    .help("Open the existing B-roll picker at the current playhead. It supports a single source selection.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
