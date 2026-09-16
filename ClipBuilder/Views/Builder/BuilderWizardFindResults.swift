import SwiftUI

struct BuilderWizardFindResults: View {
    let model: WizardSheetModel
    let openPicker: (Int64) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            Text("Found \(model.results.count) scenes").font(.subheadline.weight(.semibold))
            Text("Adding scenes creates a preview for Apply.")
                .font(.caption).foregroundStyle(.secondary)
            if model.results.isEmpty { Text("No scenes match this request.").foregroundStyle(.secondary) }
            let tracks = model.trackChoices
            HStack(spacing: Theme.spaceS) {
                Menu("Add All to Track") {
                    ForEach(tracks, id: \.index) { choice in
                        Button(choice.label) { model.addAllToTrack(choice.index) }
                    }
                }
                .fixedSize()
                .disabled(model.results.isEmpty)
                .help("Preview all results back-to-back as main clips on that track, starting at the current playhead (a sequential track packs them after its last clip).")
                Button("Add all as B-roll", action: model.addAllAsBRoll)
                    .disabled(model.results.isEmpty)
                    .help("Preview all results back-to-back as B-roll starting at the current playhead on the focused track.")
            }
            LazyVStack(alignment: .leading, spacing: Theme.spaceM) {
                ForEach(model.results.prefix(BuilderSceneSearch.limit)) { scene in
                    BuilderWizardFindResultRow(scene: scene, reason: model.resultReasons[scene.id] ?? "",
                        tracks: tracks,
                        addToTrack: { model.addToTrack(sceneID: scene.id, track: $0) },
                        add: { model.addAsBRoll(sceneID: scene.id) }, openPicker: { openPicker(scene.id) })
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
