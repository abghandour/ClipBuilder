import SwiftUI

struct TagStyleEditor: View {
    @Environment(AppStore.self) private var store
    @Binding var name: String
    @Binding var style: TagStyle
    let isDefault: Bool
    @Binding var selectedState: String
    @Binding var selectedImage: UUID?
    @State private var showingImages = false

    private var surface: TextLookSurface {
        var parent = style
        parent.decor = nil
        parent.name.decor = nil
        parent.description.decor = nil
        parent = parent.applyingSharedStyle(store.activeProfile.textStyles ?? [])
        let lineParent = style.applyingSharedStyle(store.activeProfile.textStyles ?? []).lineDecor
        return TextLookSurface(
            states: [
                .init(
                    id: "Box", decor: $style.decor, fontFamily: .constant(nil), inherited: parent.boxDecor,
                    boxOnly: true, sharedStyleID: $style.sharedStyleID, source: "name tag box"),
                .init(
                    id: "Name", decor: $style.name.decor, fontFamily: $style.name.fontOverride,
                    inherited: lineParent.merged(over: style.name.legacyDecor), source: "name line"),
                .init(
                    id: "Description", decor: $style.description.decor, fontFamily: $style.description.fontOverride,
                    inherited: lineParent.merged(over: style.description.legacyDecor), source: "description line")
            ], selection: $selectedState, sample: .tags)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spaceM) {
                TextField("Name", text: $name).disabled(isDefault)
                    .help(WizardFieldHelp.textDecor["name"]!.tooltip)
                TextLookInspector(surface: surface) {
                    if selectedState == "Description" {
                        TextLookRow("Field") {
                            TextField("Field", text: $style.description.field)
                                .help("Shows the saved People field, or AI fills it from the reel's context")
                            Menu("Suggestions") {
                                ForEach(TagTextWriter.profileFields, id: \.self) { field in
                                    Button(field) { style.description.field = field }
                                }
                            }.lineLimit(1).fixedSize()
                        }
                    }
                }
                if selectedState == "Box" {
                    DisclosureGroup("Images") {
                        VStack(alignment: .leading, spacing: Theme.spaceM) {
                            Button("Add Image", systemImage: "photo") { showingImages = true }
                                .lineLimit(1).fixedSize()
                            if style.images.isEmpty {
                                FormCaption("Add an image from the Images library, then drag or resize it on the preview.")
                            }
                            ForEach($style.images) { $image in
                                TagImageControls(
                                    image: $image, selected: selectedImage == image.id,
                                    select: { selectedImage = image.id },
                                    remove: {
                                        let id = image.id
                                        style.images.removeAll { $0.id == id }
                                        if selectedImage == id { selectedImage = nil }
                                    })
                            }
                        }
                    }
                }
            }.padding(12)
        }
        .sheet(isPresented: $showingImages) {
            ImagePickerSheet { urls in
                for url in urls {
                    let image = TagImage(path: url.path)
                    style.images.append(image)
                    selectedImage = image.id
                }
            }
        }
    }
}

private struct TagImageControls: View {
    @Binding var image: TagImage
    let selected: Bool
    let select: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            HStack {
                Button(action: select) {
                    Label(
                        URL(fileURLWithPath: image.path).lastPathComponent,
                        systemImage: selected ? "checkmark.circle.fill" : "photo"
                    )
                    .lineLimit(1)
                }.buttonStyle(.plain)
                Spacer()
                Button("Remove", systemImage: "trash", role: .destructive, action: remove)
                    .labelStyle(.iconOnly).fixedSize()
            }
            HStack {
                Text("Opacity").lineLimit(1).fixedSize()
                Spacer(minLength: 4)
                TextField(
                    "Opacity", value: clampedTextLookNumber($image.opacity, in: 0...1), format: .number.precision(.fractionLength(0...2))
                )
                .frame(width: 52).textFieldStyle(.roundedBorder)
            }
            Slider(value: $image.opacity, in: 0...1) {
                Text("Opacity").lineLimit(1).fixedSize()
            }
            Picker("Layer", selection: $image.behindText) {
                Text("Behind text").lineLimit(1).fixedSize().tag(true)
                Text("In front").lineLimit(1).fixedSize().tag(false)
            }.pickerStyle(.segmented)
            HStack {
                TextField("X", value: $image.x, format: .number).accessibilityLabel("Image horizontal position")
                TextField("Y", value: $image.y, format: .number).accessibilityLabel("Image vertical position")
            }
            HStack {
                Text("Width").lineLimit(1).fixedSize()
                Spacer(minLength: 4)
                TextField(
                    "Width", value: clampedTextLookNumber($image.width, in: 0.05...2), format: .number.precision(.fractionLength(0...2))
                )
                .frame(width: 52).textFieldStyle(.roundedBorder)
            }
            Slider(value: $image.width, in: 0.05...2) {
                Text("Width").lineLimit(1).fixedSize()
            }
        }
    }
}
