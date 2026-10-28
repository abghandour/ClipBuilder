import SwiftUI

struct TagStyleEditor: View {
    @Environment(AppStore.self) private var store
    @Binding var name: String
    @Binding var style: TagStyle
    let isDefault: Bool
    @State private var selectedImage: UUID?
    @State private var showingImages = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            previewColumn
                .padding()
                .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            settings
                .frame(width: 360)
                .frame(maxHeight: .infinity)
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

    private var previewColumn: some View {
        VStack(spacing: 10) {
            Text(name).font(.headline).lineLimit(1)
            TagStylePreview(style: $style, selection: $selectedImage)
                .frame(maxWidth: 640)
            Text("Sample text. Click an image to select it; drag to reposition, or use its corner handle to resize.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var settings: some View {
        Form {
            Section {
                FormGroupHeader("Name tag style")
                TextField("Name", text: $name).disabled(isDefault)
                SharedTextStylePicker(selection: $style.sharedStyleID)
                TextDecorControls(decor: $style.decor, fontFamily: .constant(nil),
                    inherited: style.applyingSharedStyle(store.activeProfile.textStyles ?? []).boxDecor, boxOnly: true,
                    sourceLabel: "name tag box")
                FormCaption("Available in this profile’s Express and full Wizard. Changes save automatically.")
            }
            Section {
                FormGroupHeader("Name line")
                LabeledContent("Field", value: "Name")
                TagLineControls(style: $style.name, inherited: style.applyingSharedStyle(store.activeProfile.textStyles ?? []).lineDecor, label: "name line")
            }
            Section {
                FormGroupHeader("Description line")
                HStack {
                    TextField("Field", text: $style.description.field)
                    Menu("Suggestions") {
                        ForEach(TagTextWriter.profileFields, id: \.self) { field in
                            Button(field) { style.description.field = field }
                        }
                    }.lineLimit(1).fixedSize()
                }
                FormCaption("Shows what People has saved for this field. For people without it, AI fills the field from the reel’s context; edit it in People.")
                TagLineControls(style: $style.description, inherited: style.applyingSharedStyle(store.activeProfile.textStyles ?? []).lineDecor, label: "description line")
            }
            Section {
                FormGroupHeader("Images")
                Button("Add Image", systemImage: "photo") { showingImages = true }
                    .lineLimit(1).fixedSize()
                if style.images.isEmpty {
                    FormCaption("Add an image from the Images library, then drag or resize it on the preview.")
                }
                ForEach($style.images) { $image in
                    TagImageControls(image: $image, selected: selectedImage == image.id,
                        select: { selectedImage = image.id }, remove: {
                            let id = image.id
                            style.images.removeAll { $0.id == id }
                            if selectedImage == id { selectedImage = nil }
                        })
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct TagLineControls: View {
    @Binding var style: TagLineStyle
    var inherited: TextDecor
    var label = "name tag line"

    var body: some View {
        TextDecorControls(decor: $style.decor, fontFamily: $style.fontOverride,
                          inherited: inherited.merged(over: style.legacyDecor), sourceLabel: label)
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
                    Label(URL(fileURLWithPath: image.path).lastPathComponent,
                          systemImage: selected ? "checkmark.circle.fill" : "photo")
                        .lineLimit(1)
                }.buttonStyle(.plain)
                Spacer()
                Button("Remove", systemImage: "trash", role: .destructive, action: remove)
                    .labelStyle(.iconOnly).fixedSize()
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
            Slider(value: $image.width, in: 0.05...2) {
                Text("Width").lineLimit(1).fixedSize()
            }
        }
    }
}
