import SwiftUI

struct BuilderWizardFindResults: View {
    let model: WizardSheetModel
    let openPicker: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            Text("Found \(model.results.count) scenes").font(.subheadline.weight(.semibold))
            Text("Finds do not edit the timeline. Adding these results creates a new preview for Apply. The picker opens with its usual selection.")
                .font(.caption).foregroundStyle(.secondary)
            if model.results.isEmpty { Text("No scenes match this request.").foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: Theme.spaceS) {
                Button("Add all as B-roll at playhead", action: model.addAllAsBRoll)
                    .disabled(model.results.isEmpty)
                    .help("Preview all results back-to-back as B-roll starting at the current playhead on the focused track.")
                Button("Open in B-roll picker", action: openPicker)
                    .help("Open the existing B-roll picker at the current playhead. It supports a single source selection.")
            }
            LazyVStack(alignment: .leading, spacing: Theme.spaceS) {
                ForEach(model.results) { scene in
                    HStack(spacing: Theme.spaceM) {
                        VideoThumbnail(url: URL(fileURLWithPath: scene.videoPath), time: scene.startTime, cornerRadius: 4)
                            .frame(width: 64, height: 36)
                            .accessibilityLabel("Thumbnail for \(scene.videoFilename)")
                        VStack(alignment: .leading, spacing: Theme.spaceS) {
                            Text(scene.videoFilename).lineLimit(1)
                            Text("\(scene.startTime.timecode)–\(scene.endTime.timecode) · \(scene.tags.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
