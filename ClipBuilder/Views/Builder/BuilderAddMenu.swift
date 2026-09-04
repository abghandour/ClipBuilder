import SwiftUI

/// The single entry point for adding material to a cut. It keeps the common
/// first move obvious while retaining every asset type the timeline supports.
struct BuilderAddMenu: View {
    @Environment(AppStore.self) private var store

    @Binding var showScenePicker: Bool
    @Binding var showImagePicker: Bool

    var body: some View {
        Menu {
            Button("Video Clip…", systemImage: "film") {
                showScenePicker = true
            }
            .disabled(store.scenes.isEmpty)

            Menu("Music", systemImage: "music.note") {
                let music = WizardEngine.availableMusic()
                if music.isEmpty {
                    Text("Add music files to the Music library first")
                } else {
                    ForEach(music, id: \.name) { track in
                        Button(track.name) {
                            store.builder.addSound(name: track.name)
                        }
                    }
                }
            }

            Menu("Crop Layout", systemImage: "crop") {
                let layouts = BuilderTimelineModel.availableCropLayouts()
                ForEach(layouts, id: \.self) { layout in
                    Button(layout.displayName) {
                        store.builder.addCropBlock(layout)
                    }
                }
                if layouts.count == 1 {
                    Text("Add layouts under Resources > Screen Crop")
                }
            }

            Divider()

            Button("Text", systemImage: "textformat") {
                _ = store.builder.addText()
            }

            Button("Image…", systemImage: "photo") {
                showImagePicker = true
            }

            Menu("Overlay", systemImage: "square.2.layers.3d") {
                let templates = OverlayTemplateStore.list()
                if templates.isEmpty {
                    Text("Create an overlay template first")
                } else {
                    ForEach(templates) { template in
                        Button(template.name) {
                            store.builder.addOverlayBlock(name: template.name,
                                                          composition: template.composition)
                        }
                    }
                }
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .help("Add a clip, music, crop layout, text, image, or overlay at the playhead")
    }
}
